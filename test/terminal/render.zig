const std = @import("std");
const tui = @import("tui");
const Oracle = @import("oracle.zig");
const vt = Oracle.vt;
const testing = std.testing;

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

test "session enter and leave acknowledge partial writes and restore terminal state" {
    var master: c_int = -1;
    var slave: c_int = -1;
    if (openpty(&master, &slave, null, null, null) != 0) return error.PtyUnavailable;
    defer _ = std.os.linux.close(master);
    defer _ = std.os.linux.close(slave);
    var session = try tui.terminal.Session.init(.{ .handle = slave, .flags = .{ .nonblocking = false } }, .{ .mouse = true, .kitty_keyboard = true });
    defer session.restoreTermios() catch unreachable;
    var oracle: Oracle = undefined;
    try oracle.init(testing.allocator, .{ .cols = 20, .rows = 4 });
    defer oracle.deinit();
    try oracle.write("shell");
    try session.beginEnter();
    for (0..1024) |_| {
        const bytes = session.outputStep() orelse break;
        try oracle.write(bytes[0..1]);
        try session.consumeOutput(1);
    } else return error.SessionWorkLimit;
    try testing.expect(!(try std.posix.tcgetattr(slave)).lflag.ICANON);
    try testing.expect(oracle.terminal.screens.active_key == .alternate);
    try session.beginLeave();
    for (0..1024) |_| {
        const bytes = session.outputStep() orelse break;
        try oracle.write(bytes[0..1]);
        try session.consumeOutput(1);
    } else return error.SessionWorkLimit;
    try session.restoreTermios();
    const restored = try std.posix.tcgetattr(slave);
    inline for (std.meta.fields(std.posix.termios)) |field| {
        try testing.expect(std.meta.eql(@field(session.original, field.name), @field(restored, field.name)));
    }
    try testing.expect(oracle.stream.ground());
    try testing.expect(oracle.terminal.screens.active_key == .primary);
    try testing.expect(oracle.terminal.modes.get(.cursor_visible));
    inline for (.{ .bracketed_paste, .focus_event, .mouse_event_button, .mouse_format_sgr, .synchronized_output }) |mode| {
        try testing.expect(!oracle.terminal.modes.get(mode));
    }
    try testing.expect(oracle.terminal.screens.all.get(.alternate).?.kitty_keyboard.current().int() == 0);
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
    surface = renderer.surface(.{ .x = 0, .y = 0, .width = 12, .height = 3 });
    _ = try surface.putText(.{ .x = 0, .y = 0 }, "Ae\u{301} x", .{}, .narrow);
    _ = try surface.putText(.{ .x = 0, .y = 2 }, "lower", .{}, .narrow);
    try present(&renderer, &oracle);
    try expectText(&oracle, "Ae\u{301} x\n\nlower");
}
