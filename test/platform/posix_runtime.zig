const std = @import("std");
const builtin = @import("builtin");
const tui = @import("tui");

extern fn openpty(
    master: *c_int,
    slave: *c_int,
    name: ?[*]u8,
    termios: ?*const std.posix.termios,
    winsize: ?*const std.posix.winsize,
) c_int;

test "POSIX runtime preserves input and EOF order" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const pipe = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const input = std.Io.File{ .handle = pipe[0], .flags = .{ .nonblocking = true } };
    const producer = std.Io.File{ .handle = pipe[1], .flags = .{ .nonblocking = true } };
    defer input.close(std.testing.io);
    try producer.writeStreamingAll(std.testing.io, "a\x1b");
    producer.close(std.testing.io);

    var read_buffer: [32]u8 = undefined;
    var timers: [1]tui.runtime.TimerSlot = undefined;
    var runtime = try tui.runtime.Posix.init(std.testing.io, input, &read_buffer, &timers, .{});
    defer runtime.deinit();
    const Sink = struct {
        text: [8]u8 = undefined,
        text_len: usize = 0,
        escapes: usize = 0,
        eof: usize = 0,

        pub fn emit(self: *@This(), event: tui.runtime.Event) !void {
            switch (event) {
                .input => |value| switch (value) {
                    .text => |bytes| {
                        @memcpy(self.text[self.text_len..][0..bytes.len], bytes);
                        self.text_len += bytes.len;
                    },
                    .key => |key| switch (key.code) {
                        .escape => self.escapes += 1,
                        else => {},
                    },
                    else => {},
                },
                .eof => self.eof += 1,
                else => {},
            }
        }
    };
    var sink: Sink = .{};
    try runtime.step(&sink);
    try std.testing.expectEqualStrings("a", sink.text[0..sink.text_len]);
    try std.testing.expectEqual(@as(usize, 0), sink.escapes);
    try runtime.step(&sink);
    try std.testing.expectEqual(@as(usize, 1), sink.escapes);
    try std.testing.expectEqual(@as(usize, 0), sink.eof);
    try runtime.step(&sink);
    try std.testing.expectEqual(@as(usize, 1), sink.eof);
}

test "POSIX runtime times out incomplete parser input" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const pipe = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const input = std.Io.File{ .handle = pipe[0], .flags = .{ .nonblocking = true } };
    const producer = std.Io.File{ .handle = pipe[1], .flags = .{ .nonblocking = true } };
    defer input.close(std.testing.io);
    defer producer.close(std.testing.io);
    try producer.writeStreamingAll(std.testing.io, "\x1b");

    var read_buffer: [8]u8 = undefined;
    var timers: [0]tui.runtime.TimerSlot = .{};
    var runtime = try tui.runtime.Posix.init(std.testing.io, input, &read_buffer, &timers, .{
        .input_timeouts = .{ .escape = .fromMilliseconds(1) },
    });
    defer runtime.deinit();
    const Sink = struct {
        escapes: usize = 0,

        pub fn emit(self: *@This(), event: tui.runtime.Event) !void {
            if (event == .input) switch (event.input) {
                .key => |key| switch (key.code) {
                    .escape => self.escapes += 1,
                    else => {},
                },
                else => {},
            };
        }
    };
    var sink: Sink = .{};
    try runtime.step(&sink);
    try std.testing.expectEqual(@as(usize, 1), sink.escapes);
}

test "POSIX runtime bounds incomplete sequences by default" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const pipe = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const input = std.Io.File{ .handle = pipe[0], .flags = .{ .nonblocking = true } };
    const producer = std.Io.File{ .handle = pipe[1], .flags = .{ .nonblocking = true } };
    defer input.close(std.testing.io);
    defer producer.close(std.testing.io);
    try producer.writeStreamingAll(std.testing.io, "\x1b[");

    var read_buffer: [8]u8 = undefined;
    var timers: [0]tui.runtime.TimerSlot = .{};
    var runtime = try tui.runtime.Posix.init(std.testing.io, input, &read_buffer, &timers, .{});
    defer runtime.deinit();
    const Sink = struct {
        malformed: usize = 0,

        pub fn emit(self: *@This(), event: tui.runtime.Event) !void {
            if (event == .input and event.input == .malformed) self.malformed += 1;
        }
    };
    var sink: Sink = .{};
    try runtime.step(&sink);
    try std.testing.expectEqual(@as(usize, 1), sink.malformed);
}

