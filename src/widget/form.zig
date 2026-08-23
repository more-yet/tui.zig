//! Form controls consume events already routed to their focus or hit-test target.

const std = @import("std");
const input = @import("../input.zig");
const render = @import("../render.zig");
const text = @import("../text.zig");
const theme = @import("../theme.zig");
const Update = @import("update.zig").Update;

pub const Button = struct {
    label: []const u8,
    role: theme.Role = .{},
    enabled: bool = true,
    focused: bool = false,
    width_profile: text.WidthProfile = .narrow,
    activated: bool = false,

    pub fn draw(self: *const Button, surface: *render.Surface) !void {
        const size = surface.size();
        if (size.width == 0 or size.height == 0) return;
        const style = self.role.resolve(theme.State.from(self.enabled, self.focused));
        _ = try surface.putText(.{ .x = 0, .y = 0 }, "[", style, .narrow);
        if (size.width == 1) return;
        _ = try surface.putText(.{ .x = size.width - 1, .y = 0 }, "]", style, .narrow);
        if (size.width == 2) return;
        _ = try surface.putTextLine(
            .{ .x = 1, .y = 0 },
            self.label,
            size.width - 2,
            style,
            self.width_profile,
            .{ .overflow = .ellipsis },
        );
    }

    pub fn handle(self: *Button, event: input.Event) Update {
        if (!self.enabled or !isActivation(event)) return .ignored;
        self.activated = true;
        return .handled;
    }

    pub inline fn takeActivation(self: *Button) bool {
        const activated = self.activated;
        self.activated = false;
        return activated;
    }
};

pub const Checkbox = struct {
    label: []const u8,
    checked: bool = false,
    role: theme.Role = .{},
    enabled: bool = true,
    focused: bool = false,
    width_profile: text.WidthProfile = .narrow,

    pub fn draw(self: *const Checkbox, surface: *render.Surface) !void {
        try drawChoice(
            surface,
            if (self.checked) "[x] " else "[ ] ",
            self.label,
            self.role.resolve(theme.State.from(self.enabled, self.focused)),
            self.width_profile,
        );
    }

    pub fn handle(self: *Checkbox, event: input.Event) Update {
        if (!self.enabled or !isActivation(event)) return .ignored;
        self.checked = !self.checked;
        return .redraw;
    }
};

pub const Radio = struct {
    label: []const u8,
    value: u32,
    selection: *?u32,
    role: theme.Role = .{},
    enabled: bool = true,
    focused: bool = false,
    width_profile: text.WidthProfile = .narrow,

    pub inline fn selected(self: *const Radio) bool {
        return self.selection.* == self.value;
    }

    pub fn draw(self: *const Radio, surface: *render.Surface) !void {
        try drawChoice(
            surface,
            if (self.selected()) "(*) " else "( ) ",
            self.label,
            self.role.resolve(theme.State.from(self.enabled, self.focused)),
            self.width_profile,
        );
    }

    pub fn handle(self: *Radio, event: input.Event) Update {
        if (!self.enabled or !isActivation(event)) return .ignored;
        if (self.selected()) return .handled;
        self.selection.* = self.value;
        return .redraw;
    }
};

fn drawChoice(
    surface: *render.Surface,
    marker: *const [4]u8,
    label: []const u8,
    style: render.Style,
    width_profile: text.WidthProfile,
) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;
    _ = try surface.putText(.{ .x = 0, .y = 0 }, marker, style, .narrow);
    const marker_width: u16 = marker.len;
    if (size.width <= marker_width) return;
    _ = try surface.putTextLine(
        .{ .x = marker_width, .y = 0 },
        label,
        size.width - marker_width,
        style,
        width_profile,
        .{ .overflow = .ellipsis },
    );
}

