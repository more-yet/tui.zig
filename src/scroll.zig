const std = @import("std");
const text_line = @import("text/line.zig");

pub const Range = struct {
    start: usize,
    end: usize,

    pub fn len(self: Range) usize {
        return self.end - self.start;
    }
};

/// Caller-owned row viewport with explicit tail-follow policy.
pub const Viewport = struct {
    top: usize = 0,
    follow: bool = true,

    /// Reconciles append, head eviction, data shrink, and viewport resize.
    pub fn update(self: *Viewport, total_rows: usize, visible_rows: u16, dropped_head_rows: usize) bool {
        const previous = self.*;
        if (total_rows == 0) {
            self.top = 0;
        } else if (self.follow) {
            self.top = maxTop(total_rows, visible_rows);
        } else {
            self.top -|= dropped_head_rows;
            self.top = @min(self.top, maxTop(total_rows, visible_rows));
        }
        return self.top != previous.top or self.follow != previous.follow;
    }

    pub fn setFollow(self: *Viewport, enabled: bool, total_rows: usize, visible_rows: u16) bool {
        const previous = self.*;
        self.follow = enabled;
        _ = self.update(total_rows, visible_rows, 0);
        return self.top != previous.top or self.follow != previous.follow;
    }

    pub fn scrollUp(self: *Viewport, rows: usize, total_rows: usize, visible_rows: u16) bool {
        const previous = self.*;
        _ = self.update(total_rows, visible_rows, 0);
        if (rows != 0) {
            self.follow = false;
            self.top -|= rows;
        }
        return self.top != previous.top or self.follow != previous.follow;
    }

    pub fn scrollDown(self: *Viewport, rows: usize, total_rows: usize, visible_rows: u16) bool {
        const previous = self.*;
        _ = self.update(total_rows, visible_rows, 0);
        if (rows != 0 and !self.follow) {
            self.top = @min(self.top +| rows, maxTop(total_rows, visible_rows));
        }
        return self.top != previous.top or self.follow != previous.follow;
    }

    pub fn pageUp(self: *Viewport, total_rows: usize, visible_rows: u16) bool {
        return self.scrollUp(pageRows(visible_rows), total_rows, visible_rows);
    }

    pub fn pageDown(self: *Viewport, total_rows: usize, visible_rows: u16) bool {
        return self.scrollDown(pageRows(visible_rows), total_rows, visible_rows);
    }

    pub fn home(self: *Viewport, total_rows: usize, visible_rows: u16) bool {
        const previous = self.*;
        _ = self.update(total_rows, visible_rows, 0);
        self.follow = false;
        self.top = 0;
        return self.top != previous.top or self.follow != previous.follow;
    }

    pub fn end(self: *Viewport, total_rows: usize, visible_rows: u16) bool {
        return self.setFollow(true, total_rows, visible_rows);
    }

    pub fn visibleRange(self: *const Viewport, total_rows: usize, visible_rows: u16) Range {
        if (total_rows == 0) return .{ .start = 0, .end = 0 };
        const start = if (self.follow)
            maxTop(total_rows, visible_rows)
        else
            @min(self.top, maxTop(total_rows, visible_rows));
        return .{ .start = start, .end = start + @min(total_rows - start, visible_rows) };
    }
};

pub const AppendResult = struct {
    dropped_rows: usize,
};

pub const AppendError = error{
    NoCapacity,
    LineTooLong,
    InvalidLine,
};

pub const DecodeResult = struct {
    appended_rows: usize = 0,
    dropped_rows: usize = 0,
    invalid_rows: usize = 0,
    overlong_rows: usize = 0,
    unavailable_rows: usize = 0,

    pub fn rejectedRows(self: DecodeResult) usize {
        return (self.invalid_rows +| self.overlong_rows) +| self.unavailable_rows;
    }

    pub fn merge(self: *DecodeResult, other: DecodeResult) void {
        self.appended_rows +|= other.appended_rows;
        self.dropped_rows +|= other.dropped_rows;
        self.invalid_rows +|= other.invalid_rows;
        self.overlong_rows +|= other.overlong_rows;
        self.unavailable_rows +|= other.unavailable_rows;
    }
};

