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
