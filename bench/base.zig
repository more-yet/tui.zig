const std = @import("std");
const tui = @import("tui");
const assistant_demo = @import("assistant_demo");

const batch_count = 9;
const default_iterations = 250_000;
const clipboard_benchmark_bytes = 4_096;
const terminal_size = tui.render.Size{ .width = 120, .height = 40 };
const capabilities = tui.terminal.Capabilities{
    .color_depth = .truecolor,
    .synchronized_output = true,
    .background_color_erase = true,
};
const text_area_initial =
    "00 bounded multiline editor\n" ++
    "01 caller-owned storage\n" ++
    "02 grapheme-safe movement\n" ++
    "03 deterministic selection\n" ++
    "04 horizontal viewport\n" ++
    "05 logical-row scrolling\n" ++
    "06 explicit edit failures\n" ++
    "07 fragmented paste input\n" ++
    "08 canonical LF newlines\n" ++
    "09 wide glyph: \xE7\x95\x8C\n" ++
    "10 combining glyph: e\xCC\x81\n" ++
    "11 visible row drawing\n" ++
    "12 selection styling\n" ++
    "13 caret rendering\n" ++
    "14 clipped surfaces\n" ++
    "15 bounded renderer state\n" ++
    "16 no retained events\n" ++
    "17 no steady allocation\n" ++
    "18 incremental updates\n" ++
    "19 predictable ownership\n" ++
    "20 terminal-safe output\n" ++
    "21 Unicode width profiles\n" ++
    "22 viewport away from zero\n" ++
    "23 final editable row";

const Scenario = enum {
    no_op,
    single_cell,
    surface_cell,
    widget_cell,
    text_line,
    styled_line,
    wrap_text,
    wrapped_paragraph,
    wrapped_styled,
    layout_split,
    layout_grid,
    focus_route,
    command_match,
    transport_spsc,
    owned_event_key,
    owned_event_paste,
    runtime_timer_heap,
    runtime_wakeup,
    runtime_signal,
    runtime_source_ready,
    pty_spawn,
    capability_negotiation,
    hyperlink_output,
    clipboard_4k,
    notification_dispatch,
    scrollback_append,
    line_decode,
    process_output_batch,
    editor_middle_edit,
    line_break_scan,
    app_cycle,
    theme_resolve,
    display_panel,
    display_gauge,
    display_widgets,
    form_controls,
    text_input,
    text_input_selection,
    text_area,
    text_area_soft_wrap,
    assistant_cycle,
    scrollback_view,
    list_view,
    table_view,
    overlay_modal,
    sparse_cells,
    small_fill,
    scrolling,
    unicode_style,
    full_fill,
    terminal_recovery,
    hardware_cursor,
    resize,
};

const Totals = struct {
    cells_compared: u64 = 0,
    cells_changed: u64 = 0,
    runs: u64 = 0,

    fn add(self: *Totals, stats: tui.render.FrameStats) void {
        self.cells_compared += stats.cells_compared;
        self.cells_changed += stats.cells_changed;
        self.runs += stats.runs;
    }
};

pub fn main(init: std.process.Init) !void {
    @setEvalBranchQuota(4_000);
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 3) return error.InvalidArguments;
    var selected: ?Scenario = null;
    var iterations: usize = default_iterations;
    if (args.len >= 2) {
        if (std.meta.stringToEnum(Scenario, args[1])) |scenario| {
            selected = scenario;
            if (args.len == 3) iterations = try std.fmt.parseInt(usize, args[2], 10);
        } else {
            if (args.len != 2) return error.InvalidArguments;
            iterations = try std.fmt.parseInt(usize, args[1], 10);
        }
    }
    if (iterations == 0 or iterations > (std.math.maxInt(usize) - 1_000) / batch_count) {
        return error.InvalidArguments;
    }

    var stdout_buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &file_writer.interface;

    inline for (std.meta.tags(Scenario)) |scenario| {
        if (selected == null or selected.? == scenario) switch (scenario) {
            inline else => |active| switch (active) {
                .command_match => try runCommandScenario(init, stdout, iterations),
                .transport_spsc => try runTransportScenario(init, stdout, iterations),
                .owned_event_key, .owned_event_paste => try runOwnedEventScenario(init, stdout, active, iterations),
                .runtime_timer_heap => try runRuntimeTimerScenario(init, stdout, iterations),
                .runtime_wakeup => try runRuntimeWakeScenario(init, stdout, iterations),
                .runtime_signal => try runRuntimeSignalScenario(init, stdout, iterations),
                .runtime_source_ready => try runRuntimeSourceScenario(init, stdout, iterations),
                .pty_spawn => try runPtySpawnScenario(init, stdout, iterations),
                .capability_negotiation => try runCapabilityScenario(init, stdout, iterations),
                .hyperlink_output => try runHyperlinkScenario(init, stdout, iterations),
                .clipboard_4k => try runClipboardScenario(init, stdout, iterations),
                .notification_dispatch => try runNotificationScenario(init, stdout, iterations),
                .scrollback_append => try runScrollbackScenario(init, stdout, iterations),
                .line_decode => try runLineDecodeScenario(init, stdout, iterations),
                .process_output_batch => try runProcessOutputBatchScenario(init, stdout, iterations),
                .editor_middle_edit => try runEditorScenario(init, stdout, iterations),
                .line_break_scan => try runLineBreakScenario(init, stdout, iterations),
                else => try runScenario(init, stdout, active, iterations),
            },
        };
    }
    try stdout.flush();
}

fn runTransportScenario(init: std.process.Init, stdout: *std.Io.Writer, iterations: usize) !void {
    const Queue = tui.transport.Spsc(u64);
    var storage: [64]u64 = undefined;
    var queue = try Queue.init(&storage);
    const warmup_iterations = @min(iterations, 1_000);
    var checksum: u64 = 0;
    transportBatch(&queue, warmup_iterations, &checksum);

    var samples_ps: [batch_count]u64 = undefined;
    var batch: usize = 0;
    while (batch < batch_count) : (batch += 1) {
        const start = std.Io.Clock.awake.now(init.io);
        transportBatch(&queue, iterations, &checksum);
        const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        if (elapsed <= 0) return error.ClockFailure;
        const elapsed_ns = std.math.cast(u64, elapsed) orelse return error.ClockFailure;
        samples_ps[batch] = @intCast((@as(u128, elapsed_ns) * 1_000) / iterations);
    }
    std.mem.sort(u64, &samples_ps, {}, std.sort.asc(u64));
    std.mem.doNotOptimizeAway(checksum);
    try writeNonRenderResult(stdout, .transport_spsc, iterations, samples_ps);
}

fn transportBatch(queue: *tui.transport.Spsc(u64), iterations: usize, checksum: *u64) void {
    var offset: usize = 0;
    while (offset < iterations) {
        const count = @min(queue.capacity(), iterations - offset);
        for (0..count) |index| queue.trySend(@intCast(offset + index)) catch unreachable;
        for (0..count) |_| checksum.* +%= queue.tryReceive().?;
        offset += count;
    }
}

fn runOwnedEventScenario(
    init: std.process.Init,
    stdout: *std.Io.Writer,
    comptime scenario: Scenario,
    iterations: usize,
) !void {
    const Owned = tui.input.OwnedEvent(tui.input.Parser.max_event_payload_bytes);
    const paste: [tui.input.Parser.max_paste_chunk_bytes]u8 = @splat('p');
    var checksum: u64 = 0;
    const warmup_iterations = @min(iterations, 1_000);
    for (0..warmup_iterations) |_| checksum +%= try ownedEventIteration(Owned, scenario, &paste);

    var samples_ps: [batch_count]u64 = undefined;
    var batch: usize = 0;
    while (batch < batch_count) : (batch += 1) {
        const start = std.Io.Clock.awake.now(init.io);
        for (0..iterations) |_| checksum +%= try ownedEventIteration(Owned, scenario, &paste);
        const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        if (elapsed <= 0) return error.ClockFailure;
        const elapsed_ns = std.math.cast(u64, elapsed) orelse return error.ClockFailure;
        samples_ps[batch] = @intCast((@as(u128, elapsed_ns) * 1_000) / iterations);
    }
    std.mem.sort(u64, &samples_ps, {}, std.sort.asc(u64));
    std.mem.doNotOptimizeAway(checksum);
    try writeNonRenderResult(stdout, scenario, iterations, samples_ps);
}

inline fn ownedEventIteration(
    comptime Owned: type,
    comptime scenario: Scenario,
    paste: []const u8,
) !u64 {
    var owned = switch (scenario) {
        .owned_event_key => try Owned.init(.{ .key = .{ .code = .down } }),
        .owned_event_paste => try Owned.init(.{ .paste_chunk = paste }),
        else => unreachable,
    };
    std.mem.doNotOptimizeAway(&owned);
    return switch (owned.borrow()) {
        .key => |key| @intFromEnum(std.meta.activeTag(key.code)),
        .paste_chunk => |bytes| bytes[0] + bytes[bytes.len - 1],
        else => unreachable,
    };
}

