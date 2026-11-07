const std = @import("std");
const tui = @import("tui");

const Grid = tui.render.FixedRendererStorage(512, 256, 1024, 16);
const Stop = enum { none, quit, suspend_process };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const tty: std.Io.File = .{
        .handle = try std.posix.openat(std.posix.AT.FDCWD, "/dev/tty", .{
            .ACCMODE = .RDWR,
            .NONBLOCK = true,
            .CLOEXEC = true,
        }, 0),
        .flags = .{ .nonblocking = true },
    };
    defer tty.close(io);
    var signals = try tui.runtime.SignalSource.init(io, .{});
    defer signals.deinit() catch unreachable;
    var input_bytes: [4096]u8 = undefined;
    var timers: [1]tui.runtime.TimerSlot = undefined;
    var runtime = try tui.runtime.Posix.init(io, tty, &input_bytes, &timers, .{ .signals = &signals, .resize = tty });
    defer runtime.deinit();

    var text: tui.editor.FixedStorage(4096) = .{};
    var model = try tui.editor.Model.init(
        text.slices(),
        "Terminal interface / implementation notes\n" ++
            "\n" ++
            "BOUNDARIES\n" ++
            "Application  document, bindings, pointer capture, redraw scheduling\n" ++
            "Library      grapheme indexing, clipped drawing, terminal protocols\n" ++
            "\n" ++
            "INVARIANTS\n" ++
            "Text         UTF-8; cursor and selection are byte offsets\n" ++
            "Selection    endpoints always fall on grapheme boundaries\n" ++
            "Output       acknowledge only bytes accepted by the terminal\n" ++
            "\n" ++
            "OPERATING NOTES\n" ++
            "Resize       width changes visual rows, not the document\n" ++
            "Paste        fragmented input is staged, then committed once\n" ++
            "Undo         committed edits use caller-owned history\n" ++
            "\n" ++
            "UNICODE SAMPLES\n" ++
            "Wide         界 日本語\n" ++
            "Combining    e\u{301} a\u{308}\n" ++
            "Joined       👩‍💻\n" ++
            "\n" ++
            "WORK NOTES\n" ++
            "\n",
    );
    var records: [128]tui.editor.HistoryRecord = undefined;
    var history_bytes: [16384]u8 = undefined;
    var history = try tui.editor.History.init(&records, &history_bytes);
    try model.setHistory(&history);
    _ = try model.setSoftWrap(true);
    _ = try model.setCursor(0);

    const grid = try init.arena.allocator().create(Grid);
    var renderer = try tui.render.Renderer.init(grid.slices(), boundedSize((try tui.terminal.queryGeometry(tty)).cells));
    defer renderer.deinit();
    var area: tui.widget.TextArea = .{ .model = &model, .focused = true, .paint_caret = false };
    var geometry = layout(renderer.size());
    _ = model.setViewportSize(geometry.editor.width, geometry.editor.height);

    var session = try tui.terminal.Session.init(tty, .{ .mouse = true });
    defer if (session.termios_restore_needed or session.terminal_restore_needed) {
        _ = session.emergencyRestore(tty.handle);
    };
    try session.beginEnter();
    try drainSession(&session, tty.handle, io);

    var dirty = true;
    var repaint = false;
    var resize: ?tui.render.Size = null;
    var dragging = false;
    var stop: Stop = .none;
    var failure: ?[]const u8 = null;
    var previous_frame: ?tui.render.FrameStats = null;
    while (true) {
        if (!renderer.isPresenting()) {
            if (stop != .none) {
                try session.beginLeave();
                try drainSession(&session, tty.handle, io);
                try session.restoreTermios();
                if (stop == .quit) break;
                model.cancelPaste();
                dragging = false;
                try signals.suspendProcess();
                try session.beginEnter();
                try drainSession(&session, tty.handle, io);
                _ = runtime.cancelTimer(0);
                stop = .none;
                resize = (try tui.terminal.queryGeometry(tty)).cells;
                repaint = true;
            }
            if (resize) |size| {
                try renderer.resize(boundedSize(size));
                geometry = layout(renderer.size());
                _ = model.setViewportSize(geometry.editor.width, geometry.editor.height);
                dragging = false;
                resize = null;
                dirty = true;
            }
            if (repaint) {
                try renderer.invalidateTerminal();
                repaint = false;
                dirty = true;
            }
            if (dirty) {
                try draw(&renderer, &area, geometry, runtime.inputState(), previous_frame, dragging, failure);
                dirty = false;
                try renderer.beginPresentation(.{ .color_depth = .indexed256 });
            }
        }

        var blocked = false;
        if (renderer.isPresenting()) {
            switch (try renderer.presentStep(256)) {
                .output => |bytes| {
                    if (try writeOnce(tty.handle, bytes)) |accepted| {
                        try renderer.consumePresentation(accepted);
                    } else blocked = true;
                },
                .cleared => try renderer.invalidateOutputState(),
                .complete => |stats| previous_frame = stats,
                .yielded => {},
            }
        }

        const sources = [_]tui.runtime.PollSource{.{ .file = tty, .interest = .{ .write = blocked } }};
        var poll_slots: [4]tui.runtime.PollSlot = undefined;
        const runnable = if (renderer.isPresenting()) !blocked else dirty or repaint or resize != null or stop != .none;
        const event = (if (runnable)
            try runtime.pollWithSources(&sources, &poll_slots)
        else
            try runtime.stepWithSources(&sources, &poll_slots)) orelse continue;
        const previous_stop = stop;
        switch (event) {
            .eof => stop = .quit,
            .resize => |terminal_geometry| resize = terminal_geometry.cells,
            .signal => |signal| switch (signal) {
                .interrupt, .terminate => stop = .quit,
                .suspend_requested => if (stop == .none) {
                    stop = .suspend_process;
                },
                .continued => {},
            },
            .timer => return error.OutputTimeout,
            .input_failure => {
                _ = model.handle(.malformed);
                failure = "Incomplete input";
                dirty = true;
            },
            .input => |input| input: {
                if (stop != .none) break :input;
                if (input == .key and input.key.action != .release) {
                    const key = input.key;
                    if (std.meta.eql(key.modifiers, tui.input.Modifiers{ .control = true }) and key.code == .codepoint) {
                        switch (key.code.codepoint) {
                            'q', 'c' => {
                                stop = .quit;
                                break :input;
                            },
                            'g' => {
                                stop = .suspend_process;
                                break :input;
                            },
                            'l' => {
                                repaint = true;
                                break :input;
                            },
                            else => {},
                        }
                    }
                    if (key.code == .function and key.code.function == 2 and !key.modifiers.hasNonLock()) {
                        _ = try model.setSoftWrap(!model.softWrapEnabled());
                        dirty = true;
                        break :input;
                    }
                }
                if (input == .focus_out or input == .focus_in) {
                    area.focused = input == .focus_in;
                    dragging = false;
                    if (!area.focused) model.cancelPaste();
                    dirty = true;
                    break :input;
                }
                if (input == .mouse) {
                    const mouse = input.mouse;
                    const body = geometry.editor;
                    if (mouse.action == .release) {
                        dirty = dirty or dragging;
                        dragging = false;
                        break :input;
                    }
                    if (body.isEmpty()) break :input;
                    var modifiers = mouse.modifiers;
                    modifiers.shift = false;
                    if (modifiers.hasNonLock()) break :input;
                    const inside = body.contains(.{ .x = mouse.x, .y = mouse.y });
                    if (inside and (mouse.action == .scroll_up or mouse.action == .scroll_down)) {
                        model.viewport.top_row = if (mouse.action == .scroll_up)
                            model.viewport.top_row -| 3
                        else
                            @min(model.viewport.top_row +| 3, model.visual_row_count -| body.height);
                        dirty = true;
                        break :input;
                    }
                    const press = inside and mouse.action == .press and mouse.button == .left;
                    if (press or (dragging and mouse.action == .move)) {
                        const position: tui.editor.Position = .{
                            .row = @min(model.viewport.top_row + (std.math.clamp(mouse.y, body.y, body.y + body.height - 1) - body.y), model.visual_row_count - 1),
                            .column = model.viewport.left_column + (std.math.clamp(mouse.x, body.x, body.x + body.width - 1) - body.x),
                        };
                        _ = try model.setVisualCursor(position, !press or mouse.modifiers.shift);
                        dragging = true;
                        dirty = true;
                    }
                    break :input;
                }
                dirty = dirty or dragging;
                dragging = false;
                const result = if (tui.editor.defaultAction(input, .multiline)) |action|
                    model.applyAction(action)
                else
                    model.handle(input);
                if (result.status == .redraw or result.failure != null) {
                    failure = if (result.failure) |err| @errorName(err) else null;
                    dirty = true;
                }
                if (input == .paste_start or input == .paste_chunk or input == .paste_end) dirty = true;
            },
            .ready, .wakeup => {},
        }
        if (previous_stop == .none and stop != .none) {
            _ = try runtime.setTimer(0, .{ .raw = .{ .nanoseconds = runtime.now().raw.nanoseconds + std.time.ns_per_s }, .clock = .awake });
        }
    }
}

