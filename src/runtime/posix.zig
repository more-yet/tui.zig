const std = @import("std");
const input = @import("../input.zig");
const render = @import("../render.zig");
const terminal = @import("../terminal.zig");

pub const TimerId = u32;

pub const TimerSlot = struct {
    id: TimerId,
    deadline: std.Io.Clock.Timestamp,
};

pub const TimerEvent = struct {
    id: TimerId,
    deadline: std.Io.Clock.Timestamp,
};

const max_input_bytes_per_turn: usize = input.Parser.max_paste_chunk_bytes;

const InputProgress = struct {
    bytes_consumed: usize,
    event: ?Event,
};

/// Input payload slices remain valid until the next runtime step.
pub const Event = union(enum) {
    input: input.Event,
    input_failure: input.Parser.Failure,
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
    const required = std.math.add(usize, source_count, 3) catch return error.CapacityTooLarge;
    if (required > std.math.maxInt(u32)) return error.CapacityTooLarge;
    return required;
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
    escape: std.Io.Duration = .fromMilliseconds(50),
    sequence: std.Io.Duration = .fromMilliseconds(250),
};

pub const ResizeSource = struct {
    file: std.Io.File,
    initial_size: render.Size,
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
    Interrupted,
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

var signal_source_installed: std.atomic.Value(bool) = .init(false);

pub const SignalSource = struct {
    io: std.Io,
    options: SignalOptions,
    descriptor_file: std.Io.File,
    old_mask: std.posix.sigset_t,
    owner_thread: std.Thread.Id,
    attached: bool = false,

    /// Install before starting worker threads so they inherit the managed signal mask.
    pub fn init(io: std.Io, options: SignalOptions) !SignalSource {
        const selected = selectedSignals(options);
        if (selected == 0) return error.NoSignalsSelected;
        if (signal_source_installed.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
            return error.AlreadyInstalled;
        }
        errdefer signal_source_installed.store(false, .release);

        return initSignalSourceLinux(io, options, selected);
    }

    /// The source must be detached and all worker threads stopped first.
    pub fn deinit(self: *SignalSource) error{ WrongThread, SourceAttached }!void {
        if (self.owner_thread != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.attached) return error.SourceAttached;
        self.descriptor_file.close(self.io);
        std.posix.sigprocmask(std.posix.SIG.SETMASK, &self.old_mask, null);
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
    }

    fn consume(self: *SignalSource) !u8 {
        var records: [8]std.os.linux.signalfd_siginfo = undefined;
        const count = readOnce(self.descriptor_file.handle, std.mem.sliceAsBytes(&records)) catch |err| switch (err) {
            error.WouldBlock => return 0,
            error.InvalidDescriptor => return error.InvalidSignalDescriptor,
            else => return err,
        };
        if (count % @sizeOf(std.os.linux.signalfd_siginfo) != 0) return error.Unexpected;
        var result: u8 = 0;
        for (records[0 .. count / @sizeOf(std.os.linux.signalfd_siginfo)]) |record| {
            result |= signalNumberBit(record.signo);
        }
        return result;
    }
};

const InputLifecycle = enum {
    reading,
    draining,
    eof_pending,
    ended,
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
        .descriptor_file = .{ .handle = fd, .flags = .{ .nonblocking = true } },
        .old_mask = old_mask,
        .owner_thread = std.Thread.getCurrentId(),
    };
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
    fd: std.posix.fd_t,
    reasons: std.atomic.Value(u8) = .init(0),
};

pub const Notifier = struct {
    shared: *SharedWake,

    /// Coalesces repeated notifications and never waits for event-counter capacity.
    pub fn wake(self: Notifier) WakeError!void {
        try self.notify(wake_reason);
    }

    /// Requests a resize probe on the runtime owner thread.
    pub fn requestResize(self: Notifier) WakeError!void {
        try self.notify(resize_reason);
    }

    fn notify(self: Notifier, reason: u8) WakeError!void {
        const shared = self.shared;
        _ = shared.reasons.fetchOr(reason, .release);
        try writeWake(shared.fd);
    }
};