fn writeNonRenderResult(
    stdout: *std.Io.Writer,
    scenario: Scenario,
    iterations: usize,
    samples_ps: [batch_count]u64,
) !void {
    try stdout.print(
        "{{\"scenario\":\"{s}\",\"optimize\":\"ReleaseFast\",\"width\":0,\"height\":0,\"iterations\":{d},\"frames\":{d},\"ps_median\":{d},\"ps_p95\":{d},\"allocator_calls\":0,\"allocated_bytes\":0,\"ansi_bytes\":0,\"cells_compared\":0,\"cells_changed\":0,\"runs\":0}}\n",
        .{
            @tagName(scenario),
            iterations,
            iterations * batch_count,
            samples_ps[batch_count / 2],
            samples_ps[batch_count - 1],
        },
    );
}

fn runRuntimeTimerScenario(init: std.process.Init, stdout: *std.Io.Writer, iterations: usize) !void {
    const pipe = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const input_file = std.Io.File{ .handle = pipe[0], .flags = .{ .nonblocking = true } };
    const input_writer = std.Io.File{ .handle = pipe[1], .flags = .{ .nonblocking = true } };
    defer input_file.close(init.io);
    defer input_writer.close(init.io);
    var read_buffer: [8]u8 = undefined;
    var timer_storage: [64]tui.runtime.TimerSlot = undefined;
    var runtime = try tui.runtime.Posix.init(init.io, input_file, &read_buffer, &timer_storage, .{});
    defer runtime.deinit();
    const base = runtime.now();
    for (0..timer_storage.len) |index| {
        var deadline = base;
        deadline.raw.nanoseconds += @as(i96, @intCast(index + 1)) * std.time.ns_per_s;
        _ = try runtime.setTimer(@intCast(index), deadline);
    }

    var checksum: u64 = 0;
    const warmup_iterations = @min(iterations, 1_000);
    runtimeTimerBatch(&runtime, base, warmup_iterations, &checksum);
    var samples_ps: [batch_count]u64 = undefined;
    var batch: usize = 0;
    while (batch < batch_count) : (batch += 1) {
        const start = std.Io.Clock.awake.now(init.io);
        runtimeTimerBatch(&runtime, base, iterations, &checksum);
        const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        if (elapsed <= 0) return error.ClockFailure;
        const elapsed_ns = std.math.cast(u64, elapsed) orelse return error.ClockFailure;
        samples_ps[batch] = @intCast((@as(u128, elapsed_ns) * 1_000) / iterations);
    }
    std.mem.sort(u64, &samples_ps, {}, std.sort.asc(u64));
    std.mem.doNotOptimizeAway(checksum);
    try writeNonRenderResult(stdout, .runtime_timer_heap, iterations, samples_ps);
}

fn runtimeTimerBatch(
    runtime: *tui.runtime.Posix,
    base: std.Io.Clock.Timestamp,
    iterations: usize,
    checksum: *u64,
) void {
    for (0..iterations) |iteration| {
        const id: tui.runtime.TimerId = @intCast(iteration % 64);
        var deadline = base;
        deadline.raw.nanoseconds += @as(i96, @intCast(1 + (iteration * 17) % 64)) * std.time.ns_per_s;
        const change = runtime.setTimer(id, deadline) catch unreachable;
        checksum.* +%= @intFromEnum(change);
    }
}

fn runRuntimeWakeScenario(init: std.process.Init, stdout: *std.Io.Writer, iterations: usize) !void {
    const pipe = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const input_file = std.Io.File{ .handle = pipe[0], .flags = .{ .nonblocking = true } };
    const input_writer = std.Io.File{ .handle = pipe[1], .flags = .{ .nonblocking = true } };
    defer input_file.close(init.io);
    defer input_writer.close(init.io);
    var read_buffer: [8]u8 = undefined;
    var timer_storage: [0]tui.runtime.TimerSlot = .{};
    var runtime = try tui.runtime.Posix.init(init.io, input_file, &read_buffer, &timer_storage, .{});
    defer runtime.deinit();
    const notifier = runtime.notifier();
    try notifier.wake();
    for (0..@min(iterations, 1_000)) |_| try notifier.wake();

    var samples_ps: [batch_count]u64 = undefined;
    var batch: usize = 0;
    while (batch < batch_count) : (batch += 1) {
        const start = std.Io.Clock.awake.now(init.io);
        for (0..iterations) |_| notifier.wake() catch unreachable;
        const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        if (elapsed <= 0) return error.ClockFailure;
        const elapsed_ns = std.math.cast(u64, elapsed) orelse return error.ClockFailure;
        samples_ps[batch] = @intCast((@as(u128, elapsed_ns) * 1_000) / iterations);
    }
    std.mem.sort(u64, &samples_ps, {}, std.sort.asc(u64));
    try writeNonRenderResult(stdout, .runtime_wakeup, iterations, samples_ps);
}

fn runRuntimeSignalScenario(init: std.process.Init, stdout: *std.Io.Writer, iterations: usize) !void {
    var signal_source = try tui.runtime.SignalSource.init(init.io, .{
        .resize = false,
        .interrupt = true,
        .terminate = false,
        .suspend_resume = false,
    });
    defer signal_source.deinit();
    const pipe = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const input_file = std.Io.File{ .handle = pipe[0], .flags = .{ .nonblocking = true } };
    const input_writer = std.Io.File{ .handle = pipe[1], .flags = .{ .nonblocking = true } };
    defer input_file.close(init.io);
    defer input_writer.close(init.io);
    var read_buffer: [8]u8 = undefined;
    var timer_storage: [0]tui.runtime.TimerSlot = .{};
    var runtime = try tui.runtime.Posix.init(init.io, input_file, &read_buffer, &timer_storage, .{
        .signals = &signal_source,
    });
    defer runtime.deinit();
    const Sink = struct {
        count: usize = 0,

        pub fn emit(self: *@This(), event: tui.runtime.Event) !void {
            if (event == .signal and event.signal == .interrupt) self.count += 1;
        }
    };
    var sink: Sink = .{};
    const pid = std.posix.system.getpid();
    for (0..@min(iterations, 100)) |_| {
        try std.posix.kill(pid, .INT);
        try runtime.step(&sink);
    }

    var samples_ps: [batch_count]u64 = undefined;
    var batch: usize = 0;
    while (batch < batch_count) : (batch += 1) {
        const start = std.Io.Clock.awake.now(init.io);
        for (0..iterations) |_| {
            std.posix.kill(pid, .INT) catch unreachable;
            runtime.step(&sink) catch unreachable;
        }
        const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        if (elapsed <= 0) return error.ClockFailure;
        const elapsed_ns = std.math.cast(u64, elapsed) orelse return error.ClockFailure;
        samples_ps[batch] = @intCast((@as(u128, elapsed_ns) * 1_000) / iterations);
    }
    std.mem.sort(u64, &samples_ps, {}, std.sort.asc(u64));
    std.mem.doNotOptimizeAway(sink.count);
    try writeNonRenderResult(stdout, .runtime_signal, iterations, samples_ps);
}

fn runRuntimeSourceScenario(init: std.process.Init, stdout: *std.Io.Writer, iterations: usize) !void {
    const input_pipe = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const input_file = std.Io.File{ .handle = input_pipe[0], .flags = .{ .nonblocking = true } };
    const input_writer = std.Io.File{ .handle = input_pipe[1], .flags = .{ .nonblocking = true } };
    defer input_file.close(init.io);
    defer input_writer.close(init.io);
    const source_pipe = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const source_file = std.Io.File{ .handle = source_pipe[0], .flags = .{ .nonblocking = true } };
    const source_writer = std.Io.File{ .handle = source_pipe[1], .flags = .{ .nonblocking = true } };
    defer source_file.close(init.io);
    defer source_writer.close(init.io);
    try source_writer.writeStreamingAll(init.io, "x");
    var read_buffer: [8]u8 = undefined;
    var timer_storage: [0]tui.runtime.TimerSlot = .{};
    var runtime = try tui.runtime.Posix.init(init.io, input_file, &read_buffer, &timer_storage, .{});
    defer runtime.deinit();
    const sources = [_]tui.runtime.PollSource{.{ .file = source_file, .interest = .{ .read = true } }};
    var poll_storage: [4]tui.runtime.PollSlot = undefined;
    const Sink = struct {
        count: usize = 0,

        pub fn emit(self: *@This(), event: tui.runtime.Event) !void {
            if (event == .ready) self.count += 1;
        }
    };
    var sink: Sink = .{};
    for (0..@min(iterations, 100)) |_| try runtime.stepWithSources(&sources, &poll_storage, &sink);

    var samples_ps: [batch_count]u64 = undefined;
    var batch: usize = 0;
    while (batch < batch_count) : (batch += 1) {
        const start = std.Io.Clock.awake.now(init.io);
        for (0..iterations) |_| runtime.stepWithSources(&sources, &poll_storage, &sink) catch unreachable;
        const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        if (elapsed <= 0) return error.ClockFailure;
        const elapsed_ns = std.math.cast(u64, elapsed) orelse return error.ClockFailure;
        samples_ps[batch] = @intCast((@as(u128, elapsed_ns) * 1_000) / iterations);
    }
    std.mem.sort(u64, &samples_ps, {}, std.sort.asc(u64));
    std.mem.doNotOptimizeAway(sink.count);
    try writeNonRenderResult(stdout, .runtime_source_ready, iterations, samples_ps);
}

