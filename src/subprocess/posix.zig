const std = @import("std");
const render = @import("../render.zig");
const memory = @import("../core/memory.zig");

extern "c" fn openpty(
    master: *c_int,
    slave: *c_int,
    name: ?[*]u8,
    termios: ?*const std.posix.termios,
    winsize: ?*const std.posix.winsize,
) c_int;
extern "c" fn fork() std.posix.pid_t;
extern "c" fn setsid() std.posix.pid_t;
extern "c" fn dup2(old_fd: c_int, new_fd: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern "c" fn execve(
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) c_int;
extern "c" fn waitpid(pid: std.posix.pid_t, status: *c_int, options: c_int) std.posix.pid_t;
extern "c" fn _exit(status: c_int) noreturn;

const tiocsctty: c_ulong = std.posix.T.IOCSCTTY;
const tiocswinsz: c_ulong = std.posix.T.IOCSWINSZ;
const wait_continued: c_int = std.posix.W.CONTINUED;
const max_transfer_bytes: usize = 0x7fff_f000;

pub const SpawnStorage = struct {
    pointers: []?[*:0]const u8,
    bytes: []u8,

    pub fn init(pointers: []?[*:0]const u8, bytes: []u8) SpawnStorage {
        return .{ .pointers = pointers, .bytes = bytes };
    }

    fn prepare(self: *SpawnStorage, argv: []const []const u8) !PreparedArgs {
        if (argv.len == 0 or argv[0].len == 0) return error.InvalidArguments;
        if (std.mem.indexOfScalar(u8, argv[0], '/') == null) return error.ExecutablePathRequired;
        const pointer_count = std.math.add(usize, argv.len, 1) catch return error.PointerStorageTooSmall;
        if (self.pointers.len < pointer_count) return error.PointerStorageTooSmall;
        const pointer_bytes = std.mem.sliceAsBytes(self.pointers);
        const argument_descriptors = std.mem.sliceAsBytes(argv);
        if (memory.slicesOverlap(pointer_bytes, self.bytes) or
            memory.slicesOverlap(pointer_bytes, argument_descriptors) or
            memory.slicesOverlap(self.bytes, argument_descriptors)) return error.OverlappingInput;
        var byte_count: usize = 0;
        for (argv) |argument| {
            if (std.mem.indexOfScalar(u8, argument, 0) != null) return error.EmbeddedNul;
            if (memory.slicesOverlap(pointer_bytes, argument) or
                memory.slicesOverlap(self.bytes, argument)) return error.OverlappingInput;
            const stored_len = std.math.add(usize, argument.len, 1) catch return error.ByteStorageTooSmall;
            byte_count = std.math.add(usize, byte_count, stored_len) catch return error.ByteStorageTooSmall;
        }
        if (byte_count > self.bytes.len) return error.ByteStorageTooSmall;

        var offset: usize = 0;
        for (argv, 0..) |argument, index| {
            @memcpy(self.bytes[offset..][0..argument.len], argument);
            self.bytes[offset + argument.len] = 0;
            self.pointers[index] = @ptrCast(self.bytes[offset .. offset + argument.len :0].ptr);
            offset += argument.len + 1;
        }
        self.pointers[argv.len] = null;
        return .{
            .path = self.pointers[0].?,
            .argv = @ptrCast(self.pointers.ptr),
        };
    }
};

const PreparedArgs = struct {
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
};

pub const Command = struct {
    argv: []const []const u8,
    environ: std.process.Environ,
};

pub const PtyOptions = struct {
    size: render.Size,
};

pub const Exit = union(enum) {
    exited: u8,
    signaled: std.posix.SIG,
};

pub const WaitEvent = union(enum) {
    exit: Exit,
    stopped: std.posix.SIG,
    continued,
};

pub const ReadResult = union(enum) {
    data: []u8,
    would_block,
    eof,
};

pub const WriteResult = union(enum) {
    written: usize,
    would_block,
    closed,
};

pub const PtyState = enum {
    empty,
    starting,
    /// The process exclusively owns a direct child that has not been reaped.
    /// This includes stopped children and exited children with uncollected status.
    running,
    reaped,
};

/// Owns one direct child's wait status and PTY master. Exactly one component
/// must call this value's status and cleanup methods; competing reapers,
/// especially wildcard waits, can make the child's status unavailable.
pub const PtyProcess = struct {
    io: std.Io,
    lifecycle: PtyState = .empty,
    child_pid: ?std.posix.pid_t = null,
    master: ?std.Io.File = null,
    eof: bool = false,

    pub fn init(io: std.Io) PtyProcess {
        return .{ .io = io };
    }

    /// Uses `fork`; call before starting worker threads or loading at-fork-sensitive libraries.
    /// An interrupted or failed post-fork handshake can return while retaining
    /// child ownership in `.running`; reconcile it with `killAndWait` before deinit.
    pub fn spawnBeforeThreads(
        self: *PtyProcess,
        command: Command,
        storage: *SpawnStorage,
        options: PtyOptions,
    ) !void {
        if (self.lifecycle != .empty) return error.AlreadySpawned;
        if (options.size.width == 0 or options.size.height == 0) return error.InvalidSize;
        // Automatic reaping would release the PID while this value still owns
        // it. Keep exact-child status available for signaling and cleanup.
        try validateChildWaitPolicy();
        const prepared = try storage.prepare(command.argv);
        self.lifecycle = .starting;
        errdefer if (self.child_pid == null) {
            self.lifecycle = .empty;
        };

        var master_fd: c_int = -1;
        var slave_fd: c_int = -1;
        var winsize = std.posix.winsize{
            .row = options.size.height,
            .col = options.size.width,
            .xpixel = 0,
            .ypixel = 0,
        };
        if (openpty(&master_fd, &slave_fd, null, null, &winsize) != 0) {
            return mapSpawnErrno(std.c._errno().*);
        }
        errdefer closeFd(master_fd);
        errdefer closeFd(slave_fd);
        try setCloseOnExec(master_fd);
        try setCloseOnExec(slave_fd);
        try setNonBlocking(master_fd);

        const raw_error_pipe = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
        var error_read = raw_error_pipe[0];
        var error_write = raw_error_pipe[1];
        errdefer closeFd(error_read);
        errdefer closeFd(error_write);
        if (error_write <= 2) {
            const duplicate = try duplicateCloseOnExec(error_write);
            closeFd(error_write);
            error_write = duplicate;
        }
        var child_signal_mask = std.posix.sigfillset();
        var previous_signal_mask: std.posix.sigset_t = undefined;
        std.posix.sigprocmask(std.posix.SIG.BLOCK, &child_signal_mask, &previous_signal_mask);
        const child_pid_value = fork();
        const fork_errno = if (child_pid_value < 0) std.c._errno().* else 0;
        if (child_pid_value != 0) {
            std.posix.sigprocmask(std.posix.SIG.SETMASK, &previous_signal_mask, null);
        }
        if (child_pid_value < 0) return mapSpawnErrno(fork_errno);
        if (child_pid_value == 0) childExec(master_fd, slave_fd, .{ error_read, error_write }, prepared, command.environ);

        closeFd(slave_fd);
        slave_fd = -1;
        closeFd(error_write);
        error_write = -1;
        self.child_pid = child_pid_value;
        self.master = .{ .handle = master_fd, .flags = .{ .nonblocking = true } };
        self.eof = false;
        master_fd = -1;
        errdefer if (self.lifecycle == .starting) {
            self.cleanupFailedSpawn();
        };

        var failure: ChildFailure = undefined;
        var failure_bytes = std.mem.asBytes(&failure);
        var failure_len: usize = 0;
        while (failure_len < failure_bytes.len) {
            const count = try readOnce(error_read, failure_bytes[failure_len..]);
            if (count == 0) break;
            failure_len += count;
        }
        closeFd(error_read);
        error_read = -1;
        if (failure_len != 0) {
            if (failure_len != failure_bytes.len) return error.ChildSetupFailed;
            const event = self.waitOnce(0) catch |err| switch (err) {
                error.AlreadyReaped => null,
                else => return err,
            };
            if (event) |value| if (value != .exit) return error.UnexpectedStatus;
            return mapChildFailure(failure);
        }
        self.lifecycle = .running;
    }

    pub fn state(self: *const PtyProcess) PtyState {
        return self.lifecycle;
    }

    pub fn pid(self: *const PtyProcess) !std.posix.pid_t {
        return self.child_pid orelse error.NoChild;
    }

    pub fn processGroup(self: *const PtyProcess) !std.posix.pid_t {
        return self.child_pid orelse error.NoChild;
    }

    pub fn isReaped(self: *const PtyProcess) bool {
        return self.lifecycle == .reaped;
    }

    /// Performs one nonblocking exact-pid status check. PTY EOF is independent
    /// from child status. `AlreadyReaped` means no collectible status remains;
    /// it does not fabricate a successful exit.
    pub fn poll(self: *PtyProcess) !?WaitEvent {
        switch (self.lifecycle) {
            .empty => return error.NoChild,
            .starting => return error.NotRunning,
            .reaped => return error.AlreadyReaped,
            .running => {},
        }
        return self.waitOnce(std.posix.W.NOHANG | std.posix.W.UNTRACED | wait_continued);
    }

    /// Blocks for the next exact-pid stop, continuation, or exit status. The
    /// caller must arrange its own notification/deadline policy when blocking
    /// here is unsuitable. PTY EOF does not imply that this call will complete,
    /// and signal interruption is returned rather than restarted internally.
    pub fn wait(self: *PtyProcess) !WaitEvent {
        switch (self.lifecycle) {
            .empty => return error.NoChild,
            .starting => return error.NotRunning,
            .reaped => return error.AlreadyReaped,
            .running => {},
        }
        return (try self.waitOnce(std.posix.W.UNTRACED | wait_continued)) orelse unreachable;
    }

    pub fn sendSignal(self: *PtyProcess, signal: std.posix.SIG) !void {
        const child_pid = self.child_pid orelse return error.NoChild;
        if (self.lifecycle != .running) return error.AlreadyReaped;
        try std.posix.kill(-child_pid, signal);
    }

    pub fn terminate(self: *PtyProcess) !void {
        try self.sendSignal(.TERM);
    }

    pub fn forceKill(self: *PtyProcess) !void {
        try self.sendSignal(.KILL);
    }

    /// Force-kills and reaps the exclusively owned child before an awake-clock
    /// deadline. Waiting uses a temporary pidfd and never falls back to sleeps.
    /// Timeout or interruption can leave a killed child for a later retry.
    pub fn killAndWait(self: *PtyProcess, deadline: std.Io.Clock.Timestamp) !void {
        if (deadline.clock != .awake) return error.WrongClock;
        const child_pid = self.child_pid orelse return error.NoChild;
        if (self.lifecycle != .running) return error.AlreadyReaped;
        try validateChildWaitPolicy();

        const pidfd = openPidfd(child_pid) catch |err| switch (err) {
            error.ProcessNotFound => {
                if (try self.reconcileExit()) return;
                return error.ProcessNotFound;
            },
            else => return err,
        };
        defer closeFd(pidfd);

        std.posix.kill(-child_pid, .KILL) catch |err| switch (err) {
            error.ProcessNotFound => std.posix.kill(child_pid, .KILL) catch |child_err| switch (child_err) {
                error.ProcessNotFound => {},
                else => return child_err,
            },
            else => return err,
        };

        if (try self.reconcileExit()) return;
        while (true) {
            const now = std.Io.Clock.awake.now(self.io);
            const timeout = deadlinePollTimeout(now.nanoseconds, deadline.raw.nanoseconds);
            if (timeout == 0) {
                if (try self.reconcileExit()) return;
                return error.Timeout;
            }
            var descriptor = [1]std.posix.pollfd{.{
                .fd = pidfd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const ready = try pollPidfdOnce(&descriptor, timeout);
            if (ready == 0) continue;
            const events = descriptor[0].revents;
            if (events & std.posix.POLL.NVAL != 0) return error.InvalidPidfdDescriptor;
            if (events & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR) == 0) {
                return error.UnexpectedPidfdState;
            }
            if (try self.reconcileExit()) return;
            return error.UnexpectedChildState;
        }
    }

    /// Performs one read syscall. Interruption is returned to the caller.
    pub fn read(self: *PtyProcess, buffer: []u8) !ReadResult {
        if (buffer.len == 0) return error.EmptyBuffer;
        if (self.eof) return .eof;
        const master = self.master orelse return error.Closed;
        const count = readOnce(master.handle, buffer) catch |err| switch (err) {
            error.WouldBlock => return .would_block,
            error.InputOutput => {
                self.eof = true;
                return .eof;
            },
            else => return err,
        };
        if (count == 0) {
            self.eof = true;
            return .eof;
        }
        return .{ .data = buffer[0..count] };
    }

    /// Performs one write syscall. Interruption is returned to the caller.
    pub fn write(self: *PtyProcess, bytes: []const u8) !WriteResult {
        if (bytes.len == 0) return .{ .written = 0 };
        const master = self.master orelse return .closed;
        const result = std.posix.system.write(master.handle, bytes.ptr, @min(bytes.len, max_transfer_bytes));
        return switch (std.posix.errno(result)) {
            .SUCCESS => .{ .written = @intCast(result) },
            .INTR => error.Interrupted,
            .AGAIN => .would_block,
            .PIPE, .IO => .closed,
            .BADF => error.Closed,
            .NOBUFS, .NOMEM => error.SystemResources,
            else => error.Unexpected,
        };
    }

    /// Performs one resize ioctl. Interruption is returned to the caller.
    pub fn setSize(self: *PtyProcess, size: render.Size) !void {
        if (size.width == 0 or size.height == 0) return error.InvalidSize;
        const master = self.master orelse return error.Closed;
        var winsize = std.posix.winsize{ .row = size.height, .col = size.width, .xpixel = 0, .ypixel = 0 };
        return switch (std.posix.errno(ioctl(master.handle, tiocswinsz, &winsize))) {
            .SUCCESS => {},
            .INTR => error.Interrupted,
            .BADF => error.Closed,
            else => error.ResizeFailed,
        };
    }

    /// Returns a borrowed nonblocking descriptor. It remains valid only until
    /// `closeMaster` or `deinit` and must not be closed by the borrower.
    pub fn borrowedMaster(self: *const PtyProcess) !std.Io.File {
        return self.master orelse error.Closed;
    }

    /// Releases the PTY descriptor without changing child wait ownership.
    /// Closing the master neither terminates nor reaps the child.
    pub fn closeMaster(self: *PtyProcess) void {
        const master = self.master orelse return;
        master.close(self.io);
        self.master = null;
    }

    /// Releases PTY resources only after child wait ownership is discharged.
    /// A running or stopped child must first be reaped by `wait`, `poll`, or
    /// bounded `killAndWait`; PTY EOF alone is insufficient.
    pub fn deinit(self: *PtyProcess) error{ChildNotReaped}!void {
        if (self.lifecycle == .starting or self.lifecycle == .running) return error.ChildNotReaped;
        self.closeMaster();
        self.* = init(self.io);
    }

    fn waitOnce(self: *PtyProcess, flags: c_int) !?WaitEvent {
        const child_pid = self.child_pid orelse return error.NoChild;
        var raw_status: c_int = 0;
        const result = waitpid(child_pid, &raw_status, flags);
        if (result == 0) return null;
        switch (std.posix.errno(result)) {
            .INTR => return error.Interrupted,
            .CHILD => {
                self.lifecycle = .reaped;
                return error.AlreadyReaped;
            },
            .SUCCESS => {},
            else => return error.Unexpected,
        }
        std.debug.assert(result == child_pid);
        const status: u32 = @bitCast(raw_status);
        if (status == 0xffff) return .continued; // Linux WIFCONTINUED encoding.
        if (std.posix.W.IFEXITED(status)) {
            self.lifecycle = .reaped;
            return .{ .exit = .{ .exited = std.posix.W.EXITSTATUS(status) } };
        }
        if (std.posix.W.IFSIGNALED(status)) {
            self.lifecycle = .reaped;
            return .{ .exit = .{ .signaled = std.posix.W.TERMSIG(status) } };
        }
        if (std.posix.W.IFSTOPPED(status)) return .{ .stopped = std.posix.W.STOPSIG(status) };
        return error.UnexpectedStatus;
    }

    fn reconcileExit(self: *PtyProcess) !bool {
        const event = self.waitOnce(std.posix.W.NOHANG) catch |err| switch (err) {
            error.AlreadyReaped => return true,
            else => return err,
        };
        return event != null and event.? == .exit;
    }

    fn cleanupFailedSpawn(self: *PtyProcess) void {
        const child_pid = self.child_pid orelse {
            self.lifecycle = .empty;
            return;
        };
        std.posix.kill(-child_pid, .KILL) catch {
            std.posix.kill(child_pid, .KILL) catch {};
        };
        _ = self.waitOnce(std.posix.W.NOHANG) catch {};
        if (self.lifecycle != .reaped) self.lifecycle = .running;
        self.closeMaster();
    }
};

const ChildStage = enum(u32) {
    setsid,
    controlling_terminal,
    duplicate_stdio,
    close_descriptors,
    reset_signals,
    exec,
};

const ChildFailure = extern struct {
    stage: ChildStage,
    errno_value: c_int,
};

fn childExec(
    master_fd: c_int,
    slave_fd: c_int,
    error_pipe: [2]std.posix.fd_t,
    prepared: PreparedArgs,
    environ: std.process.Environ,
) noreturn {
    closeFd(master_fd);
    closeFd(error_pipe[0]);
    var error_fd = error_pipe[1];
    if (setsid() < 0) childFail(error_fd, .setsid);
    if (ioctl(slave_fd, tiocsctty, @as(c_int, 0)) < 0) {
        childFail(error_fd, .controlling_terminal);
    }
    inline for (0..3) |target| {
        if (dup2(slave_fd, target) < 0) childFail(error_fd, .duplicate_stdio);
    }
    inline for (0..3) |target| clearCloseOnExec(target) catch childFail(error_fd, .duplicate_stdio);
    if (slave_fd > 2) closeFd(slave_fd);
    if (error_fd != 3) {
        if (dup2(error_fd, 3) < 0) childFail(error_fd, .close_descriptors);
        closeFd(error_fd);
        error_fd = 3;
    }
    setCloseOnExec(error_fd) catch childFail(error_fd, .close_descriptors);
    closeInheritedDescriptors(error_fd);

    resetSignalHandlers(error_fd);
    var empty_mask = std.posix.sigemptyset();
    std.posix.sigprocmask(std.posix.SIG.SETMASK, &empty_mask, null);

    const envp: [*:null]const ?[*:0]const u8 = environ.block.slice.ptr;
    _ = execve(prepared.path, prepared.argv, envp);
    childFail(error_fd, .exec);
}

fn childFail(error_fd: c_int, stage: ChildStage) noreturn {
    const failure = ChildFailure{ .stage = stage, .errno_value = std.c._errno().* };
    const bytes = std.mem.asBytes(&failure);
    while (true) {
        const result = std.posix.system.write(error_fd, bytes.ptr, bytes.len);
        if (std.posix.errno(result) != .INTR) break;
    }
    _exit(127);
}

fn readOnce(fd: std.posix.fd_t, buffer: []u8) !usize {
    if (buffer.len == 0) return 0;
    const result = std.posix.system.read(fd, buffer.ptr, @min(buffer.len, max_transfer_bytes));
    return switch (std.posix.errno(result)) {
        .SUCCESS => @intCast(result),
        .INTR => error.Interrupted,
        .AGAIN => error.WouldBlock,
        .BADF => error.Closed,
        .IO => error.InputOutput,
        .ISDIR => error.IsDir,
        .NOBUFS, .NOMEM => error.SystemResources,
        .NOTCONN => error.SocketUnconnected,
        .CONNRESET => error.ConnectionResetByPeer,
        .CANCELED => error.Canceled,
        else => error.Unexpected,
    };
}

fn setCloseOnExec(fd: c_int) !void {
    switch (std.posix.errno(std.posix.system.fcntl(fd, std.posix.F.SETFD, @as(u32, std.posix.FD_CLOEXEC)))) {
        .SUCCESS => {},
        else => return error.Unexpected,
    }
}

fn clearCloseOnExec(fd: c_int) !void {
    switch (std.posix.errno(std.posix.system.fcntl(fd, std.posix.F.SETFD, @as(u32, 0)))) {
        .SUCCESS => {},
        else => return error.Unexpected,
    }
}

fn duplicateCloseOnExec(fd: c_int) !c_int {
    const result = std.posix.system.fcntl(fd, std.posix.F.DUPFD_CLOEXEC, @as(u32, 3));
    return switch (std.posix.errno(result)) {
        .SUCCESS => @intCast(result),
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOMEM => error.SystemResources,
        else => error.Unexpected,
    };
}

fn closeInheritedDescriptors(error_fd: c_int) void {
    std.debug.assert(error_fd == 3);
    const result = std.os.linux.close_range(4, -1, .{ .UNSHARE = false, .CLOEXEC = false });
    const err = std.os.linux.errno(result);
    if (err != .SUCCESS) {
        // Raw Linux syscalls return -errno; libc calls use -1 plus errno.
        // Carry the kernel error into the common child-failure report.
        std.c._errno().* = @intFromEnum(err);
        childFail(error_fd, .close_descriptors);
    }
}

fn resetSignalHandlers(error_fd: c_int) void {
    const default_action = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var number: u32 = 1;
    while (number < std.posix.NSIG) : (number += 1) {
        const signal: std.posix.SIG = @enumFromInt(number);
        if (signal == .KILL or signal == .STOP) continue;
        var current: std.posix.Sigaction = undefined;
        switch (std.posix.errno(std.posix.system.sigaction(signal, null, &current))) {
            .SUCCESS => {},
            .INVAL => continue,
            else => childFail(error_fd, .reset_signals),
        }
        if (current.handler.handler == std.posix.SIG.DFL) continue;
        switch (std.posix.errno(std.posix.system.sigaction(signal, &default_action, null))) {
            .SUCCESS => {},
            else => childFail(error_fd, .reset_signals),
        }
    }
}

fn setNonBlocking(fd: c_int) !void {
    const result = std.posix.system.fcntl(fd, std.posix.F.GETFL, @as(c_int, 0));
    switch (std.posix.errno(result)) {
        .SUCCESS => {},
        else => return error.Unexpected,
    }
    const nonblocking: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    switch (std.posix.errno(std.posix.system.fcntl(fd, std.posix.F.SETFL, @as(u32, @intCast(result)) | nonblocking))) {
        .SUCCESS => {},
        else => return error.Unexpected,
    }
}

fn closeFd(fd: c_int) void {
    if (fd >= 0) _ = close(fd);
}

fn validateChildWaitPolicy() !void {
    var action: std.posix.Sigaction = undefined;
    std.posix.sigaction(.CHLD, null, &action);
    if (action.handler.handler == std.posix.SIG.IGN or action.flags & std.posix.SA.NOCLDWAIT != 0) {
        return error.IncompatibleSignalPolicy;
    }
}

fn openPidfd(pid: std.posix.pid_t) !std.posix.fd_t {
    const result = std.os.linux.pidfd_open(pid, 0);
    return switch (std.os.linux.errno(result)) {
        .SUCCESS => @intCast(result),
        .NOSYS, .NODEV => error.PidfdUnavailable,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOMEM => error.SystemResources,
        .PERM, .ACCES => error.PermissionDenied,
        .SRCH => error.ProcessNotFound,
        .INVAL => error.InvalidPidfdArguments,
        else => error.Unexpected,
    };
}

fn deadlinePollTimeout(now_ns: i96, deadline_ns: i96) i32 {
    if (now_ns >= deadline_ns) return 0;
    const remaining = std.math.sub(i96, deadline_ns, now_ns) catch std.math.maxInt(i96);
    var milliseconds = @divTrunc(remaining, std.time.ns_per_ms);
    if (@mod(remaining, std.time.ns_per_ms) != 0) milliseconds += 1;
    return @intCast(@min(milliseconds, std.math.maxInt(i32)));
}

fn pollPidfdOnce(descriptors: []std.posix.pollfd, timeout: i32) !usize {
    const result = std.posix.system.poll(descriptors.ptr, @intCast(descriptors.len), timeout);
    return switch (std.posix.errno(result)) {
        .SUCCESS => @intCast(result),
        .INTR => error.Interrupted,
        .BADF => error.InvalidPidfdDescriptor,
        .NOMEM => error.SystemResources,
        .INVAL => error.InvalidPollArguments,
        else => error.Unexpected,
    };
}

fn mapSpawnErrno(errno_value: c_int) anyerror {
    return switch (@as(std.posix.E, @enumFromInt(errno_value))) {
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOMEM, .NOBUFS => error.SystemResources,
        else => error.SpawnFailed,
    };
}

fn mapChildFailure(failure: ChildFailure) anyerror {
    if (failure.stage != .exec) return error.ChildSetupFailed;
    return switch (@as(std.posix.E, @enumFromInt(failure.errno_value))) {
        .NOENT => error.FileNotFound,
        .ACCES => error.AccessDenied,
        .NOEXEC => error.InvalidExecutable,
        .NAMETOOLONG => error.NameTooLong,
        .NOMEM => error.SystemResources,
        else => error.ExecFailed,
    };
}