fn boundedSize(size: tui.render.Size) tui.render.Size {
    return .{ .width = @min(size.width, 512), .height = @min(size.height, 256) };
}

const Geometry = struct {
    bounds: tui.render.Rect,
    editor: tui.render.Rect,
    gutter: tui.render.Rect,
    scrollbar: tui.render.Rect,
    inspector: tui.render.Rect,
};

fn layout(size: tui.render.Size) Geometry {
    const width = @min(size.width, 160);
    const margin: u16 = if (width >= 60) 2 else 0;
    const bounds: tui.render.Rect = .{ .x = (size.width - width) / 2 + margin, .y = 0, .width = width - 2 * margin, .height = size.height };
    const top: u16 = if (size.height >= 12) 4 else @intFromBool(size.height > 1);
    const height = size.height -| (top + @as(u16, if (size.height >= 12) 4 else 2));
    const inspector_width: u16 = if (bounds.width >= 108 and height >= 16) 32 else 0;
    const document_width = bounds.width - (if (inspector_width != 0) inspector_width + 3 else 0);
    const gutter_width: u16 = if (document_width >= 20) 6 else 0;
    const bar_width: u16 = if (document_width >= 20) 2 else 0;
    const editor: tui.render.Rect = .{ .x = bounds.x + gutter_width, .y = top, .width = document_width - gutter_width - bar_width, .height = height };
    return .{
        .bounds = bounds,
        .editor = editor,
        .gutter = .{ .x = bounds.x, .y = top, .width = gutter_width -| 2, .height = height },
        .scrollbar = .{ .x = editor.x + editor.width + @intFromBool(bar_width != 0), .y = top, .width = @intFromBool(bar_width != 0), .height = height },
        .inspector = .{ .x = bounds.x + bounds.width - inspector_width, .y = top, .width = inspector_width, .height = height },
    };
}

