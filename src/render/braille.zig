const std = @import("std");
const geometry = @import("../core/geometry.zig");
const renderer = @import("renderer.zig");
const style_module = @import("style.zig");
const text = @import("../text.zig");

pub const Error = error{
    BufferTooSmall,
    OutOfBounds,
};

pub const PixelPoint = struct {
    x: usize,
    y: usize,
};

/// A 2-by-4 dot canvas per terminal cell over caller-owned mask storage.
pub const BrailleCanvas = struct {
    storage: []u8,
    width: u16,
    height: u16,

    pub fn init(storage: []u8, size: geometry.Size) Error!BrailleCanvas {
        const required = @as(usize, size.width) * size.height;
        if (required > storage.len) return error.BufferTooSmall;
        @memset(storage[0..required], 0);
        return .{ .storage = storage, .width = size.width, .height = size.height };
    }

    pub fn resize(self: *BrailleCanvas, size: geometry.Size) Error!bool {
        const required = @as(usize, size.width) * size.height;
        if (required > self.storage.len) return error.BufferTooSmall;
        const changed = self.width != size.width or self.height != size.height;
        self.width = size.width;
        self.height = size.height;
        self.clear();
        return changed;
    }

    pub fn clear(self: *BrailleCanvas) void {
        @memset(self.cells(), 0);
    }

    pub fn pixelWidth(self: *const BrailleCanvas) usize {
        return @as(usize, self.width) * 2;
    }

    pub fn pixelHeight(self: *const BrailleCanvas) usize {
        return @as(usize, self.height) * 4;
    }

    pub fn set(self: *BrailleCanvas, point: PixelPoint, enabled: bool) bool {
        if (point.x >= self.pixelWidth() or point.y >= self.pixelHeight()) return false;
        const cell_x = point.x / 2;
        const cell_y = point.y / 4;
        const bit = dotBit(point.x % 2, point.y % 4);
        const mask = @as(u8, 1) << bit;
        const cell = &self.cells()[cell_y * self.width + cell_x];
        if (enabled) {
            cell.* |= mask;
        } else {
            cell.* &= ~mask;
        }
        return true;
    }

    pub fn line(self: *BrailleCanvas, start: PixelPoint, end: PixelPoint) Error!void {
        if (start.x >= self.pixelWidth() or end.x >= self.pixelWidth() or
            start.y >= self.pixelHeight() or end.y >= self.pixelHeight()) return error.OutOfBounds;
        var x: i64 = @intCast(start.x);
        var y: i64 = @intCast(start.y);
        const target_x: i64 = @intCast(end.x);
        const target_y: i64 = @intCast(end.y);
        const dx = @abs(target_x - x);
        const step_x: i64 = if (x < target_x) 1 else -1;
        const dy = -@as(i64, @intCast(@abs(target_y - y)));
        const step_y: i64 = if (y < target_y) 1 else -1;
        var err: i64 = @intCast(dx);
        err += dy;
        while (true) {
            _ = self.set(.{ .x = @intCast(x), .y = @intCast(y) }, true);
            if (x == target_x and y == target_y) break;
            const twice = err * 2;
            if (twice >= dy) {
                err += dy;
                x += step_x;
            }
            if (twice <= dx) {
                err += @intCast(dx);
                y += step_y;
            }
        }
    }

    pub fn draw(self: *const BrailleCanvas, surface: *renderer.Surface, style: style_module.Style) !void {
        std.debug.assert(surface.size().width == self.width and surface.size().height == self.height);
        try surface.putBrailleMasks(self.cells(), style);
    }

    fn cells(self: *const BrailleCanvas) []u8 {
        return self.storage[0 .. @as(usize, self.width) * self.height];
    }
};

fn dotBit(x: usize, y: usize) u3 {
    const bits = [2][4]u3{
        .{ 0, 1, 2, 6 },
        .{ 3, 4, 5, 7 },
    };
    return bits[x][y];
}

test "braille canvas maps dots and lines without allocation" {
    var masks: [2]u8 = undefined;
    var canvas = try BrailleCanvas.init(&masks, .{ .width = 2, .height = 1 });
    try std.testing.expect(canvas.set(.{ .x = 0, .y = 0 }, true));
    try canvas.line(.{ .x = 1, .y = 3 }, .{ .x = 3, .y = 0 });
    try std.testing.expectEqual(@as(u8, 0x81), masks[0]);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var output = try renderer.Renderer.init(failing.allocator(), .{ .width = 2, .height = 1 }, .{});
    defer output.deinit();
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    var frame = output.frame();
    var surface = frame.surface(geometry.Rect.fromSize(output.size()));
    try canvas.draw(&surface, .{});
    var glyph: [text.max_grapheme_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("\xE2\xA2\x81", output.desiredCellView(.{ .x = 0, .y = 0 }, &glyph).?.glyph);
    try std.testing.expect(!failing.has_induced_failure);

    var clipped_output = try renderer.Renderer.init(std.testing.allocator, .{ .width = 2, .height = 1 }, .{});
    defer clipped_output.deinit();
    frame = clipped_output.frame();
    var parent = frame.surface(.{ .x = 1, .y = 0, .width = 1, .height = 1 });
    surface = parent.surface(.{ .x = 0, .y = 0, .width = 2, .height = 1 });
    try canvas.draw(&surface, .{});
    try std.testing.expectEqualStrings(" ", clipped_output.desiredCellView(.{ .x = 0, .y = 0 }, &glyph).?.glyph);
    try std.testing.expectEqualStrings("\xE2\xA2\x81", clipped_output.desiredCellView(.{ .x = 1, .y = 0 }, &glyph).?.glyph);
}
