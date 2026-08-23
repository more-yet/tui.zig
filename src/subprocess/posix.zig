const std = @import("std");
const builtin = @import("builtin");
const render = @import("../render.zig");

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
extern "c" fn dirfd(directory: *std.c.DIR) c_int;

const tiocsctty: c_ulong = if (builtin.os.tag == .macos) 0x20007461 else std.posix.T.IOCSCTTY;
const tiocswinsz: c_ulong = if (builtin.os.tag == .macos) 0x80087467 else std.posix.T.IOCSWINSZ;
const wait_continued: c_int = if (builtin.os.tag == .macos) 0x10 else std.posix.W.CONTINUED;

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
        var byte_count: usize = 0;
        for (argv) |argument| {
            if (std.mem.indexOfScalar(u8, argument, 0) != null) return error.EmbeddedNul;
            if (slicesOverlap(self.bytes, argument)) return error.OverlappingInput;
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

pub const PtyProcess = struct {
    io: std.Io,
    child_pid: std.posix.pid_t,
    master: ?std.Io.File,
    reaped: bool = false,
    eof: bool = false,

    /// Uses `fork`; call before starting worker threads or loading at-fork-sensitive libraries.
    pub fn spawnBeforeThreads(
        io: std.Io,
        command: Command,
        storage: *SpawnStorage,
        options: PtyOptions,
    ) !PtyProcess {
        if (options.size.width == 0 or options.size.height == 0) return error.InvalidSize;
        const prepared = try storage.prepare(command.argv);

        var master_fd: c_int = -1;
        var slave_fd: c_int = -1;
        var winsize = std.posix.winsize{
            .row = options.size.height,
            .col = options.size.width,
            .xpixel = 0,
            .ypixel = 0,
        };
        if (openpty(&master_fd, &slave_fd, null, null, &winsize) != 0) return mapSpawnErrno();
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
        if (child_pid_value != 0) {
            std.posix.sigprocmask(std.posix.SIG.SETMASK, &previous_signal_mask, null);
        }
        if (child_pid_value < 0) return mapSpawnErrno();
        if (child_pid_value == 0) childExec(master_fd, slave_fd, .{ error_read, error_write }, prepared, command.environ);
        var child_needs_cleanup = true;
        errdefer if (child_needs_cleanup) abortChild(child_pid_value);

        closeFd(slave_fd);
        slave_fd = -1;
        closeFd(error_write);
        error_write = -1;
        var failure: ChildFailure = undefined;
        var failure_bytes = std.mem.asBytes(&failure);
        var failure_len: usize = 0;
        while (failure_len < failure_bytes.len) {
            const count = try std.posix.read(error_read, failure_bytes[failure_len..]);
            if (count == 0) break;
            failure_len += count;
        }
        closeFd(error_read);
        error_read = -1;
        if (failure_len != 0) {
            try waitForChild(child_pid_value);
            child_needs_cleanup = false;
            closeFd(master_fd);
            master_fd = -1;
            if (failure_len != failure_bytes.len) return error.ChildSetupFailed;
            return mapChildFailure(failure);
        }

        child_needs_cleanup = false;
        return .{
            .io = io,
            .child_pid = child_pid_value,
            .master = .{ .handle = master_fd, .flags = .{ .nonblocking = true } },
        };
    }

    pub fn pid(self: *const PtyProcess) std.posix.pid_t {
        return self.child_pid;
    }

    pub fn processGroup(self: *const PtyProcess) std.posix.pid_t {
        return self.child_pid;
    }

    pub fn isReaped(self: *const PtyProcess) bool {
        return self.reaped;
    }

    pub fn poll(self: *PtyProcess) !?WaitEvent {
        if (self.reaped) return error.AlreadyReaped;
        return self.waitImpl(std.posix.W.NOHANG | std.posix.W.UNTRACED | wait_continued);
    }

    pub fn wait(self: *PtyProcess) !WaitEvent {
        if (self.reaped) return error.AlreadyReaped;
        return (try self.waitImpl(std.posix.W.UNTRACED | wait_continued)) orelse unreachable;
    }

    pub fn sendSignal(self: *PtyProcess, signal: std.posix.SIG) !void {
        if (self.reaped) return error.AlreadyReaped;
        try std.posix.kill(-self.child_pid, signal);
    }

    pub fn terminate(self: *PtyProcess) !void {
        try self.sendSignal(.TERM);
    }

    pub fn forceKill(self: *PtyProcess) !void {
        try self.sendSignal(.KILL);
    }

    pub fn read(self: *PtyProcess, buffer: []u8) !ReadResult {
        if (buffer.len == 0) return error.EmptyBuffer;
        if (self.eof) return .eof;
        const master = self.master orelse return error.Closed;
        const count = std.posix.read(master.handle, buffer) catch |err| switch (err) {
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

    pub fn write(self: *PtyProcess, bytes: []const u8) !WriteResult {
        if (bytes.len == 0) return .{ .written = 0 };
        const master = self.master orelse return .closed;
        while (true) {
            const result = std.posix.system.write(master.handle, bytes.ptr, bytes.len);
            switch (std.posix.errno(result)) {
                .SUCCESS => return .{ .written = @intCast(result) },
                .INTR => continue,
                .AGAIN => return .would_block,
                .PIPE, .IO => return .closed,
                .BADF => return error.Closed,
                .NOBUFS, .NOMEM => return error.SystemResources,
                else => return error.Unexpected,
            }
        }
    }

    pub fn setSize(self: *PtyProcess, size: render.Size) !void {
        if (size.width == 0 or size.height == 0) return error.InvalidSize;
        const master = self.master orelse return error.Closed;
        var winsize = std.posix.winsize{ .row = size.height, .col = size.width, .xpixel = 0, .ypixel = 0 };
        const result = try self.io.operate(.{ .device_io_control = .{
            .file = master,
            .code = tiocswinsz,
            .arg = &winsize,
        } });
        if (result.device_io_control < 0) return error.ResizeFailed;
    }

    pub fn borrowedMaster(self: *const PtyProcess) !std.Io.File {
        return self.master orelse error.Closed;
    }

    pub fn closeMaster(self: *PtyProcess) void {
        const master = self.master orelse return;
        master.close(self.io);
        self.master = null;
    }

    pub fn deinit(self: *PtyProcess) void {
        std.debug.assert(self.reaped);
        self.closeMaster();
        self.* = undefined;
    }

    fn waitImpl(self: *PtyProcess, flags: c_int) !?WaitEvent {
        while (true) {
            var raw_status: c_int = 0;
            const result = waitpid(self.child_pid, &raw_status, flags);
            if (result == 0) return null;
            if (result < 0) switch (std.posix.errno(result)) {
                .INTR => continue,
                .CHILD => {
                    self.reaped = true;
                    return error.AlreadyReaped;
                },
                else => return error.Unexpected,
            };
            const status: u32 = @bitCast(raw_status);
            if (waitStatusContinued(status)) return .continued;
            if (std.posix.W.IFEXITED(status)) {
                self.reaped = true;
                return .{ .exit = .{ .exited = std.posix.W.EXITSTATUS(status) } };
            }
            if (std.posix.W.IFSIGNALED(status)) {
                self.reaped = true;
                return .{ .exit = .{ .signaled = std.posix.W.TERMSIG(status) } };
            }
            if (std.posix.W.IFSTOPPED(status)) return .{ .stopped = std.posix.W.STOPSIG(status) };
            return error.UnexpectedStatus;
        }
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
    if (builtin.os.tag == .linux) {
        const result = std.os.linux.close_range(4, -1, .{ .UNSHARE = false, .CLOEXEC = false });
        switch (std.posix.errno(result)) {
            .SUCCESS => return,
            .NOSYS => return closeProcDescriptors(error_fd),
            else => childFail(error_fd, .close_descriptors),
        }
    }
    if (builtin.os.tag == .macos) closeMacosDescriptors(error_fd);
}

fn closeProcDescriptors(error_fd: c_int) void {
    const path = "/proc/self/fd";
    const raw_directory = std.os.linux.openat(
        std.os.linux.AT.FDCWD,
        path,
        .{ .DIRECTORY = true, .CLOEXEC = true },
        0,
    );
    const directory_fd: c_int = switch (std.posix.errno(raw_directory)) {
        .SUCCESS => @intCast(raw_directory),
        else => childFail(error_fd, .close_descriptors),
    };
    defer closeFd(directory_fd);

    var buffer: [4096]u8 = undefined;
    while (true) {
        const raw_count = std.os.linux.getdents64(directory_fd, &buffer, buffer.len);
        const count: usize = switch (std.posix.errno(raw_count)) {
            .SUCCESS => raw_count,
            .INTR => continue,
            else => childFail(error_fd, .close_descriptors),
        };
        if (count == 0) return;

        var offset: usize = 0;
        while (offset < count) {
            if (count - offset < 19) childFail(error_fd, .close_descriptors);
            const record_len = @as(*align(1) const u16, @ptrCast(&buffer[offset + 16])).*;
            if (record_len < 20 or record_len > count - offset) childFail(error_fd, .close_descriptors);
            const name_bytes = buffer[offset + 19 .. offset + record_len];
            const name_end = std.mem.indexOfScalar(u8, name_bytes, 0) orelse childFail(error_fd, .close_descriptors);
            var descriptor: usize = 0;
            var numeric = name_end != 0;
            for (name_bytes[0..name_end]) |byte| {
                if (byte < '0' or byte > '9') {
                    numeric = false;
                    break;
                }
                descriptor = std.math.mul(usize, descriptor, 10) catch childFail(error_fd, .close_descriptors);
                descriptor = std.math.add(usize, descriptor, byte - '0') catch childFail(error_fd, .close_descriptors);
            }
            if (numeric and descriptor >= 4 and descriptor != @as(usize, @intCast(directory_fd))) {
                if (descriptor > std.math.maxInt(c_int)) childFail(error_fd, .close_descriptors);
                closeFd(@intCast(descriptor));
            }
            offset += record_len;
        }
    }
}

fn closeMacosDescriptors(error_fd: c_int) void {
    const directory = std.c.opendir("/dev/fd") orelse childFail(error_fd, .close_descriptors);
    const directory_fd = dirfd(directory);
    if (directory_fd < 0) {
        _ = std.c.closedir(directory);
        childFail(error_fd, .close_descriptors);
    }

    while (true) {
        std.c._errno().* = 0;
        const entry = std.c.readdir(directory) orelse {
            if (std.c._errno().* != 0) {
                _ = std.c.closedir(directory);
                childFail(error_fd, .close_descriptors);
            }
            break;
        };
        const name = entry.name[0..entry.namlen];
        if (name.len == 0 or name[0] == '.') continue;
        var descriptor: usize = 0;
        for (name) |byte| {
            if (byte < '0' or byte > '9') {
                _ = std.c.closedir(directory);
                childFail(error_fd, .close_descriptors);
            }
            descriptor = std.math.mul(usize, descriptor, 10) catch childFail(error_fd, .close_descriptors);
            descriptor = std.math.add(usize, descriptor, byte - '0') catch childFail(error_fd, .close_descriptors);
        }
        if (descriptor >= 4 and descriptor != @as(usize, @intCast(directory_fd))) {
            if (descriptor > std.math.maxInt(c_int) or close(@intCast(descriptor)) < 0) {
                _ = std.c.closedir(directory);
                childFail(error_fd, .close_descriptors);
            }
        }
    }
    if (std.c.closedir(directory) != 0) childFail(error_fd, .close_descriptors);
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
        if (current.handler.handler == std.posix.SIG.DFL or current.handler.handler == std.posix.SIG.IGN) continue;
        switch (std.posix.errno(std.posix.system.sigaction(signal, &default_action, null))) {
            .SUCCESS => {},
            else => childFail(error_fd, .reset_signals),
        }
    }
}

fn waitStatusContinued(status: u32) bool {
    if (builtin.os.tag == .macos) {
        return status & 0x7f == 0x7f and status >> 8 == 0x13;
    }
    return status == 0xffff;
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

fn abortChild(pid: std.posix.pid_t) void {
    std.posix.kill(pid, .KILL) catch {};
    var status: c_int = 0;
    while (true) {
        const result = waitpid(pid, &status, 0);
        if (result >= 0 or std.posix.errno(result) != .INTR) break;
    }
}

fn waitForChild(pid: std.posix.pid_t) !void {
    var status: c_int = 0;
    while (true) {
        const result = waitpid(pid, &status, 0);
        if (result >= 0) return;
        switch (std.posix.errno(result)) {
            .INTR => continue,
            .CHILD => return,
            else => return error.Unexpected,
        }
    }
}

fn mapSpawnErrno() anyerror {
    return switch (std.posix.errno(-1)) {
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

fn slicesOverlap(storage: []const u8, input: []const u8) bool {
    if (storage.len == 0 or input.len == 0) return false;
    const storage_start = @intFromPtr(storage.ptr);
    const input_start = @intFromPtr(input.ptr);
    const storage_end = std.math.add(usize, storage_start, storage.len) catch return true;
    const input_end = std.math.add(usize, input_start, input.len) catch return true;
    return input_start < storage_end and storage_start < input_end;
}

test "spawn storage validates before copying and preserves literal arguments" {
    var pointer_storage: [3]?[*:0]const u8 = undefined;
    var byte_storage: [32]u8 = undefined;
    var storage = SpawnStorage.init(&pointer_storage, &byte_storage);
    const prepared = try storage.prepare(&.{ "/bin/example", "a; $(b)" });
    try std.testing.expectEqualStrings("/bin/example", std.mem.span(prepared.path));
    try std.testing.expectEqualStrings("a; $(b)", std.mem.span(prepared.argv[1].?));
    try std.testing.expect(prepared.argv[2] == null);
    try std.testing.expectError(error.ExecutablePathRequired, storage.prepare(&.{"example"}));
    try std.testing.expectError(error.EmbeddedNul, storage.prepare(&.{ "/bin/example", "a\x00b" }));

    var short_pointers: [1]?[*:0]const u8 = undefined;
    var pointer_limited = SpawnStorage.init(&short_pointers, &byte_storage);
    try std.testing.expectError(error.PointerStorageTooSmall, pointer_limited.prepare(&.{"/bin/example"}));
    var short_bytes: [4]u8 = undefined;
    var byte_limited = SpawnStorage.init(&pointer_storage, &short_bytes);
    try std.testing.expectError(error.ByteStorageTooSmall, byte_limited.prepare(&.{"/bin/example"}));

    @memcpy(byte_storage[0..12], "/bin/example");
    try std.testing.expectError(error.OverlappingInput, storage.prepare(&.{byte_storage[0..12]}));
}