fn runPtySpawnScenario(init: std.process.Init, stdout: *std.Io.Writer, requested_iterations: usize) !void {
    const iterations = @min(requested_iterations, 100);
    var pointer_storage: [2]?[*:0]const u8 = undefined;
    var byte_storage: [32]u8 = undefined;
    var storage = tui.subprocess.SpawnStorage.init(&pointer_storage, &byte_storage);
    const executable = if (@import("builtin").os.tag == .macos) "/usr/bin/true" else "/bin/true";
    const arguments = [_][]const u8{executable};
    const command: tui.subprocess.Command = .{ .argv = &arguments, .environ = init.minimal.environ };
    const options: tui.subprocess.PtyOptions = .{ .size = .{ .width = 80, .height = 24 } };
    for (0..@min(iterations, 5)) |_| try spawnAndWait(init.io, command, &storage, options);

    var samples_ps: [batch_count]u64 = undefined;
    var batch: usize = 0;
    while (batch < batch_count) : (batch += 1) {
        const start = std.Io.Clock.awake.now(init.io);
        for (0..iterations) |_| try spawnAndWait(init.io, command, &storage, options);
        const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        if (elapsed <= 0) return error.ClockFailure;
        const elapsed_ns = std.math.cast(u64, elapsed) orelse return error.ClockFailure;
        samples_ps[batch] = @intCast((@as(u128, elapsed_ns) * 1_000) / iterations);
    }
    std.mem.sort(u64, &samples_ps, {}, std.sort.asc(u64));
    try writeNonRenderResult(stdout, .pty_spawn, iterations, samples_ps);
}

fn spawnAndWait(
    io: std.Io,
    command: tui.subprocess.Command,
    storage: *tui.subprocess.SpawnStorage,
    options: tui.subprocess.PtyOptions,
) !void {
    var process = try tui.subprocess.PtyProcess.spawnBeforeThreads(io, command, storage, options);
    defer cleanupPtyProcess(&process);
    const event = try process.wait();
    if (event != .exit or event.exit != .exited or event.exit.exited != 0) return error.UnexpectedChildExit;
}

fn cleanupPtyProcess(process: *tui.subprocess.PtyProcess) void {
    if (!process.isReaped()) {
        process.forceKill() catch {};
        while (!process.isReaped()) _ = process.wait() catch break;
    }
    if (process.isReaped()) process.deinit() else process.closeMaster();
}

fn runCapabilityScenario(init: std.process.Init, stdout: *std.Io.Writer, iterations: usize) !void {
    var checksum: u64 = 0;
    for (0..@min(iterations, 1_000)) |_| checksum +%= try capabilityIteration();
    var samples_ps: [batch_count]u64 = undefined;
    var batch: usize = 0;
    while (batch < batch_count) : (batch += 1) {
        const start = std.Io.Clock.awake.now(init.io);
        for (0..iterations) |_| checksum +%= capabilityIteration() catch unreachable;
        const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        if (elapsed <= 0) return error.ClockFailure;
        const elapsed_ns = std.math.cast(u64, elapsed) orelse return error.ClockFailure;
        samples_ps[batch] = @intCast((@as(u128, elapsed_ns) * 1_000) / iterations);
    }
    std.mem.sort(u64, &samples_ps, {}, std.sort.asc(u64));
    std.mem.doNotOptimizeAway(checksum);
    try writeNonRenderResult(stdout, .capability_negotiation, iterations, samples_ps);
}

fn capabilityIteration() !u64 {
    var negotiator = tui.terminal.CapabilityNegotiator.init(.{ .color_depth = .truecolor });
    var query_buffer: [160]u8 = undefined;
    var query = std.Io.Writer.fixed(&query_buffer);
    try negotiator.writeQueries(&query);
    var replies = ("\x1b[?7u\x1b[?62;4;6;22c\x1b[>1;4000;0c\x1b[?2026;1$y" ++
        "\x1b]10;rgb:ffff/8000/0000\x1b\\\x1b]11;rgb:0000/1111/ffff\x1b\\" ++
        "\x1b[1;1R\x1b[1;3R\x1b[1;5R").*;
    std.mem.doNotOptimizeAway(&replies);
    const Sink = struct {
        target: *tui.terminal.CapabilityNegotiator,

        pub fn emit(self: *@This(), event: tui.input.Event) !void {
            self.target.observe(event);
        }
    };
    var sink = Sink{ .target = &negotiator };
    var parser: tui.input.Parser = .{};
    try parser.feed(&replies, &sink);
    if (negotiator.queriesPending()) return error.IncompleteNegotiation;
    return @as(u64, query.buffered().len) +
        negotiator.observations.primary_device_attributes.?.len +
        negotiator.observations.default_foreground.?.green +
        @intFromBool(negotiator.capabilities.kitty_keyboard) +
        @intFromBool(negotiator.capabilities.synchronized_output);
}

fn runHyperlinkScenario(init: std.process.Init, stdout: *std.Io.Writer, iterations: usize) !void {
    var uri = "https://example.com/docs?q=tui.zig".*;
    var label = "tui.zig documentation".*;
    std.mem.doNotOptimizeAway(&uri);
    std.mem.doNotOptimizeAway(&label);
    var checksum: u64 = 0;
    for (0..@min(iterations, 1_000)) |_| checksum +%= try hyperlinkIteration(&uri, &label);
    var samples_ps: [batch_count]u64 = undefined;
    var batch: usize = 0;
    while (batch < batch_count) : (batch += 1) {
        const start = std.Io.Clock.awake.now(init.io);
        for (0..iterations) |_| checksum +%= hyperlinkIteration(&uri, &label) catch unreachable;
        const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        if (elapsed <= 0) return error.ClockFailure;
        const elapsed_ns = std.math.cast(u64, elapsed) orelse return error.ClockFailure;
        samples_ps[batch] = @intCast((@as(u128, elapsed_ns) * 1_000) / iterations);
    }
    std.mem.sort(u64, &samples_ps, {}, std.sort.asc(u64));
    std.mem.doNotOptimizeAway(checksum);
    try writeNonRenderResult(stdout, .hyperlink_output, iterations, samples_ps);
}

fn hyperlinkIteration(uri: []const u8, label: []const u8) !u64 {
    var output_buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    try tui.terminal.writeHyperlink(
        &output,
        .{ .hyperlinks = true },
        .{ .label = label, .uri = uri },
    );
    std.mem.doNotOptimizeAway(&output_buffer);
    return output.buffered().len;
}

fn runClipboardScenario(init: std.process.Init, stdout: *std.Io.Writer, requested_iterations: usize) !void {
    const iterations = @min(requested_iterations, 10_000);
    var text: [clipboard_benchmark_bytes]u8 = @splat('x');
    std.mem.doNotOptimizeAway(&text);
    var checksum: u64 = 0;
    for (0..@min(iterations, 100)) |_| checksum +%= try clipboardIteration(&text);
    var samples_ps: [batch_count]u64 = undefined;
    var batch: usize = 0;
    while (batch < batch_count) : (batch += 1) {
        const start = std.Io.Clock.awake.now(init.io);
        for (0..iterations) |_| checksum +%= clipboardIteration(&text) catch unreachable;
        const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        if (elapsed <= 0) return error.ClockFailure;
        const elapsed_ns = std.math.cast(u64, elapsed) orelse return error.ClockFailure;
        samples_ps[batch] = @intCast((@as(u128, elapsed_ns) * 1_000) / iterations);
    }
    std.mem.sort(u64, &samples_ps, {}, std.sort.asc(u64));
    std.mem.doNotOptimizeAway(checksum);
    try writeNonRenderResult(stdout, .clipboard_4k, iterations, samples_ps);
}

fn clipboardIteration(text: []const u8) !u64 {
    var storage: [5_472]u8 = undefined;
    var output_buffer: [5_472]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try tui.terminal.writeClipboard(
        &output,
        .{ .clipboard_write = true },
        .{ .write_only = clipboard_benchmark_bytes },
        text,
        &storage,
    );
    if (result != .emitted) return error.ClipboardDisabled;
    std.mem.doNotOptimizeAway(&output_buffer);
    return output.buffered().len;
}