test "POSIX runtime coalesces wakeups and retries a failed timer callback" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const pipe = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const input = std.Io.File{ .handle = pipe[0], .flags = .{ .nonblocking = true } };
    const producer = std.Io.File{ .handle = pipe[1], .flags = .{ .nonblocking = true } };
    defer input.close(std.testing.io);
    defer producer.close(std.testing.io);

    var read_buffer: [8]u8 = undefined;
    var timers: [2]tui.runtime.TimerSlot = undefined;
    var runtime = try tui.runtime.Posix.init(std.testing.io, input, &read_buffer, &timers, .{});
    defer runtime.deinit();
    const notifier = runtime.notifier();
    for (0..10_000) |_| try notifier.wake();

    const Sink = struct {
        wakes: usize = 0,
        timer_id: ?tui.runtime.TimerId = null,
        fail_timer: bool = false,

        pub fn emit(self: *@This(), event: tui.runtime.Event) !void {
            switch (event) {
                .wakeup => self.wakes += 1,
                .timer => |timer| {
                    if (self.fail_timer) {
                        self.fail_timer = false;
                        return error.ExpectedFailure;
                    }
                    self.timer_id = timer.id;
                },
                else => {},
            }
        }
    };
    var sink: Sink = .{};
    try runtime.step(&sink);
    try std.testing.expectEqual(@as(usize, 1), sink.wakes);

    _ = try runtime.setTimer(42, runtime.now());
    sink.fail_timer = true;
    try std.testing.expectError(error.ExpectedFailure, runtime.step(&sink));
    try std.testing.expectEqual(@as(usize, 1), runtime.timerCount());
    try runtime.step(&sink);
    try std.testing.expectEqual(@as(?tui.runtime.TimerId, 42), sink.timer_id);
    try std.testing.expectEqual(@as(usize, 0), runtime.timerCount());
}

test "POSIX runtime preserves timer mutations made by callbacks" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const pipe = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const input = std.Io.File{ .handle = pipe[0], .flags = .{ .nonblocking = true } };
    const producer = std.Io.File{ .handle = pipe[1], .flags = .{ .nonblocking = true } };
    defer input.close(std.testing.io);
    defer producer.close(std.testing.io);

    var read_buffer: [8]u8 = undefined;
    var timers: [2]tui.runtime.TimerSlot = undefined;
    var runtime = try tui.runtime.Posix.init(std.testing.io, input, &read_buffer, &timers, .{});
    defer runtime.deinit();
    const Sink = struct {
        runtime: *tui.runtime.Posix,
        replacement: ?std.Io.Clock.Timestamp = null,

        pub fn emit(self: *@This(), event: tui.runtime.Event) !void {
            if (event != .timer) return;
            if (event.timer.id == 1) {
                try std.testing.expect(self.runtime.cancelTimer(1));
            } else if (event.timer.id == 2) {
                _ = try self.runtime.setTimer(2, self.replacement.?);
            }
        }
    };
    var sink = Sink{ .runtime = &runtime };

    _ = try runtime.setTimer(1, runtime.now());
    try runtime.step(&sink);
    try std.testing.expectEqual(@as(usize, 0), runtime.timerCount());

    _ = try runtime.setTimer(2, runtime.now());
    var replacement = runtime.now();
    replacement.raw.nanoseconds += std.time.ns_per_s;
    sink.replacement = replacement;
    try runtime.step(&sink);
    try std.testing.expectEqual(@as(usize, 1), runtime.timerCount());
}

test "POSIX runtime probes requested PTY resize and ignores unchanged size" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var master_fd: c_int = -1;
    var slave_fd: c_int = -1;
    var winsize = std.posix.winsize{ .row = 5, .col = 10, .xpixel = 0, .ypixel = 0 };
    if (openpty(&master_fd, &slave_fd, null, null, &winsize) != 0) return error.OpenPtyFailed;
    const master = std.Io.File{ .handle = master_fd, .flags = .{ .nonblocking = false } };
    const slave = std.Io.File{ .handle = slave_fd, .flags = .{ .nonblocking = false } };
    defer master.close(std.testing.io);
    defer slave.close(std.testing.io);

    var read_buffer: [8]u8 = undefined;
    var timers: [1]tui.runtime.TimerSlot = undefined;
    var runtime = try tui.runtime.Posix.init(std.testing.io, master, &read_buffer, &timers, .{
        .resize = .{ .file = slave, .initial_size = .{ .width = 10, .height = 5 } },
    });
    defer runtime.deinit();
    winsize.row = 8;
    winsize.col = 20;
    _ = try std.testing.io.operate(.{ .device_io_control = .{
        .file = slave,
        .code = std.posix.T.IOCSWINSZ,
        .arg = &winsize,
    } });
    try runtime.requestResize();

    const Sink = struct {
        runtime: *tui.runtime.Posix,
        resize_count: usize = 0,
        size: tui.render.Size = .{ .width = 1, .height = 1 },
        timer_count: usize = 0,
        request_again: bool = true,

        pub fn emit(self: *@This(), event: tui.runtime.Event) !void {
            switch (event) {
                .resize => |size| {
                    self.resize_count += 1;
                    self.size = size;
                    if (self.request_again) {
                        self.request_again = false;
                        try self.runtime.requestResize();
                    }
                },
                .timer => self.timer_count += 1,
                else => {},
            }
        }
    };
    var sink: Sink = .{ .runtime = &runtime };
    try runtime.step(&sink);
    try std.testing.expectEqual(tui.render.Size{ .width = 20, .height = 8 }, sink.size);

    winsize.row = 9;
    winsize.col = 30;
    _ = try std.testing.io.operate(.{ .device_io_control = .{
        .file = slave,
        .code = std.posix.T.IOCSWINSZ,
        .arg = &winsize,
    } });
    _ = try runtime.setTimer(1, runtime.now());
    try runtime.step(&sink);
    try std.testing.expectEqual(tui.render.Size{ .width = 30, .height = 9 }, sink.size);
    try std.testing.expectEqual(@as(usize, 2), sink.resize_count);
    try std.testing.expectEqual(@as(usize, 0), sink.timer_count);
    try runtime.step(&sink);
    try std.testing.expectEqual(@as(usize, 1), sink.timer_count);
}

