const std = @import("std");
const tui = @import("tui");
const demo = @import("demo_app");
const graphics = demo.graphics_demo;
const testing = std.testing;

const initial: tui.render.Size = .{ .width = 108, .height = 30 };

test "graphics demo reserves its footer through shrink, hide, and grow" {
    var input_storage: tui.editor.FixedStorage(64) = .{};
    var input = try tui.editor.Model.initSingleLine(input_storage.slices(), "Ada");
    var editor_storage: tui.editor.FixedStorage(256) = .{};
    var editor = try tui.editor.Model.init(editor_storage.slices(), "editor text\n" ** 20);
    var app = demo.DemoApp.init(&input, &editor);
    app.graphics_available = true;
    var storage: tui.render.FixedRendererStorage(108, 30, 32, 16) = .{};
    var renderer = try tui.render.Renderer.init(storage.slices(), initial);
    defer renderer.deinit();
    var glyph_bytes: [tui.text.max_grapheme_bytes]u8 = undefined;

    for ([_]tui.render.Size{
        initial,                        .{ .width = 20, .height = 12 }, .{ .width = 19, .height = 12 },
        .{ .width = 20, .height = 11 }, .{ .width = 1, .height = 1 },   initial,
    }) |size| {
        try renderer.resize(size);
        try app.layout(size);
        const layout_height = editor.viewport.height;
        var surface = renderer.surface(tui.render.Rect.fromSize(size));
        try app.draw(&surface);
        try testing.expectEqual(layout_height, editor.viewport.height);
        const layout = graphics.Layout.forSize(size);
        try testing.expectEqual(layout != null, size.width >= 20 and size.height >= 12);
        if (layout) |area| {
            try testing.expectEqual(area.heading_y - 5, editor.viewport.height);
            try testing.expectEqualStrings("G", renderer.desiredCellView(.{ .x = 0, .y = area.heading_y }, &glyph_bytes).?.glyph);
            const origin = area.imageOrigin();
            // No input/editor text may enter any ordinary image's 6x3 bounds.
            for (0..3) |y| for (0..6) |x| {
                const cell = renderer.desiredCellView(.{ .x = origin.x + @as(u16, @intCast(x)), .y = origin.y + @as(u16, @intCast(y)) }, &glyph_bytes).?;
                try testing.expectEqualStrings(" ", cell.glyph);
            };
            const placeholders = area.placeholderRect();
            try testing.expect(placeholders.y > area.heading_y);
            try testing.expect(placeholders.bottom() < size.height);
            // The relative child is two columns wide, three right of its parent.
            try testing.expect(placeholders.x + 3 + 2 <= size.width);
        } else {
            try testing.expectEqual(size.height -| 5, editor.viewport.height);
        }
        // Every placeholder is confined to the reserved footer, including after
        // shrink/grow; none may remain beside the input or in the editor.
        var placeholder_count: usize = 0;
        for (0..size.height) |y| for (0..size.width) |x| {
            const point: tui.render.Point = .{ .x = @intCast(x), .y = @intCast(y) };
            const cell = renderer.desiredCellView(point, &glyph_bytes).?;
            if (std.mem.startsWith(u8, cell.glyph, "\u{10eeee}")) {
                placeholder_count += 1;
                try testing.expect(layout != null);
                try testing.expect(layout.?.placeholderRect().contains(point));
            }
        };
        try testing.expectEqual(@as(usize, if (layout != null) 4 else 0), placeholder_count);
    }
}

fn drain(showcase: *graphics.Showcase, output: []u8) ![]const u8 {
    var len: usize = 0;
    while (try showcase.outputStep()) |pending| {
        if (len == output.len) return error.TestOutputLimit;
        if (std.mem.startsWith(u8, pending, "\x1b_G")) {
            const placement: ?tui.graphics.kitty.Placement = switch (showcase.sender.command) {
                .transmit_and_display => |value| value.placement,
                .display => |value| value.placement,
                else => null,
            };
            if (placement) |value| {
                // The burst's single absolute anchor stays valid throughout.
                try testing.expect(value.cursor == .preserve);
                try testing.expect(value.cell_x_offset_pixels <= 1 and value.cell_y_offset_pixels <= 1);
                try testing.expect(value.columns + @as(u32, @intFromBool(value.cell_x_offset_pixels != 0)) <= 6);
                try testing.expect(value.rows + @as(u32, @intFromBool(value.cell_y_offset_pixels != 0)) <= 3);
            }
        }
        // Repeated reads and zero acceptance must not change an exposed suffix.
        try testing.expectEqualStrings(pending, (try showcase.outputStep()).?);
        try showcase.consumeOutput(0);
        try testing.expectEqualStrings(pending, (try showcase.outputStep()).?);
        output[len] = pending[0];
        len += 1;
        try showcase.consumeOutput(1);
    }
    return output[0..len];
}