fn runNotificationScenario(init: std.process.Init, stdout: *std.Io.Writer, iterations: usize) !void {
    var body: [256]u8 = @splat('x');
    std.mem.doNotOptimizeAway(&body);
    const Collector = struct {
        checksum: u64 = 0,

        pub fn notify(self: *@This(), notification: tui.terminal.Notification) !void {
            self.checksum +%= notification.body.len + notification.body[0] + @intFromEnum(notification.urgency);
        }
    };
    var collector: Collector = .{};
    const backend = tui.terminal.NotificationBackend.init(&collector);
    for (0..@min(iterations, 1_000)) |_| {
        _ = try tui.terminal.dispatchNotification(backend, .{ .body = &body });
    }
    var samples_ps: [batch_count]u64 = undefined;
    var batch: usize = 0;
    while (batch < batch_count) : (batch += 1) {
        const start = std.Io.Clock.awake.now(init.io);
        for (0..iterations) |_| {
            _ = tui.terminal.dispatchNotification(backend, .{ .body = &body }) catch unreachable;
        }
        const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        if (elapsed <= 0) return error.ClockFailure;
        const elapsed_ns = std.math.cast(u64, elapsed) orelse return error.ClockFailure;
        samples_ps[batch] = @intCast((@as(u128, elapsed_ns) * 1_000) / iterations);
    }
    std.mem.sort(u64, &samples_ps, {}, std.sort.asc(u64));
    std.mem.doNotOptimizeAway(collector.checksum);
    try writeNonRenderResult(stdout, .notification_dispatch, iterations, samples_ps);
}

fn runScrollbackScenario(init: std.process.Init, stdout: *std.Io.Writer, iterations: usize) !void {
    const Ring = tui.scroll.LineRing(64);
    var storage: [256]Ring.Slot = undefined;
    var ring = Ring.init(&storage);
    var viewport: tui.scroll.Viewport = .{};
    var line: [32]u8 = @splat('x');
    std.mem.doNotOptimizeAway(&line);
    var checksum: u64 = 0;
    for (0..@min(iterations, storage.len)) |_| {
        const result = try ring.append(&line);
        _ = viewport.update(ring.count(), 24, result.dropped_rows);
    }
    var samples_ps: [batch_count]u64 = undefined;
    var batch: usize = 0;
    while (batch < batch_count) : (batch += 1) {
        const start = std.Io.Clock.awake.now(init.io);
        for (0..iterations) |_| {
            const result = ring.append(&line) catch unreachable;
            _ = viewport.update(ring.count(), 24, result.dropped_rows);
            checksum +%= viewport.top + ring.row(ring.count() - 1)[0];
        }
        const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        if (elapsed <= 0) return error.ClockFailure;
        const elapsed_ns = std.math.cast(u64, elapsed) orelse return error.ClockFailure;
        samples_ps[batch] = @intCast((@as(u128, elapsed_ns) * 1_000) / iterations);
    }
    std.mem.sort(u64, &samples_ps, {}, std.sort.asc(u64));
    std.mem.doNotOptimizeAway(checksum);
    try writeNonRenderResult(stdout, .scrollback_append, iterations, samples_ps);
}

fn runLineDecodeScenario(init: std.process.Init, stdout: *std.Io.Writer, iterations: usize) !void {
    const Decoder = tui.scroll.LineDecoder(64);
    var slots: [256]Decoder.Ring.Slot = undefined;
    var ring = Decoder.Ring.init(&slots);
    var decoder: Decoder = .{};
    var viewport: tui.scroll.Viewport = .{};
    const chunk = "INFO worker ready\r\nWARN queue depth 12\r\n" ++
        "INFO request completed in 42 ms\r\nDEBUG poll cycle complete\r\n";
    var checksum: u64 = 0;
    for (0..@min(iterations, 1_000)) |_| lineDecodeCycle(&decoder, &ring, &viewport, chunk, &checksum);

    var samples_ps: [batch_count]u64 = undefined;
    var batch: usize = 0;
    while (batch < batch_count) : (batch += 1) {
        const start = std.Io.Clock.awake.now(init.io);
        for (0..iterations) |_| lineDecodeCycle(&decoder, &ring, &viewport, chunk, &checksum);
        const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        if (elapsed <= 0) return error.ClockFailure;
        const elapsed_ns = std.math.cast(u64, elapsed) orelse return error.ClockFailure;
        samples_ps[batch] = @intCast((@as(u128, elapsed_ns) * 1_000) / iterations);
    }
    std.mem.sort(u64, &samples_ps, {}, std.sort.asc(u64));
    std.mem.doNotOptimizeAway(checksum);
    try writeNonRenderResult(stdout, .line_decode, iterations, samples_ps);
}

fn lineDecodeCycle(
    decoder: anytype,
    ring: anytype,
    viewport: *tui.scroll.Viewport,
    chunk: []const u8,
    checksum: *u64,
) void {
    const result = decoder.feed(ring, chunk);
    if (result.appended_rows != 4 or result.rejectedRows() != 0) unreachable;
    _ = viewport.update(ring.count(), 24, result.dropped_rows);
    checksum.* +%= viewport.top + ring.row(ring.count() - 1)[0];
}

fn runProcessOutputBatchScenario(init: std.process.Init, stdout: *std.Io.Writer, iterations: usize) !void {
    const Decoder = tui.scroll.LineDecoder(512);
    const slots = try init.gpa.alloc(Decoder.Ring.Slot, 2048);
    defer init.gpa.free(slots);
    var ring = Decoder.Ring.init(slots);
    var decoder: Decoder = .{};
    var viewport: tui.scroll.Viewport = .{};
    var chunk: [4096]u8 = undefined;
    for (0..chunk.len / 2) |index| {
        chunk[index * 2] = 'x';
        chunk[index * 2 + 1] = '\n';
    }
    std.mem.doNotOptimizeAway(&chunk);
    var checksum: u64 = 0;
    for (0..@min(iterations, 20)) |_| processOutputBatch(&decoder, &ring, &viewport, &chunk, &checksum);

    var samples_ps: [batch_count]u64 = undefined;
    var batch: usize = 0;
    while (batch < batch_count) : (batch += 1) {
        const start = std.Io.Clock.awake.now(init.io);
        for (0..iterations) |_| processOutputBatch(&decoder, &ring, &viewport, &chunk, &checksum);
        const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        if (elapsed <= 0) return error.ClockFailure;
        const elapsed_ns = std.math.cast(u64, elapsed) orelse return error.ClockFailure;
        samples_ps[batch] = @intCast((@as(u128, elapsed_ns) * 1_000) / iterations);
    }
    std.mem.sort(u64, &samples_ps, {}, std.sort.asc(u64));
    std.mem.doNotOptimizeAway(checksum);
    try writeNonRenderResult(stdout, .process_output_batch, iterations, samples_ps);
}

fn processOutputBatch(
    decoder: anytype,
    ring: anytype,
    viewport: *tui.scroll.Viewport,
    chunk: []const u8,
    checksum: *u64,
) void {
    for (0..16) |_| {
        const result = decoder.feed(ring, chunk);
        if (result.appended_rows != chunk.len / 2 or result.rejectedRows() != 0) unreachable;
        _ = viewport.update(ring.count(), 24, result.dropped_rows);
        checksum.* +%= result.dropped_rows + viewport.top;
    }
}

fn runEditorScenario(init: std.process.Init, stdout: *std.Io.Writer, iterations: usize) !void {
    var initial: [2_048]u8 = @splat('x');
    var storage: [4_096]u8 = undefined;
    std.mem.doNotOptimizeAway(&initial);
    var editor = try tui.editor.Model.init(&storage, &initial);
    _ = try editor.setCursor(initial.len / 2);
    var checksum: u64 = 0;
    for (0..@min(iterations, 100)) |_| editorCycle(&editor, &checksum);
    var samples_ps: [batch_count]u64 = undefined;
    var batch: usize = 0;
    while (batch < batch_count) : (batch += 1) {
        const start = std.Io.Clock.awake.now(init.io);
        for (0..iterations) |_| editorCycle(&editor, &checksum);
        const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        if (elapsed <= 0) return error.ClockFailure;
        const elapsed_ns = std.math.cast(u64, elapsed) orelse return error.ClockFailure;
        samples_ps[batch] = @intCast((@as(u128, elapsed_ns) * 1_000) / iterations);
    }
    std.mem.sort(u64, &samples_ps, {}, std.sort.asc(u64));
    std.mem.doNotOptimizeAway(checksum);
    try writeNonRenderResult(stdout, .editor_middle_edit, iterations, samples_ps);
}

