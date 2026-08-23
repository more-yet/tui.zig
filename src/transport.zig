const std = @import("std");
const builtin = @import("builtin");

pub const InitError = error{CapacityTooLarge};
pub const SendError = error{Full};

/// A bounded wait-free queue for exactly one producer and one consumer.
/// The queue and caller-owned storage must stay at fixed addresses while shared.
/// Message pointers remain caller-owned and self-relative pointers are not move safe.
pub fn Spsc(comptime Message: type) type {
    return struct {
        const Self = @This();

        const Producer = struct {
            published: std.atomic.Value(usize) = .init(0),
            count: usize = 0,
            index: usize = 0,
            cached_consumed: usize = 0,
        };

        const Consumer = struct {
            published: std.atomic.Value(usize) = .init(0),
            count: usize = 0,
            index: usize = 0,
            cached_produced: usize = 0,
        };

        storage: []Message,
        producer: Producer align(std.atomic.cache_line) = .{},
        consumer: Consumer align(std.atomic.cache_line) = .{},

        pub fn init(storage: []Message) InitError!Self {
            if (storage.len > std.math.maxInt(usize) / 2) return error.CapacityTooLarge;
            return .{ .storage = storage };
        }

        pub inline fn capacity(self: *const Self) usize {
            return self.storage.len;
        }

        /// Publishes immediately or returns `Full`; it never waits or retries.
        pub inline fn trySend(self: *Self, message: Message) SendError!void {
            const producer = &self.producer;
            if (producer.count -% producer.cached_consumed == self.storage.len) {
                producer.cached_consumed = self.consumer.published.load(.acquire);
                if (producer.count -% producer.cached_consumed == self.storage.len) return error.Full;
            }

            self.storage[producer.index] = message;
            producer.index += 1;
            if (producer.index == self.storage.len) producer.index = 0;
            producer.count +%= 1;
            producer.published.store(producer.count, .release);
        }

        /// Receives immediately or returns `null`; it never waits or retries.
        pub inline fn tryReceive(self: *Self) ?Message {
            const consumer = &self.consumer;
            if (consumer.count == consumer.cached_produced) {
                consumer.cached_produced = self.producer.published.load(.acquire);
                if (consumer.count == consumer.cached_produced) return null;
            }

            const message = self.storage[consumer.index];
            consumer.index += 1;
            if (consumer.index == self.storage.len) consumer.index = 0;
            consumer.count +%= 1;
            consumer.published.store(consumer.count, .release);
            return message;
        }
    };
}

test "SPSC queue uses every slot and preserves FIFO across wraps" {
    var storage: [3]u32 = undefined;
    var queue = try Spsc(u32).init(&storage);
    try std.testing.expectEqual(@as(usize, 3), queue.capacity());
    try queue.trySend(10);
    try queue.trySend(20);
    try queue.trySend(30);
    try std.testing.expectError(error.Full, queue.trySend(40));
    try std.testing.expectEqual(@as(?u32, 10), queue.tryReceive());
    try queue.trySend(40);
    try std.testing.expectEqual(@as(?u32, 20), queue.tryReceive());
    try std.testing.expectEqual(@as(?u32, 30), queue.tryReceive());
    try std.testing.expectEqual(@as(?u32, 40), queue.tryReceive());
    try std.testing.expectEqual(@as(?u32, null), queue.tryReceive());
}

test "SPSC zero-capacity queue is deterministic" {
    var storage: [0]u8 = .{};
    var queue = try Spsc(u8).init(&storage);
    try std.testing.expectError(error.Full, queue.trySend(1));
    try std.testing.expectEqual(@as(?u8, null), queue.tryReceive());
}

test "SPSC counters remain correct across integer wrap" {
    var storage: [2]u8 = undefined;
    var queue = try Spsc(u8).init(&storage);
    const start = std.math.maxInt(usize) - 1;
    queue.producer.count = start;
    queue.producer.cached_consumed = start;
    queue.producer.published.store(start, .monotonic);
    queue.consumer.count = start;
    queue.consumer.cached_produced = start;
    queue.consumer.published.store(start, .monotonic);

    try queue.trySend(1);
    try queue.trySend(2);
    try std.testing.expectError(error.Full, queue.trySend(3));
    try std.testing.expectEqual(@as(?u8, 1), queue.tryReceive());
    try std.testing.expectEqual(@as(?u8, 2), queue.tryReceive());
}

test "SPSC transfers ordered messages between threads" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const Message = struct {
        sequence: u64,
        inverse: u64,
    };
    const Queue = Spsc(Message);
    const count = 200_000;
    var storage: [7]Message = undefined;
    var queue = try Queue.init(&storage);

    const ProducerThread = struct {
        fn run(target: *Queue) void {
            for (0..count) |sequence| {
                const value: u64 = @intCast(sequence);
                while (true) {
                    target.trySend(.{ .sequence = value, .inverse = ~value }) catch {
                        std.atomic.spinLoopHint();
                        continue;
                    };
                    break;
                }
            }
        }
    };
    const producer = try std.Thread.spawn(.{}, ProducerThread.run, .{&queue});
    for (0..count) |sequence| {
        const message = while (true) {
            if (queue.tryReceive()) |value| break value;
            std.atomic.spinLoopHint();
        };
        const expected: u64 = @intCast(sequence);
        try std.testing.expectEqual(expected, message.sequence);
        try std.testing.expectEqual(~expected, message.inverse);
    }
    producer.join();
}
