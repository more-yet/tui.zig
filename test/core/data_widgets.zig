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

test "uniform multirow items share drawing hit testing paging and selection visibility" {
    const WrappedProvider = struct {
        len: usize = 6,
        pub fn count(self: *@This()) usize {
            return self.len;
        }
        pub fn row(_: *@This(), _: usize) []const u8 {
            return "alpha beta";
        }
        pub fn cell(self: *@This(), index: usize, _: usize) []const u8 {
            return self.row(index);
        }
    };
    inline for (.{ false, true }) |table| {
        var provider: WrappedProvider = .{};
        var state: tui.widget.ScrollState = .{ .selected = 0 };
        try state.setItemGeometry(2, 1);
        const header: u16 = if (table) 1 else 0;
        var storage: tui.render.FixedRendererStorage(6, 10, 8, 4) = .{};
        var renderer = try tui.render.Renderer.init(storage.slices(), .{ .width = 6, .height = 9 + header });
        defer renderer.deinit();
        const selection: tui.theme.Role = .{ .normal = pinnedStyle() };
        var view = if (table)
            tui.widget.Table(WrappedProvider){ .provider = &provider, .state = &state, .bounds = .{ .x = 0, .y = 0, .width = 6, .height = 9 + header }, .columns = &.{.{ .title = "N", .width = 6 }}, .selected_role = selection }
        else
            tui.widget.List(WrappedProvider){ .provider = &provider, .state = &state, .bounds = .{ .x = 0, .y = 0, .width = 6, .height = 9 }, .selected_role = selection };
        var surface = renderer.surface(view.bounds);
        try view.draw(&surface);
        var scratch: [tui.text.max_grapheme_bytes]u8 = undefined;
        try testing.expectEqualStrings("b", renderer.desiredCellView(.{ .x = 0, .y = 1 + header }, &scratch).?.glyph);
        try testing.expect(renderer.desiredCellView(.{ .x = 5, .y = 1 + header }, &scratch).?.style.eql(pinnedStyle()));
        try testing.expect(!renderer.desiredCellView(.{ .x = 5, .y = 2 + header }, &scratch).?.style.eql(pinnedStyle()));
        _ = view.handle(.{ .key = .{ .code = .page_down } });
        try testing.expectEqual(@as(?usize, 2), state.selected);
        _ = view.handle(.{ .mouse = .{ .x = 0, .y = 2 + header, .button = .left, .action = .press } });
        try testing.expectEqual(@as(?usize, 2), state.selected);
        _ = view.handle(.{ .mouse = .{ .x = 0, .y = 4 + header, .button = .left, .action = .press } });
        try testing.expectEqual(@as(?usize, 1), state.selected);
        _ = view.handle(.{ .mouse = .{ .x = 0, .y = header, .button = .none, .action = .scroll_down } });
        try view.draw(&surface);
        try testing.expectEqual(@as(usize, 1), state.top);
        state.selected = 5;
        view.bounds.height = 4 + header;
        surface = renderer.surface(view.bounds);
        try view.draw(&surface);
        try testing.expectEqual(@as(usize, 5), state.top);
        state.top = 0;
        state.selected = 0;
        try view.draw(&surface);
        try testing.expectEqual(@as(usize, 2), state.visibleRange(provider.count(), 4).end);
        try testing.expectEqual(@as(u16, 1), state.itemRect(provider.count(), .{ .width = 6, .height = 4 }, 1).?.height);
        provider.len = 1;
        state.selected = 5;
        try view.draw(&surface);
        try testing.expectEqual(@as(?usize, 0), state.selected);
        try state.setItemGeometry(8, 0);
        try view.draw(&surface);
        try testing.expectEqual(@as(u16, 4), state.itemRect(provider.count(), .{ .width = 6, .height = 4 }, 0).?.height);
    }
}

fn pinnedStyle() tui.render.Style {
    return .{ .attributes = .{ .reverse = true } };
}
