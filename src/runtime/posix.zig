const std = @import("std");
const builtin = @import("builtin");
const input = @import("../input.zig");
const render = @import("../render.zig");
const terminal = @import("../terminal.zig");

extern "c" fn sigpending(set: *std.posix.sigset_t) c_int;

pub const TimerId = u32;

pub const TimerSlot = struct {
    id: TimerId,
    deadline: std.Io.Clock.Timestamp,
};

pub const TimerEvent = struct {
    id: TimerId,
    deadline: std.Io.Clock.Timestamp,
};

/// Input payload slices remain valid only during the synchronous callback.
pub const Event = union(enum) {
    input: input.Event,
    eof,
    wakeup,
    resize: render.Size,
    signal: Signal,
    timer: TimerEvent,
    ready: ReadyEvent,
};

pub const PollInterest = packed struct(u2) {
    read: bool = false,
    write: bool = false,
};

pub const PollSource = struct {
    file: std.Io.File,
    interest: PollInterest,
};

pub const ReadyEvent = struct {
    source_index: usize,
    readable: bool,
    writable: bool,
    hangup: bool,
    error_pending: bool,
};

pub const PollSlot = std.posix.pollfd;

pub fn requiredPollSlots(source_count: usize) error{CapacityTooLarge}!usize {
    return std.math.add(usize, source_count, 3) catch error.CapacityTooLarge;
}

pub const Signal = enum {
    interrupt,
    terminate,
    suspend_requested,
    continued,
};

pub const SignalOptions = struct {
    resize: bool = true,
    interrupt: bool = true,
    terminate: bool = true,
    suspend_resume: bool = true,
};

pub const InputTimeouts = struct {
    escape: ?std.Io.Duration = .fromMilliseconds(50),
    sequence: ?std.Io.Duration = .fromMilliseconds(250),
};

pub const ResizeSource = struct {
    file: std.Io.File,
    initial_size: render.Size,
    poll_interval: ?std.Io.Duration = null,
};

pub const Options = struct {
    input_timeouts: InputTimeouts = .{},
    resize: ?ResizeSource = null,
    signals: ?*SignalSource = null,
};

pub const TimerChange = enum {
    inserted,
    replaced,
};

pub const TimerSetError = error{
    WrongClock,
    CapacityExceeded,
};

pub const WakeError = error{
    Closed,
    InputOutput,
    SystemResources,
    Unexpected,
};

const wake_reason = 1;
const resize_reason = 2;

const signal_resize = 1 << 0;
const signal_interrupt = 1 << 1;
const signal_terminate = 1 << 2;
const signal_suspend = 1 << 3;
const signal_continue = 1 << 4;

const managed_signals = [_]std.posix.SIG{
    .WINCH,
    .INT,
    .TERM,
    .TSTP,
    .CONT,
};

const SignalBackend = switch (builtin.os.tag) {
    .linux => struct { old_mask: std.posix.sigset_t },
    .macos => struct { old_actions: [managed_signals.len]std.posix.Sigaction },
    else => struct {},
};

var signal_source_installed: std.atomic.Value(bool) = .init(false);

