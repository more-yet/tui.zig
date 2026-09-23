//! Fresh processes keep fork, signal dispositions, and syscall fault injection
//! independent of the Zig test runner's threads and other contract tests.
const std = @import("std");
const tui = @import("tui");
const linux = std.os.linux;
const testing = std.testing;

extern "c" fn getsid(pid: std.posix.pid_t) std.posix.pid_t;
extern "c" fn tcgetsid(fd: c_int) std.posix.pid_t;
extern "c" fn tcgetpgrp(fd: c_int) std.posix.pid_t;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.InvalidArguments;
    if (std.mem.eql(u8, args[1], "child")) {
        const pid = linux.getpid();
        try testing.expect(getsid(0) == pid and tcgetsid(0) == pid and tcgetpgrp(0) == pid);
        inline for (0..3) |fd| {
            const flags = std.posix.system.fcntl(fd, std.posix.F.GETFD, @as(c_int, 0));
            try testing.expect(std.posix.errno(flags) == .SUCCESS and flags & std.posix.FD_CLOEXEC == 0);
        }
        try testing.expectEqual(std.posix.E.BADF, std.posix.errno(std.posix.system.fcntl(100, std.posix.F.GETFD, @as(c_int, 0))));
        return;
    }

    const scenario = std.meta.stringToEnum(enum { spawn, closed_stdio, close_range_denied, close_range_unavailable, auto_reap, no_child_wait }, args[1]) orelse return error.InvalidArguments;
    const null_fd = linux.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(null_fd) != .SUCCESS) return error.OpenFailed;
    defer _ = linux.close(@intCast(null_fd));
    // An intentionally inheritable descriptor above stdio tests exec isolation.
    const marker = std.posix.system.fcntl(@intCast(null_fd), std.posix.F.DUPFD, @as(c_int, 100));
    if (marker != 100) return error.DescriptorFixtureFailed;
    defer _ = linux.close(marker);
    switch (scenario) {
        .close_range_denied => try denyCloseRange(.ACCES),
        .close_range_unavailable => try denyCloseRange(.NOSYS),
        .auto_reap, .no_child_wait => {
            const action: std.posix.Sigaction = .{
                .handler = .{ .handler = if (scenario == .auto_reap) std.posix.SIG.IGN else std.posix.SIG.DFL },
                .mask = std.posix.sigemptyset(),
                .flags = if (scenario == .no_child_wait) std.posix.SA.NOCLDWAIT else 0,
            };
            std.posix.sigaction(.CHLD, &action, null);
        },
        .closed_stdio => for (0..3) |fd| {
            _ = linux.close(@intCast(fd));
        },
        .spawn => {},
    }

    var process = tui.subprocess.PtyProcess.init(init.io);
    defer {
        if (process.state() == .running) process.killAndWait(deadline(init.io)) catch |err| {
            std.debug.panic("owned child cleanup failed: {s}", .{@errorName(err)});
        };
        process.deinit() catch unreachable;
    }
    var pointers: [3]?[*:0]const u8 = undefined;
    var bytes: [4096]u8 = undefined;
    var storage = tui.subprocess.SpawnStorage.init(&pointers, &bytes);
    const command: tui.subprocess.Command = .{ .argv = &.{ args[0], "child" }, .environ = init.minimal.environ };
    const options: tui.subprocess.PtyOptions = .{ .size = .{ .width = 20, .height = 4 } };
    switch (scenario) {
        .auto_reap, .no_child_wait => {
            try testing.expectError(error.IncompatibleSignalPolicy, process.spawnBeforeThreads(command, &storage, options));
            try testing.expectEqual(tui.subprocess.PtyState.empty, process.state());
            try testing.expectError(error.NoChild, process.pid());
        },
        .close_range_denied, .close_range_unavailable => {
            try testing.expectError(error.ChildSetupFailed, process.spawnBeforeThreads(command, &storage, options));
            try testing.expect(process.isReaped());
        },
        .spawn, .closed_stdio => {
            try process.spawnBeforeThreads(command, &storage, options);
            const pidfd_result = linux.pidfd_open(try process.pid(), 0);
            if (linux.errno(pidfd_result) != .SUCCESS) return error.PidfdFailed;
            const pidfd: std.posix.fd_t = @intCast(pidfd_result);
            defer _ = linux.close(pidfd);
            var fd = [_]std.posix.pollfd{.{ .fd = pidfd, .events = std.posix.POLL.IN, .revents = 0 }};
            if (std.posix.system.poll(&fd, 1, 5000) != 1) return error.ChildExitTimeout;
            const event = (try process.poll()) orelse return error.MissingExit;
            try testing.expect(event == .exit and event.exit == .exited and event.exit.exited == 0);
        },
    }
}

fn deadline(io: std.Io) std.Io.Clock.Timestamp {
    return .{ .clock = .awake, .raw = .{ .nanoseconds = std.Io.Clock.awake.now(io).nanoseconds + 5 * std.time.ns_per_s } };
}

fn denyCloseRange(err: std.posix.E) !void {
    // A narrow fault injector, inherited by the child. All other syscalls retain
    // their normal behavior, including those needed for reporting and cleanup.
    const Instruction = extern struct { code: u16, jt: u8 = 0, jf: u8 = 0, k: u32 };
    const Program = extern struct { len: u16, filter: [*]const Instruction };
    const bpf = linux.BPF;
    const instructions = [_]Instruction{
        .{ .code = bpf.LD | bpf.W | bpf.ABS, .k = @offsetOf(linux.SECCOMP.data, "nr") },
        .{ .code = bpf.JMP | bpf.JEQ | bpf.K, .jf = 1, .k = @intFromEnum(linux.SYS.close_range) },
        .{ .code = bpf.RET | bpf.K, .k = linux.SECCOMP.RET.ERRNO | @as(u32, @intFromEnum(err)) },
        .{ .code = bpf.RET | bpf.K, .k = linux.SECCOMP.RET.ALLOW },
    };
    const program = Program{ .len = instructions.len, .filter = &instructions };
    if (linux.errno(linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0)) != .SUCCESS or
        linux.errno(linux.seccomp(linux.SECCOMP.SET_MODE_FILTER, 0, &program)) != .SUCCESS) return error.SeccompUnavailable;
}
