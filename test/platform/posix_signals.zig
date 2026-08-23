const std = @import("std");
const builtin = @import("builtin");
const tui = @import("tui");

test "POSIX signal source restores the owner mask and enforces singleton ownership" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var before: std.posix.sigset_t = undefined;
    std.posix.sigprocmask(std.posix.SIG.BLOCK, null, &before);
    var source = try tui.runtime.SignalSource.init(std.testing.io, .{
        .resize = false,
        .interrupt = true,
        .terminate = false,
        .suspend_resume = false,
    });
    var active: std.posix.sigset_t = undefined;
    std.posix.sigprocmask(std.posix.SIG.BLOCK, null, &active);
    try std.testing.expect(std.posix.sigismember(&active, .INT));
    try std.testing.expectError(error.AlreadyInstalled, tui.runtime.SignalSource.init(std.testing.io, .{
        .resize = false,
        .interrupt = true,
        .terminate = false,
        .suspend_resume = false,
    }));
    source.deinit();

    var after: std.posix.sigset_t = undefined;
    std.posix.sigprocmask(std.posix.SIG.BLOCK, null, &after);
    try std.testing.expectEqual(std.posix.sigismember(&before, .INT), std.posix.sigismember(&after, .INT));
}

test "POSIX runtime coalesces signals with priority and retries callbacks" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var source = try tui.runtime.SignalSource.init(std.testing.io, .{ .resize = false });
    defer source.deinit();
    const pipe = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const input = std.Io.File{ .handle = pipe[0], .flags = .{ .nonblocking = true } };
    const producer = std.Io.File{ .handle = pipe[1], .flags = .{ .nonblocking = true } };
    defer input.close(std.testing.io);
    defer producer.close(std.testing.io);
    var read_buffer: [8]u8 = undefined;
    var timers: [0]tui.runtime.TimerSlot = .{};
    var runtime = try tui.runtime.Posix.init(std.testing.io, input, &read_buffer, &timers, .{ .signals = &source });
    defer runtime.deinit();

    const pid = std.posix.system.getpid();
    try std.posix.kill(pid, .INT);
    try std.posix.kill(pid, .TERM);

    const Sink = struct {
        values: [4]tui.runtime.Signal = undefined,
        count: usize = 0,
        fail_once: bool = true,

        pub fn emit(self: *@This(), event: tui.runtime.Event) !void {
            if (event != .signal) return;
            if (self.fail_once) {
                self.fail_once = false;
                return error.ExpectedFailure;
            }
            self.values[self.count] = event.signal;
            self.count += 1;
        }
    };
    var sink: Sink = .{};
    try std.testing.expectError(error.ExpectedFailure, runtime.step(&sink));
    try runtime.step(&sink);
    try runtime.step(&sink);
    try std.posix.kill(pid, .TSTP);
    try runtime.step(&sink);
    try std.posix.kill(pid, .CONT);
    try runtime.step(&sink);
    try std.testing.expectEqualSlices(tui.runtime.Signal, &.{
        .terminate,
        .interrupt,
        .suspend_requested,
        .continued,
    }, sink.values[0..sink.count]);
}