pub const SignalSource = struct {
    io: std.Io,
    options: SignalOptions,
    selected: u8,
    descriptor_file: std.Io.File,
    backend: SignalBackend,
    owner_thread: std.Thread.Id,
    attached: bool = false,
    pending_bits: u8 = 0,

    /// Install before starting worker threads so they inherit the managed signal mask.
    pub fn init(io: std.Io, options: SignalOptions) !SignalSource {
        const selected = selectedSignals(options);
        if (selected == 0) return error.NoSignalsSelected;
        if (signal_source_installed.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
            return error.AlreadyInstalled;
        }
        errdefer signal_source_installed.store(false, .release);

        if (builtin.os.tag == .linux) return initSignalSourceLinux(io, options, selected);
        if (builtin.os.tag == .macos) return initSignalSourceMacos(io, options, selected);
        return error.UnsupportedPlatform;
    }

    /// The source must be detached and all worker threads stopped first.
    pub fn deinit(self: *SignalSource) void {
        if (self.owner_thread != std.Thread.getCurrentId()) {
            @panic("SignalSource.deinit must run on its owner thread");
        }
        std.debug.assert(!self.attached);
        if (builtin.os.tag == .linux) {
            self.descriptor_file.close(self.io);
            std.posix.sigprocmask(std.posix.SIG.SETMASK, &self.backend.old_mask, null);
        } else if (builtin.os.tag == .macos) {
            deinitSignalSourceMacos(self);
        }
        signal_source_installed.store(false, .release);
        self.* = undefined;
    }

    /// Stops the process with the default SIGTSTP action and rearms notification after continue.
    /// Leave the terminal session before calling this method.
    pub fn suspendProcess(self: *SignalSource) !void {
        if (!self.options.suspend_resume) return error.SuspendUnavailable;
        if (!self.attached) return error.NotAttached;
        if (self.owner_thread != std.Thread.getCurrentId()) return error.WrongThread;
        const default_action = std.posix.Sigaction{
            .handler = .{ .handler = std.posix.SIG.DFL },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };

        if (builtin.os.tag == .linux) {
            var previous: std.posix.Sigaction = undefined;
            std.posix.sigaction(.TSTP, null, &previous);
            std.posix.sigaction(.TSTP, &default_action, null);
            var mask = std.posix.sigemptyset();
            std.posix.sigaddset(&mask, .TSTP);
            std.posix.sigprocmask(std.posix.SIG.UNBLOCK, &mask, null);
            const result = std.posix.raise(.TSTP);
            std.posix.sigprocmask(std.posix.SIG.BLOCK, &mask, null);
            std.posix.sigaction(.TSTP, &previous, null);
            try result;
        } else if (builtin.os.tag == .macos) {
            const ignore_action = std.posix.Sigaction{
                .handler = .{ .handler = std.posix.SIG.IGN },
                .mask = std.posix.sigemptyset(),
                .flags = 0,
            };
            std.posix.sigaction(.TSTP, &default_action, null);
            const result = std.posix.raise(.TSTP);
            std.posix.sigaction(.TSTP, &ignore_action, null);
            try result;
        } else return error.UnsupportedPlatform;
    }

    fn consume(self: *SignalSource) !u8 {
        const backend = if (builtin.os.tag == .linux)
            try self.consumeLinux()
        else if (builtin.os.tag == .macos)
            try self.consumeMacos()
        else
            return error.UnsupportedPlatform;
        const pending = self.pending_bits;
        self.pending_bits = 0;
        return pending | backend;
    }

    fn consumeLinux(self: *SignalSource) !u8 {
        var records: [8]std.os.linux.signalfd_siginfo = undefined;
        const count = std.posix.read(self.descriptor_file.handle, std.mem.sliceAsBytes(&records)) catch |err| switch (err) {
            error.WouldBlock => return 0,
            else => return err,
        };
        if (count % @sizeOf(std.os.linux.signalfd_siginfo) != 0) return error.Unexpected;
        var result: u8 = 0;
        for (records[0 .. count / @sizeOf(std.os.linux.signalfd_siginfo)]) |record| {
            result |= signalNumberBit(record.signo);
        }
        return result;
    }

    fn consumeMacos(self: *SignalSource) !u8 {
        var result: u8 = 0;
        var events: [8]std.posix.Kevent = undefined;
        var timeout = std.posix.timespec{ .sec = 0, .nsec = 0 };
        const count = try std.Io.Kqueue.kevent(self.descriptor_file.handle, &.{}, &events, &timeout);
        for (events[0..count]) |event| result |= signalNumberBit(@as(u32, @intCast(event.ident)));
        return result;
    }
};

fn initSignalSourceLinux(io: std.Io, options: SignalOptions, selected: u8) !SignalSource {
    var mask = std.posix.sigemptyset();
    for (managed_signals) |signal| {
        if (selected & signalBit(signal) != 0) std.posix.sigaddset(&mask, signal);
    }
    var old_mask: std.posix.sigset_t = undefined;
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &mask, &old_mask);
    errdefer std.posix.sigprocmask(std.posix.SIG.SETMASK, &old_mask, null);
    const flags: u32 = std.os.linux.SFD.NONBLOCK | std.os.linux.SFD.CLOEXEC;
    const fd = try std.posix.signalfd(-1, &mask, flags);
    return .{
        .io = io,
        .options = options,
        .selected = selected,
        .descriptor_file = .{ .handle = fd, .flags = .{ .nonblocking = true } },
        .backend = .{ .old_mask = old_mask },
        .owner_thread = std.Thread.getCurrentId(),
    };
}