/// Bounded FIFO of complete renderable lines. Borrowed rows expire when their slot is overwritten.
pub fn LineRing(comptime max_line_bytes_value: usize) type {
    return struct {
        pub const max_line_bytes = max_line_bytes_value;

        pub const Slot = struct {
            len: usize = 0,
            bytes: [max_line_bytes]u8 = undefined,
        };

        const Self = @This();

        storage: []Slot,
        head: usize = 0,
        line_count: usize = 0,

        pub fn init(storage: []Slot) Self {
            return .{ .storage = storage };
        }

        pub fn capacity(self: *const Self) usize {
            return self.storage.len;
        }

        pub fn count(self: *const Self) usize {
            return self.line_count;
        }

        pub fn clear(self: *Self) usize {
            const dropped_rows = self.line_count;
            self.head = 0;
            self.line_count = 0;
            return dropped_rows;
        }

        pub fn append(self: *Self, line: []const u8) AppendError!AppendResult {
            if (self.storage.len == 0) return error.NoCapacity;
            if (line.len > max_line_bytes) return error.LineTooLong;
            _ = text_line.measure(line, .narrow) catch return error.InvalidLine;

            const full = self.line_count == self.storage.len;
            const index = if (full) self.head else self.indexOf(self.line_count);
            copyLine(self.storage[index].bytes[0..line.len], line);
            self.storage[index].len = line.len;
            if (full) {
                self.head = nextIndex(self.head, self.storage.len);
            } else {
                self.line_count += 1;
            }
            return .{ .dropped_rows = @intFromBool(full) };
        }

        pub fn get(self: *const Self, index: usize) ?[]const u8 {
            if (index >= self.line_count) return null;
            const slot = &self.storage[self.indexOf(index)];
            return slot.bytes[0..slot.len];
        }

        /// Provider-compatible accessor. `index` must be less than `count()`.
        pub fn row(self: *const Self, index: usize) []const u8 {
            return self.get(index) orelse unreachable;
        }

        fn indexOf(self: *const Self, offset: usize) usize {
            const tail_space = self.storage.len - self.head;
            return if (offset < tail_space) self.head + offset else offset - tail_space;
        }
    };
}

/// Incrementally frames untrusted byte chunks into complete renderable lines.
pub fn LineDecoder(comptime max_line_bytes_value: usize) type {
    return struct {
        pub const max_line_bytes = max_line_bytes_value;
        pub const Ring = LineRing(max_line_bytes);

        const Self = @This();
        const Rejection = enum { invalid, overlong };

        bytes: [max_line_bytes]u8 = undefined,
        len: usize = 0,
        pending_cr: bool = false,
        discarding: ?Rejection = null,

        pub fn feed(self: *Self, ring: *Ring, input: []const u8) DecodeResult {
            var result: DecodeResult = .{};
            for (input) |byte| {
                if (self.discarding) |reason| {
                    if (byte == '\n') {
                        recordRejection(&result, reason);
                        self.reset();
                    }
                    continue;
                }
                if (self.pending_cr) {
                    self.pending_cr = false;
                    if (byte == '\n') {
                        self.appendLine(ring, &result);
                    } else {
                        self.discarding = .invalid;
                    }
                    continue;
                }
                switch (byte) {
                    '\r' => self.pending_cr = true,
                    '\n' => self.appendLine(ring, &result),
                    else => {
                        if (comptime max_line_bytes == 0) {
                            self.discarding = .overlong;
                        } else if (self.len == self.bytes.len) {
                            self.discarding = .overlong;
                        } else {
                            self.bytes[self.len] = byte;
                            self.len += 1;
                        }
                    },
                }
            }
            return result;
        }

        /// Flushes one final unterminated line and reports any incomplete rejected row.
        pub fn finish(self: *Self, ring: *Ring) DecodeResult {
            var result: DecodeResult = .{};
            if (self.discarding) |reason| {
                recordRejection(&result, reason);
                self.reset();
            } else if (self.pending_cr) {
                result.invalid_rows = 1;
                self.reset();
            } else if (self.len != 0) {
                self.appendLine(ring, &result);
            }
            return result;
        }

        pub fn reset(self: *Self) void {
            self.len = 0;
            self.pending_cr = false;
            self.discarding = null;
        }

        fn appendLine(self: *Self, ring: *Ring, result: *DecodeResult) void {
            const appended = ring.append(self.bytes[0..self.len]) catch |err| {
                switch (err) {
                    error.NoCapacity => result.unavailable_rows += 1,
                    error.LineTooLong => result.overlong_rows += 1,
                    error.InvalidLine => result.invalid_rows += 1,
                }
                self.len = 0;
                return;
            };
            result.appended_rows += 1;
            result.dropped_rows += appended.dropped_rows;
            self.len = 0;
        }

        fn recordRejection(result: *DecodeResult, rejection: Rejection) void {
            switch (rejection) {
                .invalid => result.invalid_rows += 1,
                .overlong => result.overlong_rows += 1,
            }
        }
    };
}

