const std = @import("std");
const geometry = @import("../core/geometry.zig");

pub const Error = error{
    InvalidConstraint,
    InsufficientSpace,
    CoordinateOverflow,
};

pub const Insets = struct {
    top: u16 = 0,
    right: u16 = 0,
    bottom: u16 = 0,
    left: u16 = 0,

    pub fn all(value: u16) Insets {
        return .{ .top = value, .right = value, .bottom = value, .left = value };
    }

    pub fn symmetric(horizontal: u16, vertical: u16) Insets {
        return .{ .top = vertical, .right = horizontal, .bottom = vertical, .left = horizontal };
    }

    pub fn apply(self: Insets, rect: geometry.Rect) Error!geometry.Rect {
        const horizontal = @as(u32, self.left) + self.right;
        const vertical = @as(u32, self.top) + self.bottom;
        if (horizontal > rect.width or vertical > rect.height) return error.InsufficientSpace;

        const x = @as(u32, rect.x) + self.left;
        const y = @as(u32, rect.y) + self.top;
        if (x > std.math.maxInt(u16) or y > std.math.maxInt(u16)) return error.CoordinateOverflow;
        return .{
            .x = @intCast(x),
            .y = @intCast(y),
            .width = @intCast(rect.width - horizontal),
            .height = @intCast(rect.height - vertical),
        };
    }
};

pub const Constraints = struct {
    min: geometry.Size = .{ .width = 0, .height = 0 },
    max: geometry.Size = .{
        .width = std.math.maxInt(u16),
        .height = std.math.maxInt(u16),
    },

    pub fn tight(size: geometry.Size) Constraints {
        return .{ .min = size, .max = size };
    }

    pub fn loose(max: geometry.Size) Constraints {
        return .{ .max = max };
    }

    pub fn constrain(self: Constraints, desired: geometry.Size) error{InvalidConstraint}!geometry.Size {
        if (self.min.width > self.max.width or self.min.height > self.max.height) {
            return error.InvalidConstraint;
        }
        return .{
            .width = std.math.clamp(desired.width, self.min.width, self.max.width),
            .height = std.math.clamp(desired.height, self.min.height, self.max.height),
        };
    }
};

pub const Align = enum {
    start,
    center,
    end,
    fill,
};

pub const Alignment = struct {
    horizontal: Align = .start,
    vertical: Align = .start,
};

pub fn place(
    area: geometry.Rect,
    desired: geometry.Size,
    constraints: Constraints,
    alignment: Alignment,
) Error!geometry.Rect {
    const bounded = constraints.constrain(desired) catch return error.InvalidConstraint;
    if (constraints.min.width > area.width or constraints.min.height > area.height) {
        return error.InsufficientSpace;
    }
    const width = resolvedLength(area.width, bounded.width, constraints.max.width, alignment.horizontal);
    const height = resolvedLength(area.height, bounded.height, constraints.max.height, alignment.vertical);
    const offset_x = alignedOffset(area.width, width, alignment.horizontal);
    const offset_y = alignedOffset(area.height, height, alignment.vertical);
    const x = @as(u32, area.x) + offset_x;
    const y = @as(u32, area.y) + offset_y;
    if (x > std.math.maxInt(u16) or y > std.math.maxInt(u16)) return error.CoordinateOverflow;
    return .{
        .x = @intCast(x),
        .y = @intCast(y),
        .width = width,
        .height = height,
    };
}

inline fn resolvedLength(available: u16, desired: u16, maximum: u16, alignment: Align) u16 {
    return if (alignment == .fill) @min(available, maximum) else @min(available, desired);
}

inline fn alignedOffset(available: u16, length: u16, alignment: Align) u16 {
    const remaining = available - length;
    return switch (alignment) {
        .start, .fill => 0,
        .center => remaining / 2,
        .end => remaining,
    };
}

test "insets and constraints are checked without allocation" {
    const inset = try Insets.symmetric(2, 1).apply(.{ .x = 4, .y = 3, .width = 10, .height = 6 });
    try std.testing.expectEqual(geometry.Rect{ .x = 6, .y = 4, .width = 6, .height = 4 }, inset);
    try std.testing.expectError(
        error.InsufficientSpace,
        Insets.all(3).apply(.{ .x = 0, .y = 0, .width = 5, .height = 5 }),
    );
    try std.testing.expectError(
        error.CoordinateOverflow,
        (Insets{ .left = 1 }).apply(.{
            .x = std.math.maxInt(u16),
            .y = 0,
            .width = 2,
            .height = 1,
        }),
    );
    try std.testing.expectError(
        error.InvalidConstraint,
        (Constraints{
            .min = .{ .width = 5, .height = 1 },
            .max = .{ .width = 4, .height = 2 },
        }).constrain(.{ .width = 2, .height = 2 }),
    );
}

test "placement aligns constrained sizes" {
    const centered = try place(
        .{ .x = 10, .y = 5, .width = 20, .height = 10 },
        .{ .width = 6, .height = 4 },
        .{},
        .{ .horizontal = .center, .vertical = .center },
    );
    try std.testing.expectEqual(geometry.Rect{ .x = 17, .y = 8, .width = 6, .height = 4 }, centered);

    const filled = try place(
        .{ .x = 2, .y = 3, .width = 20, .height = 10 },
        .{ .width = 1, .height = 1 },
        .{ .max = .{ .width = 12, .height = 8 } },
        .{ .horizontal = .fill, .vertical = .fill },
    );
    try std.testing.expectEqual(geometry.Rect{ .x = 2, .y = 3, .width = 12, .height = 8 }, filled);
}

test "placement rejects impossible space and coordinates" {
    try std.testing.expectError(
        error.InsufficientSpace,
        place(
            .{ .x = 0, .y = 0, .width = 4, .height = 4 },
            .{ .width = 2, .height = 2 },
            .{ .min = .{ .width = 5, .height = 1 } },
            .{},
        ),
    );
    try std.testing.expectError(
        error.CoordinateOverflow,
        place(
            .{ .x = std.math.maxInt(u16), .y = 0, .width = 2, .height = 1 },
            .{ .width = 1, .height = 1 },
            .{},
            .{ .horizontal = .end },
        ),
    );
}
