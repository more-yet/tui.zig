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
        const start = @min(self.top, maxTop(count, visible_rows));
        return .{ .start = start, .end = start + @min(count - start, visible_rows) };
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
        self.top = @min(self.top, maxTop(count, visible_rows));
    }

    /// After changing selection, call `state.reveal(count, body_height)` and redraw if true.
    pub fn reveal(self: *ScrollState, count: usize, visible_rows: u16) bool {
        const previous_top = self.top;
        const previous_selected = self.selected;
        self.clamp(count, visible_rows);
        self.last_visible_rows = visible_rows;
        if (self.selected) |selected| {
            if (visible_rows != 0) {
                if (selected < self.top) {
                    self.top = selected;
                } else if (selected - self.top >= visible_rows) {
                    self.top = selected - visible_rows + 1;
                }
                self.top = @min(self.top, maxTop(count, visible_rows));
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
            var y: u16 = 0;
            while (y < size.height) : (y += 1) {
                const index = if (@as(usize, y) < visible.len())
                    visible.start + y
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

            var body_y: u16 = 0;
            while (body_y < body.height) : (body_y += 1) {
                const y = body_y + body.y;
                const index = if (@as(usize, body_y) < visible.len())
                    visible.start + body_y
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
                    columns = ColumnLayout.init(self.columns, size.width);
                    while (columns.next()) |placement| {
                        const column = self.columns[placement.index];
                        _ = try surface.putTextLine(
                            .{ .x = placement.x, .y = y },
                            self.provider.cell(row, placement.index),
                            placement.width,
                            style,
                            self.width_profile,
                            column.options,
                        );
                    }
                    if (columns.x < size.width) {
                        try surface.fill(.{ .x = columns.x, .y = y, .width = size.width - columns.x, .height = 1 }, style);
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
