const std = @import("std");
const input = @import("../input.zig");
const render = @import("../render.zig");
const scroll = @import("../scroll.zig");
const text = @import("../text.zig");
const theme = @import("../ui/theme.zig");
const Update = @import("update.zig").Update;

pub const ScrollState = struct {
    top: usize = 0,
    selected: ?usize = null,
    last_visible_rows: ?u16 = null,
    item_height: u16 = 1,
    gap: u16 = 0,

    /// Change geometry through this method. Top and selection remain item indices.
    pub fn setItemGeometry(self: *ScrollState, item_height: u16, gap: u16) error{InvalidItemHeight}!void {
        if (item_height == 0) return error.InvalidItemHeight;
        if (self.item_height == item_height and self.gap == gap) return;
        self.item_height = item_height;
        self.gap = gap;
        self.last_visible_rows = null;
    }

    fn stride(self: *const ScrollState) u32 {
        std.debug.assert(self.item_height != 0);
        return @as(u32, self.item_height) + self.gap;
    }

    fn fittingItems(self: *const ScrollState, height: u16) u16 {
        return @intCast(@max(1, (@as(u32, height) + self.gap) / self.stride()));
    }

    /// Body-local cells, clipped to the viewport. Gaps are not part of an item.
    pub fn itemRect(self: *const ScrollState, count: usize, body_size: render.Size, index: usize) ?render.Rect {
        const visible = self.visibleRange(count, body_size.height);
        if (body_size.width == 0 or index < visible.start or index >= visible.end) return null;
        const y: u16 = @intCast((index - visible.start) * self.stride());
        return .{ .x = 0, .y = y, .width = body_size.width, .height = @min(self.item_height, body_size.height - y) };
    }

    pub fn itemAt(self: *const ScrollState, count: usize, body_size: render.Size, point: render.Point) ?usize {
        if (point.x >= body_size.width or point.y >= body_size.height) return null;
        if (point.y % self.stride() >= self.item_height) return null;
        const visible = self.visibleRange(count, body_size.height);
        const offset = point.y / self.stride();
        if (offset >= visible.len()) return null;
        return visible.start + offset;
    }

    /// Route focused keys here; mouse coordinates must use the same space as bounds.
    /// Use header_rows = 0 for a list, 1 for a table. No drawing or provider is required.
    pub fn handle(self: *ScrollState, event: input.Event, count: usize, bounds: render.Rect, header_rows: u16) Update {
        const visible_rows = bounds.height -| header_rows;
        const previous = self.*;
        self.normalize(count, visible_rows);
        const update = handleView(self, count, visible_rows, bounds, header_rows, event);
        return if (previous.top != self.top or previous.selected != self.selected) update.merge(.redraw) else update;
    }

    /// Call normalize() before drawing; this query does not move selection or scroll position.
    pub fn visibleRange(self: *const ScrollState, count: usize, visible_rows: u16) scroll.Range {
        const start = @min(self.top, count -| self.fittingItems(visible_rows));
        const shown = (@as(u32, visible_rows) + self.stride() - 1) / self.stride();
        return .{ .start = start, .end = start + @min(count - start, shown) };
    }

    pub fn normalize(self: *ScrollState, count: usize, visible_rows: u16) void {
        const resized = self.last_visible_rows != visible_rows;
        const selected = self.selected;
        self.clamp(count, visible_rows);
        self.last_visible_rows = visible_rows;
        if (resized or selected != self.selected) _ = self.reveal(count, visible_rows);
    }

    fn clamp(self: *ScrollState, count: usize, visible_rows: u16) void {
        if (count == 0) {
            self.top = 0;
            self.selected = null;
            return;
        }
        if (self.selected) |selected| {
            if (selected >= count) self.selected = count - 1;
        }
        self.top = @min(self.top, count -| self.fittingItems(visible_rows));
    }

    /// After changing selection, call `state.reveal(count, body_height)` and redraw if true.
    pub fn reveal(self: *ScrollState, count: usize, visible_rows: u16) bool {
        const previous_top = self.top;
        const previous_selected = self.selected;
        self.clamp(count, visible_rows);
        self.last_visible_rows = visible_rows;
        if (self.selected) |selected| {
            if (visible_rows != 0) {
                const capacity = self.fittingItems(visible_rows);
                if (selected < self.top) {
                    self.top = selected;
                } else if (selected - self.top >= capacity) {
                    self.top = selected - capacity + 1;
                }
            }
        }
        return previous_top != self.top or previous_selected != self.selected;
    }
};

