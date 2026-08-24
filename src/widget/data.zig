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

pub const TreeState = struct {
    scroll: ScrollState = .{},
    toggled: ?usize = null,
    activated: ?usize = null,

    pub fn takeToggle(self: *TreeState) ?usize {
        const toggled = self.toggled;
        self.toggled = null;
        return toggled;
    }

    pub fn takeActivation(self: *TreeState) ?usize {
        const activated = self.activated;
        self.activated = null;
        return activated;
    }
};

/// A flattened visible tree. The provider owns expansion and supplies
/// `count`, `row`, `depth`, `hasChildren`, and `expanded`.
pub fn Tree(comptime Provider: type) type {
    return struct {
        provider: *Provider,
        state: *TreeState,
        bounds: render.Rect,
        row_role: theme.Role = .{},
        selected_role: theme.Role = .{},
        enabled: bool = true,
        focused: bool = false,
        width_profile: text.WidthProfile = .narrow,

        const Self = @This();

        pub fn handle(self: *Self, event: input.Event) Update {
            const count = self.provider.count();
            self.state.scroll.normalize(count, self.bounds.height);
            if (!self.enabled) return .ignored;
            if (event == .key) {
                const key = event.key;
                if (key.action != .release and !key.modifiers.hasNonLock()) switch (key.code) {
                    .left => return self.moveLeft(),
                    .right => return self.moveRight(),
                    .enter => return self.activate(),
                    .codepoint => |codepoint| if (codepoint == ' ') return self.toggle(),
                    else => {},
                };
            }
            return handleView(&self.state.scroll, count, self.bounds.height, self.bounds, 0, event);
        }

        pub fn draw(self: *Self, surface: *render.Surface) !void {
            const size = surface.size();
            const count = self.provider.count();
            self.state.scroll.normalize(count, size.height);
            var y: u16 = 0;
            while (y < size.height) : (y += 1) {
                const index = if (@as(usize, y) < count -| self.state.scroll.top)
                    self.state.scroll.top + y
                else
                    null;
                const style = rowStyle(
                    self.row_role,
                    self.selected_role,
                    self.enabled,
                    self.focused,
                    if (index) |row| self.state.scroll.selected == row else false,
                );
                try surface.fill(.{ .x = 0, .y = y, .width = size.width, .height = 1 }, style);
                const row = index orelse continue;
                const indent = @min(self.provider.depth(row), @as(usize, size.width) / 2) * 2;
                if (indent >= size.width) continue;
                const marker = if (!self.provider.hasChildren(row))
                    "  "
                else if (self.provider.expanded(row))
                    "v "
                else
                    "> ";
                const marker_width = @min(@as(u16, 2), size.width - @as(u16, @intCast(indent)));
                _ = try surface.putTextLine(
                    .{ .x = @intCast(indent), .y = y },
                    marker,
                    marker_width,
                    style,
                    self.width_profile,
                    .{},
                );
                const text_x = @as(u16, @intCast(indent)) + marker_width;
                if (text_x < size.width) _ = try surface.putTextLine(
                    .{ .x = text_x, .y = y },
                    self.provider.row(row),
                    size.width - text_x,
                    style,
                    self.width_profile,
                    .{ .overflow = .ellipsis },
                );
            }
        }

        fn activate(self: *Self) Update {
            const selected = self.state.scroll.selected orelse return .handled;
            self.state.activated = selected;
            return .handled;
        }

        fn toggle(self: *Self) Update {
            const selected = self.state.scroll.selected orelse return .handled;
            if (self.provider.hasChildren(selected)) self.state.toggled = selected;
            return .handled;
        }

        fn moveLeft(self: *Self) Update {
            const selected = self.state.scroll.selected orelse return .handled;
            if (self.provider.hasChildren(selected) and self.provider.expanded(selected)) return self.toggle();
            const depth = self.provider.depth(selected);
            if (depth == 0) return .handled;
            var index = selected;
            while (index != 0) {
                index -= 1;
                if (self.provider.depth(index) < depth) {
                    self.state.scroll.selected = index;
                    self.state.scroll.reveal(self.provider.count(), self.bounds.height);
                    return .redraw;
                }
            }
            return .handled;
        }

        fn moveRight(self: *Self) Update {
            const selected = self.state.scroll.selected orelse return .handled;
            if (!self.provider.hasChildren(selected)) return .handled;
            if (!self.provider.expanded(selected)) return self.toggle();
            const child = selected + 1;
            if (child < self.provider.count() and self.provider.depth(child) > self.provider.depth(selected)) {
                self.state.scroll.selected = child;
                self.state.scroll.reveal(self.provider.count(), self.bounds.height);
                return .redraw;
            }
            return .handled;
        }
    };
}