fn editorCycle(editor: *tui.editor.Model, checksum: *u64) void {
    _ = editor.replaceSelection("y") catch unreachable;
    const result = editor.handle(.{ .key = .{ .code = .backspace } });
    if (result.failure != null) unreachable;
    checksum.* +%= editor.cursor + editor.revision;
}

fn runLineBreakScenario(init: std.process.Init, stdout: *std.Io.Writer, iterations: usize) !void {
    const text = "Build v17.4 costs $1,234.50 - ready " ++
        "\xE4\xB8\x96\xE7\x95\x8C \xF0\x9F\x91\x8D\xF0\x9F\x8F\xBD now.";
    var checksum: u64 = 0;
    for (0..@min(iterations, 1_000)) |_| checksum +%= try lineBreakIteration(text);
    var samples_ps: [batch_count]u64 = undefined;
    var batch: usize = 0;
    while (batch < batch_count) : (batch += 1) {
        const start = std.Io.Clock.awake.now(init.io);
        for (0..iterations) |_| checksum +%= try lineBreakIteration(text);
        const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        if (elapsed <= 0) return error.ClockFailure;
        const elapsed_ns = std.math.cast(u64, elapsed) orelse return error.ClockFailure;
        samples_ps[batch] = @intCast((@as(u128, elapsed_ns) * 1_000) / iterations);
    }
    std.mem.sort(u64, &samples_ps, {}, std.sort.asc(u64));
    std.mem.doNotOptimizeAway(checksum);
    try writeNonRenderResult(stdout, .line_break_scan, iterations, samples_ps);
}

fn lineBreakIteration(text: []const u8) !u64 {
    var iterator = try tui.text.LineBreakIterator.init(text);
    var checksum: u64 = 0;
    while (iterator.next()) |boundary| {
        checksum +%= boundary.offset + @intFromEnum(boundary.kind);
    }
    return checksum;
}

fn runCommandScenario(init: std.process.Init, stdout: *std.Io.Writer, iterations: usize) !void {
    var bindings: [64]tui.command.Binding = undefined;
    var strokes: [128]tui.command.Stroke = undefined;
    var registry = try tui.command.Registry.init(&bindings, &strokes);
    for (0..32) |index| {
        const stroke = tui.command.Stroke.press(.{ .function = @intCast(index + 1) }, .{});
        try registry.add(tui.command.global_context, @intCast(index + 1), &.{stroke});
    }
    for (0..16) |index| {
        const stroke = tui.command.Stroke.press(.{ .function = @intCast(index + 1) }, .{});
        try registry.add(7, @intCast(index + 101), &.{stroke});
    }
    const control_k = tui.command.Stroke.press(.{ .codepoint = 'k' }, .{ .control = true });
    const control_c = tui.command.Stroke.press(.{ .codepoint = 'c' }, .{ .control = true });
    const control_u = tui.command.Stroke.press(.{ .codepoint = 'u' }, .{ .control = true });
    try registry.add(7, 201, &.{ control_k, control_c });
    try registry.add(7, 202, &.{ control_k, control_u });

    var matcher: tui.command.Matcher = .{};
    const warmup_iterations = @min(iterations, 1_000);
    var iteration: usize = 0;
    var checksum: u64 = 0;
    while (iteration < warmup_iterations) : (iteration += 1) {
        checksum +%= commandIteration(&registry, &matcher, iteration);
    }

    var samples_ps: [batch_count]u64 = undefined;
    var batch: usize = 0;
    while (batch < batch_count) : (batch += 1) {
        const start = std.Io.Clock.awake.now(init.io);
        iteration = 0;
        while (iteration < iterations) : (iteration += 1) {
            checksum +%= commandIteration(&registry, &matcher, warmup_iterations + batch * iterations + iteration);
        }
        const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        if (elapsed <= 0) return error.ClockFailure;
        const elapsed_ns = std.math.cast(u64, elapsed) orelse return error.ClockFailure;
        samples_ps[batch] = @intCast((@as(u128, elapsed_ns) * 1_000) / iterations);
    }
    std.mem.sort(u64, &samples_ps, {}, std.sort.asc(u64));
    std.mem.doNotOptimizeAway(checksum);

    try stdout.print(
        "{{\"scenario\":\"command_match\",\"optimize\":\"ReleaseFast\",\"width\":120,\"height\":40,\"iterations\":{d},\"frames\":{d},\"ps_median\":{d},\"ps_p95\":{d},\"allocator_calls\":0,\"allocated_bytes\":0,\"ansi_bytes\":0,\"cells_compared\":0,\"cells_changed\":0,\"runs\":0}}\n",
        .{
            iterations,
            iterations * batch_count,
            samples_ps[batch_count / 2],
            samples_ps[batch_count - 1],
        },
    );
}

fn commandIteration(
    registry: *const tui.command.Registry,
    matcher: *tui.command.Matcher,
    iteration: usize,
) u64 {
    const first = matcher.feed(registry, 7, .{
        .code = .{ .codepoint = 'k' },
        .modifiers = .{ .control = true },
    });
    if (first != .pending) unreachable;
    const second = matcher.feed(registry, 7, .{
        .code = .{ .codepoint = if (iteration & 1 == 0) 'c' else 'u' },
        .modifiers = .{ .control = true },
    });
    return switch (second) {
        .command => |command| command,
        else => unreachable,
    };
}

fn runScenario(
    init: std.process.Init,
    stdout: *std.Io.Writer,
    comptime scenario: Scenario,
    iterations: usize,
) !void {
    var allocator_state = std.testing.FailingAllocator.init(init.gpa, .{});
    var renderer = try tui.render.Renderer.init(allocator_state.allocator(), terminal_size, .{});
    defer renderer.deinit();

    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.Writer.Discarding.init(&output_buffer);
    _ = try renderer.present(&output.writer, capabilities);
    if (scenario == .terminal_recovery) {
        var frame = renderer.frame();
        var y: u16 = 0;
        while (y < terminal_size.height) : (y += 1) {
            try frame.fillAscii(
                .{ .x = 0, .y = y, .width = terminal_size.width, .height = 1 },
                if (y & 1 == 0) '#' else '-',
                .{ .foreground = .{ .indexed = @intCast(1 + y % 7) } },
            );
        }
        _ = try renderer.present(&output.writer, capabilities);
    }
    var driver: tui.app.Driver = .{};
    var application: BenchmarkApplication = .{};
    var form_state: BenchmarkFormState = .{};
    var text_input_storage: [128]u8 = undefined;
    var text_input = try tui.widget.TextInput.init(&text_input_storage, "alpha ox");
    text_input.focused = true;
    var text_area_storage: [2048]u8 = undefined;
    var text_area_model = try tui.editor.Model.init(&text_area_storage, text_area_initial);
    var text_area = tui.widget.TextArea{ .model = &text_area_model, .focused = true };
    if (scenario == .text_input_selection) _ = try text_input.setSelection(6, 8);
    if (scenario == .text_area_soft_wrap) {
        _ = text_area_model.setSoftWrap(true);
        _ = text_area_model.setViewportSize(24, 20);
        _ = try text_area_model.setCursor(0);
        if (text_area.handle(.{ .key = .{ .code = .end, .modifiers = .{ .shift = true } } }) != .redraw) unreachable;
    }
    var assistant_slots: [64]assistant_demo.Ring.Slot = undefined;
    var assistant_ring = assistant_demo.Ring.init(&assistant_slots);
    var assistant_prompt_storage: [128]u8 = undefined;
    var assistant_prompt = try tui.editor.Model.init(&assistant_prompt_storage, "");
    var assistant = try assistant_demo.AssistantApp.init(&assistant_ring, &assistant_prompt);
    var data_state: BenchmarkDataState = .{};

    const warmup_iterations = @min(iterations, 1_000);
    var iteration: usize = 0;
    while (iteration < warmup_iterations) : (iteration += 1) {
        _ = try renderIteration(
            scenario,
            &renderer,
            &output.writer,
            &driver,
            &application,
            &form_state,
            &text_input,
            &text_area,
            &assistant,
            &data_state,
            iteration,
        );
    }

    const allocations_before = allocator_state.allocations;
    const allocated_bytes_before = allocator_state.allocated_bytes;
    const resize_calls_before = allocator_state.resize_index;
    const output_bytes_before = output.fullCount();
    const frames = iterations * batch_count;
    var samples_ps: [batch_count]u64 = undefined;
    var totals: Totals = .{};

    var batch: usize = 0;
    while (batch < batch_count) : (batch += 1) {
        const start = std.Io.Clock.awake.now(init.io);
        iteration = 0;
        while (iteration < iterations) : (iteration += 1) {
            std.mem.doNotOptimizeAway(&renderer);
            totals.add(try renderIteration(
                scenario,
                &renderer,
                &output.writer,
                &driver,
                &application,
                &form_state,
                &text_input,
                &text_area,
                &assistant,
                &data_state,
                warmup_iterations + batch * iterations + iteration,
            ));
        }
        const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        if (elapsed <= 0) return error.ClockFailure;
        const elapsed_ns = std.math.cast(u64, elapsed) orelse return error.ClockFailure;
        samples_ps[batch] = @intCast((@as(u128, elapsed_ns) * 1_000) / iterations);
    }
    std.mem.sort(u64, &samples_ps, {}, std.sort.asc(u64));

    const allocator_calls = allocator_state.allocations - allocations_before +
        allocator_state.resize_index - resize_calls_before;
    const allocated_bytes = allocator_state.allocated_bytes - allocated_bytes_before;
    if (allocator_calls != 0) return error.SteadyStateAllocation;

    try stdout.print(
        "{{\"scenario\":\"{s}\",\"optimize\":\"ReleaseFast\",\"width\":120,\"height\":40,\"iterations\":{d},\"frames\":{d},\"ps_median\":{d},\"ps_p95\":{d},\"allocator_calls\":{d},\"allocated_bytes\":{d},\"ansi_bytes\":{d},\"cells_compared\":{d},\"cells_changed\":{d},\"runs\":{d}}}\n",
        .{
            @tagName(scenario),
            iterations,
            frames,
            samples_ps[batch_count / 2],
            samples_ps[batch_count - 1],
            allocator_calls,
            allocated_bytes,
            output.fullCount() - output_bytes_before,
            totals.cells_compared,
            totals.cells_changed,
            totals.runs,
        },
    );
}