fn draw(
    renderer: *tui.render.Renderer,
    area: *const tui.widget.TextArea,
    geometry: Geometry,
    input_state: tui.runtime.InputState,
    previous_frame: ?tui.render.FrameStats,
    dragging: bool,
    failure: ?[]const u8,
) !void {
    var surface = renderer.surface(tui.render.Rect.fromSize(renderer.size()));
    const size = surface.size();
    const bounds = geometry.bounds;
    const model = area.model;
    const position = model.cursorPosition();
    const selected = model.selection();
    const selected_bytes = if (selected) |range| range.end - range.start else 0;
    const heading: tui.render.Style = .{ .foreground = .{ .indexed = 4 }, .attributes = .{ .bold = true } };
    const muted: tui.render.Style = .{ .attributes = .{ .dim = true } };
    const key_style: tui.render.Style = .{ .attributes = .{ .bold = true } };
    const title_style: tui.render.Style = .{ .attributes = .{ .bold = true, .reverse = true } };
    _ = try surface.putTextLine(.{ .x = bounds.x, .y = 0 }, " tui.zig  /  text workbench", bounds.width, title_style, .narrow, .{ .overflow = .ellipsis });
    if (bounds.width >= 64) {
        _ = try surface.putTextLine(.{ .x = bounds.x + bounds.width - 24, .y = 0 }, "SCRATCH  /  MEMORY ONLY ", 24, title_style, .narrow, .{ .alignment = .right });
    }

    if (size.height >= 12) {
        const document_width = geometry.editor.x + geometry.editor.width + geometry.scrollbar.width + @intFromBool(geometry.scrollbar.width != 0) - bounds.x;
        _ = try surface.putStyledLine(.{ .x = bounds.x, .y = 2 }, &.{
            .{ .text = "DOCUMENT", .style = heading },
            .{ .text = "  scratch  /  UTF-8" },
        }, document_width, .{}, .narrow, .{ .overflow = .ellipsis });
        try surface.fillAscii(.{ .x = bounds.x, .y = 3, .width = document_width, .height = 1 }, '-', muted);
        try surface.fillAscii(.{ .x = bounds.x, .y = size.height - 4, .width = bounds.width, .height = 1 }, '-', muted);
    }

    var body = surface.surface(geometry.editor);
    try area.draw(&body);
    const caret = if (area.caretPosition()) |point| body.screenPoint(point) else null;
    try renderer.setCursor(.{ .position = caret orelse .{ .x = 0, .y = 0 }, .visible = caret != null, .shape = .steady_bar });

    if (geometry.gutter.width != 0) {
        try surface.fillAscii(.{ .x = geometry.editor.x - 2, .y = geometry.editor.y, .width = 1, .height = geometry.editor.height }, '|', muted);
        var rows = model.visualRowsFrom(model.viewport.top_row);
        var line_number: usize = 1;
        var y: u16 = 0;
        while (rows.next()) |row| : (y += 1) {
            if (y == geometry.editor.height) break;
            if (y == 0) line_number = std.mem.count(u8, model.value()[0..row.start], "\n") + 1;
            const continuation = y != 0 and row.start != 0 and model.value()[row.start - 1] != '\n';
            var number_bytes: [16]u8 = undefined;
            const number = if (continuation) ">" else try std.fmt.bufPrint(&number_bytes, "{d}", .{line_number});
            _ = try surface.putTextLine(.{ .x = geometry.gutter.x, .y = geometry.gutter.y + y }, number, geometry.gutter.width, if (line_number == position.row + 1) heading else muted, .narrow, .{ .alignment = .right });
            if (row.break_kind == .hard) line_number += 1;
        }
        try surface.fill(.{ .x = geometry.gutter.x, .y = geometry.gutter.y + y, .width = geometry.gutter.width, .height = geometry.gutter.height - y }, .{});
    }
    if (geometry.scrollbar.width != 0) {
        if (model.visual_row_count > geometry.editor.height) {
            const bar: tui.widget.Scrollbar = .{ .total_rows = model.visual_row_count, .visible_rows = geometry.editor.height, .top_row = model.viewport.top_row };
            try surface.fillAscii(geometry.scrollbar, '|', muted);
            if (bar.geometry(geometry.scrollbar.height)) |thumb| {
                try surface.fillAscii(.{ .x = geometry.scrollbar.x, .y = geometry.scrollbar.y + thumb.start, .width = 1, .height = thumb.height }, ' ', .{ .attributes = .{ .reverse = true } });
            }
        } else try surface.fill(geometry.scrollbar, .{});
    }

    if (geometry.inspector.width != 0) {
        const inspector = geometry.inspector;
        _ = try surface.putStyledLine(.{ .x = inspector.x, .y = 2 }, &.{
            .{ .text = "STATE", .style = heading },
            .{ .text = "  /  live", .style = muted },
        }, inspector.width, .{}, .narrow, .{});
        try surface.fillAscii(.{ .x = inspector.x, .y = 3, .width = inspector.width, .height = 1 }, '-', muted);
        try surface.fillAscii(.{ .x = inspector.x - 2, .y = 2, .width = 1, .height = inspector.height + 2 }, '|', muted);

        var selection_buffer: [64]u8 = undefined;
        const selection_text = if (selected) |range|
            try std.fmt.bufPrint(&selection_buffer, "{d} B [{d}..{d}]", .{ selected_bytes, range.start, range.end })
        else
            "none";
        var document_buffer: [256]u8 = undefined;
        const document = try std.fmt.bufPrint(&document_buffer, "Bytes      {d} / 4096\nLines      {d}\nCaret      {d}:{d}\nByte       {d}\nSelection  {s}\n", .{
            model.value().len, model.lineCount(), position.row + 1, position.column + 1, model.cursorOffset(), selection_text,
        });
        const history = model.history.?;
        var history_buffer: [128]u8 = undefined;
        const history_text = try std.fmt.bufPrint(&history_buffer, "Undo       {d} records\nRedo       {d} records\n", .{ history.cursor, history.len - history.cursor });
        const visible = model.visibleRows();
        var view_buffer: [256]u8 = undefined;
        const view = try std.fmt.bufPrint(&view_buffer, "Wrap       {s}\nRows       {d} visual\nViewport   {d}..{d}\nColumns    {d}..{d}\nParser     {s}\n", .{
            if (model.softWrapEnabled()) "on" else "off",
            model.visual_row_count,
            visible.start + 1,
            visible.end,
            model.viewport.left_column + 1,
            model.viewport.left_column + model.viewport.width,
            if (input_state.pending == .none) "idle" else @tagName(input_state.pending),
        });
        var frame_buffer: [256]u8 = undefined;
        const frame = if (previous_frame) |stats|
            try std.fmt.bufPrint(&frame_buffer, "Changed    {d} cells\nOutput     {d} B\nWork       {d} units\n", .{ stats.cells_changed, stats.bytes, stats.work_units })
        else
            "No completed frame yet\n";
        _ = try surface.putWrappedStyledText(inspector, &.{
            .{ .text = document },
            .{ .text = "\nHISTORY\n", .style = heading },
            .{ .text = history_text },
            .{ .text = "\nVIEW\n", .style = heading },
            .{ .text = view },
            .{ .text = if (inspector.height >= 22) "\nPREVIOUS FRAME\n" else "", .style = heading },
            .{ .text = if (inspector.height >= 22) frame else "", .style = muted },
        }, .{}, .narrow, .{});
    }

    if (size.height > 1) {
        var status_buffer: [160]u8 = undefined;
        const status = if (failure) |message|
            try std.fmt.bufPrint(&status_buffer, "ERROR  {s}", .{message})
        else if (bounds.width >= 68)
            try std.fmt.bufPrint(&status_buffer, "{s}  Ln {d}  Col {d}  |  {d} B selected  |  {d}/4096 B  |  Wrap {s}", .{
                if (!area.focused) "UNFOCUSED" else if (dragging) "SELECTING" else "READY",
                position.row + 1,
                position.column + 1,
                selected_bytes,
                model.value().len,
                if (model.softWrapEnabled()) "on" else "off",
            })
        else
            try std.fmt.bufPrint(&status_buffer, "{d}:{d}  {d}/4096 B  Wrap {s}", .{ position.row + 1, position.column + 1, model.value().len, if (model.softWrapEnabled()) "on" else "off" });
        const status_y = size.height - @as(u16, if (size.height >= 12) 3 else 2);
        _ = try surface.putTextLine(.{ .x = bounds.x, .y = status_y }, status, bounds.width, if (failure != null) .{ .foreground = .{ .indexed = 1 }, .attributes = .{ .bold = true } } else .{}, .narrow, .{ .overflow = .ellipsis });
        if (size.height >= 12) {
            _ = try surface.putStyledLine(.{ .x = bounds.x, .y = size.height - 2 }, &.{
                .{ .text = "EDIT     ", .style = heading },
                .{ .text = "Ctrl+Z", .style = key_style },
                .{ .text = " undo   " },
                .{ .text = "Ctrl+Y", .style = key_style },
                .{ .text = " redo   " },
                .{ .text = if (bounds.width >= 68) "Shift+arrows" else "", .style = key_style },
                .{ .text = if (bounds.width >= 68) " select   " else "" },
                .{ .text = if (bounds.width >= 108) "Mouse" else "", .style = key_style },
                .{ .text = if (bounds.width >= 108) " place / drag selection   > wrapped continuation" else "" },
            }, bounds.width, .{}, .narrow, .{ .overflow = .ellipsis });
        }
        _ = try surface.putStyledLine(.{ .x = bounds.x, .y = size.height - 1 }, &.{
            .{ .text = if (bounds.width >= 68) "SESSION  " else "", .style = heading },
            .{ .text = "Ctrl+Q", .style = key_style },
            .{ .text = " quit   " },
            .{ .text = if (bounds.width >= 68) "Ctrl+G" else "", .style = key_style },
            .{ .text = if (bounds.width >= 68) " suspend     " else "" },
            .{ .text = if (bounds.width >= 68) "VIEW  " else "", .style = heading },
            .{ .text = "F2", .style = key_style },
            .{ .text = " wrap   " },
            .{ .text = "Ctrl+L", .style = key_style },
            .{ .text = " repaint" },
        }, bounds.width, .{}, .narrow, .{ .overflow = .ellipsis });
    }
}