test "graphics replay positions before upload and deletes stale images on hide" {
    var fixture = try graphics.Fixture.init(.direct);
    defer fixture.deinit();
    var showcase = graphics.Showcase.init(&fixture);
    var bytes: [8192]u8 = undefined;
    for ([_]tui.render.Size{ initial, .{ .width = 20, .height = 12 }, initial }) |size| {
        try showcase.restart(size);
        var prefix: [32]u8 = undefined;
        // Assert protocol coordinates independently of Layout.imageOrigin().
        const expected = try std.fmt.bufPrint(&prefix, "\x1b[{d};3H\x1b_Ga=d,", .{size.height - 3});
        const output = try drain(&showcase, &bytes);
        try testing.expect(std.mem.startsWith(u8, output, expected));
        try testing.expect(std.mem.indexOf(u8, output, "\x1b_Ga=T,") != null);
        try testing.expectEqual(@as(usize, 17), std.mem.count(u8, output, "\x1b_G"));
        try testing.expect(showcase.takeOutputInvalidation());
        try testing.expect(!showcase.hasWork());
    }
    for ([_]tui.render.Size{ .{ .width = 19, .height = 12 }, .{ .width = 20, .height = 11 } }) |size| {
        try showcase.restart(size);
        const output = try drain(&showcase, &bytes);
        try testing.expect(std.mem.indexOf(u8, output, "\x1b_Ga=T,") == null);
        try testing.expect(std.mem.indexOf(u8, output, "H") == null);
        try testing.expect(showcase.takeOutputInvalidation());
        try testing.expect(!showcase.hasWork());
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "\x1b_Ga=d,"));
    }
    try showcase.restart(initial);
    _ = try drain(&showcase, &bytes);
    try testing.expect(showcase.takeOutputInvalidation());
}

test "graphics cancellation drains every cursor prefix before deleting" {
    var fixture = try graphics.Fixture.init(.direct);
    defer fixture.deinit();
    const cursor = "\x1b[27;3H";
    for (0..cursor.len + 1) |accepted| {
        var showcase = graphics.Showcase.init(&fixture);
        try showcase.restart(initial);
        const exposed = (try showcase.outputStep()).?;
        try testing.expectEqualStrings(cursor, exposed);
        try testing.expectError(error.GraphicsOutputActive, showcase.restart(initial));
        try testing.expectError(error.InvalidByteCount, showcase.consumeOutput(cursor.len + 1));
        try showcase.consumeOutput(accepted);
        showcase.requestCleanup();
        var bytes: [256]u8 = undefined;
        const rest = try drain(&showcase, &bytes);
        try testing.expect(std.mem.startsWith(u8, rest, cursor[accepted..]));
        try testing.expect(std.mem.indexOf(u8, rest, "\x1b_Ga=d,") != null);
        try testing.expect(std.mem.indexOf(u8, rest, "\x1b_Ga=T,") == null);
        try testing.expect(showcase.takeOutputInvalidation());
        try testing.expect(!showcase.hasWork());
    }
}

test "local graphics waits for correlated confirmation and stops on rejection" {
    // Wire-only fixture: source paths are borrowed, and only a terminal reply
    // confirms consumption. Transport acknowledgement alone keeps replay gated.
    var fixture = graphics.Fixture{ .medium = .temporary_file };
    const name = "/tmp/tui-zig-tty-graphics-protocol-test.rgba";
    @memcpy(fixture.protocol_name[0..name.len], name);
    fixture.protocol_name_len = name.len;
    var showcase = graphics.Showcase.init(&fixture);
    var bytes: [8192]u8 = undefined;
    try showcase.restart(initial);
    const initial_output = try drain(&showcase, &bytes);
    try testing.expect(std.mem.indexOf(u8, initial_output, "t=t") != null);
    try testing.expect(showcase.waitingForReply());
    try testing.expect(showcase.hasWork());
    try testing.expectError(error.GraphicsOutputActive, showcase.restart(initial));
    try reply(&showcase, "\x1b_Gi=4000;OK\x1b\\");
    try testing.expect(showcase.waitingForReply());
    try reply(&showcase, "\x1b_Gi=4001,p=2;OK\x1b\\");
    try testing.expect(showcase.waitingForReply());
    try reply(&showcase, "\x1b_Gi=4001,p=1;OK\x1b\\");
    try testing.expect(!showcase.waitingForReply());
    _ = try drain(&showcase, &bytes);
    try testing.expect(showcase.takeOutputInvalidation());
    try showcase.restart(initial);
    const replay = try drain(&showcase, &bytes);
    try testing.expect(std.mem.indexOf(u8, replay, "t=t") == null);
    try testing.expect(showcase.takeOutputInvalidation());

    showcase = graphics.Showcase.init(&fixture);
    try showcase.restart(initial);
    _ = try drain(&showcase, &bytes);
    try reply(&showcase, "\x1b_Gi=4001,p=1;ENOENT: fixture missing\x1b\\");
    const cleanup = try drain(&showcase, &bytes);
    try testing.expect(std.mem.indexOf(u8, cleanup, "\x1b_Ga=d,") != null);
    try testing.expect(showcase.takeOutputInvalidation());
    try showcase.restart(initial);
    try testing.expectEqual(@as(usize, 0), (try drain(&showcase, &bytes)).len);
    try testing.expectEqualStrings("ENOENT: fixture missing", showcase.errorMessage());
}

fn reply(showcase: *graphics.Showcase, bytes: []const u8) !void {
    var parser: tui.input.Parser = .{};
    const parsed = parser.next(bytes);
    try testing.expectEqual(bytes.len, parsed.consumed);
    showcase.observe(parsed.outcome.event);
}