fn initSignalSourceMacos(io: std.Io, options: SignalOptions, selected: u8) !SignalSource {
    var selected_mask = selectedSignalMask(selected);
    var previous_mask: std.posix.sigset_t = undefined;
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &selected_mask, &previous_mask);
    errdefer std.posix.sigprocmask(std.posix.SIG.SETMASK, &previous_mask, null);

    const fd = try std.Io.Kqueue.createFileDescriptor();
    const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    errdefer file.close(io);
    switch (std.posix.errno(std.posix.system.fcntl(fd, std.posix.F.SETFD, @as(u32, std.posix.FD_CLOEXEC)))) {
        .SUCCESS => {},
        else => return error.Unexpected,
    }

    var old_actions: [managed_signals.len]std.posix.Sigaction = undefined;
    for (managed_signals, 0..) |signal, index| {
        if (selected & signalBit(signal) != 0) std.posix.sigaction(signal, null, &old_actions[index]);
    }
    const ignore_action = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    for (managed_signals) |signal| {
        if (selected & signalBit(signal) == 0) continue;
        const change = [1]std.posix.Kevent{.{
            .ident = @intFromEnum(signal),
            .filter = std.c.EVFILT.SIGNAL,
            .flags = std.c.EV.ADD | std.c.EV.ENABLE | std.c.EV.CLEAR,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        }};
        _ = try std.Io.Kqueue.kevent(fd, &change, &.{}, null);
    }
    var pending_set: std.posix.sigset_t = undefined;
    if (sigpending(&pending_set) != 0) return error.Unexpected;
    const pending_bits = pendingSignalBits(&pending_set, selected);
    for (managed_signals) |signal| {
        if (selected & signalBit(signal) != 0) std.posix.sigaction(signal, &ignore_action, null);
    }
    std.posix.sigprocmask(std.posix.SIG.SETMASK, &previous_mask, null);
    return .{
        .io = io,
        .options = options,
        .selected = selected,
        .descriptor_file = file,
        .backend = .{ .old_actions = old_actions },
        .owner_thread = std.Thread.getCurrentId(),
        .pending_bits = pending_bits,
    };
}

fn deinitSignalSourceMacos(source: *SignalSource) void {
    var selected_mask = selectedSignalMask(source.selected);
    var previous_mask: std.posix.sigset_t = undefined;
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &selected_mask, &previous_mask);
    for (managed_signals, 0..) |signal, index| {
        if (source.selected & signalBit(signal) != 0) {
            std.posix.sigaction(signal, &source.backend.old_actions[index], null);
        }
    }
    const pending_bits = source.pending_bits | (source.consumeMacos() catch 0);
    source.descriptor_file.close(source.io);
    for (managed_signals) |signal| {
        if (pending_bits & signalBit(signal) != 0) std.posix.raise(signal) catch {};
    }
    std.posix.sigprocmask(std.posix.SIG.SETMASK, &previous_mask, null);
}

fn selectedSignalMask(selected: u8) std.posix.sigset_t {
    var mask = std.posix.sigemptyset();
    for (managed_signals) |signal| {
        if (selected & signalBit(signal) != 0) std.posix.sigaddset(&mask, signal);
    }
    return mask;
}

fn pendingSignalBits(set: *const std.posix.sigset_t, selected: u8) u8 {
    var bits: u8 = 0;
    for (managed_signals) |signal| {
        const bit = signalBit(signal);
        if (selected & bit != 0 and std.posix.sigismember(set, signal)) bits |= bit;
    }
    return bits;
}

fn selectedSignals(options: SignalOptions) u8 {
    var result: u8 = 0;
    if (options.resize) result |= signal_resize;
    if (options.interrupt) result |= signal_interrupt;
    if (options.terminate) result |= signal_terminate;
    if (options.suspend_resume) result |= signal_suspend | signal_continue;
    return result;
}