fn writeOnce(fd: std.posix.fd_t, bytes: []const u8) !?usize {
    const result = std.posix.system.write(fd, bytes.ptr, bytes.len);
    switch (std.posix.errno(result)) {
        .SUCCESS => return if (result == 0) error.OutputClosed else @as(usize, @intCast(result)),
        .AGAIN, .INTR => return null,
        .IO => return error.InputOutput,
        .PIPE => return error.BrokenPipe,
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

fn drainSession(session: *tui.terminal.Session, fd: std.posix.fd_t, io: std.Io) !void {
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + std.time.ns_per_s;
    while (session.outputStep()) |bytes| {
        const remaining = deadline - std.Io.Clock.awake.now(io).nanoseconds;
        if (remaining <= 0) return error.OutputTimeout;
        if (try writeOnce(fd, bytes)) |accepted| {
            try session.consumeOutput(accepted);
        } else {
            var slots = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
            const timeout: std.posix.timespec = .{ .sec = @intCast(@divTrunc(remaining, std.time.ns_per_s)), .nsec = @intCast(@rem(remaining, std.time.ns_per_s)) };
            _ = std.posix.ppoll(&slots, &timeout, null) catch |err| switch (err) {
                error.SignalInterrupt => continue,
                else => return err,
            };
        }
    }
}
