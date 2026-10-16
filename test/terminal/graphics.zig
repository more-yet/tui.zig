const std = @import("std");
const tui = @import("tui");
const Oracle = @import("oracle.zig");
const testing = std.testing;

fn send(sender: *tui.graphics.Sender, oracle: *Oracle) !void {
    for (0..8192) |_| {
        const bytes = (try sender.outputStep()) orelse return;
        try oracle.write(bytes[0..1]);
        try sender.consumeOutput(1);
    }
    return error.GraphicsWorkLimit;
}

test "fragmented graphics upload placement deletion and cancellation round trip through terminal" {
    var oracle: Oracle = undefined;
    try oracle.init(testing.allocator, .{ .io = testing.io, .cols = 20, .rows = 8, .images = .direct });
    defer oracle.deinit();
    const rgba = [_]u8{ 255, 64, 32, 255, 32, 255, 64, 128, 32, 64, 255, 128, 255, 255, 255, 0 };
    var sender = tui.graphics.Sender.init(.{});
    try sender.begin(.{ .transmit = .{ .transmission = .{
        .width_pixels = 2,
        .height_pixels = 2,
        .identifiers = .{ .image_id = 1 },
    } } }, .{ .direct = &rgba }, .none);
    try send(&sender, &oracle);
    const images = &oracle.terminal.screens.active.kitty_images;
    try testing.expectEqualSlices(u8, &rgba, images.images.get(1).?.data.complete);
    try oracle.write("\x1b[3;4H");
    try sender.beginCommand(.{ .display = .{
        .identifiers = .{ .image_id = 1, .placement_id = 2 },
        .placement = .{ .source_x_pixels = 1, .source_width_pixels = 1, .source_height_pixels = 2, .columns = 3, .rows = 2, .z_order = 1, .cursor = .preserve },
    } }, .none);
    try send(&sender, &oracle);
    const placement = images.placements.get(.{ .image_id = 1, .placement_id = .{ .tag = .external, .id = 2 } }).?;
    try testing.expectEqual(@as(u32, 1), placement.source_x);
    try testing.expectEqual(@as(u32, 1), placement.source_width);
    try testing.expectEqual(@as(u32, 2), placement.source_height);
    try testing.expectEqual(@as(u32, 3), placement.columns);
    try testing.expectEqual(@as(u32, 2), placement.rows);
    try testing.expectEqual(@as(i32, 1), placement.z);
    try testing.expectEqual(@as(u16, 3), oracle.terminal.screens.active.cursor.x);
    try testing.expectEqual(@as(u16, 2), oracle.terminal.screens.active.cursor.y);
    try sender.beginCommand(.{ .delete = .{ .selector = .{ .image_id = .{ .image_id = 1, .free_data = true } } } }, .none);
    try send(&sender, &oracle);
    try testing.expect(oracle.stream.ground());
    try testing.expectEqual(@as(u32, 0), images.images.count());
    try testing.expectEqual(@as(u32, 0), images.placements.count());
    try testing.expectEqual(@as(usize, 0), images.total_bytes);

    const large: [3076]u8 = @splat(255);
    try sender.begin(.{ .transmit = .{ .transmission = .{
        .width_pixels = large.len / 4,
        .height_pixels = 1,
        .identifiers = .{ .image_id = 2 },
    } } }, .{ .direct = &large }, .none);
    const pending = (try sender.outputStep()).?;
    var saved: [tui.graphics.Sender.output_capacity]u8 = undefined;
    @memcpy(saved[0..pending.len], pending);
    const pending_len = pending.len;
    try oracle.write(pending[0..1]);
    try sender.consumeOutput(1);
    try sender.cancel(.{ .selector = .{ .image_id = .{ .image_id = 2, .free_data = true } } });
    try testing.expectEqualSlices(u8, saved[1..pending_len], (try sender.outputStep()).?);
    try send(&sender, &oracle);
    try testing.expect(!sender.isActive());
    try testing.expect(oracle.stream.ground());
    try testing.expectEqual(@as(u32, 0), images.images.count());
    try testing.expectEqual(@as(usize, 0), images.total_bytes);
}
