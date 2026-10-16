const std = @import("std");
const tui = @import("tui");

const testing = std.testing;
const pinned_style = tui.render.Style{ .foreground = .{ .indexed = 1 } };
const unavailable_style = tui.render.Style{ .foreground = .{ .indexed = 2 } };

fn expectValidWideCells(renderer: *const tui.render.Renderer) !void {
    const size = renderer.size();
    var y: u16 = 0;
    while (y < size.height) : (y += 1) {
        var x: u16 = 0;
        while (x < size.width) : (x += 1) {
            const cell = renderer.desiredCell(.{ .x = x, .y = y }).?;
            switch (cell.width) {
                .narrow => {},
                .continuation => {
                    try testing.expect(x > 0);
                    const previous = renderer.desiredCell(.{ .x = x - 1, .y = y }).?;
                    try testing.expectEqual(tui.render.CellWidth.wide, previous.width);
                    try testing.expectEqual(previous.style, cell.style);
                },
                .wide => {
                    try testing.expect(x + 1 < size.width);
                    const next = renderer.desiredCell(.{ .x = x + 1, .y = y }).?;
                    try testing.expectEqual(tui.render.CellWidth.continuation, next.width);
                    try testing.expectEqual(cell.style, next.style);
                },
            }
        }
    }
}

test "failed styled draws preserve valid cells and succeed after releasing capacity" {
    const cases = [_]struct {
        wide_x: u16 = 0,
        field_x: u16 = 0,
        field_width: u16 = 2,
        spans: []const tui.render.StyledSpan = &.{.{ .text = "x", .style = unavailable_style }},
        base_style: tui.render.Style = .{},
        options: tui.text.LineOptions = .{},
        expected_x: u16 = 1,
        expected_glyph: []const u8 = "x",
    }{
        .{ .field_x = 1, .field_width = 1 },
        .{ .options = .{ .alignment = .right } },
        .{ .wide_x = 1, .spans = &.{}, .base_style = unavailable_style, .expected_x = 0, .expected_glyph = " " },
        .{ .spans = &.{ .{ .text = "a" }, .{ .text = "b", .style = unavailable_style } }, .expected_glyph = "b" },
    };
    for (cases) |case| {
        var storage: tui.render.FixedRendererStorage(6, 1, 1, 2) = .{};
        var renderer = try tui.render.Renderer.init(storage.slices(), .{ .width = 6, .height = 1 });
        defer renderer.deinit();
        var surface = renderer.surface(tui.render.Rect.fromSize(renderer.size()));
        _ = try surface.putText(.{ .x = case.wide_x, .y = 0 }, "\u{754c}", .{}, .narrow);
        _ = try surface.putText(.{ .x = 5, .y = 0 }, "p", pinned_style, .narrow);

        try testing.expectError(error.StyleCapacityExceeded, surface.putStyledLine(
            .{ .x = case.field_x, .y = 0 },
            case.spans,
            case.field_width,
            case.base_style,
            .narrow,
            case.options,
        ));
        try expectValidWideCells(&renderer);

        _ = try surface.putText(.{ .x = 5, .y = 0 }, "p", .{}, .narrow);
        _ = try surface.putStyledLine(.{ .x = case.field_x, .y = 0 }, case.spans, case.field_width, case.base_style, .narrow, case.options);
        try expectValidWideCells(&renderer);
        var scratch: [tui.text.max_grapheme_bytes]u8 = undefined;
        const cell = renderer.desiredCellView(.{ .x = case.expected_x, .y = 0 }, &scratch).?;
        try testing.expectEqualStrings(case.expected_glyph, cell.glyph);
        try testing.expect(cell.style.eql(unavailable_style));
    }
}
