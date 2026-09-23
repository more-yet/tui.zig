const std = @import("std");
const tui = @import("tui");
const demo_app = @import("demo_app");

const batch_count = 9;
const default_iterations = 250_000;
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
    wrap_long_word,
    wrap_ascii,
    wrap_unicode,
    wrapped_paragraph,
    wrapped_styled,
    wrapped_styled_ascii,
    wrapped_styled_unicode,
    layout_split,
    layout_grid,
    focus_route,
    command_match,
    owned_event_key,
    owned_event_paste,
    runtime_timer_heap,
    runtime_wakeup,
    runtime_signal,
    runtime_source_ready,
    pty_spawn,
    capability_negotiation,
    scrollback_append,
    line_decode,
    process_output_batch,
    editor_middle_edit,
    editor_deep_line,
    editor_unicode_navigation,
    editor_history,
    line_break_scan,
    word_break_scan,
    app_cycle,
    theme_resolve,
    display_panel,
    display_gauge,
    display_widgets,
    form_controls,
    text_input,
    text_input_selection,
    text_area,
    text_area_full,
    text_area_soft_wrap,
    text_area_deep_soft_wrap,
    text_area_deep_unwrapped,
    demo_cycle,
    scrollback_view,
    list_view,
    table_view,
    overlay_modal,
    sparse_cells,
    small_fill,
    identical_full_fill,
    dense_same_style,
    intern_churn,
    nonblocking_pipe,
    scrolling,
    unicode_style,
    full_fill,
    terminal_recovery,
    hardware_cursor,
    resize,
    resize_large,
    graphics_transfer,
};

const Totals = struct {
    work_units: u64 = 0,
    cells_compared: u64 = 0,
    cells_changed: u64 = 0,
    runs: u64 = 0,
    output_chunks: u64 = 0,
    write_attempts: u64 = 0,
    accepted_bytes: u64 = 0,
    yielded_turns: u64 = 0,
    presentation_call_ns_max: u64 = 0,

    fn add(self: *Totals, measurement: RenderMeasurement) void {
        self.work_units += measurement.stats.work_units;
        self.cells_compared += measurement.stats.cells_compared;
        self.cells_changed += measurement.stats.cells_changed;
        self.runs += measurement.stats.runs;
        self.output_chunks += measurement.output_chunks;
        self.write_attempts += measurement.write_attempts;
        self.accepted_bytes += measurement.accepted_bytes;
        self.yielded_turns += measurement.yielded_turns;
        self.presentation_call_ns_max = @max(
            self.presentation_call_ns_max,
            measurement.presentation_call_ns_max,
        );
    }
};

const RenderMeasurement = struct {
    stats: tui.render.FrameStats,
    output_chunks: u64 = 0,
    write_attempts: u64 = 0,
    accepted_bytes: u64 = 0,
    yielded_turns: u64 = 0,
    presentation_call_ns_max: u64 = 0,
};

pub fn main(init: std.process.Init) !void {
    // Compile-time dispatch specializes every benchmark scenario.
    @setEvalBranchQuota(8_000);
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
                .owned_event_key, .owned_event_paste => try runOwnedEventScenario(init, stdout, active, iterations),
                .runtime_timer_heap => try runRuntimeTimerScenario(init, stdout, iterations),
                .runtime_wakeup => try runRuntimeWakeScenario(init, stdout, iterations),
                .runtime_signal => try runRuntimeSignalScenario(init, stdout, iterations),
                .runtime_source_ready => try runRuntimeSourceScenario(init, stdout, iterations),
                .pty_spawn => try runPtySpawnScenario(init, stdout, iterations),
                .capability_negotiation => try runCapabilityScenario(init, stdout, iterations),
                .scrollback_append => try runScrollbackScenario(init, stdout, iterations),
                .line_decode => try runLineDecodeScenario(init, stdout, iterations),
                .process_output_batch => try runProcessOutputBatchScenario(init, stdout, iterations),
                .editor_middle_edit => try runEditorScenario(init, stdout, iterations),
                .editor_deep_line => try runDeepLineScenario(init, stdout, iterations),
                .editor_unicode_navigation => try runUnicodeNavigationScenario(init, stdout, iterations),
                .editor_history => try runHistoryScenario(init, stdout, iterations),
                .line_break_scan => try runLineBreakScenario(init, stdout, iterations),
                .word_break_scan => try runWordBreakScenario(init, stdout, iterations),
                .nonblocking_pipe => try runNonblockingPipeScenario(init, stdout, iterations),
                .resize_large => try runLargeResizeScenario(init, stdout, iterations),
                .graphics_transfer => try runGraphicsTransferScenario(init, stdout, iterations),
                else => try runScenario(init, stdout, active, iterations),
            },
        };
    }
    try stdout.flush();
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
        "{{\"scenario\":\"{s}\",\"optimize\":\"ReleaseFast\",\"width\":0,\"height\":0,\"iterations\":{d},\"frames\":{d},\"ps_median\":{d},\"ps_batch_max\":{d},\"operation_ps_max\":null,\"presentation_call_ps_max\":null,\"allocator_calls\":null,\"allocated_bytes\":null,\"ansi_bytes\":null,\"work_units\":null,\"cells_compared\":null,\"cells_changed\":null,\"runs\":null,\"output_chunks\":null,\"write_attempts\":null,\"accepted_bytes\":null,\"yielded_turns\":null}}\n",
        .{
            @tagName(scenario),
            iterations,
            iterations * batch_count,
            samples_ps[batch_count / 2],
            samples_ps[batch_count - 1],
        },
    );
}

fn runDeepLineScenario(init: std.process.Init, stdout: *std.Io.Writer, requested_iterations: usize) !void {
    const iterations = @min(requested_iterations, 10_000);
    const line = "0123456789abcdef\n";
    var storage: [line.len * 8_192]u8 = undefined;
    for (0..8_192) |index| @memcpy(storage[index * line.len ..][0..line.len], line);
    const boundaries = try init.gpa.alloc(tui.editor.Boundary, storage.len + 1);
    defer init.gpa.free(boundaries);
    const visual_rows = try init.gpa.alloc(tui.editor.VisualRow, storage.len + 1);
    defer init.gpa.free(visual_rows);
    var model = try tui.editor.Model.init(.{
        .text = &storage,
        .boundaries = boundaries,
        .visual_rows = visual_rows,
        .paste = &.{},
    }, &storage);
    const first_row = model.lineCount() - 20;
    for (0..@min(iterations, 100)) |iteration| {
        std.mem.doNotOptimizeAway(model.lineRange(first_row + iteration % 20).?);
    }

    var samples_ps: [batch_count]u64 = undefined;
    var checksum: u64 = 0;
    var batch: usize = 0;
    while (batch < batch_count) : (batch += 1) {
        const start = std.Io.Clock.awake.now(init.io);
        for (0..iterations) |iteration| {
            const bounds = model.lineRange(first_row + iteration % 20).?;
            checksum +%= bounds.start + bounds.end;
        }
        const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        if (elapsed <= 0) return error.ClockFailure;
        const elapsed_ns = std.math.cast(u64, elapsed) orelse return error.ClockFailure;
        samples_ps[batch] = @intCast((@as(u128, elapsed_ns) * 1_000) / iterations);
    }
    std.mem.sort(u64, &samples_ps, {}, std.sort.asc(u64));
    std.mem.doNotOptimizeAway(checksum);
    try writeNonRenderResult(stdout, .editor_deep_line, iterations, samples_ps);
}