pub const Posix = struct {
    io: std.Io,
    input_file: std.Io.File,
    read_buffer: []u8,
    parser: input.Parser = .{},
    input_start: usize = 0,
    input_end: usize = 0,
    input_lifecycle: InputLifecycle = .reading,
    parser_deadline_ns: ?i96 = null,
    timers: []TimerSlot,
    timer_count: usize = 0,
    options: Options,
    last_size: ?render.Size,
    resize_requested: bool = false,
    wakeup_pending: bool = false,
    signal_interrupt_pending: bool = false,
    signal_terminate_pending: bool = false,
    signal_suspend_pending: bool = false,
    signal_continue_pending: bool = false,
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
        if (!input_file.flags.nonblocking) return error.BlockingInput;
        const input_nonblocking = descriptorIsNonblocking(input_file.handle) catch |err| switch (err) {
            error.InvalidDescriptor => return error.InvalidInputDescriptor,
            else => return err,
        };
        if (!input_nonblocking) return error.BlockingInput;
        try validateDuration(options.input_timeouts.escape);
        try validateDuration(options.input_timeouts.sequence);
        if (options.resize) |resize| {
            if (resize.initial_size.width == 0 or resize.initial_size.height == 0) return error.InvalidInitialSize;
        }
        if (options.signals) |signals| {
            if (signals.attached) return error.SignalSourceAlreadyAttached;
            if (signals.owner_thread != std.Thread.getCurrentId()) return error.WrongThread;
            if (signals.options.resize and options.resize == null) return error.ResizeUnavailable;
        }

        const wake_fd = try createWakeFd();
        if (options.signals) |signals| signals.attached = true;
        return .{
            .io = io,
            .input_file = input_file,
            .read_buffer = read_buffer,
            .timers = timer_storage,
            .options = options,
            .last_size = if (options.resize) |resize| resize.initial_size else null,
            .wake_read = .{ .handle = wake_fd, .flags = .{ .nonblocking = true } },
            .shared_wake = .{ .fd = wake_fd },
        };
    }

    /// All notifier users must stop before deinitialization.
    pub fn deinit(self: *Posix) void {
        if (self.options.signals) |signals| signals.attached = false;
        self.wake_read.close(self.io);
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

    /// Requests a resize probe without writing the wake event counter.
    pub fn requestResize(self: *Posix) error{ResizeUnavailable}!void {
        if (self.options.resize == null) return error.ResizeUnavailable;
        self.resize_requested = true;
    }

    /// Blocks until one event is available. With no local work or deadline, the
    /// owner thread sleeps in an indefinite readiness wait.
    pub fn step(self: *Posix) !Event {
        var poll_storage: [3]PollSlot = undefined;
        return self.stepWithSources(&.{}, &poll_storage);
    }

    /// Blocks until one runtime or caller-source event is available. With no
    /// local work or deadline, the owner thread sleeps indefinitely.
    pub fn stepWithSources(
        self: *Posix,
        sources: []const PollSource,
        poll_storage: []PollSlot,
    ) !Event {
        try self.validatePollArguments(sources, poll_storage);
        while (true) {
            if (try self.pollTurn(sources, poll_storage, true)) |event| return event;
        }
    }

    /// Performs one bounded, non-waiting runtime turn. Use this only to
    /// interleave actual runnable work; it is not an idle-loop primitive.
    /// `null` means this turn produced no event; buffered parser work may remain.
    pub fn pollWithSources(
        self: *Posix,
        sources: []const PollSource,
        poll_storage: []PollSlot,
    ) !?Event {
        try self.validatePollArguments(sources, poll_storage);
        return self.pollTurn(sources, poll_storage, false);
    }

    fn validatePollArguments(
        self: *Posix,
        sources: []const PollSource,
        poll_storage: []PollSlot,
    ) !void {
        const required = try requiredPollSlots(sources.len);
        if (poll_storage.len < required) return error.PollStorageTooSmall;
        if (self.options.signals) |signals| {
            if (signals.owner_thread != std.Thread.getCurrentId()) return error.WrongThread;
        }
        for (sources) |source| {
            if (!source.file.flags.nonblocking) return error.BlockingPollSource;
            const source_nonblocking = descriptorIsNonblocking(source.file.handle) catch |err| switch (err) {
                error.InvalidDescriptor => return error.InvalidPollSource,
                else => return err,
            };
            if (!source_nonblocking) return error.BlockingPollSource;
        }
    }

    fn pollTurn(
        self: *Posix,
        sources: []const PollSource,
        poll_storage: []PollSlot,
        wait: bool,
    ) !?Event {
        if (self.takePendingControl()) |event| return event;

        var now_ns = std.Io.Clock.awake.now(self.io).nanoseconds;
        if (try self.takeResize()) |event| return event;
        if (self.takeDueTimer(now_ns)) |event| return event;
        if (self.takeEof()) |event| return event;

        if (self.parser_deadline_ns) |deadline| {
            if (deadline <= now_ns) {
                const result = switch (self.parser.pending()) {
                    .none => input.Parser.Result{ .consumed = 0, .outcome = .need_more },
                    .escape => self.parser.resolveEscape(),
                    .sequence => self.parser.cancelPending(),
                };
                try self.updateParserDeadline(now_ns);
                if (parserEvent(result)) |event| return event;
            }
        }

        const required = try requiredPollSlots(sources.len);
        poll_storage[0] = .{
            .fd = if (self.input_lifecycle == .reading) self.input_file.handle else -1,
            .events = std.posix.POLL.IN,
            .revents = 0,
        };
        poll_storage[1] = .{
            .fd = self.wake_read.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        };
        poll_storage[2] = .{
            .fd = if (self.options.signals) |signals| signals.descriptor_file.handle else -1,
            .events = std.posix.POLL.IN,
            .revents = 0,
        };
        for (sources, poll_storage[3..required]) |source, *slot| {
            const interested = source.interest.read or source.interest.write;
            slot.* = .{
                .fd = if (interested) source.file.handle else -1,
                .events = (if (source.interest.read) @as(i16, std.posix.POLL.IN) else 0) |
                    (if (source.interest.write) @as(i16, std.posix.POLL.OUT) else 0),
                .revents = 0,
            };
        }

        const local_input_work = self.parser.hasQueuedEvent() or
            self.input_start != self.input_end or self.input_lifecycle == .draining;
        const timer_deadline_ns: ?i96 = if (self.timer_count == 0)
            null
        else
            self.timers[0].deadline.raw.nanoseconds;
        const timeout = pollTimeout(
            wait,
            local_input_work,
            now_ns,
            timer_deadline_ns,
            self.parser_deadline_ns,
        );
        const poll_fds = poll_storage[0..required];
        _ = try pollOnce(poll_fds, timeout);

        if (poll_fds[0].revents & std.posix.POLL.NVAL != 0) return error.InvalidInputDescriptor;
        if (poll_fds[1].revents & std.posix.POLL.NVAL != 0) return error.InvalidWakeDescriptor;
        if (poll_fds[2].revents & std.posix.POLL.NVAL != 0) return error.InvalidSignalDescriptor;

        if (poll_fds[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
            try self.consumeWake();
        }
        if (poll_fds[2].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
            try self.consumeSignals();
        }
        if (self.takePendingControl()) |event| return event;

        now_ns = std.Io.Clock.awake.now(self.io).nanoseconds;
        if (try self.takeResize()) |event| return event;
        if (self.takeDueTimer(now_ns)) |event| return event;
        if (self.takeEof()) |event| return event;

        const input_ready = self.parser.hasQueuedEvent() or
            self.input_start != self.input_end or self.input_lifecycle == .draining or
            self.input_lifecycle == .reading and poll_fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR) != 0;
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
            if (try self.consumeInputQuantum()) |event| return event;
        }
        if (ready_source) |index| {
            const revents = poll_fds[3 + index].revents;
            self.source_cursor = if (index + 1 == sources.len) 0 else index + 1;
            self.prefer_input = true;
            return .{ .ready = .{
                .source_index = index,
                .readable = revents & (std.posix.POLL.IN | std.posix.POLL.HUP) != 0,
                .writable = revents & std.posix.POLL.OUT != 0,
                .hangup = revents & std.posix.POLL.HUP != 0,
                .error_pending = revents & std.posix.POLL.ERR != 0,
            } };
        }
        return null;
    }

    fn takePendingControl(self: *Posix) ?Event {
        if (self.wakeup_pending) {
            self.wakeup_pending = false;
            return .wakeup;
        }
        if (self.signal_terminate_pending) {
            self.signal_terminate_pending = false;
            return .{ .signal = .terminate };
        }
        if (self.signal_interrupt_pending) {
            self.signal_interrupt_pending = false;
            return .{ .signal = .interrupt };
        }
        if (self.signal_suspend_pending) {
            self.signal_suspend_pending = false;
            return .{ .signal = .suspend_requested };
        }
        if (self.signal_continue_pending) {
            self.signal_continue_pending = false;
            return .{ .signal = .continued };
        }
        return null;
    }

    fn takeResize(self: *Posix) !?Event {
        const resize = self.options.resize orelse return null;
        if (!self.resize_requested) return null;
        const size = try terminal.querySize(resize.file);
        self.resize_requested = false;
        if (self.last_size) |last| {
            if (last.width == size.width and last.height == size.height) return null;
        }
        self.last_size = size;
        return .{ .resize = size };
    }

    fn takeDueTimer(self: *Posix, now_ns: i96) ?Event {
        if (self.timer_count == 0 or !timerDue(self.timers[0], now_ns)) return null;
        const timer = self.timers[0];
        self.removeTimer(0);
        return .{ .timer = .{ .id = timer.id, .deadline = timer.deadline } };
    }

    fn takeEof(self: *Posix) ?Event {
        if (self.input_lifecycle != .eof_pending) return null;
        self.input_lifecycle = .ended;
        return .eof;
    }

    fn consumeInputQuantum(self: *Posix) !?Event {
        var remaining = max_input_bytes_per_turn;
        while (remaining != 0) {
            const progress = try self.consumeInput(remaining);
            if (progress.event) |event| return event;
            if (progress.bytes_consumed == 0) return null;
            std.debug.assert(progress.bytes_consumed <= remaining);
            remaining -= progress.bytes_consumed;
        }
        return null;
    }

    fn consumeInput(self: *Posix, byte_budget: usize) !InputProgress {
        std.debug.assert(byte_budget != 0);
        if (self.parser.hasQueuedEvent()) {
            const result = self.parser.next("");
            return .{ .bytes_consumed = 0, .event = parserEvent(result) };
        }
        if (self.input_lifecycle == .draining) {
            std.debug.assert(self.input_start == self.input_end);
            const result = self.parser.endInput();
            if (result.outcome == .done) {
                self.input_lifecycle = .eof_pending;
            }
            return .{ .bytes_consumed = 0, .event = parserEvent(result) };
        }

        if (self.input_start == self.input_end) {
            std.debug.assert(self.input_lifecycle == .reading);
            const read_buffer = self.read_buffer[0..@min(self.read_buffer.len, byte_budget)];
            const count = readOnce(self.input_file.handle, read_buffer) catch |err| switch (err) {
                error.WouldBlock => return .{ .bytes_consumed = 0, .event = null },
                error.InvalidDescriptor => return error.InvalidInputDescriptor,
                else => return err,
            };
            self.input_start = 0;
            self.input_end = count;
            if (count == 0) {
                self.input_lifecycle = .draining;
                self.parser_deadline_ns = null;
                return .{ .bytes_consumed = 0, .event = null };
            }
        }

        const parse_end = @min(self.input_end, self.input_start + byte_budget);
        const result = self.parser.next(self.read_buffer[self.input_start..parse_end]);
        self.input_start += result.consumed;
        if (self.input_start == self.input_end) {
            self.input_start = 0;
            self.input_end = 0;
        }
        try self.updateParserDeadline(std.Io.Clock.awake.now(self.io).nanoseconds);
        return .{
            .bytes_consumed = result.consumed,
            .event = parserEvent(result),
        };
    }

    fn updateParserDeadline(self: *Posix, now_ns: i96) !void {
        const timeout = switch (self.parser.pending()) {
            .none => null,
            .escape => self.options.input_timeouts.escape,
            .sequence => self.options.input_timeouts.sequence,
        };
        self.parser_deadline_ns = if (timeout) |duration| try addTime(now_ns, duration.nanoseconds) else null;
    }

    fn consumeWake(self: *Posix) !void {
        var count: u64 = 0;
        const bytes_read = readOnce(self.wake_read.handle, std.mem.asBytes(&count)) catch |err| switch (err) {
            error.WouldBlock => 0,
            error.InvalidDescriptor => return error.InvalidWakeDescriptor,
            else => return err,
        };
        if (bytes_read != 0 and bytes_read != @sizeOf(u64)) return error.Unexpected;

        const reasons = self.shared_wake.reasons.swap(0, .acq_rel);
        self.wakeup_pending = self.wakeup_pending or reasons & wake_reason != 0;
        self.resize_requested = self.resize_requested or reasons & resize_reason != 0;
    }

    fn consumeSignals(self: *Posix) !void {
        const signals = self.options.signals orelse return;
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
            if (index > (std.math.maxInt(usize) - 1) / 2) return;
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
};