fn signalBit(signal: std.posix.SIG) u8 {
    return switch (signal) {
        .WINCH => signal_resize,
        .INT => signal_interrupt,
        .TERM => signal_terminate,
        .TSTP => signal_suspend,
        .CONT => signal_continue,
        else => 0,
    };
}

fn signalNumberBit(number: u32) u8 {
    inline for (managed_signals) |signal| {
        if (number == @intFromEnum(signal)) return signalBit(signal);
    }
    return 0;
}

const SharedWake = struct {
    write_fd: std.posix.fd_t,
    reasons: std.atomic.Value(u8) = .init(0),
    armed: std.atomic.Value(bool) = .init(false),
    closed: std.atomic.Value(bool) = .init(false),
};

pub const Notifier = struct {
    shared: *SharedWake,

    /// Coalesces repeated notifications and never waits for pipe capacity.
    pub fn wake(self: Notifier) WakeError!void {
        try self.notify(wake_reason);
    }

    /// Requests a resize probe on the runtime owner thread.
    pub fn requestResize(self: Notifier) WakeError!void {
        try self.notify(resize_reason);
    }

    fn notify(self: Notifier, reason: u8) WakeError!void {
        const shared = self.shared;
        if (shared.closed.load(.acquire)) return error.Closed;
        _ = shared.reasons.fetchOr(reason, .release);
        if (shared.armed.swap(true, .acq_rel)) return;
        writeWake(shared.write_fd) catch |err| {
            shared.armed.store(false, .release);
            return err;
        };
    }
};