pub const Column = struct {
    title: []const u8,
    width: u16,
    options: text.LineOptions = .{ .overflow = .ellipsis },
};

/// Borrows columns; returned indices refer to the original slice, without renumbering hidden columns.
pub const ColumnLayout = struct {
    pub const Placement = struct {
        index: usize,
        x: u16,
        width: u16,
    };

    columns: []const Column,
    width: u16,
    index: usize = 0,
    x: u16 = 0,

    pub fn init(columns: []const Column, width: u16) ColumnLayout {
        return .{ .columns = columns, .width = width };
    }

    /// Skips zero-width columns and clips the last visible column to the available width.
    pub fn next(self: *ColumnLayout) ?Placement {
        while (self.index < self.columns.len and self.x < self.width) {
            const index = self.index;
            self.index += 1;
            const width = @min(self.columns[index].width, self.width - self.x);
            if (width == 0) continue;
            const placement = Placement{ .index = index, .x = self.x, .width = width };
            self.x += width;
            return placement;
        }
        return null;
    }
};

pub fn List(comptime Provider: type) type {
    return struct {
        provider: *Provider,
        state: *ScrollState,
        /// Input coordinates use this space; draw into a surface of exactly this size.
        bounds: render.Rect,
        row_role: theme.Role = .{},
        selected_role: theme.Role = .{},
        enabled: bool = true,
        focused: bool = false,
        width_profile: text.WidthProfile = .narrow,

        const Self = @This();

        pub fn handle(self: *Self, event: input.Event) Update {
            const count = self.provider.count();
            if (!self.enabled) {
                self.state.normalize(count, self.bounds.height);
                return .ignored;
            }
            return self.state.handle(event, count, self.bounds, 0);
        }

        pub fn draw(self: *Self, surface: *render.Surface) !void {
            const size: render.Size = .{ .width = self.bounds.width, .height = self.bounds.height };
            std.debug.assert(std.meta.eql(size, surface.size()));
            const count = self.provider.count();
            self.state.normalize(count, size.height);
            const visible = self.state.visibleRange(count, size.height);
            try surface.fill(render.Rect.fromSize(size), self.row_role.resolve(if (self.enabled) .normal else .disabled));
            for (visible.start..visible.end) |index| {
                const rect = self.state.itemRect(count, size, index) orelse continue;
                const style = rowStyle(
                    self.row_role,
                    self.selected_role,
                    self.enabled,
                    self.focused,
                    self.state.selected == index,
                );
                if (self.state.item_height == 1) {
                    _ = try surface.putTextLine(.{ .x = 0, .y = rect.y }, self.provider.row(index), size.width, style, self.width_profile, .{ .overflow = .ellipsis });
                } else {
                    _ = try surface.putWrappedText(rect, self.provider.row(index), style, self.width_profile, .{});
                }
            }
        }
    };
}