fn runUnicodeNavigationScenario(init: std.process.Init, stdout: *std.Io.Writer, requested_iterations: usize) !void {
    const iterations = @min(requested_iterations, 10_000);
    const segment = "ascii·世界👋é";
    var storage: tui.editor.FixedStorage(segment.len * 256) = .{};
    for (0..256) |index| @memcpy(storage.text[index * segment.len ..][0..segment.len], segment);
    var model = try tui.editor.Model.init(storage.slices(), &storage.text);
    var checksum: u64 = 0;
    for (0..@min(iterations, 100)) |_| {
        _ = model.applyAction(.{ .move_left = false });
        _ = model.applyAction(.{ .move_right = false });
        checksum +%= model.cursorOffset();
    }

    var samples_ps: [batch_count]u64 = undefined;
    var batch: usize = 0;
    while (batch < batch_count) : (batch += 1) {
        const start = std.Io.Clock.awake.now(init.io);
        for (0..iterations) |_| {
            _ = model.applyAction(.{ .move_left = false });
            _ = model.applyAction(.{ .move_right = false });
            checksum +%= model.cursorOffset();
        }
        const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        if (elapsed <= 0) return error.ClockFailure;
        const elapsed_ns = std.math.cast(u64, elapsed) orelse return error.ClockFailure;
        samples_ps[batch] = @intCast((@as(u128, elapsed_ns) * 1_000) / iterations);
    }
    std.mem.sort(u64, &samples_ps, {}, std.sort.asc(u64));
    std.mem.doNotOptimizeAway(checksum);
    try writeNonRenderResult(stdout, .editor_unicode_navigation, iterations, samples_ps);
}

fn runHistoryScenario(init: std.process.Init, stdout: *std.Io.Writer, iterations: usize) !void {
    var records: [128]tui.editor.HistoryRecord = undefined;
    var bytes: [4_096]u8 = undefined;
    var history = try tui.editor.History.init(&records, &bytes);
    var checksum: u64 = 0;
    for (0..records.len) |index| historyIteration(&history, index, &checksum);

    var samples_ps: [batch_count]u64 = undefined;
    var batch: usize = 0;
    while (batch < batch_count) : (batch += 1) {
        const start = std.Io.Clock.awake.now(init.io);
        for (0..iterations) |index| historyIteration(&history, index, &checksum);
        const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        if (elapsed <= 0) return error.ClockFailure;
        const elapsed_ns = std.math.cast(u64, elapsed) orelse return error.ClockFailure;
        samples_ps[batch] = @intCast((@as(u128, elapsed_ns) * 1_000) / iterations);
    }
    std.mem.sort(u64, &samples_ps, {}, std.sort.asc(u64));
    std.mem.doNotOptimizeAway(checksum);
    try writeNonRenderResult(stdout, .editor_history, iterations, samples_ps);
}

fn historyIteration(history: *tui.editor.History, index: usize, checksum: *u64) void {
    const inserted = if (index & 1 == 0) "a" else "b";
    const record = history.record(index, "", inserted, .{ .cursor = index, .anchor = null }) catch unreachable;
    history.finish(record, .{ .cursor = index + 1, .anchor = null });
    const current = history.peekUndo().?;
    checksum.* +%= current.start + current.inserted[0] + current.transaction;
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
    defer signal_source.deinit() catch unreachable;
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
    var event_count: usize = 0;
    const pid = std.posix.system.getpid();
    for (0..@min(iterations, 100)) |_| {
        try std.posix.kill(pid, .INT);
        const event = try runtime.step();
        if (event == .signal and event.signal == .interrupt) event_count += 1;
    }

    var samples_ps: [batch_count]u64 = undefined;
    var batch: usize = 0;
    while (batch < batch_count) : (batch += 1) {
        const start = std.Io.Clock.awake.now(init.io);
        for (0..iterations) |_| {
            std.posix.kill(pid, .INT) catch unreachable;
            const event = runtime.step() catch unreachable;
            if (event == .signal and event.signal == .interrupt) event_count += 1;
        }
        const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        if (elapsed <= 0) return error.ClockFailure;
        const elapsed_ns = std.math.cast(u64, elapsed) orelse return error.ClockFailure;
        samples_ps[batch] = @intCast((@as(u128, elapsed_ns) * 1_000) / iterations);
    }
    std.mem.sort(u64, &samples_ps, {}, std.sort.asc(u64));
    std.mem.doNotOptimizeAway(event_count);
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
    var event_count: usize = 0;
    for (0..@min(iterations, 100)) |_| {
        if (try runtime.stepWithSources(&sources, &poll_storage) == .ready) event_count += 1;
    }

    var samples_ps: [batch_count]u64 = undefined;
    var batch: usize = 0;
    while (batch < batch_count) : (batch += 1) {
        const start = std.Io.Clock.awake.now(init.io);
        for (0..iterations) |_| {
            if ((runtime.stepWithSources(&sources, &poll_storage) catch unreachable) == .ready) event_count += 1;
        }
        const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        if (elapsed <= 0) return error.ClockFailure;
        const elapsed_ns = std.math.cast(u64, elapsed) orelse return error.ClockFailure;
        samples_ps[batch] = @intCast((@as(u128, elapsed_ns) * 1_000) / iterations);
    }
    std.mem.sort(u64, &samples_ps, {}, std.sort.asc(u64));
    std.mem.doNotOptimizeAway(event_count);
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
    var process = tui.subprocess.PtyProcess.init(io);
    defer cleanupPtyProcess(&process);
    try process.spawnBeforeThreads(command, storage, options);
    const event = try process.wait();
    if (event != .exit or event.exit != .exited or event.exit.exited != 0) return error.UnexpectedChildExit;
}