pub const Posix = struct {
    io: std.Io,
    input_file: std.Io.File,
    read_buffer: []u8,
    parser: input.Parser = .{},
    input_active: bool = true,
    eof_pending: bool = false,
    eof_emitted: bool = false,
    parser_deadline_ns: ?i96 = null,
    timers: []TimerSlot,
    timer_count: usize = 0,
    options: Options,
    last_size: ?render.Size,
    pending_resize: ?render.Size = null,
    resize_requested: bool = false,
    resize_deadline_ns: ?i96 = null,
    wakeup_pending: bool = false,
    signal_interrupt_pending: bool = false,
    signal_terminate_pending: bool = false,
    signal_suspend_pending: bool = false,
    signal_continue_pending: bool = false,
    signals: ?*SignalSource,
    source_cursor: usize = 0,
    prefer_input: bool = false,
    wake_read: std.Io.File,
    shared_wake: SharedWake,

    pub fn init(
        io: std.Io,
        input_file: std.Io.File,
        read_buffer: []u8,
        timer_storage: []TimerSlot,
        options: Options,
    ) !Posix {
        if (read_buffer.len == 0) return error.EmptyReadBuffer;
        if (timer_storage.len > std.math.maxInt(u32)) return error.CapacityTooLarge;
        try validateDuration(options.input_timeouts.escape);
        try validateDuration(options.input_timeouts.sequence);
        if (options.resize) |resize| {
            if (resize.initial_size.width == 0 or resize.initial_size.height == 0) return error.InvalidInitialSize;
            try validateDuration(resize.poll_interval);
        }
        if (options.signals) |signals| {
            if (signals.attached) return error.SignalSourceAlreadyAttached;
            if (signals.options.resize and options.resize == null) return error.ResizeUnavailable;
        }

        const now_ns = std.Io.Clock.awake.now(io).nanoseconds;
        const resize_deadline_ns = if (options.resize) |resize|
            if (resize.poll_interval) |interval| try addTime(now_ns, interval.nanoseconds) else null
        else
            null;
        const fds = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
        if (options.signals) |signals| signals.attached = true;
        return .{
            .io = io,
            .input_file = input_file,
            .read_buffer = read_buffer,
            .timers = timer_storage,
            .options = options,
            .signals = options.signals,
            .last_size = if (options.resize) |resize| resize.initial_size else null,
            .resize_deadline_ns = resize_deadline_ns,
            .wake_read = .{ .handle = fds[0], .flags = .{ .nonblocking = true } },
            .shared_wake = .{ .write_fd = fds[1] },
        };
    }

    /// All notifier users must stop before deinitialization.
    pub fn deinit(self: *Posix) void {
        if (self.signals) |signals| signals.attached = false;
        self.shared_wake.closed.store(true, .release);
        self.wake_read.close(self.io);
        (std.Io.File{ .handle = self.shared_wake.write_fd, .flags = .{ .nonblocking = true } }).close(self.io);
        self.* = undefined;
    }

    /// The runtime must remain at a fixed address while this handle is shared.
    pub fn notifier(self: *Posix) Notifier {
        return .{ .shared = &self.shared_wake };
    }

    pub fn now(self: *const Posix) std.Io.Clock.Timestamp {
        return .{ .raw = std.Io.Clock.awake.now(self.io), .clock = .awake };
    }

    pub fn setTimer(self: *Posix, id: TimerId, deadline: std.Io.Clock.Timestamp) TimerSetError!TimerChange {
        if (deadline.clock != .awake) return error.WrongClock;
        for (self.timers[0..self.timer_count], 0..) |slot, index| {
            if (slot.id != id) continue;
            self.timers[index].deadline = deadline;
            self.repairTimer(index);
            return .replaced;
        }
        if (self.timer_count == self.timers.len) return error.CapacityExceeded;
        const index = self.timer_count;
        self.timer_count += 1;
        self.timers[index] = .{ .id = id, .deadline = deadline };
        self.siftTimerUp(index);
        return .inserted;
    }

    pub fn cancelTimer(self: *Posix, id: TimerId) bool {
        for (self.timers[0..self.timer_count], 0..) |slot, index| {
            if (slot.id != id) continue;
            self.removeTimer(index);
            return true;
        }
        return false;
    }

    pub fn timerCount(self: *const Posix) usize {
        return self.timer_count;
    }

    /// Requests a resize probe without writing the wake pipe.
    pub fn requestResize(self: *Posix) error{ResizeUnavailable}!void {
        if (self.options.resize == null) return error.ResizeUnavailable;
        self.resize_requested = true;
    }

    /// Blocks until one event category is delivered successfully.
    pub fn step(self: *Posix, sink: anytype) anyerror!void {
        var poll_storage: [3]PollSlot = undefined;
        return self.stepWithSources(&.{}, &poll_storage, sink);
    }

    /// Polls caller-owned nonblocking descriptors alongside runtime events.
    /// Ready-event callbacks are synchronous and must bound their own work to preserve fairness.
    pub fn stepWithSources(
        self: *Posix,
        sources: []const PollSource,
        poll_storage: []PollSlot,
        sink: anytype,
    ) anyerror!void {
        const required = try requiredPollSlots(sources.len);
        if (poll_storage.len < required) return error.PollStorageTooSmall;
        for (sources) |source| {
            if (!source.file.flags.nonblocking) return error.BlockingPollSource;
        }
        while (true) {
            if (self.wakeup_pending) {
                try sink.emit(Event.wakeup);
                self.wakeup_pending = false;
                return;
            }

            if (self.signal_terminate_pending) {
                try sink.emit(Event{ .signal = .terminate });
                self.signal_terminate_pending = false;
                return;
            }
            if (self.signal_interrupt_pending) {
                try sink.emit(Event{ .signal = .interrupt });
                self.signal_interrupt_pending = false;
                return;
            }
            if (self.signal_suspend_pending) {
                try sink.emit(Event{ .signal = .suspend_requested });
                self.signal_suspend_pending = false;
                return;
            }
            if (self.signal_continue_pending) {
                try sink.emit(Event{ .signal = .continued });
                self.signal_continue_pending = false;
                return;
            }
            if (self.signals) |signals| {
                if (signals.pending_bits != 0) {
                    try self.consumeSignals();
                    continue;
                }
            }

            const now_ns = std.Io.Clock.awake.now(self.io).nanoseconds;
            if (try self.prepareResize(now_ns)) {
                const size = self.pending_resize.?;
                try sink.emit(Event{ .resize = size });
                self.last_size = size;
                self.pending_resize = null;
                return;
            }

            if (self.timer_count != 0 and timerDue(self.timers[0], now_ns)) {
                const timer = self.timers[0];
                try sink.emit(Event{ .timer = .{ .id = timer.id, .deadline = timer.deadline } });
                self.removeDeliveredTimer(timer);
                return;
            }

            if (self.eof_pending) {
                try sink.emit(Event.eof);
                self.eof_pending = false;
                self.eof_emitted = true;
                return;
            }

            if (self.parser_deadline_ns) |deadline| {
                if (deadline <= now_ns) {
                    var delivered = false;
                    var input_sink = InputSink(@TypeOf(sink)){ .target = sink, .delivered = &delivered };
                    switch (self.parser.pending()) {
                        .none => {},
                        .escape => try self.parser.flushEscape(&input_sink),
                        .sequence => try self.parser.abort(&input_sink),
                    }
                    self.updateParserDeadline(now_ns) catch |err| return err;
                    if (delivered) return;
                    continue;
                }
            }

            poll_storage[0] = .{
                .fd = if (self.input_active) self.input_file.handle else -1,
                .events = std.posix.POLL.IN,
                .revents = 0,
            };
            poll_storage[1] = .{
                .fd = self.wake_read.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            };
            poll_storage[2] = .{
                .fd = if (self.signals) |signals| signals.descriptor_file.handle else -1,
                .events = std.posix.POLL.IN,
                .revents = 0,
            };
            for (sources, poll_storage[3..required]) |source, *slot| {
                slot.* = .{
                    .fd = source.file.handle,
                    .events = (if (source.interest.read) @as(i16, std.posix.POLL.IN) else 0) |
                        (if (source.interest.write) @as(i16, std.posix.POLL.OUT) else 0),
                    .revents = 0,
                };
            }
            const poll_fds = poll_storage[0..required];
            _ = try std.posix.poll(poll_fds, self.pollTimeout(now_ns));

            if (poll_fds[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
                try self.consumeWake();
            }
            if (poll_fds[2].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
                try self.consumeSignals();
                continue;
            }

            const input_ready = self.input_active and
                poll_fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR) != 0;
            var ready_source: ?usize = null;
            if (sources.len != 0) {
                var index = self.source_cursor % sources.len;
                for (0..sources.len) |_| {
                    const revents = poll_fds[3 + index].revents;
                    if (revents & std.posix.POLL.NVAL != 0) return error.InvalidPollSource;
                    if (revents != 0) {
                        ready_source = index;
                        break;
                    }
                    index = if (index + 1 == sources.len) 0 else index + 1;
                }
            }

            if (input_ready and (ready_source == null or self.prefer_input)) {
                self.prefer_input = false;
                if (try self.consumeInput(sink)) return;
            }
            if (ready_source) |index| {
                const revents = poll_fds[3 + index].revents;
                self.source_cursor = if (index + 1 == sources.len) 0 else index + 1;
                self.prefer_input = true;
                try sink.emit(Event{ .ready = .{
                    .source_index = index,
                    .readable = revents & (std.posix.POLL.IN | std.posix.POLL.HUP) != 0,
                    .writable = revents & std.posix.POLL.OUT != 0,
                    .hangup = revents & std.posix.POLL.HUP != 0,
                    .error_pending = revents & std.posix.POLL.ERR != 0,
                } });
                return;
            }
        }
    }

    fn consumeInput(self: *Posix, sink: anytype) anyerror!bool {
        const count = std.posix.read(self.input_file.handle, self.read_buffer) catch |err| switch (err) {
            error.WouldBlock => return false,
            else => return err,
        };
        var delivered = false;
        var input_sink = InputSink(@TypeOf(sink)){ .target = sink, .delivered = &delivered };
        if (count == 0) {
            self.input_active = false;
            self.parser.finish(&input_sink) catch |err| {
                self.parser_deadline_ns = null;
                self.eof_pending = true;
                return err;
            };
            self.parser_deadline_ns = null;
            self.eof_pending = !self.eof_emitted;
        } else {
            self.parser.feed(self.read_buffer[0..count], &input_sink) catch |err| {
                self.parser_deadline_ns = null;
                return err;
            };
            try self.updateParserDeadline(std.Io.Clock.awake.now(self.io).nanoseconds);
        }
        return delivered;
    }

    fn prepareResize(self: *Posix, now_ns: i96) !bool {
        const resize = self.options.resize orelse return false;
        const periodic_due = if (self.resize_deadline_ns) |deadline| deadline <= now_ns else false;
        if (self.pending_resize == null and (self.resize_requested or periodic_due)) {
            const size = try terminal.querySize(self.io, resize.file);
            self.resize_requested = false;
            if (resize.poll_interval) |interval| {
                self.resize_deadline_ns = try addTime(now_ns, interval.nanoseconds);
            }
            if (self.last_size) |last| {
                if (last.width == size.width and last.height == size.height) {
                    self.resize_requested = false;
                    return false;
                }
            }
            self.pending_resize = size;
        }
        return self.pending_resize != null;
    }

    fn updateParserDeadline(self: *Posix, now_ns: i96) !void {
        const timeout = switch (self.parser.pending()) {
            .none => null,
            .escape => self.options.input_timeouts.escape,
            .sequence => self.options.input_timeouts.sequence,
        };
        self.parser_deadline_ns = if (timeout) |duration| try addTime(now_ns, duration.nanoseconds) else null;
    }

    fn pollTimeout(self: *const Posix, now_ns: i96) i32 {
        var deadline: ?i96 = self.parser_deadline_ns;
        if (self.timer_count != 0) deadline = earlier(deadline, self.timers[0].deadline.raw.nanoseconds);
        deadline = earlier(deadline, self.resize_deadline_ns);
        const target = deadline orelse return -1;
        if (target <= now_ns) return 0;
        const remaining = std.math.sub(i96, target, now_ns) catch std.math.maxInt(i96);
        var milliseconds = @divTrunc(remaining, std.time.ns_per_ms);
        if (@mod(remaining, std.time.ns_per_ms) != 0) milliseconds += 1;
        return @intCast(@min(milliseconds, std.math.maxInt(i32)));
    }

    fn consumeWake(self: *Posix) !void {
        var buffer: [64]u8 = undefined;
        while (true) {
            const count = std.posix.read(self.wake_read.handle, &buffer) catch |err| switch (err) {
                error.WouldBlock => break,
                else => return err,
            };
            if (count == 0) break;
        }

        const reasons = self.shared_wake.reasons.swap(0, .acq_rel);
        _ = self.shared_wake.armed.swap(false, .acq_rel);
        if (self.shared_wake.reasons.load(.acquire) != 0 and
            !self.shared_wake.armed.swap(true, .acq_rel))
        {
            writeWake(self.shared_wake.write_fd) catch |err| {
                self.shared_wake.armed.store(false, .release);
                return err;
            };
        }
        self.wakeup_pending = self.wakeup_pending or reasons & wake_reason != 0;
        self.resize_requested = self.resize_requested or reasons & resize_reason != 0;
    }

    fn consumeSignals(self: *Posix) !void {
        const signals = self.signals orelse return;
        const pending = try signals.consume();
        self.signal_interrupt_pending = self.signal_interrupt_pending or pending & signal_interrupt != 0;
        self.signal_terminate_pending = self.signal_terminate_pending or pending & signal_terminate != 0;
        self.signal_suspend_pending = self.signal_suspend_pending or pending & signal_suspend != 0;
        self.signal_continue_pending = self.signal_continue_pending or pending & signal_continue != 0;
        self.resize_requested = self.resize_requested or pending & (signal_resize | signal_continue) != 0;
        if (pending & (signal_suspend | signal_continue) != 0) {
            self.parser.reset();
            self.parser_deadline_ns = null;
        }
    }

    fn repairTimer(self: *Posix, index: usize) void {
        if (index != 0 and timerLess(self.timers[index], self.timers[(index - 1) / 2])) {
            self.siftTimerUp(index);
        } else {
            self.siftTimerDown(index);
        }
    }

    fn siftTimerUp(self: *Posix, raw_index: usize) void {
        var index = raw_index;
        while (index != 0) {
            const parent = (index - 1) / 2;
            if (!timerLess(self.timers[index], self.timers[parent])) break;
            std.mem.swap(TimerSlot, &self.timers[index], &self.timers[parent]);
            index = parent;
        }
    }

    fn siftTimerDown(self: *Posix, raw_index: usize) void {
        var index = raw_index;
        while (true) {
            const left = index * 2 + 1;
            if (left >= self.timer_count) return;
            const right = left + 1;
            const child = if (right < self.timer_count and timerLess(self.timers[right], self.timers[left])) right else left;
            if (!timerLess(self.timers[child], self.timers[index])) return;
            std.mem.swap(TimerSlot, &self.timers[index], &self.timers[child]);
            index = child;
        }
    }

    fn removeTimer(self: *Posix, index: usize) void {
        self.timer_count -= 1;
        if (index == self.timer_count) return;
        self.timers[index] = self.timers[self.timer_count];
        self.repairTimer(index);
    }

    fn removeDeliveredTimer(self: *Posix, delivered: TimerSlot) void {
        for (self.timers[0..self.timer_count], 0..) |timer, index| {
            if (timer.id != delivered.id) continue;
            if (timer.deadline.raw.nanoseconds == delivered.deadline.raw.nanoseconds) self.removeTimer(index);
            return;
        }
    }
};

