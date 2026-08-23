const render = @import("render.zig");

pub const State = enum(u2) {
    normal,
    focused,
    disabled,

    pub inline fn from(enabled: bool, focused: bool) State {
        if (!enabled) return .disabled;
        return if (focused) .focused else .normal;
    }
};

/// Optional states replace the complete normal style; fields are not merged.
pub const Role = struct {
    normal: render.Style = .{},
    focused: ?render.Style = null,
    disabled: ?render.Style = null,

    pub inline fn resolve(self: Role, state: State) render.Style {
        return switch (state) {
            .normal => self.normal,
            .focused => self.focused orelse self.normal,
            .disabled => self.disabled orelse self.normal,
        };
    }
};

test "theme roles resolve explicit states and whole-style fallbacks" {
    const normal = render.Style{ .foreground = .{ .indexed = 7 } };
    const disabled = render.Style{ .foreground = .{ .indexed = 8 }, .attributes = .{ .dim = true } };
    const role = Role{ .normal = normal, .disabled = disabled };

    try @import("std").testing.expectEqual(normal, role.resolve(.normal));
    try @import("std").testing.expectEqual(normal, role.resolve(.focused));
    try @import("std").testing.expectEqual(disabled, role.resolve(.disabled));
    try @import("std").testing.expectEqual(State.focused, State.from(true, true));
    try @import("std").testing.expectEqual(State.disabled, State.from(false, true));
}