pub const TaskStatus = enum {
    pending,
    running,
    succeeded,
    failed,
    cancelled,
};

pub const TaskListState = struct {
    scroll: ScrollState = .{},
    activated: ?usize = null,

    pub fn takeActivation(self: *TaskListState) ?usize {
        const activated = self.activated;
        self.activated = null;
        return activated;
    }
};

/// A provider-backed task collection. The provider supplies `count`, `row`, and `status`.
pub fn TaskList(comptime Provider: type) type {
    return struct {
        provider: *Provider,
        state: *TaskListState,
        bounds: render.Rect,
        row_role: theme.Role = .{},
        running_role: theme.Role = .{},
        succeeded_role: theme.Role = .{},
        failed_role: theme.Role = .{},
        cancelled_role: theme.Role = .{},
        selected_role: theme.Role = .{},
        enabled: bool = true,
        focused: bool = false,
        width_profile: text.WidthProfile = .narrow,

        const Self = @This();

        pub fn handle(self: *Self, event: input.Event) Update {
            const count = self.provider.count();
            self.state.scroll.normalize(count, self.bounds.height);
            if (!self.enabled) return .ignored;
            if (keyboardActivation(event)) {
                self.state.activated = self.state.scroll.selected;
                return .handled;
            }
            return handleView(&self.state.scroll, count, self.bounds.height, self.bounds, 0, event);
        }

        pub fn draw(self: *Self, surface: *render.Surface) !void {
            const size = surface.size();
            const count = self.provider.count();
            self.state.scroll.normalize(count, size.height);
            var y: u16 = 0;
            while (y < size.height) : (y += 1) {
                const index = if (@as(usize, y) < count -| self.state.scroll.top)
                    self.state.scroll.top + y
                else
                    null;
                const selected = if (index) |row| self.state.scroll.selected == row else false;
                const status = if (index) |row| self.provider.status(row) else TaskStatus.pending;
                const role = switch (status) {
                    .pending => self.row_role,
                    .running => self.running_role,
                    .succeeded => self.succeeded_role,
                    .failed => self.failed_role,
                    .cancelled => self.cancelled_role,
                };
                const style = rowStyle(role, self.selected_role, self.enabled, self.focused, selected);
                try surface.fill(.{ .x = 0, .y = y, .width = size.width, .height = 1 }, style);
                const row = index orelse continue;
                const marker = switch (status) {
                    .pending => "[ ] ",
                    .running => "[~] ",
                    .succeeded => "[x] ",
                    .failed => "[!] ",
                    .cancelled => "[-] ",
                };
                const marker_width = @min(@as(u16, 4), size.width);
                _ = try surface.putTextLine(.{ .x = 0, .y = y }, marker, marker_width, style, self.width_profile, .{});
                if (marker_width < size.width) _ = try surface.putTextLine(
                    .{ .x = marker_width, .y = y },
                    self.provider.row(row),
                    size.width - marker_width,
                    style,
                    self.width_profile,
                    .{ .overflow = .ellipsis },
                );
            }
        }
    };
}

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

fn keyboardActivation(event: input.Event) bool {
    return switch (event) {
        .key => |key| key.action == .press and !key.modifiers.hasNonLock() and switch (key.code) {
            .enter => true,
            .codepoint => |codepoint| codepoint == ' ' or codepoint == '\r' or codepoint == '\n',
            else => false,
        },
        else => false,
    };
}

const std = @import("std");