fn descriptorIsNonblocking(fd: std.posix.fd_t) !bool {
    const result = std.posix.system.fcntl(fd, std.posix.F.GETFL, @as(usize, 0));
    return switch (std.posix.errno(result)) {
        .SUCCESS => @as(usize, @intCast(result)) & (@as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK")) != 0,
        .INTR => error.Interrupted,
        .BADF => error.InvalidDescriptor,
        else => error.Unexpected,
    };
}

fn pollOnce(fds: []std.posix.pollfd, timeout: i32) !usize {
    const result = std.posix.system.poll(fds.ptr, @intCast(fds.len), timeout);
    return switch (std.posix.errno(result)) {
        .SUCCESS => @intCast(result),
        .INTR => error.Interrupted,
        .NOMEM => error.SystemResources,
        .INVAL => error.InvalidPollArguments,
        else => error.Unexpected,
    };
}

fn readOnce(fd: std.posix.fd_t, buffer: []u8) !usize {
    if (buffer.len == 0) return 0;
    const result = std.posix.system.read(fd, buffer.ptr, @min(buffer.len, 0x7fff_f000));
    return switch (std.posix.errno(result)) {
        .SUCCESS => @intCast(result),
        .INTR => error.Interrupted,
        .AGAIN => error.WouldBlock,
        .BADF => error.InvalidDescriptor,
        .IO => error.InputOutput,
        .ISDIR => error.IsDir,
        .NOBUFS, .NOMEM => error.SystemResources,
        .NOTCONN => error.SocketUnconnected,
        .CONNRESET => error.ConnectionResetByPeer,
        .CANCELED => error.Canceled,
        else => error.Unexpected,
    };
}

fn parserEvent(result: input.Parser.Result) ?Event {
    return switch (result.outcome) {
        .event => |value| .{ .input = value },
        .failure => |failure| .{ .input_failure = failure },
        .need_more, .done => null,
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

fn pollTimeout(
    wait: bool,
    local_input_work: bool,
    now_ns: i96,
    timer_deadline_ns: ?i96,
    parser_deadline_ns: ?i96,
) i32 {
    if (!wait or local_input_work) return 0;
    const target = earlier(timer_deadline_ns, parser_deadline_ns) orelse return -1;
    if (target <= now_ns) return 0;
    const remaining = std.math.sub(i96, target, now_ns) catch std.math.maxInt(i96);
    var milliseconds = @divTrunc(remaining, std.time.ns_per_ms);
    if (@mod(remaining, std.time.ns_per_ms) != 0) milliseconds += 1;
    return @intCast(@min(milliseconds, std.math.maxInt(i32)));
}

fn validateDuration(duration: std.Io.Duration) !void {
    if (duration.nanoseconds <= 0) return error.InvalidTimeout;
}

fn addTime(timestamp: i96, duration: i96) !i96 {
    return std.math.add(i96, timestamp, duration) catch error.DeadlineOverflow;
}

fn createWakeFd() !std.posix.fd_t {
    const result = std.os.linux.eventfd(0, std.os.linux.EFD.NONBLOCK | std.os.linux.EFD.CLOEXEC);
    return switch (std.os.linux.errno(result)) {
        .SUCCESS => @intCast(result),
        .MFILE, .NFILE, .NODEV, .NOMEM => error.SystemResources,
        else => error.Unexpected,
    };
}

fn writeWake(fd: std.posix.fd_t) WakeError!void {
    const count: u64 = 1;
    const bytes = std.mem.asBytes(&count);
    const result = std.posix.system.write(fd, bytes.ptr, bytes.len);
    switch (std.posix.errno(result)) {
        .SUCCESS => return,
        .INTR => return error.Interrupted,
        .AGAIN => return,
        .BADF, .PIPE => return error.Closed,
        .IO => return error.InputOutput,
        .NOBUFS, .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }
}