fn cleanupPtyProcess(process: *tui.subprocess.PtyProcess) void {
    if (!process.isReaped()) {
        const deadline = std.Io.Clock.Timestamp.fromNow(
            process.io,
            .{ .raw = .fromSeconds(5), .clock = .awake },
        );
        process.killAndWait(deadline) catch |err| {
            std.debug.panic("failed to clean up PTY child: {s}", .{@errorName(err)});
        };
    }
    process.deinit() catch |err| {
        std.debug.panic("failed to release PTY child: {s}", .{@errorName(err)});
    };
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
    const query = negotiator.beginQueries();
    var replies = "\x1b[?7u\x1b[?2026;1$y".*;
    std.mem.doNotOptimizeAway(&replies);
    var parser: tui.input.Parser = .{};
    var consumed: usize = 0;
    while (true) {
        const result = parser.next(replies[consumed..]);
        consumed += result.consumed;
        switch (result.outcome) {
            .event => |event| _ = negotiator.observe(event),
            .failure => return error.MalformedReply,
            .need_more => break,
            .done => unreachable,
        }
    }
    if (negotiator.queriesPending()) return error.IncompleteNegotiation;
    const negotiated = negotiator.capabilities();
    return @as(u64, query.len) +
        @intFromBool(negotiated.kitty_keyboard) +
        @intFromBool(negotiated.synchronized_output);
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
    var storage: tui.editor.FixedStorage(4_096) = .{};
    std.mem.doNotOptimizeAway(&initial);
    var editor = try tui.editor.Model.init(storage.slices(), &initial);
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
    checksum.* +%= editor.cursorOffset() + editor.revision;
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

fn runWordBreakScenario(init: std.process.Init, stdout: *std.Io.Writer, iterations: usize) !void {
    const text = "can't stop 3.1415 or build_17 " ++
        "\xE4\xB8\x96\xE7\x95\x8C e\xCC\x81 " ++
        "\xF0\x9F\x87\xBA\xF0\x9F\x87\xB8\xF0\x9F\x87\xA8\xF0\x9F\x87\xA6";
    var checksum: u64 = 0;
    for (0..@min(iterations, 1_000)) |_| checksum +%= try wordBreakIteration(text);
    var samples_ps: [batch_count]u64 = undefined;
    var batch: usize = 0;
    while (batch < batch_count) : (batch += 1) {
        const start = std.Io.Clock.awake.now(init.io);
        for (0..iterations) |_| checksum +%= try wordBreakIteration(text);
        const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        if (elapsed <= 0) return error.ClockFailure;
        const elapsed_ns = std.math.cast(u64, elapsed) orelse return error.ClockFailure;
        samples_ps[batch] = @intCast((@as(u128, elapsed_ns) * 1_000) / iterations);
    }
    std.mem.sort(u64, &samples_ps, {}, std.sort.asc(u64));
    std.mem.doNotOptimizeAway(checksum);
    try writeNonRenderResult(stdout, .word_break_scan, iterations, samples_ps);
}

fn wordBreakIteration(text: []const u8) !u64 {
    var iterator = try tui.text.WordBreakIterator.init(text);
    var checksum: u64 = 0;
    while (iterator.next()) |boundary| checksum +%= boundary.offset;
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
        "{{\"scenario\":\"command_match\",\"optimize\":\"ReleaseFast\",\"width\":0,\"height\":0,\"iterations\":{d},\"frames\":{d},\"ps_median\":{d},\"ps_batch_max\":{d},\"operation_ps_max\":null,\"presentation_call_ps_max\":null,\"allocator_calls\":null,\"allocated_bytes\":null,\"ansi_bytes\":null,\"work_units\":null,\"cells_compared\":null,\"cells_changed\":null,\"runs\":null,\"output_chunks\":null,\"write_attempts\":null,\"accepted_bytes\":null,\"yielded_turns\":null}}\n",
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

fn runNonblockingPipeScenario(init: std.process.Init, stdout: *std.Io.Writer, requested_iterations: usize) !void {
    const iterations = @min(requested_iterations, 100);
    const input_pipe = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const input = std.Io.File{ .handle = input_pipe[0], .flags = .{ .nonblocking = true } };
    const input_writer = std.Io.File{ .handle = input_pipe[1], .flags = .{ .nonblocking = true } };
    defer input.close(init.io);
    defer input_writer.close(init.io);
    const output_pipe = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const output_reader = std.Io.File{ .handle = output_pipe[0], .flags = .{ .nonblocking = true } };
    const output_writer = std.Io.File{ .handle = output_pipe[1], .flags = .{ .nonblocking = true } };
    defer output_reader.close(init.io);
    defer output_writer.close(init.io);

    var read_buffer: [64]u8 = undefined;
    var timers: [0]tui.runtime.TimerSlot = .{};
    var runtime = try tui.runtime.Posix.init(init.io, input, &read_buffer, &timers, .{});
    defer runtime.deinit();
    var renderer_storage: tui.render.FixedRendererStorage(120, 40, 32, 8) = .{};
    var renderer = try tui.render.Renderer.init(renderer_storage.slices(), terminal_size);
    defer renderer.deinit();
    var discard_buffer: [4096]u8 = undefined;
    var discard = std.Io.Writer.Discarding.init(&discard_buffer);
    _ = try presentBuffered(&renderer, &discard.writer, capabilities, null);

    var samples_ps: [batch_count]u64 = undefined;
    var totals: Totals = .{};
    var operation_ns_max: u64 = 0;
    var batch: usize = 0;
    while (batch < batch_count) : (batch += 1) {
        const start = std.Io.Clock.awake.now(init.io);
        for (0..iterations) |iteration| {
            const operation_start = std.Io.Clock.awake.now(init.io);
            var surface = renderer.surface(tui.render.Rect.fromSize(renderer.size()));
            try surface.fillAscii(
                tui.render.Rect.fromSize(renderer.size()),
                if ((batch * iterations + iteration) & 1 == 0) 'x' else 'y',
                .{ .foreground = .{ .indexed = 2 } },
            );
            totals.add(try presentThroughPipe(&renderer, &runtime, output_reader, output_writer, init.io));
            const operation_elapsed = operation_start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
            operation_ns_max = @max(operation_ns_max, std.math.cast(u64, operation_elapsed) orelse return error.ClockFailure);
            if (start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds > 30 * std.time.ns_per_s) {
                return error.BenchmarkDeadlineExceeded;
            }
        }
        const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        if (elapsed <= 0) return error.ClockFailure;
        const elapsed_ns = std.math.cast(u64, elapsed) orelse return error.ClockFailure;
        samples_ps[batch] = @intCast((@as(u128, elapsed_ns) * 1_000) / iterations);
    }
    std.mem.sort(u64, &samples_ps, {}, std.sort.asc(u64));
    try stdout.print(
        "{{\"scenario\":\"nonblocking_pipe\",\"optimize\":\"ReleaseFast\",\"width\":120,\"height\":40,\"iterations\":{d},\"frames\":{d},\"ps_median\":{d},\"ps_batch_max\":{d},\"operation_ps_max\":{d},\"presentation_call_ps_max\":{d},\"allocator_calls\":null,\"allocated_bytes\":null,\"ansi_bytes\":{d},\"work_units\":{d},\"cells_compared\":{d},\"cells_changed\":{d},\"runs\":{d},\"output_chunks\":{d},\"write_attempts\":{d},\"accepted_bytes\":{d},\"yielded_turns\":{d}}}\n",
        .{
            iterations,
            iterations * batch_count,
            samples_ps[batch_count / 2],
            samples_ps[batch_count - 1],
            operation_ns_max * 1_000,
            totals.presentation_call_ns_max * 1_000,
            totals.accepted_bytes,
            totals.work_units,
            totals.cells_compared,
            totals.cells_changed,
            totals.runs,
            totals.output_chunks,
            totals.write_attempts,
            totals.accepted_bytes,
            totals.yielded_turns,
        },
    );
}

fn runLargeResizeScenario(init: std.process.Init, stdout: *std.Io.Writer, requested_iterations: usize) !void {
    const iterations = @min(requested_iterations, 10_000);
    const large_size = tui.render.Size{ .width = 240, .height = 80 };
    var renderer_storage: tui.render.FixedRendererStorage(240, 80, 32, 8) = .{};
    var renderer = try tui.render.Renderer.init(renderer_storage.slices(), large_size);
    defer renderer.deinit();
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.Writer.Discarding.init(&output_buffer);
    _ = try presentBuffered(&renderer, &output.writer, capabilities, null);

    const warmup_iterations = @min(iterations, 1_000);
    for (0..warmup_iterations) |iteration| {
        try renderer.resize(if (iteration & 1 == 0) .{ .width = 239, .height = 80 } else large_size);
        _ = try presentBuffered(&renderer, &output.writer, capabilities, null);
    }

    var samples_ps: [batch_count]u64 = undefined;
    var totals: Totals = .{};
    var batch: usize = 0;
    while (batch < batch_count) : (batch += 1) {
        const start = std.Io.Clock.awake.now(init.io);
        for (0..iterations) |iteration| {
            try renderer.resize(if ((batch * iterations + iteration) & 1 == 0)
                .{ .width = 239, .height = 80 }
            else
                large_size);
            totals.add(try presentBuffered(&renderer, &output.writer, capabilities, null));
        }
        const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        if (elapsed <= 0) return error.ClockFailure;
        const elapsed_ns = std.math.cast(u64, elapsed) orelse return error.ClockFailure;
        samples_ps[batch] = @intCast((@as(u128, elapsed_ns) * 1_000) / iterations);
    }
    std.mem.sort(u64, &samples_ps, {}, std.sort.asc(u64));
    try stdout.print(
        "{{\"scenario\":\"resize_large\",\"optimize\":\"ReleaseFast\",\"width\":240,\"height\":80,\"iterations\":{d},\"frames\":{d},\"ps_median\":{d},\"ps_batch_max\":{d},\"operation_ps_max\":null,\"presentation_call_ps_max\":null,\"allocator_calls\":null,\"allocated_bytes\":null,\"ansi_bytes\":{d},\"work_units\":{d},\"cells_compared\":{d},\"cells_changed\":{d},\"runs\":{d},\"output_chunks\":{d},\"write_attempts\":{d},\"accepted_bytes\":{d},\"yielded_turns\":{d}}}\n",
        .{
            iterations,
            iterations * batch_count,
            samples_ps[batch_count / 2],
            samples_ps[batch_count - 1],
            totals.accepted_bytes,
            totals.work_units,
            totals.cells_compared,
            totals.cells_changed,
            totals.runs,
            totals.output_chunks,
            totals.write_attempts,
            totals.accepted_bytes,
            totals.yielded_turns,
        },
    );
}

fn runGraphicsTransferScenario(init: std.process.Init, stdout: *std.Io.Writer, requested_iterations: usize) !void {
    const iterations: usize = @min(requested_iterations, 100_000);
    var payload: [tui.graphics.Sender.max_source_chunk_bytes]u8 = undefined;
    for (&payload, 0..) |*byte, index| byte.* = @truncate(index);
    const command = tui.graphics.kitty.Command{ .transmit = .{ .transmission = .{
        .width_pixels = payload.len / 4,
        .height_pixels = 1,
        .identifiers = .{ .image_id = 7 },
    } } };
    var sender = tui.graphics.Sender.init(.{});
    var encoded_bytes: u64 = 0;
    var output_steps: u64 = 0;
    var checksum: u64 = 0;
    for (0..@min(iterations, 1_000)) |_| {
        try sender.begin(command, .{ .direct = &payload }, .none);
        while (try sender.outputStep()) |bytes| try sender.consumeOutput(bytes.len);
    }

    var samples_ps: [batch_count]u64 = undefined;
    var batch: usize = 0;
    while (batch < batch_count) : (batch += 1) {
        const start = std.Io.Clock.awake.now(init.io);
        for (0..iterations) |_| {
            try sender.begin(command, .{ .direct = &payload }, .none);
            while (try sender.outputStep()) |bytes| {
                for (bytes) |byte| checksum +%= byte;
                encoded_bytes += bytes.len;
                output_steps += 1;
                try sender.consumeOutput(bytes.len);
            }
        }
        const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        if (elapsed <= 0) return error.ClockFailure;
        const elapsed_ns = std.math.cast(u64, elapsed) orelse return error.ClockFailure;
        samples_ps[batch] = @intCast((@as(u128, elapsed_ns) * 1_000) / iterations);
    }
    std.mem.sort(u64, &samples_ps, {}, std.sort.asc(u64));
    std.mem.doNotOptimizeAway(checksum);
    try stdout.print(
        "{{\"scenario\":\"graphics_transfer\",\"optimize\":\"ReleaseFast\",\"iterations\":{d},\"transfers\":{d},\"source_bytes\":{d},\"encoded_bytes\":{d},\"output_steps\":{d},\"checksum\":{d},\"ps_median\":{d},\"ps_batch_max\":{d},\"allocator_calls\":null}}\n",
        .{
            iterations,
            iterations * batch_count,
            @as(u64, iterations) * batch_count * payload.len,
            encoded_bytes,
            output_steps,
            checksum,
            samples_ps[batch_count / 2],
            samples_ps[batch_count - 1],
        },
    );
}

fn presentThroughPipe(
    renderer: *tui.render.Renderer,
    runtime: *tui.runtime.Posix,
    output_reader: std.Io.File,
    output_writer: std.Io.File,
    io: std.Io,
) !RenderMeasurement {
    errdefer renderer.abortPresentation() catch {};
    try renderer.beginPresentation(capabilities);
    var measurement: RenderMeasurement = .{ .stats = .{} };
    var drain_buffer: [4096]u8 = undefined;
    while (true) {
        const call_start = std.Io.Clock.awake.now(io);
        const step = try renderer.presentStep(256);
        const call_elapsed = call_start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
        measurement.presentation_call_ns_max = @max(
            measurement.presentation_call_ns_max,
            std.math.cast(u64, call_elapsed) orelse return error.ClockFailure,
        );
        switch (step) {
            .output => |output| {
                measurement.output_chunks += 1;
                var pending = output;
                while (pending.len != 0) {
                    const sources = [_]tui.runtime.PollSource{.{
                        .file = output_writer,
                        .interest = .{ .write = true },
                    }};
                    var poll_storage: [4]tui.runtime.PollSlot = undefined;
                    _ = try runtime.pollWithSources(&sources, &poll_storage);
                    measurement.write_attempts += 1;
                    const accepted = writeOnce(output_writer.handle, pending[0..@min(pending.len, 17)]) catch |err| switch (err) {
                        error.WouldBlock, error.Interrupted => {
                            try drainPipe(output_reader.handle, &drain_buffer);
                            continue;
                        },
                        else => return err,
                    };
                    if (accepted == 0) return error.NoWriteProgress;
                    measurement.accepted_bytes += accepted;
                    try renderer.consumePresentation(accepted);
                    pending = pending[accepted..];
                    try drainPipe(output_reader.handle, &drain_buffer);
                }
            },
            .yielded => measurement.yielded_turns += 1,
            .cleared => {},
            .complete => |stats| {
                measurement.stats = stats;
                return measurement;
            },
        }
    }
}

fn writeOnce(fd: std.posix.fd_t, bytes: []const u8) !usize {
    const result = std.posix.system.write(fd, bytes.ptr, bytes.len);
    return switch (std.posix.errno(result)) {
        .SUCCESS => @intCast(result),
        .INTR => error.Interrupted,
        .AGAIN => error.WouldBlock,
        .BADF => error.InvalidDescriptor,
        .IO => error.InputOutput,
        .PIPE => error.BrokenPipe,
        .NOBUFS, .NOMEM => error.SystemResources,
        else => error.Unexpected,
    };
}

fn drainPipe(fd: std.posix.fd_t, buffer: []u8) !void {
    while (true) {
        const result = std.posix.system.read(fd, buffer.ptr, buffer.len);
        switch (std.posix.errno(result)) {
            .SUCCESS => if (result == 0) return,
            .INTR => continue,
            .AGAIN => return,
            .BADF => return error.InvalidDescriptor,
            .IO => return error.InputOutput,
            else => return error.Unexpected,
        }
    }
}

fn runScenario(
    init: std.process.Init,
    stdout: *std.Io.Writer,
    comptime scenario: Scenario,
    iterations: usize,
) !void {
    var renderer_storage: tui.render.FixedRendererStorage(120, 40, 2048, 256) = .{};
    var renderer = try tui.render.Renderer.init(renderer_storage.slices(), terminal_size);
    defer renderer.deinit();

    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.Writer.Discarding.init(&output_buffer);
    _ = try presentBuffered(&renderer, &output.writer, capabilities, null);
    if (scenario == .terminal_recovery) {
        var surface = renderer.surface(tui.render.Rect.fromSize(renderer.size()));
        var y: u16 = 0;
        while (y < terminal_size.height) : (y += 1) {
            try surface.fillAscii(
                .{ .x = 0, .y = y, .width = terminal_size.width, .height = 1 },
                if (y & 1 == 0) '#' else '-',
                .{ .foreground = .{ .indexed = @intCast(1 + y % 7) } },
            );
        }
        _ = try presentBuffered(&renderer, &output.writer, capabilities, null);
    }
    var driver: tui.app.Driver = .{};
    var application: BenchmarkApplication = .{};
    var form_state: BenchmarkFormState = .{};
    var text_input_storage: tui.editor.FixedStorage(128) = .{};
    var text_input_model = try tui.editor.Model.initSingleLine(text_input_storage.slices(), "alpha ox");
    var text_input = tui.widget.TextInput.init(&text_input_model);
    text_input.focused = true;
    var text_area_storage: tui.editor.FixedStorage(2048) = .{};
    var deep_unwrapped_initial: [1536]u8 = @splat('x');
    var text_area_model = try tui.editor.Model.init(
        text_area_storage.slices(),
        if (scenario == .text_area_deep_unwrapped) &deep_unwrapped_initial else text_area_initial,
    );
    var text_area = tui.widget.TextArea{ .model = &text_area_model, .focused = true };
    if (scenario == .text_area or scenario == .text_area_full) {
        _ = text_area.layout(.{ .width = 64, .height = 20 });
        if (scenario == .text_area) text_area_model.viewport.top_row = text_area_model.lineCount() - 1;
    }
    if (scenario == .text_input_selection) _ = try text_input_model.setSelection(6, 8);
    if (scenario == .text_area_soft_wrap or scenario == .text_area_deep_soft_wrap) {
        _ = text_area_model.setSoftWrap(true);
        _ = text_area.layout(.{ .width = if (scenario == .text_area_deep_soft_wrap) 8 else 24, .height = 20 });
        if (scenario == .text_area_soft_wrap) {
            _ = try text_area_model.setCursor(0);
        } else {
            const visible = text_area_model.visibleRows();
            var rows = text_area_model.visualRows();
            var row_count: usize = 0;
            while (rows.next() != null) row_count += 1;
            if (visible.start == 0 or visible.end != row_count) unreachable;
        }
        if (text_area.handle(.{ .key = .{ .code = .home } }) != .redraw) unreachable;
        if (text_area.handle(.{ .key = .{ .code = .end, .modifiers = .{ .shift = true } } }) != .redraw) unreachable;
    }
    if (scenario == .text_area_deep_unwrapped) {
        _ = text_area.layout(.{ .width = 24, .height = 1 });
        _ = try text_area_model.setCursor(deep_unwrapped_initial.len);
        _ = try text_area_model.setSelection(deep_unwrapped_initial.len - 8, deep_unwrapped_initial.len);
    }
    var portfolio_input_storage: tui.editor.FixedStorage(256) = .{};
    var portfolio_input_model = try tui.editor.Model.initSingleLine(portfolio_input_storage.slices(), "Ada");
    var portfolio_editor_storage: tui.editor.FixedStorage(1024) = .{};
    var portfolio_editor = try tui.editor.Model.init(portfolio_editor_storage.slices(), "Bounded portfolio editor");
    var portfolio = demo_app.DemoApp.init(&portfolio_input_model, &portfolio_editor);
    if (scenario == .demo_cycle) try portfolio.layout(.{ .width = 80, .height = 24 });
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
            &portfolio,
            &data_state,
            iteration,
            init.io,
        );
    }

    const output_bytes_before = output.fullCount();
    const frames = iterations * batch_count;
    var samples_ps: [batch_count]u64 = undefined;
    var totals: Totals = .{};
    var operation_ns_max: u64 = 0;

    var batch: usize = 0;
    while (batch < batch_count) : (batch += 1) {
        const start = std.Io.Clock.awake.now(init.io);
        iteration = 0;
        while (iteration < iterations) : (iteration += 1) {
            std.mem.doNotOptimizeAway(&renderer);
            const operation_start = if (scenario == .intern_churn) std.Io.Clock.awake.now(init.io) else undefined;
            const measurement = try renderIteration(
                scenario,
                &renderer,
                &output.writer,
                &driver,
                &application,
                &form_state,
                &text_input,
                &text_area,
                &portfolio,
                &data_state,
                warmup_iterations + batch * iterations + iteration,
                init.io,
            );
            totals.add(measurement);
            if (scenario == .intern_churn) {
                const operation_elapsed = operation_start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
                operation_ns_max = @max(
                    operation_ns_max,
                    std.math.cast(u64, operation_elapsed) orelse return error.ClockFailure,
                );
            }
        }
        const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        if (elapsed <= 0) return error.ClockFailure;
        const elapsed_ns = std.math.cast(u64, elapsed) orelse return error.ClockFailure;
        samples_ps[batch] = @intCast((@as(u128, elapsed_ns) * 1_000) / iterations);
    }
    std.mem.sort(u64, &samples_ps, {}, std.sort.asc(u64));
    const operation_ps_max: ?u64 = if (scenario == .intern_churn) operation_ns_max * 1_000 else null;
    const presentation_call_ps_max: ?u64 = if (scenario == .intern_churn)
        totals.presentation_call_ns_max * 1_000
    else
        null;

    try stdout.print(
        "{{\"scenario\":\"{s}\",\"optimize\":\"ReleaseFast\",\"width\":120,\"height\":40,\"iterations\":{d},\"frames\":{d},\"ps_median\":{d},\"ps_batch_max\":{d},\"operation_ps_max\":{any},\"presentation_call_ps_max\":{any},\"allocator_calls\":null,\"allocated_bytes\":null,\"ansi_bytes\":{d},\"work_units\":{d},\"cells_compared\":{d},\"cells_changed\":{d},\"runs\":{d},\"output_chunks\":{d},\"write_attempts\":{d},\"accepted_bytes\":{d},\"yielded_turns\":{d}}}\n",
        .{
            @tagName(scenario),
            iterations,
            frames,
            samples_ps[batch_count / 2],
            samples_ps[batch_count - 1],
            operation_ps_max,
            presentation_call_ps_max,
            output.fullCount() - output_bytes_before,
            totals.work_units,
            totals.cells_compared,
            totals.cells_changed,
            totals.runs,
            totals.output_chunks,
            totals.write_attempts,
            totals.accepted_bytes,
            totals.yielded_turns,
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
    portfolio: *demo_app.DemoApp,
    data_state: *BenchmarkDataState,
    iteration: usize,
    io: std.Io,
) !RenderMeasurement {
    switch (scenario) {
        .command_match => unreachable,
        .app_cycle => {
            const update = driver.dispatch(application, .{ .key = .{ .code = .enter } });
            if (update != .redraw) unreachable;
            try driver.prepare(renderer, application);
            if (!renderer.needsPresentation(capabilities)) return .{ .stats = .{} };
            return presentBuffered(
                renderer,
                writer,
                capabilities,
                if (scenario == .intern_churn) io else null,
            );
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
            var root = renderer.surface(.{ .x = 4, .y = 2, .width = 52, .height = 8 });
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
            var surface = renderer.surface(.{ .x = 4, .y = 2, .width = 52, .height = 8 });
            const panel = tui.widget.Panel{
                .title = if (iteration & 1 == 0) "production" else "staging",
                .border = .{ .normal = .{ .foreground = .{ .indexed = 6 } } },
            };
            try panel.draw(&surface);
        },
        .display_gauge => {
            var surface = renderer.surface(.{ .x = 5, .y = 5, .width = 50, .height = 1 });
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

            var button_surface = renderer.surface(.{ .x = 4, .y = 2, .width = 24, .height = 1 });
            try form_state.button.draw(&button_surface);
            var checkbox_surface = renderer.surface(.{ .x = 4, .y = 3, .width = 24, .height = 1 });
            try form_state.checkbox.draw(&checkbox_surface);
            var radio_surface = renderer.surface(.{ .x = 4, .y = 4, .width = 24, .height = 1 });
            try radio.draw(&radio_surface);
        },
        .text_input => {
            if (text_input.handle(.{ .key = .{ .code = .left } }) != .redraw) unreachable;
            if (text_input.handle(.{ .key = .{ .code = .backspace } }) != .redraw) unreachable;
            if (text_input.handle(.{ .text = if (iteration & 1 == 0) "e\xCC\x81" else "o" }) != .redraw) unreachable;
            if (text_input.handle(.{ .key = .{ .code = .right } }) != .redraw) unreachable;
            var surface = renderer.surface(.{ .x = 4, .y = 2, .width = 32, .height = 1 });
            try text_input.draw(&surface);
        },
        .text_input_selection => {
            if (text_input.handle(.{ .text = if (iteration & 1 == 0) "go" else "ox" }) != .redraw) unreachable;
            if (!try text_input.model.setSelection(6, 8)) unreachable;
            var surface = renderer.surface(.{ .x = 4, .y = 2, .width = 32, .height = 1 });
            try text_input.draw(&surface);
        },
        .text_area, .text_area_full => {
            if (text_area.handle(.{ .key = .{ .code = .left } }) != .redraw) unreachable;
            if (text_area.handle(.{ .key = .{ .code = .backspace } }) != .redraw) unreachable;
            if (text_area.handle(.{ .text = if (iteration & 1 == 0) "x" else "o" }) != .redraw) unreachable;
            if (text_area.handle(.{ .key = .{ .code = .right } }) != .redraw) unreachable;
            var surface = renderer.surface(.{ .x = 4, .y = 4, .width = 64, .height = 20 });
            try text_area.draw(&surface);
        },
        .text_area_soft_wrap, .text_area_deep_soft_wrap => {
            if (text_area.handle(.{ .key = .{ .code = .home } }) != .redraw) unreachable;
            if (text_area.handle(.{ .key = .{ .code = .end, .modifiers = .{ .shift = true } } }) != .redraw) unreachable;
            var surface = renderer.surface(.{
                .x = 4,
                .y = 4,
                .width = if (scenario == .text_area_deep_soft_wrap) 8 else 24,
                .height = 20,
            });
            try text_area.draw(&surface);
        },
        .text_area_deep_unwrapped => {
            if (text_area.handle(.{ .key = .{ .code = .left } }) != .redraw) unreachable;
            if (text_area.handle(.{ .key = .{ .code = .right } }) != .redraw) unreachable;
            var surface = renderer.surface(.{ .x = 4, .y = 4, .width = 24, .height = 1 });
            try text_area.draw(&surface);
        },
        .demo_cycle => {
            const update = portfolio.handle(.{ .key = .{
                .code = if (iteration & 1 == 0) .right else .left,
                .modifiers = .{ .alt = true },
            } });
            if (update != .redraw) unreachable;
            var surface = renderer.surface(.{ .x = 0, .y = 0, .width = 80, .height = 24 });
            try portfolio.draw(&surface);
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
            var surface = renderer.surface(scrollback.bounds);
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
            var surface = renderer.surface(list.bounds);
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
            var surface = renderer.surface(table.bounds);
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

            var root = renderer.surface(tui.render.Rect.fromSize(renderer.size()));
            _ = try root.putText(.{ .x = 0, .y = 0 }, if (iteration & 1 == 0) "a" else "b", .{}, .narrow);
            for (overlays.entries()) |overlay_entry| {
                if (overlay_entry.id != 1) unreachable;
                var panel_surface = renderer.surface(overlay_entry.bounds);
                const panel = tui.widget.Panel{ .title = "command palette" };
                try panel.draw(&panel_surface);
                var menu_surface = renderer.surface(menu.bounds);
                try menu.draw(&menu_surface);
            }
            if (overlays.pop() == null) unreachable;
        },
        .no_op => {},
        .single_cell => {
            var surface = renderer.surface(tui.render.Rect.fromSize(renderer.size()));
            _ = try surface.putText(
                .{ .x = 5, .y = 2 },
                if (iteration & 1 == 0) "x" else "y",
                .{},
                .narrow,
            );
        },
        .surface_cell => {
            var panel = renderer.surface(.{ .x = 10, .y = 5, .width = 80, .height = 24 });
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
            var panel = renderer.surface(.{ .x = 10, .y = 5, .width = 80, .height = 24 });
            var surface = panel.surface(.{ .x = 2, .y = 1, .width = 40, .height = 12 });
            const widget = CellWidget{ .text = if (iteration & 1 == 0) "x" else "y" };
            try widget.draw(&surface);
        },
        .text_line => {
            var surface = renderer.surface(.{ .x = 10, .y = 5, .width = 32, .height = 1 });
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
            var surface = renderer.surface(.{ .x = 10, .y = 5, .width = 32, .height = 1 });
            _ = try surface.putStyledLine(
                .{ .x = 0, .y = 0 },
                if (iteration & 1 == 0) &first else &second,
                32,
                .{},
                .narrow,
                .{ .overflow = .ellipsis },
            );
        },
        .wrap_text, .wrap_long_word, .wrap_ascii, .wrap_unicode => {
            const text = if (scenario == .wrap_long_word)
                "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz"
            else if (scenario == .wrap_ascii)
                "status: ready/active; retry-after=10, queue=(alpha,beta), range=4-9."
            else if (scenario == .wrap_unicode)
                "naïve 世界 e\xCC\x81lan 👩\xE2\x80\x8D💻 — Καλημέρα κόσμε"
            else if (iteration & 1 == 0)
                "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu"
            else
                "one two three four five six seven eight nine ten eleven twelve thirteen";
            var lines = try tui.text.WrapIterator.init(text, 16, .narrow);
            var width: u16 = 0;
            while (try lines.next()) |line| width +%= line.width;
            std.mem.doNotOptimizeAway(width);
        },
        .wrapped_paragraph => {
            var surface = renderer.surface(.{ .x = 10, .y = 5, .width = 32, .height = 4 });
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
            var surface = renderer.surface(.{ .x = 10, .y = 5, .width = 32, .height = 4 });
            _ = try surface.putWrappedStyledText(
                .{ .x = 0, .y = 0, .width = 32, .height = 4 },
                if (iteration & 1 == 0) &first else &second,
                .{},
                .narrow,
                .left,
            );
        },
        .wrapped_styled_ascii => {
            const first = [_]tui.render.StyledSpan{
                .{ .text = "status:" },
                .{ .text = " ready/", .style = .{ .foreground = .{ .indexed = 2 } } },
                .{ .text = "active;" },
                .{ .text = " retry-", .style = .{ .attributes = .{ .bold = true } } },
                .{ .text = "after=10," },
                .{ .text = " queue=(alpha,beta), range=4-9." },
            };
            const second = [_]tui.render.StyledSpan{
                .{ .text = "status:" },
                .{ .text = " busy/", .style = .{ .foreground = .{ .indexed = 3 } } },
                .{ .text = "active;" },
                .{ .text = " retry-", .style = .{ .attributes = .{ .bold = true } } },
                .{ .text = "after=11," },
                .{ .text = " queue=(beta,gamma), range=5-10." },
            };
            var surface = renderer.surface(.{ .x = 10, .y = 5, .width = 32, .height = 4 });
            _ = try surface.putWrappedStyledText(
                .{ .x = 0, .y = 0, .width = 32, .height = 4 },
                if (iteration & 1 == 0) &first else &second,
                .{},
                .narrow,
                .left,
            );
        },
        .wrapped_styled_unicode => {
            const first = [_]tui.render.StyledSpan{
                .{ .text = "naïve " },
                .{ .text = "世界", .style = .{ .foreground = .{ .indexed = 2 } } },
                .{ .text = "" },
                .{ .text = " e\xCC\x81lan " },
                .{ .text = "👩\xE2\x80\x8D💻", .style = .{ .attributes = .{ .bold = true } } },
                .{ .text = " — Καλημέρα κόσμε" },
            };
            const second = [_]tui.render.StyledSpan{
                .{ .text = "naïve " },
                .{ .text = "東京", .style = .{ .foreground = .{ .indexed = 3 } } },
                .{ .text = "" },
                .{ .text = " e\xCC\x81lan " },
                .{ .text = "👩\xE2\x80\x8D💻", .style = .{ .attributes = .{ .bold = true } } },
                .{ .text = " — Καλησπέρα κόσμε" },
            };
            var surface = renderer.surface(.{ .x = 10, .y = 5, .width = 32, .height = 4 });
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
        .owned_event_key,
        .owned_event_paste,
        .runtime_timer_heap,
        .runtime_wakeup,
        .runtime_signal,
        .runtime_source_ready,
        .pty_spawn,
        .capability_negotiation,
        .scrollback_append,
        .line_decode,
        .process_output_batch,
        .editor_middle_edit,
        .editor_deep_line,
        .editor_unicode_navigation,
        .editor_history,
        .line_break_scan,
        .word_break_scan,
        .nonblocking_pipe,
        .resize_large,
        .graphics_transfer,
        => unreachable,
        .sparse_cells => {
            var surface = renderer.surface(tui.render.Rect.fromSize(renderer.size()));
            _ = try surface.putText(
                .{ .x = 5, .y = 2 },
                if (iteration & 1 == 0) "x" else "y",
                .{},
                .narrow,
            );
            _ = try surface.putText(
                .{ .x = 105, .y = 2 },
                if (iteration & 1 == 0) "a" else "b",
                .{},
                .narrow,
            );
        },
        .small_fill => {
            var surface = renderer.surface(tui.render.Rect.fromSize(renderer.size()));
            try surface.fill(.{ .x = 20, .y = 10, .width = 6, .height = 6 }, .{
                .background = .{ .indexed = if (iteration & 1 == 0) 4 else 5 },
            });
        },
        .identical_full_fill => {
            var surface = renderer.surface(tui.render.Rect.fromSize(renderer.size()));
            try surface.fill(tui.render.Rect.fromSize(renderer.size()), .{
                .background = .{ .indexed = 4 },
            });
        },
        .dense_same_style => {
            var line: [terminal_size.width]u8 = @splat(if (iteration & 1 == 0) 'x' else 'y');
            var surface = renderer.surface(tui.render.Rect.fromSize(renderer.size()));
            var y: u16 = 0;
            while (y < terminal_size.height) : (y += 1) {
                _ = try surface.putTextPadded(
                    .{ .x = 0, .y = y },
                    &line,
                    terminal_size.width,
                    .{ .foreground = .{ .indexed = 2 } },
                    .narrow,
                );
            }
        },
        .intern_churn => {
            const mark: u21 = @intCast(0x0300 + iteration % 0x70);
            var encoded: [4]u8 = undefined;
            const mark_len = std.unicode.utf8Encode(mark, &encoded) catch unreachable;
            var cluster: [5]u8 = undefined;
            cluster[0] = @intCast('a' + iteration % 26);
            @memcpy(cluster[1 .. 1 + mark_len], encoded[0..mark_len]);
            const color: u24 = @truncate(iteration *% 2_654_435_761);
            var surface = renderer.surface(tui.render.Rect.fromSize(renderer.size()));
            _ = try surface.putText(
                .{ .x = 5, .y = 2 },
                cluster[0 .. 1 + mark_len],
                .{ .foreground = .{ .rgb = .{
                    .r = @truncate(color >> 16),
                    .g = @truncate(color >> 8),
                    .b = @truncate(color),
                } } },
                .narrow,
            );
        },
        .scrolling => {
            try renderer.scrollUp(.{ .x = 0, .y = 4, .width = 120, .height = 36 });
            var surface = renderer.surface(tui.render.Rect.fromSize(renderer.size()));
            _ = try surface.putTextPadded(
                .{ .x = 0, .y = 39 },
                if (iteration & 1 == 0) "log alpha" else "log beta",
                120,
                .{},
                .narrow,
            );
        },
        .unicode_style => {
            var surface = renderer.surface(tui.render.Rect.fromSize(renderer.size()));
            _ = try surface.putText(
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
            var surface = renderer.surface(tui.render.Rect.fromSize(renderer.size()));
            try surface.fill(tui.render.Rect.fromSize(renderer.size()), .{
                .background = .{ .indexed = if (iteration & 1 == 0) 1 else 2 },
            });
        },
        .terminal_recovery => try renderer.invalidateTerminal(),
        .hardware_cursor => try renderer.setCursor(.{
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
    return presentBuffered(
        renderer,
        writer,
        capabilities,
        if (scenario == .intern_churn) io else null,
    );
}

fn presentBuffered(
    renderer: *tui.render.Renderer,
    writer: *std.Io.Writer,
    terminal_capabilities: tui.terminal.Capabilities,
    clock_io: ?std.Io,
) !RenderMeasurement {
    errdefer renderer.abortPresentation() catch {};
    try renderer.beginPresentation(terminal_capabilities);
    var measurement: RenderMeasurement = .{ .stats = .{} };
    while (true) {
        const call_start = if (clock_io) |io| std.Io.Clock.awake.now(io) else undefined;
        const step = try renderer.presentStep(256);
        if (clock_io) |io| {
            const elapsed = call_start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
            measurement.presentation_call_ns_max = @max(
                measurement.presentation_call_ns_max,
                std.math.cast(u64, elapsed) orelse return error.ClockFailure,
            );
        }
        switch (step) {
            .output => |bytes| {
                measurement.output_chunks += 1;
                measurement.write_attempts += 1;
                try writer.writeAll(bytes);
                measurement.accepted_bytes += bytes.len;
                try renderer.consumePresentation(bytes.len);
            },
            .yielded => measurement.yielded_turns += 1,
            .cleared => {},
            .complete => |stats| {
                measurement.stats = stats;
                return measurement;
            },
        }
    }
}

const BenchmarkApplication = struct {
    alternate: bool = false,

    pub inline fn handle(self: *@This(), _: tui.input.Event) tui.widget.Update {
        self.alternate = !self.alternate;
        return .redraw;
    }

    pub inline fn layout(_: *@This(), _: tui.render.Size) !void {}

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
