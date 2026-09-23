const input = @import("../input.zig");
const render = @import("../render.zig");
const text = @import("../text.zig");
const theme = @import("../theme.zig");
const Update = @import("update.zig").Update;

pub const ScrollState = struct {
    top: usize = 0,
    selected: ?usize = null,

    pub fn normalize(self: *ScrollState, count: usize, visible_rows: u16) void {
        if (count == 0) {
            self.* = .{};
            return;
        }
        if (self.selected) |selected| {
            if (selected >= count) self.selected = count - 1;
        }
        self.top = @min(self.top, maxTop(count, visible_rows));
    }

    fn reveal(self: *ScrollState, count: usize, visible_rows: u16) void {
        const selected = self.selected orelse return;
        if (count == 0 or visible_rows == 0) return;
        if (selected < self.top) {
            self.top = selected;
        } else if (selected - self.top >= visible_rows) {
            self.top = selected - visible_rows + 1;
        }
        self.top = @min(self.top, maxTop(count, visible_rows));
    }
};

pub const Column = struct {
    title: []const u8,
    width: u16,
    options: text.LineOptions = .{ .overflow = .ellipsis },
};

pub fn List(comptime Provider: type) type {
    return struct {
        provider: *Provider,
        state: *ScrollState,
        bounds: render.Rect,
        row_role: theme.Role = .{},
        selected_role: theme.Role = .{},
        enabled: bool = true,
        focused: bool = false,
        width_profile: text.WidthProfile = .narrow,

        const Self = @This();

        pub fn handle(self: *Self, event: input.Event) Update {
            const count = self.provider.count();
            self.state.normalize(count, self.bounds.height);
            if (!self.enabled) return .ignored;
            return handleView(self.state, count, self.bounds.height, self.bounds, 0, event);
        }

        pub fn draw(self: *Self, surface: *render.Surface) !void {
            const size = surface.size();
            const count = self.provider.count();
            self.state.normalize(count, size.height);
            var y: u16 = 0;
            while (y < size.height) : (y += 1) {
                const index = if (@as(usize, y) < count -| self.state.top)
                    self.state.top + y
                else
                    null;
                const style = rowStyle(
                    self.row_role,
                    self.selected_role,
                    self.enabled,
                    self.focused,
                    if (index) |row| self.state.selected == row else false,
                );
                _ = try surface.putTextLine(
                    .{ .x = 0, .y = y },
                    if (index) |row| self.provider.row(row) else "",
                    size.width,
                    style,
                    self.width_profile,
                    .{ .overflow = .ellipsis },
                );
            }
        }
    };
}

pub fn Table(comptime Provider: type) type {
    return struct {
        provider: *Provider,
        state: *ScrollState,
        bounds: render.Rect,
        columns: []const Column,
        row_role: theme.Role = .{},
        selected_role: theme.Role = .{},
        header_role: theme.Role = .{},
        enabled: bool = true,
        focused: bool = false,
        width_profile: text.WidthProfile = .narrow,

        const Self = @This();

        pub fn handle(self: *Self, event: input.Event) Update {
            const count = self.provider.count();
            const visible_rows = self.bounds.height -| 1;
            self.state.normalize(count, visible_rows);
            if (!self.enabled) return .ignored;
            return handleView(self.state, count, visible_rows, self.bounds, 1, event);
        }

        pub fn draw(self: *Self, surface: *render.Surface) !void {
            const size = surface.size();
            const visible_rows = size.height -| 1;
            const count = self.provider.count();
            self.state.normalize(count, visible_rows);
            if (size.height == 0) return;

            const header_style = self.header_role.resolve(if (self.enabled) .normal else .disabled);
            var x: u16 = 0;
            for (self.columns) |column| {
                if (column.width == 0) continue;
                if (x == size.width) break;
                const field_width = @min(column.width, size.width - x);
                _ = try surface.putTextLine(
                    .{ .x = x, .y = 0 },
                    column.title,
                    field_width,
                    header_style,
                    self.width_profile,
                    column.options,
                );
                x += field_width;
            }
            if (x < size.width) {
                try surface.fill(.{ .x = x, .y = 0, .width = size.width - x, .height = 1 }, header_style);
            }

            var body_y: u16 = 0;
            while (body_y < visible_rows) : (body_y += 1) {
                const y = body_y + 1;
                const index = if (@as(usize, body_y) < count -| self.state.top)
                    self.state.top + body_y
                else
                    null;
                const style = rowStyle(
                    self.row_role,
                    self.selected_role,
                    self.enabled,
                    self.focused,
                    if (index) |row| self.state.selected == row else false,
                );
                if (index) |row| {
                    x = 0;
                    for (self.columns, 0..) |column, column_index| {
                        if (column.width == 0) continue;
                        if (x == size.width) break;
                        const field_width = @min(column.width, size.width - x);
                        _ = try surface.putTextLine(
                            .{ .x = x, .y = y },
                            self.provider.cell(row, column_index),
                            field_width,
                            style,
                            self.width_profile,
                            column.options,
                        );
                        x += field_width;
                    }
                    if (x < size.width) {
                        try surface.fill(.{ .x = x, .y = y, .width = size.width - x, .height = 1 }, style);
                    }
                } else {
                    try surface.fill(.{ .x = 0, .y = y, .width = size.width, .height = 1 }, style);
                }
            }
        }
    };
}