test "POSIX runtime reports caller-owned descriptor readiness" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const input_pipe = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const input = std.Io.File{ .handle = input_pipe[0], .flags = .{ .nonblocking = true } };
    const input_writer = std.Io.File{ .handle = input_pipe[1], .flags = .{ .nonblocking = true } };
    defer input.close(std.testing.io);
    defer input_writer.close(std.testing.io);
    const source_pipe = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const source = std.Io.File{ .handle = source_pipe[0], .flags = .{ .nonblocking = true } };
    const source_writer = std.Io.File{ .handle = source_pipe[1], .flags = .{ .nonblocking = true } };
    defer source.close(std.testing.io);
    defer source_writer.close(std.testing.io);
    try source_writer.writeStreamingAll(std.testing.io, "ready");

    var read_buffer: [8]u8 = undefined;
    var timers: [0]tui.runtime.TimerSlot = .{};
    var runtime = try tui.runtime.Posix.init(std.testing.io, input, &read_buffer, &timers, .{});
    defer runtime.deinit();
    const sources = [_]tui.runtime.PollSource{.{ .file = source, .interest = .{ .read = true } }};
    var poll_storage: [4]tui.runtime.PollSlot = undefined;
    const Sink = struct {
        ready: ?tui.runtime.ReadyEvent = null,

        pub fn emit(self: *@This(), event: tui.runtime.Event) !void {
            if (event == .ready) self.ready = event.ready;
        }
    };
    var sink: Sink = .{};
    try runtime.stepWithSources(&sources, &poll_storage, &sink);
    try std.testing.expectEqual(@as(usize, 0), sink.ready.?.source_index);
    try std.testing.expect(sink.ready.?.readable);
    try std.testing.expect(!sink.ready.?.writable);
    try std.testing.expectError(
        error.PollStorageTooSmall,
        runtime.stepWithSources(&sources, poll_storage[0..3], &sink),
    );
}

test "POSIX runtime alternates ready sources with terminal input" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const input_pipe = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const input = std.Io.File{ .handle = input_pipe[0], .flags = .{ .nonblocking = true } };
    const input_writer = std.Io.File{ .handle = input_pipe[1], .flags = .{ .nonblocking = true } };
    defer input.close(std.testing.io);
    defer input_writer.close(std.testing.io);
    const source_pipe = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const source = std.Io.File{ .handle = source_pipe[0], .flags = .{ .nonblocking = true } };
    const source_writer = std.Io.File{ .handle = source_pipe[1], .flags = .{ .nonblocking = true } };
    defer source.close(std.testing.io);
    defer source_writer.close(std.testing.io);
    try input_writer.writeStreamingAll(std.testing.io, "i");
    try source_writer.writeStreamingAll(std.testing.io, "s");

    var read_buffer: [8]u8 = undefined;
    var timers: [0]tui.runtime.TimerSlot = .{};
    var runtime = try tui.runtime.Posix.init(std.testing.io, input, &read_buffer, &timers, .{});
    defer runtime.deinit();
    const sources = [_]tui.runtime.PollSource{.{ .file = source, .interest = .{ .read = true } }};
    var poll_storage: [4]tui.runtime.PollSlot = undefined;
    const Sink = struct {
        ready: usize = 0,
        input: usize = 0,

        pub fn emit(self: *@This(), event: tui.runtime.Event) !void {
            switch (event) {
                .ready => self.ready += 1,
                .input => self.input += 1,
                else => {},
            }
        }
    };
    var sink: Sink = .{};
    try runtime.stepWithSources(&sources, &poll_storage, &sink);
    try runtime.stepWithSources(&sources, &poll_storage, &sink);
    try std.testing.expectEqual(@as(usize, 1), sink.ready);
    try std.testing.expectEqual(@as(usize, 1), sink.input);
}
