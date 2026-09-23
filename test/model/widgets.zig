const std = @import("std");
const tui = @import("tui");
const testing = std.testing;

test "gauge fills preserve proportional width styles clipping and adjacent rows" {
    const cases = [_]struct { value: u64, total: u64 }{
        .{ .value = 0, .total = 0 },
        .{ .value = 5, .total = 10 },
        .{ .value = std.math.maxInt(u64), .total = std.math.maxInt(u64) },
        .{ .value = std.math.maxInt(u64), .total = 1 },
    };
    const filled: tui.render.Style = .{ .foreground = .{ .indexed = 2 } };
    const empty: tui.render.Style = .{ .foreground = .{ .indexed = 8 } };
    for ([_]u16{ 0, 1, 63, 64, 65, 130, 65535 }) |width| {
        for (cases) |case| {
            var storage: tui.render.FixedRendererStorage(132, 2, 1, 3) = .{};
            var renderer = try tui.render.Renderer.init(storage.slices(), .{ .width = 132, .height = 2 });
            defer renderer.deinit();
            var root = renderer.surface(tui.render.Rect.fromSize(renderer.size()));
            try root.fillAscii(tui.render.Rect.fromSize(root.size()), '.', .{});
            var surface = root.surface(.{ .x = 1, .y = 0, .width = width, .height = 2 });
            const gauge: tui.widget.Gauge = .{
                .value = case.value,
                .total = case.total,
                .filled = .{ .normal = filled },
                .empty = .{ .normal = empty },
            };
            try gauge.draw(&surface);
            const filled_width = if (case.total == 0) 0 else @as(u128, @min(case.value, case.total)) * width / case.total;
            for (0..2) |y| {
                for (0..132) |x| {
                    var scratch: [tui.text.max_grapheme_bytes]u8 = undefined;
                    const cell = renderer.desiredCellView(.{ .x = @intCast(x), .y = @intCast(y) }, &scratch).?;
                    const painted = y == 0 and x >= 1 and x - 1 < width;
                    const is_filled = painted and x - 1 < filled_width;
                    try testing.expectEqualStrings(if (!painted) "." else if (is_filled) "#" else "-", cell.glyph);
                    try testing.expect(cell.style.eql(if (!painted) .{} else if (is_filled) filled else empty));
                }
            }
        }
    }
}