fn nextIndex(index: usize, capacity: usize) usize {
    return if (index + 1 == capacity) 0 else index + 1;
}

fn copyLine(destination: []u8, source: []const u8) void {
    if (source.len == 0 or destination.ptr == source.ptr) return;
    const destination_start = @intFromPtr(destination.ptr);
    const source_start = @intFromPtr(source.ptr);
    const separated = if (destination_start < source_start)
        source_start - destination_start >= source.len
    else
        destination_start - source_start >= source.len;
    if (separated) {
        @memcpy(destination, source);
    } else {
        @memmove(destination, source);
    }
}

fn maxTop(total_rows: usize, visible_rows: u16) usize {
    if (total_rows == 0) return 0;
    if (visible_rows == 0) return total_rows - 1;
    return total_rows -| visible_rows;
}

fn pageRows(visible_rows: u16) usize {
    return @max(@as(usize, 1), @as(usize, visible_rows) -| 1);
}

test "viewport preserves browsing position and explicitly follows the tail" {
    var viewport: Viewport = .{};
    try std.testing.expect(viewport.update(10, 3, 0));
    try std.testing.expectEqual(@as(usize, 7), viewport.top);
    try std.testing.expect(viewport.follow);

    try std.testing.expect(viewport.scrollUp(2, 10, 3));
    try std.testing.expectEqual(@as(usize, 5), viewport.top);
    try std.testing.expect(!viewport.follow);
    try std.testing.expect(!viewport.update(11, 3, 0));
    try std.testing.expectEqual(@as(usize, 5), viewport.top);
    try std.testing.expect(viewport.update(9, 3, 2));
    try std.testing.expectEqual(@as(usize, 3), viewport.top);

    try std.testing.expect(viewport.scrollDown(100, 9, 3));
    try std.testing.expectEqual(@as(usize, 6), viewport.top);
    try std.testing.expect(!viewport.follow);
    try std.testing.expect(viewport.end(9, 3));
    try std.testing.expect(viewport.follow);
    try std.testing.expect(viewport.update(9, 5, 0));
    try std.testing.expectEqual(@as(usize, 4), viewport.top);
    try std.testing.expectEqual(Range{ .start = 4, .end = 9 }, viewport.visibleRange(9, 5));
}

test "viewport zero-height and empty states remain bounded" {
    var viewport: Viewport = .{};
    _ = viewport.update(4, 0, 0);
    try std.testing.expectEqual(@as(usize, 3), viewport.top);
    try std.testing.expectEqual(Range{ .start = 3, .end = 3 }, viewport.visibleRange(4, 0));
    try std.testing.expect(viewport.home(4, 0));
    try std.testing.expectEqual(@as(usize, 0), viewport.top);
    try std.testing.expect(!viewport.follow);
    _ = viewport.update(0, 0, 4);
    try std.testing.expectEqual(Range{ .start = 0, .end = 0 }, viewport.visibleRange(0, 0));
}