fn InputSink(comptime Sink: type) type {
    return struct {
        target: Sink,
        delivered: *bool,

        pub fn emit(self: *@This(), value: input.Event) !void {
            try self.target.emit(Event{ .input = value });
            self.delivered.* = true;
        }
    };
}

fn timerLess(lhs: TimerSlot, rhs: TimerSlot) bool {
    const lhs_ns = lhs.deadline.raw.nanoseconds;
    const rhs_ns = rhs.deadline.raw.nanoseconds;
    return lhs_ns < rhs_ns or (lhs_ns == rhs_ns and lhs.id < rhs.id);
}

fn timerDue(timer: TimerSlot, now_ns: i96) bool {
    return timer.deadline.raw.nanoseconds <= now_ns;
}

fn earlier(current: ?i96, candidate: ?i96) ?i96 {
    const value = candidate orelse return current;
    return if (current) |existing| @min(existing, value) else value;
}

fn validateDuration(optional: ?std.Io.Duration) !void {
    if (optional) |duration| if (duration.nanoseconds <= 0) return error.InvalidTimeout;
}

fn addTime(timestamp: i96, duration: i96) !i96 {
    return std.math.add(i96, timestamp, duration) catch error.DeadlineOverflow;
}

fn writeWake(fd: std.posix.fd_t) WakeError!void {
    const bytes = [1]u8{1};
    while (true) {
        const result = std.posix.system.write(fd, &bytes, bytes.len);
        switch (std.posix.errno(result)) {
            .SUCCESS => return,
            .INTR => continue,
            .AGAIN => return,
            .BADF, .PIPE => return error.Closed,
            .IO => return error.InputOutput,
            .NOBUFS, .NOMEM => return error.SystemResources,
            else => return error.Unexpected,
        }
    }
}