test "scroll state and list navigation remain bounded" {
    const Provider = struct {
        pub fn count(_: *@This()) usize {
            return 5;
        }

        pub fn row(_: *@This(), _: usize) []const u8 {
            return "row";
        }
    };
    var provider: Provider = .{};
    var state: ScrollState = .{ .top = 99, .selected = 99 };
    state.normalize(5, 3);
    try std.testing.expectEqual(@as(usize, 2), state.top);
    try std.testing.expectEqual(@as(?usize, 4), state.selected);

    state = .{};
    var list = List(Provider){
        .provider = &provider,
        .state = &state,
        .bounds = .{ .x = 10, .y = 5, .width = 8, .height = 3 },
    };
    try std.testing.expectEqual(Update.redraw, list.handle(.{ .key = .{ .code = .down } }));
    try std.testing.expectEqual(@as(?usize, 0), state.selected);
    try std.testing.expectEqual(Update.redraw, list.handle(.{ .key = .{ .code = .page_down } }));
    try std.testing.expectEqual(@as(?usize, 2), state.selected);
    try std.testing.expectEqual(Update.redraw, list.handle(.{ .key = .{ .code = .down } }));
    try std.testing.expectEqual(@as(usize, 1), state.top);
    try std.testing.expectEqual(
        Update.redraw,
        list.handle(.{ .mouse = .{ .x = 11, .y = 5, .button = .none, .action = .scroll_up } }),
    );
    try std.testing.expectEqual(@as(usize, 0), state.top);
    try std.testing.expectEqual(
        Update.redraw,
        list.handle(.{ .mouse = .{ .x = 11, .y = 7, .button = .left, .action = .press } }),
    );
    try std.testing.expectEqual(@as(?usize, 2), state.selected);

    state.normalize(0, 0);
    try std.testing.expectEqual(ScrollState{}, state);
}

test "list pulls only visible rows and clears after data shrinks" {
    const Provider = struct {
        len: usize = 1_000_000,
        calls: usize = 0,
        indices: [3]usize = undefined,

        pub fn count(self: *@This()) usize {
            return self.len;
        }

        pub fn row(self: *@This(), index: usize) []const u8 {
            self.indices[self.calls % self.indices.len] = index;
            self.calls += 1;
            return if (index & 1 == 0) "even" else "odd";
        }
    };
    var provider: Provider = .{};
    var state: ScrollState = .{ .top = 999_999 };
    var list = List(Provider){
        .provider = &provider,
        .state = &state,
        .bounds = .{ .x = 0, .y = 0, .width = 8, .height = 3 },
    };
    var allocator_state = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var renderer = try render.Renderer.init(allocator_state.allocator(), .{ .width = 8, .height = 3 }, .{});
    defer renderer.deinit();
    allocator_state.fail_index = allocator_state.alloc_index;
    allocator_state.resize_fail_index = allocator_state.resize_index;
    var frame = renderer.frame();
    var surface = frame.surface(render.Rect.fromSize(renderer.size()));

    try list.draw(&surface);
    try std.testing.expectEqual(@as(usize, 3), provider.calls);
    try std.testing.expectEqual(@as(usize, 999_997), provider.indices[0]);
    try std.testing.expectEqual(@as(usize, 999_999), provider.indices[2]);

    provider.len = 1;
    try list.draw(&surface);
    try std.testing.expectEqual(@as(usize, 4), provider.calls);
    try std.testing.expect(renderer.desiredCell(.{ .x = 0, .y = 1 }).?.eql(.{}));
    try std.testing.expect(!allocator_state.has_induced_failure);
}

