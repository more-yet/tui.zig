const std = @import("std");

pub const Size = struct {
    width: u16,
    height: u16,

    pub fn cellCount(self: Size) error{Overflow}!usize {
        return std.math.mul(usize, self.width, self.height) catch error.Overflow;
    }
};

pub const Point = struct {
    x: u16,
    y: u16,
};

pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    pub fn fromSize(size: Size) Rect {
        return .{ .x = 0, .y = 0, .width = size.width, .height = size.height };
    }

    pub fn isEmpty(self: Rect) bool {
        return self.width == 0 or self.height == 0;
    }

    pub fn right(self: Rect) u32 {
        return @as(u32, self.x) + self.width;
    }

    pub fn bottom(self: Rect) u32 {
        return @as(u32, self.y) + self.height;
    }

    pub fn intersection(self: Rect, other: Rect) Rect {
        const x1 = @max(@as(u32, self.x), other.x);
        const y1 = @max(@as(u32, self.y), other.y);
        const x2 = @min(self.right(), other.right());
        const y2 = @min(self.bottom(), other.bottom());
        if (x1 >= x2 or y1 >= y2) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        return .{
            .x = @intCast(x1),
            .y = @intCast(y1),
            .width = @intCast(x2 - x1),
            .height = @intCast(y2 - y1),
        };
    }

    pub fn contains(self: Rect, point: Point) bool {
        return point.x >= self.x and point.y >= self.y and point.x < self.right() and point.y < self.bottom();
    }
};

test "rectangle intersection clips without overflow" {
    const clipped = (Rect{ .x = 8, .y = 3, .width = 8, .height = 4 }).intersection(
        .{ .x = 10, .y = 1, .width = 2, .height = 8 },
    );
    try std.testing.expectEqual(Rect{ .x = 10, .y = 3, .width = 2, .height = 4 }, clipped);
}
