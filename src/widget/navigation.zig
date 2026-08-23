const std = @import("std");
const input = @import("../input.zig");
const render = @import("../render.zig");
const text = @import("../text.zig");
const theme = @import("../theme.zig");
const data = @import("data.zig");
const Update = @import("update.zig").Update;

pub const MenuState = struct {
    scroll: data.ScrollState = .{},
    activated: ?usize = null,

    pub fn takeActivation(self: *MenuState) ?usize {
        const activated = self.activated;
        self.activated = null;
        return activated;
    }
};

pub const Menu = struct {
    labels: []const []const u8,
    state: *MenuState,
    bounds: render.Rect,
    row_role: theme.Role = .{},
    selected_role: theme.Role = .{},
    enabled: bool = true,
    focused: bool = false,
    width_profile: text.WidthProfile = .narrow,

    const Provider = struct {
        labels: []const []const u8,

        pub inline fn count(self: *@This()) usize {
            return self.labels.len;
        }

        pub inline fn row(self: *@This(), index: usize) []const u8 {
            return self.labels[index];
        }
    };

    pub fn draw(self: *Menu, surface: *render.Surface) !void {
        var provider = Provider{ .labels = self.labels };
        var list = self.makeList(&provider);
        try list.draw(surface);
    }

    pub fn handle(self: *Menu, event: input.Event) Update {
        if (!self.enabled) return .ignored;
        self.state.scroll.normalize(self.labels.len, self.bounds.height);
        if (keyboardActivation(event)) {
            const selected = self.state.scroll.selected orelse return .handled;
            if (selected >= self.labels.len) return .handled;
            self.state.activated = selected;
            return .handled;
        }

        const clicked = self.clickedRow(event);
        var provider = Provider{ .labels = self.labels };
        var list = self.makeList(&provider);
        const update = list.handle(event);
        if (clicked) |index| self.state.activated = index;
        return update;
    }

    fn makeList(self: *Menu, provider: *Provider) data.List(Provider) {
        return .{
            .provider = provider,
            .state = &self.state.scroll,
            .bounds = self.bounds,
            .row_role = self.row_role,
            .selected_role = self.selected_role,
            .enabled = self.enabled,
            .focused = self.focused,
            .width_profile = self.width_profile,
        };
    }

    fn clickedRow(self: *const Menu, event: input.Event) ?usize {
        const mouse = switch (event) {
            .mouse => |mouse| mouse,
            else => return null,
        };
        if (mouse.action != .press or mouse.button != .left or mouse.modifiers.hasNonLock() or
            !self.bounds.contains(.{ .x = mouse.x, .y = mouse.y })) return null;
        const offset = mouse.y - self.bounds.y;
        if (@as(usize, offset) >= self.labels.len -| self.state.scroll.top) return null;
        return self.state.scroll.top + offset;
    }
};

fn keyboardActivation(event: input.Event) bool {
    return switch (event) {
        .key => |key| key.action == .press and !key.modifiers.hasNonLock() and switch (key.code) {
            .enter => true,
            .codepoint => |codepoint| codepoint == ' ' or codepoint == '\r' or codepoint == '\n',
            else => false,
        },
        .text => |value| std.mem.eql(u8, value, " "),
        else => false,
    };
}

test "menu exposes caller-polled keyboard and click activation" {
    const labels = [_][]const u8{ "first", "second", "third" };
    var state: MenuState = .{};
    var menu = Menu{
        .labels = &labels,
        .state = &state,
        .bounds = .{ .x = 5, .y = 3, .width = 8, .height = 3 },
    };
    try std.testing.expectEqual(Update.redraw, menu.handle(.{ .key = .{ .code = .down } }));
    try std.testing.expectEqual(Update.handled, menu.handle(.{ .key = .{ .code = .enter } }));
    try std.testing.expectEqual(@as(?usize, 0), state.takeActivation());
    try std.testing.expectEqual(@as(?usize, null), state.takeActivation());

    try std.testing.expectEqual(
        Update.redraw,
        menu.handle(.{ .mouse = .{ .x = 6, .y = 5, .button = .left, .action = .press } }),
    );
    try std.testing.expectEqual(@as(?usize, 2), state.takeActivation());
    try std.testing.expectEqual(Update.ignored, menu.handle(.{ .key = .{ .code = .escape } }));
}

test "menu drawing is clipped and allocation-free" {
    const labels = [_][]const u8{ "production cluster", "staging", "local" };
    var state: MenuState = .{ .scroll = .{ .selected = 0 } };
    var menu = Menu{
        .labels = &labels,
        .state = &state,
        .bounds = .{ .x = 0, .y = 0, .width = 6, .height = 2 },
        .focused = true,
        .selected_role = .{ .focused = .{ .attributes = .{ .reverse = true } } },
    };
    var allocator_state = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var renderer = try render.Renderer.init(allocator_state.allocator(), .{ .width = 6, .height = 2 }, .{});
    defer renderer.deinit();
    allocator_state.fail_index = allocator_state.alloc_index;
    allocator_state.resize_fail_index = allocator_state.resize_index;
    var frame = renderer.frame();
    var surface = frame.surface(render.Rect.fromSize(renderer.size()));
    try menu.draw(&surface);
    try std.testing.expectEqual(@as(u32, 'p'), renderer.desiredCell(.{ .x = 0, .y = 0 }).?.glyph);
    try std.testing.expectEqual(@as(u32, 0x2026), renderer.desiredCell(.{ .x = 5, .y = 0 }).?.glyph);
    try std.testing.expect(!allocator_state.has_induced_failure);
}