fn renderIteration(
    comptime scenario: Scenario,
    renderer: *tui.render.Renderer,
    writer: *std.Io.Writer,
    driver: *tui.app.Driver,
    application: *BenchmarkApplication,
    form_state: *BenchmarkFormState,
    text_input: *tui.widget.TextInput,
    text_area: *tui.widget.TextArea,
    assistant: *assistant_demo.AssistantApp,
    data_state: *BenchmarkDataState,
    iteration: usize,
) !tui.render.FrameStats {
    switch (scenario) {
        .command_match => unreachable,
        .app_cycle => {
            const update = driver.dispatch(application, .{ .key = .{ .code = .enter } });
            if (update != .redraw) unreachable;
            return driver.refresh(renderer, application, writer, capabilities);
        },
        .theme_resolve => {
            const role = tui.theme.Role{
                .normal = .{ .foreground = .{ .indexed = 7 } },
                .focused = .{ .foreground = .{ .indexed = 15 }, .attributes = .{ .bold = true } },
                .disabled = .{ .foreground = .{ .indexed = 8 }, .attributes = .{ .dim = true } },
            };
            const state: tui.theme.State = @enumFromInt(iteration % 3);
            const style = role.resolve(state);
            std.mem.doNotOptimizeAway(style);
        },
        .display_widgets => {
            var frame = renderer.frame();
            var root = frame.surface(.{ .x = 4, .y = 2, .width = 52, .height = 8 });
            const panel = tui.widget.Panel{
                .title = if (iteration & 1 == 0) "production" else "staging",
                .border = .{ .normal = .{ .foreground = .{ .indexed = 6 } } },
            };
            try panel.draw(&root);
            var content = root.surface(tui.widget.Panel.contentRect(root.size()));
            const label = tui.widget.Label{
                .text = if (iteration & 1 == 0) "healthy workers" else "queued workers",
                .options = .{ .alignment = .center },
            };
            var label_surface = content.surface(.{ .x = 0, .y = 0, .width = content.size().width, .height = 1 });
            try label.draw(&label_surface);
            const paragraph = tui.widget.Paragraph{
                .text = if (iteration & 1 == 0)
                    "All workers are healthy and no jobs are queued."
                else
                    "Two workers are busy and three jobs are queued.",
            };
            var paragraph_surface = content.surface(.{ .x = 0, .y = 1, .width = content.size().width, .height = 4 });
            try paragraph.draw(&paragraph_surface);
            const gauge = tui.widget.Gauge{
                .value = if (iteration & 1 == 0) 9 else 6,
                .total = 10,
                .filled = .{ .normal = .{ .foreground = .{ .indexed = 2 } } },
                .empty = .{ .normal = .{ .foreground = .{ .indexed = 8 } } },
            };
            var gauge_surface = content.surface(.{ .x = 0, .y = 5, .width = content.size().width, .height = 1 });
            try gauge.draw(&gauge_surface);
        },
        .display_panel => {
            var frame = renderer.frame();
            var surface = frame.surface(.{ .x = 4, .y = 2, .width = 52, .height = 8 });
            const panel = tui.widget.Panel{
                .title = if (iteration & 1 == 0) "production" else "staging",
                .border = .{ .normal = .{ .foreground = .{ .indexed = 6 } } },
            };
            try panel.draw(&surface);
        },
        .display_gauge => {
            var frame = renderer.frame();
            var surface = frame.surface(.{ .x = 5, .y = 5, .width = 50, .height = 1 });
            const gauge = tui.widget.Gauge{
                .value = if (iteration & 1 == 0) 9 else 6,
                .total = 10,
                .filled = .{ .normal = .{ .foreground = .{ .indexed = 2 } } },
                .empty = .{ .normal = .{ .foreground = .{ .indexed = 8 } } },
            };
            try gauge.draw(&surface);
        },
        .form_controls => {
            const activate = tui.input.Event{ .key = .{ .code = .enter } };
            if (form_state.button.handle(activate) != .handled or !form_state.button.takeActivation()) unreachable;
            if (form_state.checkbox.handle(activate) != .redraw) unreachable;
            var radio = tui.widget.Radio{
                .label = "fast mode",
                .value = if (iteration & 1 == 0) 1 else 2,
                .selection = &form_state.selection,
            };
            if (radio.handle(activate) != .redraw) unreachable;

            var frame = renderer.frame();
            var button_surface = frame.surface(.{ .x = 4, .y = 2, .width = 24, .height = 1 });
            try form_state.button.draw(&button_surface);
            var checkbox_surface = frame.surface(.{ .x = 4, .y = 3, .width = 24, .height = 1 });
            try form_state.checkbox.draw(&checkbox_surface);
            var radio_surface = frame.surface(.{ .x = 4, .y = 4, .width = 24, .height = 1 });
            try radio.draw(&radio_surface);
        },
        .text_input => {
            if (text_input.handle(.{ .key = .{ .code = .left } }) != .redraw) unreachable;
            if (text_input.handle(.{ .key = .{ .code = .backspace } }) != .redraw) unreachable;
            if (text_input.handle(.{ .text = if (iteration & 1 == 0) "e\xCC\x81" else "o" }) != .redraw) unreachable;
            if (text_input.handle(.{ .key = .{ .code = .right } }) != .redraw) unreachable;
            var frame = renderer.frame();
            var surface = frame.surface(.{ .x = 4, .y = 2, .width = 32, .height = 1 });
            try text_input.draw(&surface);
        },
        .text_input_selection => {
            if (text_input.handle(.{ .text = if (iteration & 1 == 0) "go" else "ox" }) != .redraw) unreachable;
            if (!try text_input.setSelection(6, 8)) unreachable;
            var frame = renderer.frame();
            var surface = frame.surface(.{ .x = 4, .y = 2, .width = 32, .height = 1 });
            try text_input.draw(&surface);
        },
        .text_area => {
            if (text_area.handle(.{ .key = .{ .code = .left } }) != .redraw) unreachable;
            if (text_area.handle(.{ .key = .{ .code = .backspace } }) != .redraw) unreachable;
            if (text_area.handle(.{ .text = if (iteration & 1 == 0) "x" else "o" }) != .redraw) unreachable;
            if (text_area.handle(.{ .key = .{ .code = .right } }) != .redraw) unreachable;
            var frame = renderer.frame();
            var surface = frame.surface(.{ .x = 4, .y = 4, .width = 64, .height = 20 });
            try text_area.draw(&surface);
        },
        .text_area_soft_wrap => {
            if (text_area.handle(.{ .key = .{ .code = .home } }) != .redraw) unreachable;
            if (text_area.handle(.{ .key = .{ .code = .end, .modifiers = .{ .shift = true } } }) != .redraw) unreachable;
            var frame = renderer.frame();
            var surface = frame.surface(.{ .x = 4, .y = 4, .width = 24, .height = 20 });
            try text_area.draw(&surface);
        },
        .assistant_cycle => {
            if (!assistant.streaming) {
                if (assistant.handle(.{ .text = "benchmark" }) != .redraw) unreachable;
                if (assistant.handle(.{ .key = .{
                    .code = .{ .codepoint = 's' },
                    .modifiers = .{ .control = true },
                } }) != .redraw) unreachable;
            }
            while (assistant.streamStep() != .redraw) {}
            var frame = renderer.frame();
            var surface = frame.surface(.{ .x = 0, .y = 0, .width = 80, .height = 24 });
            try assistant.draw(&surface);
        },
        .scrollback_view => {
            var scrollback = tui.widget.Scrollback(BenchmarkListProvider){
                .provider = &data_state.list_provider,
                .viewport = &data_state.scrollback_viewport,
                .bounds = .{ .x = 4, .y = 2, .width = 60, .height = 30 },
                .focused = true,
            };
            const direction: tui.input.KeyCode = if (iteration & 1 == 0) .page_up else .page_down;
            if (scrollback.handle(.{ .key = .{ .code = direction } }) != .redraw) unreachable;
            var frame = renderer.frame();
            var surface = frame.surface(scrollback.bounds);
            try scrollback.draw(&surface);
        },
        .list_view => {
            data_state.list_scroll.selected = iteration % (data_state.list_provider.count() - 1);
            data_state.list_scroll.top = data_state.list_scroll.selected.?;
            var list = tui.widget.List(BenchmarkListProvider){
                .provider = &data_state.list_provider,
                .state = &data_state.list_scroll,
                .bounds = .{ .x = 4, .y = 0, .width = 60, .height = 40 },
                .focused = true,
                .selected_role = .{ .focused = .{ .attributes = .{ .reverse = true } } },
            };
            if (list.handle(.{ .key = .{ .code = .down } }) != .redraw) unreachable;
            var frame = renderer.frame();
            var surface = frame.surface(list.bounds);
            try list.draw(&surface);
        },
        .table_view => {
            data_state.table_scroll.selected = iteration % (data_state.table_provider.count() - 39);
            data_state.table_scroll.top = data_state.table_scroll.selected.?;
            var table = tui.widget.Table(BenchmarkTableProvider){
                .provider = &data_state.table_provider,
                .state = &data_state.table_scroll,
                .bounds = .{ .x = 0, .y = 0, .width = 120, .height = 40 },
                .columns = &benchmark_columns,
                .focused = true,
                .selected_role = .{ .focused = .{ .attributes = .{ .reverse = true } } },
            };
            if (table.handle(.{ .key = .{ .code = .page_down } }) != .redraw) unreachable;
            var frame = renderer.frame();
            var surface = frame.surface(table.bounds);
            try table.draw(&surface);
        },
        .overlay_modal => {
            var entries: [4]tui.overlay.Entry = undefined;
            var overlays = try tui.overlay.Stack.init(&entries);
            const entry = tui.overlay.Entry{
                .id = 1,
                .bounds = .{ .x = 36, .y = 12, .width = 48, .height = 14 },
                .modal = true,
            };
            try overlays.push(entry);
            if (overlays.hit(.{ .x = 0, .y = 0 }) != .modal_backdrop) unreachable;

            data_state.menu.scroll.selected = iteration % (benchmark_menu_labels.len - 1);
            var menu = tui.widget.Menu{
                .labels = &benchmark_menu_labels,
                .state = &data_state.menu,
                .bounds = .{ .x = 37, .y = 13, .width = 46, .height = 10 },
                .focused = true,
                .selected_role = .{ .focused = .{ .attributes = .{ .reverse = true } } },
            };
            if (menu.handle(.{ .key = .{ .code = .down } }) != .redraw) unreachable;

            var frame = renderer.frame();
            _ = try frame.putText(.{ .x = 0, .y = 0 }, if (iteration & 1 == 0) "a" else "b", .{}, .narrow);
            for (overlays.entries()) |overlay_entry| {
                if (overlay_entry.id != 1) unreachable;
                var panel_surface = frame.surface(overlay_entry.bounds);
                const panel = tui.widget.Panel{ .title = "command palette" };
                try panel.draw(&panel_surface);
                var menu_surface = frame.surface(menu.bounds);
                try menu.draw(&menu_surface);
            }
            if (overlays.pop() == null) unreachable;
        },
        .no_op => {},
        .single_cell => {
            var frame = renderer.frame();
            _ = try frame.putText(
                .{ .x = 5, .y = 2 },
                if (iteration & 1 == 0) "x" else "y",
                .{},
                .narrow,
            );
        },
        .surface_cell => {
            var frame = renderer.frame();
            var panel = frame.surface(.{ .x = 10, .y = 5, .width = 80, .height = 24 });
            var child = panel.surface(.{ .x = 2, .y = 1, .width = 40, .height = 12 });
            _ = try child.putText(
                .{ .x = 1, .y = 1 },
                if (iteration & 1 == 0) "x" else "y",
                .{},
                .narrow,
            );
        },
        .widget_cell => {
            const CellWidget = struct {
                text: []const u8,

                pub inline fn draw(self: *const @This(), surface: *tui.render.Surface) !void {
                    _ = try surface.putText(.{ .x = 1, .y = 1 }, self.text, .{}, .narrow);
                }
            };
            var frame = renderer.frame();
            var panel = frame.surface(.{ .x = 10, .y = 5, .width = 80, .height = 24 });
            var surface = panel.surface(.{ .x = 2, .y = 1, .width = 40, .height = 12 });
            const widget = CellWidget{ .text = if (iteration & 1 == 0) "x" else "y" };
            try tui.widget.draw(&widget, &surface);
        },
        .text_line => {
            var frame = renderer.frame();
            var surface = frame.surface(.{ .x = 10, .y = 5, .width = 32, .height = 1 });
            _ = try surface.putTextLine(
                .{ .x = 0, .y = 0 },
                if (iteration & 1 == 0)
                    "alpha connected to production cluster"
                else
                    "beta connected to production cluster",
                32,
                .{},
                .narrow,
                .{ .alignment = .center, .overflow = .ellipsis },
            );
        },
        .styled_line => {
            const first = [_]tui.render.StyledSpan{
                .{ .text = "alpha", .style = .{ .foreground = .{ .indexed = 2 } } },
                .{ .text = " connected to ", .style = .{} },
                .{ .text = "production", .style = .{ .attributes = .{ .bold = true } } },
                .{ .text = " cluster", .style = .{ .foreground = .{ .indexed = 4 } } },
            };
            const second = [_]tui.render.StyledSpan{
                .{ .text = "beta", .style = .{ .foreground = .{ .indexed = 3 } } },
                .{ .text = " connected to ", .style = .{} },
                .{ .text = "production", .style = .{ .attributes = .{ .bold = true } } },
                .{ .text = " cluster", .style = .{ .foreground = .{ .indexed = 5 } } },
            };
            var frame = renderer.frame();
            var surface = frame.surface(.{ .x = 10, .y = 5, .width = 32, .height = 1 });
            _ = try surface.putStyledLine(
                .{ .x = 0, .y = 0 },
                if (iteration & 1 == 0) &first else &second,
                32,
                .{},
                .narrow,
                .{ .overflow = .ellipsis },
            );
        },
        .wrap_text => {
            const text = if (iteration & 1 == 0)
                "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu"
            else
                "one two three four five six seven eight nine ten eleven twelve thirteen";
            var lines = try tui.text.WrapIterator.init(text, 16, .narrow);
            var width: u16 = 0;
            while (try lines.next()) |line| width +%= line.width;
            std.mem.doNotOptimizeAway(width);
        },
        .wrapped_paragraph => {
            var frame = renderer.frame();
            var surface = frame.surface(.{ .x = 10, .y = 5, .width = 32, .height = 4 });
            _ = try surface.putWrappedText(
                .{ .x = 0, .y = 0, .width = 32, .height = 4 },
                if (iteration & 1 == 0)
                    "alpha connected to production cluster with four healthy workers and no queued jobs"
                else
                    "beta connected to production cluster with three healthy workers and two queued jobs",
                .{},
                .narrow,
                .left,
            );
        },
        .wrapped_styled => {
            const first = [_]tui.render.StyledSpan{
                .{ .text = "alpha connected ", .style = .{ .foreground = .{ .indexed = 2 } } },
                .{ .text = "to production cluster ", .style = .{} },
                .{ .text = "with four healthy workers ", .style = .{ .attributes = .{ .bold = true } } },
                .{ .text = "and no queued jobs", .style = .{ .foreground = .{ .indexed = 4 } } },
            };
            const second = [_]tui.render.StyledSpan{
                .{ .text = "beta connected ", .style = .{ .foreground = .{ .indexed = 3 } } },
                .{ .text = "to production cluster ", .style = .{} },
                .{ .text = "with three healthy workers ", .style = .{ .attributes = .{ .bold = true } } },
                .{ .text = "and two queued jobs", .style = .{ .foreground = .{ .indexed = 5 } } },
            };
            var frame = renderer.frame();
            var surface = frame.surface(.{ .x = 10, .y = 5, .width = 32, .height = 4 });
            _ = try surface.putWrappedStyledText(
                .{ .x = 0, .y = 0, .width = 32, .height = 4 },
                if (iteration & 1 == 0) &first else &second,
                .{},
                .narrow,
                .left,
            );
        },
        .layout_split => {
            const segments = [_]tui.layout.Segment{
                tui.layout.Segment.fixed(3),
                tui.layout.Segment.flex(1, 2, 40),
                tui.layout.Segment.flex(2, 1, 50),
                tui.layout.Segment.fixed(5),
                tui.layout.Segment.flex(1, 0, 30),
                tui.layout.Segment.flex(3, 2, 60),
            };
            var output: [segments.len]tui.render.Rect = undefined;
            _ = try tui.layout.split(
                .{
                    .x = 4,
                    .y = 2,
                    .width = 79 + @as(u16, @intCast((iteration ^ (iteration >> 3)) & 31)),
                    .height = 20,
                },
                .horizontal,
                &segments,
                &output,
            );
            std.mem.doNotOptimizeAway(&output);
        },
        .layout_grid => {
            const rows = [_]tui.layout.Segment{
                tui.layout.Segment.fixed(3),
                tui.layout.Segment.flex(1, 2, 20),
                tui.layout.Segment.flex(2, 2, 30),
            };
            const columns = [_]tui.layout.Segment{
                tui.layout.Segment.fixed(8),
                tui.layout.Segment.flex(1, 4, 40),
                tui.layout.Segment.flex(2, 4, 60),
                tui.layout.Segment.flex(1, 4, 30),
            };
            var output: [rows.len * columns.len]tui.render.Rect = undefined;
            _ = try tui.layout.grid(
                .{
                    .x = 4,
                    .y = 2,
                    .width = 79 + @as(u16, @intCast((iteration ^ (iteration >> 3)) & 31)),
                    .height = 20 + @as(u16, @intCast((iteration ^ (iteration >> 2)) & 15)),
                },
                &rows,
                &columns,
                &output,
            );
            std.mem.doNotOptimizeAway(&output);
        },
        .focus_route => {
            const Router = struct {
                count: u16 = 0,

                pub fn capture(self: *@This(), _: tui.focus.Id, _: tui.input.Event) tui.focus.RouteResult {
                    self.count += 1;
                    return .continueWith(.ignored);
                }

                pub fn target(self: *@This(), _: tui.focus.Id, _: tui.input.Event) tui.focus.RouteResult {
                    self.count += 1;
                    return .continueWith(.redraw);
                }

                pub fn bubble(self: *@This(), _: tui.focus.Id, _: tui.input.Event) tui.focus.RouteResult {
                    self.count += 1;
                    return .continueWith(.handled);
                }
            };

            var storage: [8]tui.focus.Node = undefined;
            var registry = try tui.focus.Registry.init(&storage);
            try registry.add(.{
                .id = 1,
                .rect = .{ .x = 0, .y = 0, .width = 40, .height = 10 },
                .focusable = false,
            });
            try registry.add(.{
                .id = 2,
                .parent = 1,
                .rect = .{ .x = 0, .y = 0, .width = 30, .height = 8 },
                .focusable = false,
            });
            try registry.add(.{ .id = 3, .parent = 2, .rect = .{ .x = 1, .y = 1, .width = 4, .height = 1 } });
            try registry.add(.{ .id = 4, .parent = 2, .rect = .{ .x = 10, .y = 1, .width = 4, .height = 1 } });
            try registry.add(.{ .id = 5, .parent = 2, .rect = .{ .x = 1, .y = 5, .width = 4, .height = 1 } });
            try registry.add(.{
                .id = 6,
                .parent = 2,
                .rect = .{ .x = 10, .y = 5, .width = 4, .height = 1 },
                .enabled = false,
            });

            var manager: tui.focus.Manager = .{};
            _ = manager.move(&registry, .next);
            const target = manager.move(&registry, .right).?;
            var path_storage: [4]tui.focus.Id = undefined;
            const path = try registry.path(target, &path_storage);
            var router: Router = .{};
            const result = tui.focus.route(&router, path, .focus_in);
            std.mem.doNotOptimizeAway(&manager);
            std.mem.doNotOptimizeAway(&router);
            std.mem.doNotOptimizeAway(&result);
        },
        .transport_spsc,
        .owned_event_key,
        .owned_event_paste,
        .runtime_timer_heap,
        .runtime_wakeup,
        .runtime_signal,
        .runtime_source_ready,
        .pty_spawn,
        .capability_negotiation,
        .hyperlink_output,
        .clipboard_4k,
        .notification_dispatch,
        .scrollback_append,
        .line_decode,
        .process_output_batch,
        .editor_middle_edit,
        .line_break_scan,
        => unreachable,
        .sparse_cells => {
            var frame = renderer.frame();
            _ = try frame.putText(
                .{ .x = 5, .y = 2 },
                if (iteration & 1 == 0) "x" else "y",
                .{},
                .narrow,
            );
            _ = try frame.putText(
                .{ .x = 105, .y = 2 },
                if (iteration & 1 == 0) "a" else "b",
                .{},
                .narrow,
            );
        },
        .small_fill => {
            var frame = renderer.frame();
            try frame.fill(.{ .x = 20, .y = 10, .width = 6, .height = 6 }, .{
                .background = .{ .indexed = if (iteration & 1 == 0) 4 else 5 },
            });
        },
        .scrolling => {
            try renderer.scrollUp(.{ .x = 0, .y = 4, .width = 120, .height = 36 });
            var frame = renderer.frame();
            _ = try frame.putTextPadded(
                .{ .x = 0, .y = 39 },
                if (iteration & 1 == 0) "log alpha" else "log beta",
                120,
                .{},
                .narrow,
            );
        },
        .unicode_style => {
            var frame = renderer.frame();
            _ = try frame.putText(
                .{ .x = 10, .y = 10 },
                "e\xCC\x81 \xE7\x95\x8C \xF0\x9F\x91\xA9\xE2\x80\x8D\xF0\x9F\x92\xBB",
                .{
                    .foreground = .{ .indexed = if (iteration & 1 == 0) 2 else 4 },
                    .attributes = .{ .bold = true },
                },
                .narrow,
            );
        },
        .full_fill => {
            var frame = renderer.frame();
            try frame.fill(tui.render.Rect.fromSize(renderer.size()), .{
                .background = .{ .indexed = if (iteration & 1 == 0) 1 else 2 },
            });
        },
        .terminal_recovery => renderer.invalidateTerminal(),
        .hardware_cursor => renderer.setCursor(.{
            .position = .{ .x = if (iteration & 1 == 0) 5 else 6, .y = 2 },
            .shape = .steady_bar,
        }),
        .resize => {
            try renderer.resize(if (iteration & 1 == 0)
                .{ .width = 119, .height = 40 }
            else
                terminal_size);
        },
    }
    return renderer.present(writer, capabilities);
}