fn isActivation(event: input.Event) bool {
    return switch (event) {
        .key => |key| key.action == .press and !key.modifiers.hasNonLock() and switch (key.code) {
            .enter => true,
            .codepoint => |codepoint| codepoint == ' ' or codepoint == '\r' or codepoint == '\n',
            else => false,
        },
        .text => |value| std.mem.eql(u8, value, " "),
        .mouse => |mouse| mouse.action == .press and mouse.button == .left and
            !mouse.modifiers.hasNonLock(),
        else => false,
    };
}

test "form controls activate only from supported target-routed events" {
    var button = Button{ .label = "run" };
    try std.testing.expectEqual(
        Update.ignored,
        button.handle(.{ .key = .{ .code = .enter, .action = .repeat } }),
    );
    try std.testing.expectEqual(
        Update.ignored,
        button.handle(.{ .key = .{ .code = .enter, .modifiers = .{ .control = true } } }),
    );
    try std.testing.expectEqual(Update.handled, button.handle(.{ .text = " " }));
    try std.testing.expect(button.takeActivation());
    try std.testing.expect(!button.takeActivation());
    try std.testing.expectEqual(
        Update.handled,
        button.handle(.{ .key = .{ .code = .{ .codepoint = '\r' }, .modifiers = .{ .caps_lock = true } } }),
    );
    try std.testing.expect(button.takeActivation());

    button.enabled = false;
    try std.testing.expectEqual(
        Update.ignored,
        button.handle(.{ .mouse = .{ .x = 0, .y = 0, .button = .left, .action = .press } }),
    );
}

test "checkboxes and radios keep caller-owned selection state" {
    var checkbox = Checkbox{ .label = "logs" };
    try std.testing.expectEqual(
        Update.redraw,
        checkbox.handle(.{ .key = .{ .code = .{ .codepoint = ' ' } } }),
    );
    try std.testing.expect(checkbox.checked);

    var selection: ?u32 = null;
    var radio = Radio{ .label = "fast", .value = 7, .selection = &selection };
    const click = input.Event{ .mouse = .{ .x = 8, .y = 4, .button = .left, .action = .press } };
    try std.testing.expectEqual(Update.redraw, radio.handle(click));
    try std.testing.expectEqual(@as(?u32, 7), selection);
    try std.testing.expectEqual(Update.handled, radio.handle(click));
}

test "form controls draw clipped rows without steady-state allocation" {
    var allocator_state = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var renderer = try render.Renderer.init(allocator_state.allocator(), .{ .width = 12, .height = 3 }, .{});
    defer renderer.deinit();
    allocator_state.fail_index = allocator_state.alloc_index;
    allocator_state.resize_fail_index = allocator_state.resize_index;

    var frame = renderer.frame();
    var root = frame.surface(render.Rect.fromSize(renderer.size()));
    var button_surface = root.surface(.{ .x = 0, .y = 0, .width = 12, .height = 1 });
    const button = Button{ .label = "Run workers now" };
    try button.draw(&button_surface);
    var checkbox_surface = root.surface(.{ .x = 0, .y = 1, .width = 12, .height = 1 });
    const checkbox = Checkbox{ .label = "logs", .checked = true };
    try checkbox.draw(&checkbox_surface);
    var selection: ?u32 = 1;
    var radio_surface = root.surface(.{ .x = 0, .y = 2, .width = 12, .height = 1 });
    const radio = Radio{ .label = "fast", .value = 1, .selection = &selection };
    try radio.draw(&radio_surface);

    try std.testing.expectEqual(@as(u32, '['), renderer.desiredCell(.{ .x = 0, .y = 0 }).?.glyph);
    try std.testing.expectEqual(@as(u32, ']'), renderer.desiredCell(.{ .x = 11, .y = 0 }).?.glyph);
    try std.testing.expectEqual(@as(u32, 'x'), renderer.desiredCell(.{ .x = 1, .y = 1 }).?.glyph);
    try std.testing.expectEqual(@as(u32, '*'), renderer.desiredCell(.{ .x = 1, .y = 2 }).?.glyph);
    try std.testing.expect(!allocator_state.has_induced_failure);
}
