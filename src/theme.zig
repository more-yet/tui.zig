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
