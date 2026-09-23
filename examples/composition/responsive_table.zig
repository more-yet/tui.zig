const tui = @import("tui");

pub const Row = struct {
    name: []const u8,
    status: []const u8,
    detail: []const u8,
};

pub const Provider = struct {
    rows: []const Row,
    cell_calls: usize = 0,
    column_calls: [3]usize = @splat(0),

    pub fn count(self: *const Provider) usize {
        return self.rows.len;
    }

    pub fn cell(self: *Provider, row: usize, column: usize) []const u8 {
        self.cell_calls += 1;
        self.column_calls[column] += 1;
        return switch (column) {
            0 => self.rows[row].name,
            1 => self.rows[row].status,
            2 => self.rows[row].detail,
            else => unreachable,
        };
    }
};

pub const App = struct {
    provider: *Provider,
    state: *tui.widget.ScrollState,
    bounds: tui.render.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    pub fn layout(self: *App, size: tui.render.Size) void {
        self.bounds = tui.render.Rect.fromSize(size);
    }

    pub fn handle(self: *App, event: tui.input.Event) tui.widget.Update {
        const areas = self.geometry();
        var columns = columnsForWidth(areas.table.width);
        var table = tui.widget.Table(Provider){
            .provider = self.provider,
            .state = self.state,
            .bounds = areas.table,
            .columns = &columns,
        };
        return table.handle(event);
    }

    pub fn draw(self: *App, surface: *tui.render.Surface) !void {
        try surface.fill(tui.render.Rect.fromSize(surface.size()), .{});
        const areas = self.geometry();
        var columns = columnsForWidth(areas.table.width);
        var table = tui.widget.Table(Provider){
            .provider = self.provider,
            .state = self.state,
            .bounds = areas.table,
            .columns = &columns,
        };
        var table_surface = surface.surface(areas.table);
        try table.draw(&table_surface);

        if (!areas.scrollbar.isEmpty()) {
            const bar = tui.widget.Scrollbar{
                .total_rows = self.provider.count(),
                .visible_rows = areas.table.height -| 1,
                .top_row = self.state.top,
            };
            var bar_surface = surface.surface(areas.scrollbar);
            try bar.draw(&bar_surface);
        }
    }

    fn geometry(self: *const App) struct { table: tui.render.Rect, scrollbar: tui.render.Rect } {
        const reserve_bar = self.bounds.width >= 2 and self.bounds.height > 1;
        const table_width = self.bounds.width - @intFromBool(reserve_bar);
        return .{
            .table = .{ .x = self.bounds.x, .y = self.bounds.y, .width = table_width, .height = self.bounds.height },
            .scrollbar = if (reserve_bar)
                .{ .x = self.bounds.x + table_width, .y = self.bounds.y + 1, .width = 1, .height = self.bounds.height - 1 }
            else
                .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        };
    }
};

pub fn columnsForWidth(width: u16) [3]tui.widget.Column {
    if (width < 32) return .{
        .{ .title = "Name", .width = width },
        .{ .title = "Status", .width = 0 },
        .{ .title = "Detail", .width = 0 },
    };
    if (width < 64) return .{
        .{ .title = "Name", .width = width - 12 },
        .{ .title = "Status", .width = 12 },
        .{ .title = "Detail", .width = 0 },
    };
    return .{
        .{ .title = "Name", .width = 20 },
        .{ .title = "Status", .width = 12 },
        .{ .title = "Detail", .width = width - 32 },
    };
}