test "timer heap replaces cancels and orders equal deadlines by id" {
    var read_buffer: [1]u8 = undefined;
    var timers: [3]TimerSlot = undefined;
    const pipe = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const input_file = std.Io.File{ .handle = pipe[0], .flags = .{ .nonblocking = true } };
    defer input_file.close(std.testing.io);
    defer (std.Io.File{ .handle = pipe[1], .flags = .{ .nonblocking = true } }).close(std.testing.io);
    var runtime = try Posix.init(std.testing.io, input_file, &read_buffer, &timers, .{});
    defer runtime.deinit();
    const deadline = runtime.now();
    try std.testing.expectEqual(TimerChange.inserted, try runtime.setTimer(3, deadline));
    try std.testing.expectEqual(TimerChange.inserted, try runtime.setTimer(1, deadline));
    try std.testing.expectEqual(TimerChange.inserted, try runtime.setTimer(2, deadline));
    try std.testing.expectEqual(@as(TimerId, 1), runtime.timers[0].id);
    try std.testing.expectEqual(TimerChange.replaced, try runtime.setTimer(2, deadline));
    try std.testing.expect(runtime.cancelTimer(2));
    try std.testing.expect(!runtime.cancelTimer(99));
    try std.testing.expectEqual(@as(usize, 2), runtime.timerCount());
}
