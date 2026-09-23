const std = @import("std");
const tui = @import("tui");
const Oracle = @import("oracle.zig");
const vt = Oracle.vt;
const testing = std.testing;
const demo = @import("demo_app");

extern "c" fn openpty(master: *c_int, slave: *c_int, name: ?[*]u8, termios: ?*const std.posix.termios, winsize: ?*const std.posix.winsize) c_int;

fn expectText(oracle: *Oracle, expected: []const u8) !void {
    const actual = try oracle.terminal.plainString(testing.allocator);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

fn writeFragmented(oracle: *Oracle, bytes: []const u8) !void {
    for (bytes, 0..) |_, i| try oracle.write(bytes[i..][0..1]);
    try testing.expect(oracle.stream.ground());
}

test "oracle decodes fragmented UTF-8, styles, wide cells, and render state" {
    var oracle: Oracle = undefined;
    try oracle.init(testing.allocator, .{ .cols = 12, .rows = 4, .replies = false });
    defer oracle.deinit();
    const t = &oracle.terminal;

    try writeFragmented(&oracle, "\x1b[2J\x1b[H\x1b[1;38;2;12;34;56mA\x1b[0me\u{301}界");
    try expectText(&oracle, "Ae\u{301}界");
    const a = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
    try testing.expect(a.style().flags.bold);
    try testing.expect(a.style().fg_color.eql(.{ .rgb = .{ .r = 12, .g = 34, .b = 56 } }));
    const wide = t.screens.active.pages.getCell(.{ .active = .{ .x = 2, .y = 0 } }).?;
    const tail = t.screens.active.pages.getCell(.{ .active = .{ .x = 3, .y = 0 } }).?;
    try testing.expectEqual(vt.Cell.Wide.wide, wide.cell.wide);
    try testing.expectEqual(vt.Cell.Wide.spacer_tail, tail.cell.wide);

    var state: vt.RenderState = .empty;
    defer state.deinit(testing.allocator);
    try state.update(testing.allocator, t);
    try testing.expectEqual(@as(u16, 12), state.cols);
    try testing.expectEqual(@as(u16, 4), state.rows);
    try testing.expectEqual(@as(u16, 4), state.cursor.viewport.?.x);
    try testing.expectEqual(@as(u16, 0), state.cursor.viewport.?.y);
    try testing.expect(state.cursor.visible);
    try testing.expectEqual(@as(usize, 4), state.row_data.len);
    const cells = state.row_data.items(.cells)[0];
    try testing.expectEqual(@as(usize, 12), cells.len);
    try testing.expect(cells.items(.style)[0].flags.bold);
}

test "oracle preserves primary screen and modes across alternate-screen resize" {
    var oracle: Oracle = undefined;
    try oracle.init(testing.allocator, .{ .cols = 6, .rows = 3, .replies = false });
    defer oracle.deinit();
    const t = &oracle.terminal;

    // 1049 copies the cursor; a fullscreen application must position it.
    try writeFragmented(&oracle, "shell\x1b[?1049h\x1b[H\x1b[?2004h\x1b[?1004h\x1b[?25labcdefgh");
    try testing.expectEqual(vt.ScreenSet.Key.alternate, t.screens.active_key);
    try testing.expect(t.modes.get(.bracketed_paste));
    try testing.expect(t.modes.get(.focus_event));
    try testing.expect(!t.modes.get(.cursor_visible));
    try expectText(&oracle, "abcdef\ngh");

    try t.resize(testing.allocator, .{ .cols = 10, .rows = 4 });
    try testing.expectEqual(@as(u16, 10), t.cols);
    try testing.expectEqual(@as(u16, 4), t.rows);
    try expectText(&oracle, "abcdef\ngh");
    try writeFragmented(&oracle, "\x1b[?25h\x1b[?1004l\x1b[?2004l\x1b[?1049l");
    try testing.expectEqual(vt.ScreenSet.Key.primary, t.screens.active_key);
    try testing.expect(!t.modes.get(.bracketed_paste));
    try testing.expect(!t.modes.get(.focus_event));
    try testing.expect(t.modes.get(.cursor_visible));
    try expectText(&oracle, "shell");
}

test "emergency restoration terminates partial strings and restores a private PTY" {
    var master: c_int = -1;
    var slave: c_int = -1;
    if (openpty(&master, &slave, null, null, null) != 0) return error.PtyUnavailable;
    defer _ = std.os.linux.close(master);
    defer _ = std.os.linux.close(slave);
    var session = try tui.terminal.Session.init(.{ .handle = slave, .flags = .{ .nonblocking = false } }, .{ .mouse = true, .kitty_keyboard = true });
    var oracle: Oracle = undefined;
    try oracle.init(testing.allocator, .{ .cols = 20, .rows = 4 });
    defer oracle.deinit();
    try oracle.write("shell");
    try session.beginEnter();
    while (session.outputStep()) |bytes| {
        try oracle.write(bytes);
        try session.consumeOutput(bytes.len);
    }
    try testing.expect(!(try std.posix.tcgetattr(slave)).lflag.ICANON);
    try oracle.write("\x1b]2;partial title");
    try testing.expect(!oracle.stream.ground());

    const saved_session = session;
    const saved_errno = std.c._errno().*;
    defer std.c._errno().* = saved_errno;
    std.c._errno().* = @intFromEnum(std.posix.E.IO);
    const result = session.emergencyRestore(slave);
    try testing.expectEqual(@as(c_int, @intFromEnum(std.posix.E.IO)), std.c._errno().*);
    try testing.expect(result.succeeded());
    try testing.expect(std.meta.eql(saved_session, session));
    const restored = try std.posix.tcgetattr(slave);
    inline for (std.meta.fields(std.posix.termios)) |field| {
        try testing.expect(std.meta.eql(@field(session.original, field.name), @field(restored, field.name)));
    }
    var bytes: [256]u8 = undefined;
    try testing.expect(result.written_bytes > 2 and result.written_bytes <= bytes.len);
    var received: usize = 0;
    while (received < result.written_bytes) {
        var descriptor = [_]std.posix.pollfd{.{ .fd = master, .events = std.posix.POLL.IN, .revents = 0 }};
        if (std.posix.system.poll(&descriptor, 1, 1000) != 1) return error.RestorationReadTimeout;
        const n = std.posix.system.read(master, bytes[received..].ptr, result.written_bytes - received);
        if (n <= 0) return error.RestorationReadFailed;
        received += @intCast(n);
    }
    try writeFragmented(&oracle, bytes[0..received]);
    try testing.expect(oracle.terminal.screens.active_key == .primary);
    try testing.expect(oracle.terminal.modes.get(.cursor_visible));
    inline for (.{ .bracketed_paste, .focus_event, .mouse_event_button, .mouse_format_sgr, .synchronized_output }) |mode| {
        try testing.expect(!oracle.terminal.modes.get(mode));
    }
    try testing.expect(oracle.terminal.screens.all.get(.alternate).?.kitty_keyboard.current().int() == 0);
    try expectText(&oracle, "shell");
}

test "terminal replies feed tui input parser and capability negotiator" {
    var oracle: Oracle = undefined;
    try oracle.init(testing.allocator, .{ .cols = 40, .rows = 8 });
    defer oracle.deinit();
    try writeFragmented(&oracle, "\x1b[3;7H\x1b[6n");
    try testing.expectEqualStrings("\x1b[3;7R", oracle.takeReplies());

    var negotiator = tui.terminal.CapabilityNegotiator.init(.{});
    try writeFragmented(&oracle, negotiator.beginQueries());
    const replies = oracle.takeReplies();
    try testing.expect(replies.len > 0);
    var parser: tui.input.Parser = .{};
    var offset: usize = 0;
    for (0..replies.len + 8) |_| {
        const result = parser.next(replies[offset..]);
        offset += result.consumed;
        switch (result.outcome) {
            .event => |event| _ = negotiator.observe(event),
            .failure => return error.MalformedReply,
            .need_more, .done => {
                try testing.expectEqual(replies.len, offset);
                break;
            },
        }
    } else return error.ParserWorkLimit;
    try testing.expect(negotiator.capabilities().kitty_keyboard);
    try testing.expect(negotiator.capabilities().synchronized_output);
    try testing.expect(!negotiator.queriesPending());
}

fn present(renderer: *tui.render.Renderer, oracle: *Oracle) !void {
    try renderer.beginPresentation(.{ .color_depth = .truecolor });
    // A bounded loop with one-byte acceptance splits both CSI and UTF-8.
    for (0..20_000) |_| {
        switch (try renderer.presentStep(2)) {
            .output => |bytes| {
                try testing.expect(bytes.len > 0);
                try oracle.write(bytes[0..1]);
                try renderer.consumePresentation(1);
            },
            .yielded, .cleared => {},
            .complete => break,
        }
    } else return error.PresentationWorkLimit;
    try testing.expect(oracle.stream.ground());
    try testing.expect(!renderer.isPresenting());
}

test "renderer full frame, differential wide-cell repair, and resized repaint" {
    var oracle: Oracle = undefined;
    try oracle.init(testing.allocator, .{ .cols = 20, .rows = 4, .replies = false });
    defer oracle.deinit();
    const t = &oracle.terminal;
    var storage: tui.render.FixedRendererStorage(20, 4, 32, 16) = .{};
    var renderer = try tui.render.Renderer.init(storage.slices(), .{ .width = 20, .height = 4 });
    defer renderer.deinit();
    var surface = renderer.surface(.{ .x = 0, .y = 0, .width = 20, .height = 4 });
    _ = try surface.putText(.{ .x = 0, .y = 0 }, "Ae\u{301}界", .{
        .foreground = .{ .rgb = .{ .r = 12, .g = 34, .b = 56 } },
        .attributes = .{ .bold = true },
    }, .narrow);
    _ = try surface.putText(.{ .x = 0, .y = 2 }, "lower", .{}, .narrow);
    try renderer.setCursor(.{ .position = .{ .x = 4, .y = 2 }, .shape = .steady_bar });
    try present(&renderer, &oracle);
    try expectText(&oracle, "Ae\u{301}界\n\nlower");
    const cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
    try testing.expect(cell.style().flags.bold);
    try testing.expect(cell.style().fg_color.eql(.{ .rgb = .{ .r = 12, .g = 34, .b = 56 } }));
    try testing.expectEqual(@as(u16, 4), t.screens.active.cursor.x);
    try testing.expectEqual(@as(u16, 2), t.screens.active.cursor.y);
    try testing.expectEqual(vt.CursorStyle.bar, t.screens.active.cursor.cursor_style);

    _ = try surface.putText(.{ .x = 3, .y = 0 }, "x", .{}, .narrow);
    try present(&renderer, &oracle);
    try expectText(&oracle, "Ae\u{301} x\n\nlower");
    const repaired = t.screens.active.pages.getCell(.{ .active = .{ .x = 2, .y = 0 } }).?;
    try testing.expectEqual(vt.Cell.Wide.narrow, repaired.cell.wide);

    try t.resize(testing.allocator, .{ .cols = 12, .rows = 3 });
    try renderer.resize(.{ .width = 12, .height = 3 });
    // Renderer.resize resets the desired grid; application layout/draw owns it.
    surface = renderer.surface(.{ .x = 0, .y = 0, .width = 12, .height = 3 });
    _ = try surface.putText(.{ .x = 0, .y = 0 }, "Ae\u{301} x", .{}, .narrow);
    _ = try surface.putText(.{ .x = 0, .y = 2 }, "lower", .{}, .narrow);
    try present(&renderer, &oracle);
    try expectText(&oracle, "Ae\u{301} x\n\nlower");
}

fn replayGraphics(showcase: *demo.graphics_demo.Showcase, oracle: *Oracle) !void {
    for (0..8192) |_| {
        const bytes = (try showcase.outputStep()) orelse break;
        try oracle.write(bytes[0..1]);
        try showcase.consumeOutput(1);
    } else return error.GraphicsWorkLimit;
    try testing.expect(oracle.stream.ground());
}

test "demo graphics anchors survive clear and late replay without shifting text" {
    // The oracle deliberately does not decode images. This checks CUP/VT
    // framing and renderer state ownership, not pixels or Kitty conformance.
    var oracle: Oracle = undefined;
    try oracle.init(testing.allocator, .{ .cols = 40, .rows = 16, .replies = false });
    defer oracle.deinit();
    var fixture = try demo.graphics_demo.Fixture.init(.direct);
    defer fixture.deinit();
    var showcase = demo.graphics_demo.Showcase.init(&fixture);
    var input_storage: tui.editor.FixedStorage(32) = .{};
    var input = try tui.editor.Model.initSingleLine(input_storage.slices(), "Ada");
    var editor_storage: tui.editor.FixedStorage(128) = .{};
    var editor = try tui.editor.Model.init(editor_storage.slices(), "first\nsecond\nthird");
    var app = demo.DemoApp.init(&input, &editor);
    app.graphics_available = true;
    var storage: tui.render.FixedRendererStorage(40, 16, 32, 16) = .{};
    var renderer = try tui.render.Renderer.init(storage.slices(), .{ .width = 40, .height = 16 });
    defer renderer.deinit();

    for ([_]tui.render.Size{
        .{ .width = 40, .height = 16 }, .{ .width = 20, .height = 12 },
        .{ .width = 19, .height = 11 }, .{ .width = 40, .height = 16 },
    }) |size| {
        try oracle.terminal.resize(testing.allocator, .{ .cols = size.width, .rows = size.height });
        try renderer.resize(size);
        try app.layout(size);
        var surface = renderer.surface(tui.render.Rect.fromSize(size));
        try app.draw(&surface);
        try renderer.beginPresentation(.{ .color_depth = .truecolor, .kitty_graphics = true });
        for (0..50_000) |_| {
            switch (try renderer.presentStep(2)) {
                .output => |bytes| {
                    try oracle.write(bytes[0..1]);
                    try renderer.consumePresentation(1);
                },
                .cleared => {
                    try showcase.restart(size);
                    try replayGraphics(&showcase, &oracle);
                    if (showcase.takeOutputInvalidation()) try renderer.invalidateOutputState();
                },
                .yielded => {},
                .complete => break,
            }
        } else return error.PresentationWorkLimit;
        const before = try oracle.terminal.plainString(testing.allocator);
        defer testing.allocator.free(before);
        try testing.expect(std.mem.startsWith(u8, before, "tui.zig  OVERVIEW"));
        try testing.expect(std.mem.indexOf(u8, before, "Ada") != null);
        try testing.expect(std.mem.indexOf(u8, before, "Editor") != null);

        // A late capability reply can start graphics after a finished frame.
        // Deliberately leave the cursor in the header before replay.
        try oracle.write("\x1b[2;5H");
        try showcase.restart(size);
        try replayGraphics(&showcase, &oracle);
        if (demo.graphics_demo.Layout.forSize(size)) |layout| {
            const origin = layout.imageOrigin();
            try testing.expectEqual(origin.x, oracle.terminal.screens.active.cursor.x);
            try testing.expectEqual(origin.y, oracle.terminal.screens.active.cursor.y);
        }
        try testing.expect(showcase.takeOutputInvalidation());
        try renderer.invalidateOutputState();
        try expectText(&oracle, before);
        try testing.expect(!showcase.hasWork());
    }
}
