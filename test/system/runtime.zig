const std = @import("std");
const tui = @import("tui");
const expect = std.testing.expect;

extern "c" fn fork() std.posix.pid_t;
extern "c" fn setpgid(pid: std.posix.pid_t, group: std.posix.pid_t) c_int;
extern "c" fn waitpid(pid: std.posix.pid_t, status: *c_int, flags: c_int) std.posix.pid_t;
extern "c" fn alarm(seconds: c_uint) c_uint;
extern "c" fn _exit(status: c_int) noreturn;

const Scenario = enum { interrupt, terminate, suspend_resume };

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.InvalidArguments;
    const scenario = std.meta.stringToEnum(Scenario, args[1]) orelse return error.InvalidArguments;
    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = alarm(10);
        run(init.io, scenario) catch |err| {
            std.debug.print("runtime {s}: {s}\n", .{ args[1], @errorName(err) });
            _exit(1);
        };
        _exit(0);
    }
    var reaped = false;
    defer if (!reaped) {
        std.posix.kill(pid, .KILL) catch {};
        var status: c_int = 0;
        _ = waitpid(pid, &status, 0);
    };
    const result = std.os.linux.pidfd_open(pid, 0);
    if (std.os.linux.errno(result) != .SUCCESS) return error.PidfdFailed;
    const pidfd: std.posix.fd_t = @intCast(result);
    defer _ = std.os.linux.close(pidfd);
    if (scenario == .suspend_resume) {
        var status: c_int = 0;
        try expect(waitpid(pid, &status, std.posix.W.UNTRACED) == pid);
        reaped = !std.posix.W.IFSTOPPED(@intCast(status));
        try expect(std.posix.W.IFSTOPPED(@intCast(status)));
        try expect(std.posix.W.STOPSIG(@intCast(status)) == .TSTP);
        try std.posix.kill(pid, .CONT);
    }
    var slots = [_]std.posix.pollfd{.{ .fd = pidfd, .events = std.posix.POLL.IN, .revents = 0 }};
    if (std.posix.system.poll(&slots, 1, 5000) != 1) return error.ChildExitTimeout;
    var status: c_int = 0;
    try expect(waitpid(pid, &status, 0) == pid);
    reaped = true;
    try expect(std.posix.W.IFEXITED(@intCast(status)) and std.posix.W.EXITSTATUS(@intCast(status)) == 0);
}

fn run(io: std.Io, scenario: Scenario) !void {
    if (setpgid(0, 0) != 0) return error.ProcessGroupFailed;
    var signals = try tui.runtime.SignalSource.init(io, .{ .resize = false });
    defer signals.deinit() catch unreachable;
    const fds = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const reader: std.Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = true } };
    const writer: std.Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = true } };
    defer reader.close(io);
    defer writer.close(io);
    var bytes: [32]u8 = undefined;
    var timers: [0]tui.runtime.TimerSlot = .{};
    var runtime = try tui.runtime.Posix.init(io, reader, &bytes, &timers, .{ .signals = &signals });
    defer runtime.deinit();
    try std.posix.raise(switch (scenario) {
        .interrupt => .INT,
        .terminate => .TERM,
        .suspend_resume => .TSTP,
    });
    try std.testing.expectEqual(switch (scenario) {
        .interrupt => tui.runtime.Signal.interrupt,
        .terminate => .terminate,
        .suspend_resume => .suspend_requested,
    }, (try runtime.step()).signal);
    if (scenario == .suspend_resume) {
        try signals.suspendProcess();
        try std.testing.expectEqual(tui.runtime.Signal.continued, (try runtime.step()).signal);
    }
}
