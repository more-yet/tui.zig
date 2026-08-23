const geometry = @import("../core/geometry.zig");

pub const Shape = enum(u3) {
    default = 0,
    blinking_block = 1,
    steady_block = 2,
    blinking_underline = 3,
    steady_underline = 4,
    blinking_bar = 5,
    steady_bar = 6,
};

pub const Cursor = struct {
    position: geometry.Point,
    visible: bool = true,
    shape: Shape = .default,

    pub fn eql(lhs: Cursor, rhs: Cursor) bool {
        return lhs.position.x == rhs.position.x and lhs.position.y == rhs.position.y and
            lhs.visible == rhs.visible and lhs.shape == rhs.shape;
    }
};
