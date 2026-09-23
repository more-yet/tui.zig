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