const BenchmarkApplication = struct {
    alternate: bool = false,

    pub inline fn handle(self: *@This(), _: tui.input.Event) tui.widget.Update {
        self.alternate = !self.alternate;
        return .redraw;
    }

    pub inline fn draw(self: *const @This(), surface: *tui.render.Surface) !void {
        _ = try surface.putText(
            .{ .x = 1, .y = 1 },
            if (self.alternate) "x" else "y",
            .{},
            .narrow,
        );
    }
};

const BenchmarkFormState = struct {
    button: tui.widget.Button = .{ .label = "apply" },
    checkbox: tui.widget.Checkbox = .{ .label = "verbose" },
    selection: ?u32 = null,
};

const BenchmarkListProvider = struct {
    pub inline fn count(_: *@This()) usize {
        return 1_000_000;
    }

    pub inline fn row(_: *@This(), index: usize) []const u8 {
        return if (index & 1 == 0) "worker healthy" else "worker busy";
    }
};

const BenchmarkTableProvider = struct {
    pub inline fn count(_: *@This()) usize {
        return 1_000_000;
    }

    pub inline fn cell(_: *@This(), row: usize, column: usize) []const u8 {
        return switch (column) {
            0 => if (row & 1 == 0) "worker-alpha" else "worker-beta",
            1 => if (row & 1 == 0) "healthy" else "busy",
            else => if (row & 1 == 0) "42 ms" else "87 ms",
        };
    }
};

const benchmark_columns = [_]tui.widget.Column{
    .{ .title = "worker", .width = 48 },
    .{ .title = "status", .width = 36 },
    .{ .title = "latency", .width = 36 },
};

const BenchmarkDataState = struct {
    list_provider: BenchmarkListProvider = .{},
    list_scroll: tui.widget.ScrollState = .{},
    table_provider: BenchmarkTableProvider = .{},
    table_scroll: tui.widget.ScrollState = .{},
    scrollback_viewport: tui.scroll.Viewport = .{},
    menu: tui.widget.MenuState = .{},
};

const benchmark_menu_labels = [_][]const u8{
    "Open file",
    "Save file",
    "Close file",
    "Search workspace",
    "Replace in files",
    "Toggle panel",
    "Run task",
    "Show diagnostics",
    "Change theme",
    "Quit",
};