test "table reserves its header and selects only body rows" {
    const Provider = struct {
        const rows = [3][2][]const u8{
            .{ "a0", "b0" },
            .{ "a1", "b1" },
            .{ "a2", "b2" },
        };

        pub fn count(_: *@This()) usize {
            return rows.len;
        }

        pub fn cell(_: *@This(), row: usize, column: usize) []const u8 {
            return rows[row][column];
        }
    };
    const columns = [_]Column{
        .{ .title = "A", .width = 3 },
        .{ .title = "B", .width = 4 },
    };
    var provider: Provider = .{};
    var state: ScrollState = .{};
    var table = Table(Provider){
        .provider = &provider,
        .state = &state,
        .bounds = .{ .x = 4, .y = 2, .width = 8, .height = 4 },
        .columns = &columns,
    };
    var renderer = try render.Renderer.init(std.testing.allocator, .{ .width = 8, .height = 4 }, .{});
    defer renderer.deinit();
    var frame = renderer.frame();
    var surface = frame.surface(render.Rect.fromSize(renderer.size()));
    try table.draw(&surface);
    try std.testing.expectEqual(@as(u32, 'A'), renderer.desiredCell(.{ .x = 0, .y = 0 }).?.glyph);
    try std.testing.expectEqual(@as(u32, 'B'), renderer.desiredCell(.{ .x = 3, .y = 0 }).?.glyph);
    try std.testing.expectEqual(@as(u32, '1'), renderer.desiredCell(.{ .x = 1, .y = 2 }).?.glyph);
    try std.testing.expect(renderer.desiredCell(.{ .x = 7, .y = 3 }).?.eql(.{}));

    try std.testing.expectEqual(
        Update.handled,
        table.handle(.{ .mouse = .{ .x = 5, .y = 2, .button = .left, .action = .press } }),
    );
    try std.testing.expectEqual(@as(?usize, null), state.selected);
    try std.testing.expectEqual(
        Update.redraw,
        table.handle(.{ .mouse = .{ .x = 5, .y = 4, .button = .left, .action = .press } }),
    );
    try std.testing.expectEqual(@as(?usize, 1), state.selected);
}

test "tree emits expansion requests and navigates visible hierarchy" {
    const Provider = struct {
        labels: []const []const u8,
        depths: []const usize,

        pub fn count(self: *@This()) usize {
            return self.labels.len;
        }

        pub fn row(self: *@This(), index: usize) []const u8 {
            return self.labels[index];
        }

        pub fn depth(self: *@This(), index: usize) usize {
            return self.depths[index];
        }

        pub fn hasChildren(_: *@This(), index: usize) bool {
            return index == 0;
        }

        pub fn expanded(_: *@This(), index: usize) bool {
            return index == 0;
        }
    };
    const labels = [_][]const u8{ "root", "child", "peer" };
    const depths = [_]usize{ 0, 1, 0 };
    var provider = Provider{ .labels = &labels, .depths = &depths };
    var state = TreeState{ .scroll = .{ .selected = 0 } };
    var tree = Tree(Provider){
        .provider = &provider,
        .state = &state,
        .bounds = .{ .x = 0, .y = 0, .width = 12, .height = 3 },
    };
    try std.testing.expectEqual(Update.redraw, tree.handle(.{ .key = .{ .code = .right } }));
    try std.testing.expectEqual(@as(?usize, 1), state.scroll.selected);
    try std.testing.expectEqual(Update.redraw, tree.handle(.{ .key = .{ .code = .left } }));
    try std.testing.expectEqual(@as(?usize, 0), state.scroll.selected);
    try std.testing.expectEqual(Update.handled, tree.handle(.{ .key = .{ .code = .left } }));
    try std.testing.expectEqual(@as(?usize, 0), state.takeToggle());
}

test "task list pulls visible status and exposes activation" {
    const Provider = struct {
        pub fn count(_: *@This()) usize {
            return 2;
        }

        pub fn row(_: *@This(), index: usize) []const u8 {
            return if (index == 0) "compile" else "test";
        }

        pub fn status(_: *@This(), index: usize) TaskStatus {
            return if (index == 0) .succeeded else .running;
        }
    };
    var provider: Provider = .{};
    var state = TaskListState{ .scroll = .{ .selected = 1 } };
    var tasks = TaskList(Provider){
        .provider = &provider,
        .state = &state,
        .bounds = .{ .x = 0, .y = 0, .width = 12, .height = 2 },
    };
    try std.testing.expectEqual(Update.handled, tasks.handle(.{ .key = .{ .code = .enter } }));
    try std.testing.expectEqual(@as(?usize, 1), state.takeActivation());

    var renderer = try render.Renderer.init(std.testing.allocator, .{ .width = 12, .height = 2 }, .{});
    defer renderer.deinit();
    var frame = renderer.frame();
    var surface = frame.surface(render.Rect.fromSize(renderer.size()));
    try tasks.draw(&surface);
    var glyph: [text.max_grapheme_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("[", renderer.desiredCellView(.{ .x = 0, .y = 0 }, &glyph).?.glyph);
    try std.testing.expectEqualStrings("~", renderer.desiredCellView(.{ .x = 1, .y = 1 }, &glyph).?.glyph);
}
