const std = @import("std");
const tui = @import("tui");

test "renderer releases every partial initialization" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, initializeRenderer, .{});
}

test "renderer preserves ownership through every failed growth allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, growRenderer, .{});
}

fn initializeRenderer(allocator: std.mem.Allocator) !void {
    var renderer = try tui.render.Renderer.init(
        allocator,
        .{ .width = 80, .height = 24 },
        .{ .grapheme_capacity = 32, .style_capacity = 32 },
    );
    defer renderer.deinit();
}

fn growRenderer(allocator: std.mem.Allocator) !void {
    var renderer = try tui.render.Renderer.init(
        allocator,
        .{ .width = 2, .height = 1 },
        .{ .grapheme_capacity = 16, .style_capacity = 16 },
    );
    defer renderer.deinit();
    var frame = renderer.frame();
    _ = try frame.putText(.{ .x = 0, .y = 0 }, "x", .{}, .narrow);
    try renderer.resize(.{ .width = 80, .height = 24 });
}