pub fn Table(comptime Provider: type) type {
    return struct {
        provider: *Provider,
        state: *ScrollState,
        /// Input coordinates use this space; draw into a surface of exactly this size.
        bounds: render.Rect,
        columns: []const Column,
        row_role: theme.Role = .{},
        selected_role: theme.Role = .{},
        header_role: theme.Role = .{},
        enabled: bool = true,
        focused: bool = false,
        width_profile: text.WidthProfile = .narrow,

        const Self = @This();

        /// Local body cells, excluding the single header row.
        pub fn bodyRect(size: render.Size) render.Rect {
            return .{ .x = 0, .y = @intFromBool(size.height != 0), .width = size.width, .height = size.height -| 1 };
        }

        pub fn handle(self: *Self, event: input.Event) Update {
            const count = self.provider.count();
            if (!self.enabled) {
                self.state.normalize(count, self.bounds.height -| 1);
                return .ignored;
            }
            return self.state.handle(event, count, self.bounds, 1);
        }

        pub fn draw(self: *Self, surface: *render.Surface) !void {
            const size: render.Size = .{ .width = self.bounds.width, .height = self.bounds.height };
            std.debug.assert(std.meta.eql(size, surface.size()));
            const body = bodyRect(size);
            const count = self.provider.count();
            self.state.normalize(count, body.height);
            const visible = self.state.visibleRange(count, body.height);
            if (size.height == 0) return;

            const header_style = self.header_role.resolve(if (self.enabled) .normal else .disabled);
            var columns = ColumnLayout.init(self.columns, size.width);
            while (columns.next()) |placement| {
                const column = self.columns[placement.index];
                _ = try surface.putTextLine(
                    .{ .x = placement.x, .y = 0 },
                    column.title,
                    placement.width,
                    header_style,
                    self.width_profile,
                    column.options,
                );
            }
            if (columns.x < size.width) {
                try surface.fill(.{ .x = columns.x, .y = 0, .width = size.width - columns.x, .height = 1 }, header_style);
            }

            try surface.fill(body, self.row_role.resolve(if (self.enabled) .normal else .disabled));
            for (visible.start..visible.end) |index| {
                var rect = self.state.itemRect(count, .{ .width = body.width, .height = body.height }, index) orelse continue;
                rect.y += body.y;
                const style = rowStyle(
                    self.row_role,
                    self.selected_role,
                    self.enabled,
                    self.focused,
                    self.state.selected == index,
                );
                try surface.fill(rect, style);
                columns = ColumnLayout.init(self.columns, size.width);
                while (columns.next()) |placement| {
                    const column = self.columns[placement.index];
                    if (self.state.item_height == 1) {
                        _ = try surface.putTextLine(
                            .{ .x = placement.x, .y = rect.y },
                            self.provider.cell(index, placement.index),
                            placement.width,
                            style,
                            self.width_profile,
                            column.options,
                        );
                    } else {
                        _ = try surface.putWrappedText(.{ .x = placement.x, .y = rect.y, .width = placement.width, .height = rect.height }, self.provider.cell(index, placement.index), style, self.width_profile, .{ .alignment = column.options.alignment });
                    }
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
            const step: usize = @max(@as(usize, 1), @as(usize, state.fittingItems(visible_rows)) -| 1);
            state.selected = switch (direction) {
                .first => 0,
                .last => count - 1,
                .backward => if (previous) |selected| selected -| 1 else count - 1,
                .forward => if (previous) |selected| @min(selected +| 1, count - 1) else 0,
                .page_backward => if (previous) |selected| selected -| step else count - 1,
                .page_forward => if (previous) |selected| @min(selected +| step, count - 1) else 0,
            };
            const revealed = state.reveal(count, visible_rows);
            return if (state.selected != previous or revealed) .redraw else .handled;
        },
        .mouse => |mouse| {
            if (mouse.modifiers.hasNonLock() or
                !bounds.contains(.{ .x = mouse.x, .y = mouse.y })) return .ignored;
            switch (mouse.action) {
                .scroll_up, .scroll_down => {
                    const previous = state.top;
                    state.top = switch (mouse.action) {
                        .scroll_up => state.top -| 1,
                        .scroll_down => @min(state.top +| 1, count -| state.fittingItems(visible_rows)),
                        else => unreachable,
                    };
                    return if (state.top == previous) .handled else .redraw;
                },
                .press => {
                    if (mouse.button != .left) return .ignored;
                    const local_y = mouse.y - bounds.y;
                    if (local_y < header_rows) return .handled;
                    const selected = state.itemAt(count, .{ .width = bounds.width, .height = visible_rows }, .{ .x = mouse.x - bounds.x, .y = local_y - header_rows }) orelse return .handled;
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
