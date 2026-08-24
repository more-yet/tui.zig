const std = @import("std");
const braille = @import("../render/braille.zig");
const render = @import("../render.zig");
const theme = @import("../theme.zig");

pub const Range = struct {
    minimum: ?f64 = null,
    maximum: ?f64 = null,
};

/// A line chart over a provider supplying `count()` and finite `sample(index)` values.
pub fn LineChart(comptime Provider: type) type {
    return struct {
        provider: *Provider,
        canvas: *braille.BrailleCanvas,
        range: Range = .{},
        role: theme.Role = .{},
        enabled: bool = true,
        focused: bool = false,

        const Self = @This();

        pub fn layout(self: *Self, size: render.Size) braille.Error!bool {
            return self.canvas.resize(size);
        }

        pub fn draw(self: *Self, surface: *render.Surface) !void {
            std.debug.assert(surface.size().width == self.canvas.width);
            std.debug.assert(surface.size().height == self.canvas.height);
            self.canvas.clear();
            const style = self.role.resolve(theme.State.from(self.enabled, self.focused));
            const pixel_width = self.canvas.pixelWidth();
            const pixel_height = self.canvas.pixelHeight();
            const count = self.provider.count();
            if (count == 0 or pixel_width == 0 or pixel_height == 0) {
                try self.canvas.draw(surface, style);
                return;
            }

            var minimum = self.range.minimum orelse std.math.inf(f64);
            var maximum = self.range.maximum orelse -std.math.inf(f64);
            if (!std.math.isFinite(minimum) and self.range.minimum != null or
                !std.math.isFinite(maximum) and self.range.maximum != null) return error.InvalidRange;
            for (0..count) |index| {
                const sample = self.provider.sample(index);
                if (!std.math.isFinite(sample)) return error.InvalidSample;
                if (self.range.minimum == null) minimum = @min(minimum, sample);
                if (self.range.maximum == null) maximum = @max(maximum, sample);
            }
            if (minimum > maximum) return error.InvalidRange;

            var previous: ?braille.PixelPoint = null;
            for (0..pixel_width) |x| {
                const sample_index: usize = if (pixel_width == 1 or count == 1)
                    0
                else
                    @intCast((@as(u128, x) * (count - 1)) / (pixel_width - 1));
                const sample = std.math.clamp(self.provider.sample(sample_index), minimum, maximum);
                const y = if (minimum == maximum)
                    (pixel_height - 1) / 2
                else y: {
                    const normalized = (sample - minimum) / (maximum - minimum);
                    const scaled = (1.0 - normalized) * @as(f64, @floatFromInt(pixel_height - 1));
                    break :y @as(usize, @intFromFloat(@round(scaled)));
                };
                const point = braille.PixelPoint{ .x = x, .y = y };
                if (previous) |start| {
                    self.canvas.line(start, point) catch unreachable;
                } else {
                    _ = self.canvas.set(point, true);
                }
                previous = point;
            }
            try self.canvas.draw(surface, style);
        }
    };
}

test "line chart scales provider samples into a caller-owned braille canvas" {
    const Provider = struct {
        values: []const f64,

        pub fn count(self: *@This()) usize {
            return self.values.len;
        }

        pub fn sample(self: *@This(), index: usize) f64 {
            return self.values[index];
        }
    };
    const values = [_]f64{ 0, 1, 0 };
    var provider = Provider{ .values = &values };
    var masks: [2]u8 = undefined;
    var canvas = try braille.BrailleCanvas.init(&masks, .{ .width = 2, .height = 1 });
    var chart = LineChart(Provider){ .provider = &provider, .canvas = &canvas };
    var renderer = try render.Renderer.init(std.testing.allocator, .{ .width = 2, .height = 1 }, .{});
    defer renderer.deinit();
    var frame = renderer.frame();
    var surface = frame.surface(render.Rect.fromSize(renderer.size()));
    try chart.draw(&surface);
    try std.testing.expect(masks[0] != 0 and masks[1] != 0);
}

test "line chart rejects non-finite provider samples" {
    const Provider = struct {
        pub fn count(_: *@This()) usize {
            return 1;
        }

        pub fn sample(_: *@This(), _: usize) f64 {
            return std.math.nan(f64);
        }
    };
    var provider: Provider = .{};
    var masks: [1]u8 = undefined;
    var canvas = try braille.BrailleCanvas.init(&masks, .{ .width = 1, .height = 1 });
    var chart = LineChart(Provider){ .provider = &provider, .canvas = &canvas };
    var renderer = try render.Renderer.init(std.testing.allocator, .{ .width = 1, .height = 1 }, .{});
    defer renderer.deinit();
    var frame = renderer.frame();
    var surface = frame.surface(render.Rect.fromSize(renderer.size()));
    try std.testing.expectError(error.InvalidSample, chart.draw(&surface));
}