test "line ring wraps, validates, and reports head eviction" {
    const Ring = LineRing(8);
    var slots: [3]Ring.Slot = undefined;
    var ring = Ring.init(&slots);
    try std.testing.expectEqual(@as(usize, 0), (try ring.append("one")).dropped_rows);
    _ = try ring.append("two");
    _ = try ring.append("");
    try std.testing.expectEqualStrings("", ring.get(2).?);
    try std.testing.expectEqual(@as(usize, 1), (try ring.append("four")).dropped_rows);
    try std.testing.expectEqualStrings("two", ring.row(0));
    try std.testing.expectEqualStrings("", ring.row(1));
    try std.testing.expectEqualStrings("four", ring.row(2));

    try std.testing.expectError(error.LineTooLong, ring.append("123456789"));
    try std.testing.expectError(error.InvalidLine, ring.append("bad\x1b"));
    try std.testing.expectError(error.InvalidLine, ring.append("\xff"));
    try std.testing.expectEqualStrings("two", ring.row(0));

    const borrowed = ring.row(0);
    try std.testing.expectEqual(@as(usize, 1), (try ring.append(borrowed)).dropped_rows);
    try std.testing.expectEqualStrings("two", ring.row(2));

    const LongRing = LineRing(64);
    var long_slots: [1]LongRing.Slot = undefined;
    var long_ring = LongRing.init(&long_slots);
    var oversized_grapheme: [49]u8 = undefined;
    oversized_grapheme[0] = 'a';
    var byte_index: usize = 1;
    while (byte_index < oversized_grapheme.len) : (byte_index += 2) {
        oversized_grapheme[byte_index] = 0xCC;
        oversized_grapheme[byte_index + 1] = 0x81;
    }
    try std.testing.expectError(error.InvalidLine, long_ring.append(&oversized_grapheme));

    try std.testing.expectEqual(@as(usize, 3), ring.clear());
    try std.testing.expectEqual(@as(usize, 0), ring.count());
    try std.testing.expect(ring.get(0) == null);
}

test "line ring handles zero slots and zero-byte lines deterministically" {
    const EmptyRing = LineRing(0);
    var no_slots: [0]EmptyRing.Slot = .{};
    var unavailable = EmptyRing.init(&no_slots);
    try std.testing.expectError(error.NoCapacity, unavailable.append(""));

    var slots: [1]EmptyRing.Slot = undefined;
    var empty_lines = EmptyRing.init(&slots);
    _ = try empty_lines.append("");
    try std.testing.expectEqualStrings("", empty_lines.row(0));
    try std.testing.expectError(error.LineTooLong, empty_lines.append("x"));
}

test "line decoder preserves fragmented UTF-8 CRLF and final rows" {
    const Decoder = LineDecoder(8);
    var slots: [2]Decoder.Ring.Slot = undefined;
    var ring = Decoder.Ring.init(&slots);
    var decoder: Decoder = .{};
    var result: DecodeResult = .{};

    result.merge(decoder.feed(&ring, "one\r"));
    result.merge(decoder.feed(&ring, "\n\xC3"));
    result.merge(decoder.feed(&ring, "\xA9\nlast"));
    result.merge(decoder.finish(&ring));

    try std.testing.expectEqual(@as(usize, 3), result.appended_rows);
    try std.testing.expectEqual(@as(usize, 1), result.dropped_rows);
    try std.testing.expectEqual(@as(usize, 0), result.rejectedRows());
    try std.testing.expectEqualStrings("\xC3\xA9", ring.row(0));
    try std.testing.expectEqualStrings("last", ring.row(1));
}

test "line decoder rejects and resynchronizes unsafe rows" {
    const Decoder = LineDecoder(4);
    var slots: [4]Decoder.Ring.Slot = undefined;
    var ring = Decoder.Ring.init(&slots);
    var decoder: Decoder = .{};
    var result = decoder.feed(&ring, "bad\x1b\n12345\nok\nbad\rx\n\xff\n1234\r\n");
    result.merge(decoder.feed(&ring, "tail\r"));
    result.merge(decoder.finish(&ring));

    try std.testing.expectEqual(@as(usize, 2), result.appended_rows);
    try std.testing.expectEqual(@as(usize, 4), result.invalid_rows);
    try std.testing.expectEqual(@as(usize, 1), result.overlong_rows);
    try std.testing.expectEqual(@as(usize, 0), result.unavailable_rows);
    try std.testing.expectEqualStrings("ok", ring.row(0));
    try std.testing.expectEqualStrings("1234", ring.row(1));

    const Unavailable = LineDecoder(0);
    var no_slots: [0]Unavailable.Ring.Slot = .{};
    var unavailable_ring = Unavailable.Ring.init(&no_slots);
    var unavailable: Unavailable = .{};
    const unavailable_result = unavailable.feed(&unavailable_ring, "\n");
    try std.testing.expectEqual(@as(usize, 1), unavailable_result.unavailable_rows);
}