fn handleView(
    state: *ScrollState,
    count: usize,
    visible_rows: u16,
    bounds: render.Rect,
    header_rows: u16,
    event: input.Event,
) Update {
    switch (event) {
        .key => |key| {
            if (key.action == .release or key.modifiers.hasNonLock()) return .ignored;
            const direction: enum { first, last, backward, forward, page_backward, page_forward } = switch (key.code) {
                .home => .first,
                .end => .last,
                .up => .backward,
                .down => .forward,
                .page_up => .page_backward,
                .page_down => .page_forward,
                else => return .ignored,
            };
            if (count == 0) return .handled;
            const previous = state.selected;
            const step: usize = @max(@as(usize, 1), @as(usize, visible_rows) -| 1);
            state.selected = switch (direction) {
                .first => 0,
                .last => count - 1,
                .backward => if (previous) |selected| selected -| 1 else count - 1,
                .forward => if (previous) |selected| @min(selected +| 1, count - 1) else 0,
                .page_backward => if (previous) |selected| selected -| step else count - 1,
                .page_forward => if (previous) |selected| @min(selected +| step, count - 1) else 0,
            };
            if (state.selected == previous) return .handled;
            state.reveal(count, visible_rows);
            return .redraw;
        },
        .mouse => |mouse| {
            if (mouse.modifiers.hasNonLock() or
                !bounds.contains(.{ .x = mouse.x, .y = mouse.y })) return .ignored;
            switch (mouse.action) {
                .scroll_up, .scroll_down => {
                    const previous = state.top;
                    state.top = switch (mouse.action) {
                        .scroll_up => state.top -| 1,
                        .scroll_down => @min(state.top +| 1, maxTop(count, visible_rows)),
                        else => unreachable,
                    };
                    return if (state.top == previous) .handled else .redraw;
                },
                .press => {
                    if (mouse.button != .left) return .ignored;
                    const local_y = mouse.y - bounds.y;
                    if (local_y < header_rows) return .handled;
                    const row_offset = local_y - header_rows;
                    if (@as(usize, row_offset) >= count -| state.top) return .handled;
                    const selected = state.top + row_offset;
                    if (state.selected == selected) return .handled;
                    state.selected = selected;
                    return .redraw;
                },
                else => return .ignored,
            }
        },
        else => return .ignored,
    }
}

fn rowStyle(
    role: theme.Role,
    selected_role: theme.Role,
    enabled: bool,
    focused: bool,
    selected: bool,
) render.Style {
    if (!selected) return role.resolve(if (enabled) .normal else .disabled);
    return selected_role.resolve(theme.State.from(enabled, focused));
}

fn maxTop(count: usize, visible_rows: u16) usize {
    if (count == 0) return 0;
    if (visible_rows == 0) return count - 1;
    return count -| visible_rows;
}
