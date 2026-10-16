const std = @import("std");
const tui = @import("tui");
const testing = std.testing;

const Provider = struct {
    pub fn count(_: *@This()) usize {
        return 10;
    }

    pub fn row(_: *@This(), index: usize) []const u8 {
        return "0123456789"[index..][0..1];
    }

    pub fn cell(self: *@This(), index: usize, _: usize) []const u8 {
        return self.row(index);
    }
};

test "list and table reveal on resize but preserve wheel scrolling until navigation" {
    inline for (.{ false, true }) |table| {
        var provider: Provider = .{};
        var state: tui.widget.ScrollState = .{ .selected = 9 };
        const header: u16 = if (table) 1 else 0;
        var storage: tui.render.FixedRendererStorage(8, 11, 1, 3) = .{};
        var renderer = try tui.render.Renderer.init(storage.slices(), .{ .width = 8, .height = 10 + header });
        defer renderer.deinit();
        var view = if (table)
            tui.widget.Table(Provider){ .provider = &provider, .state = &state, .bounds = tui.render.Rect.fromSize(renderer.size()), .columns = &.{.{ .title = "N", .width = 8 }} }
        else
            tui.widget.List(Provider){ .provider = &provider, .state = &state, .bounds = tui.render.Rect.fromSize(renderer.size()) };
        var surface = renderer.surface(view.bounds);
        try view.draw(&surface);
        try testing.expectEqual(@as(usize, 0), state.top);

        try renderer.resize(.{ .width = 8, .height = 5 + header });
        view.bounds = tui.render.Rect.fromSize(renderer.size());
        surface = renderer.surface(view.bounds);
        try view.draw(&surface);
        try testing.expectEqual(@as(usize, 5), state.top);
        try testing.expectEqual(@as(?usize, 9), state.selected);
        var scratch: [tui.text.max_grapheme_bytes]u8 = undefined;
        try testing.expectEqualStrings("9", renderer.desiredCellView(.{ .x = 0, .y = 4 + header }, &scratch).?.glyph);

        for (0..5) |_| {
            _ = view.handle(.{ .mouse = .{ .x = 0, .y = header, .button = .none, .action = .scroll_up } });
        }
        try view.draw(&surface);
        try testing.expectEqual(@as(usize, 0), state.top);
        try testing.expectEqual(@as(?usize, 9), state.selected);
        try testing.expectEqual(.redraw, view.handle(.{ .key = .{ .code = .down } }));
        try testing.expectEqual(@as(usize, 5), state.top);
        try testing.expectEqual(.handled, view.handle(.{ .key = .{ .code = .down } }));

        view.bounds.height = 3 + header;
        try testing.expectEqual(.redraw, view.handle(.{ .key = .{ .code = .down } }));
        try testing.expectEqual(@as(usize, 7), state.top);
        state.selected = 0;
        try testing.expectEqual(.redraw, view.handle(.{ .key = .{ .code = .up } }));
        try testing.expectEqual(@as(usize, 0), state.top);
    }
}
