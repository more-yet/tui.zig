//! A private job-control parent. It owns the demo's wait status, gives the demo
//! its own foreground process group, and reports real TSTP stops to the test.
const std = @import("std");

extern "c" fn getsid(pid: std.posix.pid_t) std.posix.pid_t;
extern "c" fn tcgetsid(fd: c_int) std.posix.pid_t;
extern "c" fn tcgetpgrp(fd: c_int) std.posix.pid_t;
extern "c" fn tcsetpgrp(fd: c_int, pid: std.posix.pid_t) c_int;
extern "c" fn setpgid(pid: std.posix.pid_t, group: std.posix.pid_t) c_int;
extern "c" fn fork() std.posix.pid_t;
extern "c" fn waitpid(pid: std.posix.pid_t, status: *c_int, flags: c_int) std.posix.pid_t;
extern "c" fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn _exit(status: c_int) noreturn;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2 or args.len > 4) return error.InvalidArguments;
    if (args.len == 4 and !std.mem.eql(u8, args[3], "--limit-file-size")) return error.InvalidArguments;
    const parent = std.os.linux.getpid();
    if (getsid(0) != parent or tcgetsid(0) != parent or tcgetpgrp(0) != parent) return error.NotPrivateControllingTerminal;
    const path = try init.arena.allocator().dupeZ(u8, args[1]);
    const medium = if (args.len >= 3) try init.arena.allocator().dupeZ(u8, args[2]) else null;
    const argv = [_:null]?[*:0]const u8{ path.ptr, if (medium) |arg| arg.ptr else null };

    var mask = std.posix.sigemptyset();
    inline for (.{ .CHLD, .TSTP, .INT, .TERM, .HUP }) |sig| std.posix.sigaddset(&mask, sig);
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &mask, null);
    const signal_fd = try std.posix.signalfd(-1, &mask, std.os.linux.SFD.NONBLOCK | std.os.linux.SFD.CLOEXEC);
    defer _ = std.os.linux.close(signal_fd);
    const ignore: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.TTOU, &ignore, null);

    // Fork precedes threaded I/O. The initial stop is a barrier: the demo only
    // execs after the test has captured termios and this parent grants the TTY.
    const child = fork();
    if (child < 0) return error.ForkFailed;
    if (child == 0) {
        if (std.os.linux.prctl(@intFromEnum(std.os.linux.PR.SET_PDEATHSIG), @intFromEnum(std.posix.SIG.KILL), 0, 0, 0) != 0) _exit(126);
        if (std.os.linux.getppid() != parent or setpgid(0, 0) != 0) _exit(126);
        const defaults: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 };
        std.posix.sigaction(.TTOU, &defaults, null);
        const empty = std.posix.sigemptyset();
        std.posix.sigprocmask(std.posix.SIG.SETMASK, &empty, null);
        if (args.len == 4) {
            std.posix.setrlimit(.FSIZE, .{ .cur = 0, .max = 0 }) catch _exit(126);
            std.posix.sigaction(.XFSZ, &ignore, null);
        }
        std.posix.kill(std.os.linux.getpid(), .STOP) catch _exit(126);
        _ = execve(path, &argv, init.minimal.environ.block.slice.ptr);
        _exit(126);
    }
    const pidfd_result = std.os.linux.pidfd_open(child, 0);
    if (std.os.linux.errno(pidfd_result) != .SUCCESS) {
        // No wait has run yet, so this child PID is still exclusively owned.
        std.posix.kill(child, .KILL) catch {};
        _ = try waitChild(child, 0);
        return error.PidfdFailed;
    }
    const pidfd: std.posix.fd_t = @intCast(pidfd_result);
    defer _ = std.os.linux.close(pidfd);
    var owned = true;
    defer if (owned) {
        // A failed initial wait may already have reaped the child. Pin identity
        // for cleanup instead of signaling a potentially reusable integer PID.
        _ = std.os.linux.pidfd_send_signal(pidfd, .KILL, null, 0);
        _ = waitChild(child, 0) catch {};
    };
    const initial = (try waitChild(child, std.posix.W.UNTRACED)) orelse return error.MissingStartupStop;
    if (!std.posix.W.IFSTOPPED(initial) or std.posix.W.STOPSIG(initial) != .STOP) return error.MissingStartupStop;
    var message: [64]u8 = undefined;
    try writeAll(try std.fmt.bufPrint(&message, "TUI_TEST_READY pid={d}\n", .{child}));
    var at_prompt = true;

    while (true) {
        if (try waitChild(child, std.posix.W.NOHANG | std.posix.W.UNTRACED)) |status| {
            if (std.posix.W.IFEXITED(status) or std.posix.W.IFSIGNALED(status)) {
                owned = false;
                if (tcsetpgrp(0, parent) != 0) return error.ForegroundFailed;
                if (std.posix.W.IFEXITED(status)) std.process.exit(@intCast(std.posix.W.EXITSTATUS(status)));
                return error.DemoKilled;
            }
            if (!std.posix.W.IFSTOPPED(status) or std.posix.W.STOPSIG(status) != .TSTP) return error.UnexpectedStop;
            if (tcsetpgrp(0, parent) != 0) return error.ForegroundFailed;
            at_prompt = true;
            try writeAll("TUI_TEST_STOPPED\n");
        }

        var descriptors = [_]std.posix.pollfd{
            .{ .fd = signal_fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = if (at_prompt) 0 else -1, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const ready = std.posix.system.poll(&descriptors, descriptors.len, 15_000);
        if (ready == 0) return error.FixtureTimeout;
        if (ready < 0) {
            if (std.posix.errno(ready) == .INTR) continue;
            return error.PollFailed;
        }
        if (descriptors[0].revents & std.posix.POLL.IN != 0) {
            var signals: [8]std.os.linux.signalfd_siginfo = undefined;
            const n = std.posix.system.read(signal_fd, std.mem.asBytes(&signals).ptr, @sizeOf(@TypeOf(signals)));
            if (n <= 0) return error.SignalReadFailed;
            for (signals[0 .. @as(usize, @intCast(n)) / @sizeOf(std.os.linux.signalfd_siginfo)]) |signal| {
                const sig: std.posix.SIG = @enumFromInt(signal.signo);
                if (sig == .CHLD) continue;
                try std.posix.kill(child, sig);
                if (sig != .TSTP and at_prompt) try std.posix.kill(child, .CONT);
            }
        }
        if (descriptors[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP) != 0) {
            var go: [1]u8 = undefined;
            const n = std.posix.system.read(0, &go, go.len);
            if (n != 1 or go[0] != '\n') return error.InvalidGateInput;
            if (tcsetpgrp(0, child) != 0) return error.ForegroundFailed;
            try std.posix.kill(child, .CONT);
            at_prompt = false;
        }
    }
}

fn waitChild(pid: std.posix.pid_t, flags: c_int) !?u32 {
    while (true) {
        var status: c_int = 0;
        const result = waitpid(pid, &status, flags);
        if (result == pid) return @bitCast(status);
        if (result == 0) return null;
        if (std.posix.errno(result) != .INTR) return error.WaitFailed;
    }
}

fn writeAll(bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = std.posix.system.write(1, bytes[offset..].ptr, bytes.len - offset);
        if (n > 0) {
            offset += @intCast(n);
        } else if (std.posix.errno(n) != .INTR) return error.WriteFailed;
    }
}
