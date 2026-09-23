const std = @import("std");
const demo = @import("demo_app");
const Oracle = @import("oracle.zig");
const graphics_checks = @import("graphics_checks.zig");
const placeholder = @import("tui").graphics.placeholder;

test "graphics oracle decodes the demo's images and releases their storage" {
    var oracle: Oracle = undefined;
    try oracle.init(std.testing.allocator, .{
        .io = std.testing.io,
        .cols = 60,
        .rows = 16,
        .images = .direct,
    });
    defer oracle.deinit();
    var fixture = try demo.graphics_demo.Fixture.init(.direct);
    defer fixture.deinit();
    var showcase = demo.graphics_demo.Showcase.init(&fixture);
    try showcase.restart(.{ .width = 60, .height = 16 });
    var cropped = false;
    var animated = false;
    for (0..8192) |_| {
        const bytes = (try showcase.outputStep()) orelse break;
        try oracle.write(bytes[0..1]);
        try showcase.consumeOutput(1);
        if (!showcase.sender.isActive() and showcase.cursor_len == 0) {
            const images = &oracle.terminal.screens.active.kitty_images;
            switch (showcase.sender.command) {
                .display => |display| {
                    if (display.identifiers.image_id == 4001 and display.identifiers.placement_id == 2) {
                        const placement = images.placements.get(.{ .image_id = 4001, .placement_id = .{ .tag = .external, .id = 2 } }).?;
                        try std.testing.expectEqual(@as(u32, 1), placement.source_x);
                        try std.testing.expectEqual(@as(u32, 1), placement.source_width);
                        try std.testing.expectEqual(@as(u32, 2), placement.source_height);
                        try std.testing.expectEqual(@as(u32, 1), placement.x_offset);
                        try std.testing.expectEqual(@as(u32, 1), placement.y_offset);
                        try std.testing.expectEqual(@as(i32, 1), placement.z);
                        try std.testing.expectEqual(@as(u32, 3), placement.columns);
                        try std.testing.expectEqual(@as(u32, 2), placement.rows);
                        cropped = true;
                    }
                    if (display.identifiers.image_id == 4004) {
                        const animation = images.images.get(4004).?.animation.?;
                        try std.testing.expectEqual(@as(u32, 2), animation.frameCount());
                        try std.testing.expectEqualSlices(u8, &.{ 255, 64, 32, 255 }, animation.frames.items[0].data[12..16]);
                        try std.testing.expectEqual(@as(?u64, 160), images.animationTick(std.testing.io, 1000));
                        try std.testing.expectEqual(@as(?u64, 1), images.animationTick(std.testing.io, 1159));
                        try std.testing.expectEqual(@as(u32, 0), animation.current_index);
                        try std.testing.expectEqual(@as(?u64, 120), images.animationTick(std.testing.io, 1160));
                        try std.testing.expectEqual(@as(u32, 1), animation.current_index);
                        try std.testing.expectEqual(@as(?u64, 160), images.animationTick(std.testing.io, 1280));
                        try std.testing.expectEqual(@as(?u64, 120), images.animationTick(std.testing.io, 1440));
                        try std.testing.expectEqual(@as(?u64, null), images.animationTick(std.testing.io, 1560));
                        try std.testing.expectEqual(@as(u32, 2), animation.current_loop);
                        animated = true;
                    }
                },
                else => {},
            }
        }
    } else return error.GraphicsWorkLimit;
    const images = &oracle.terminal.screens.active.kitty_images;
    try std.testing.expect(cropped and animated);
    try std.testing.expectEqual(@as(u32, 4), images.images.count());
    try std.testing.expectEqual(@as(u32, 5), images.placements.count());
    try std.testing.expect(showcase.takeOutputInvalidation());

    // Fragment the following text frame at complete VT command boundaries.
    // Images and the heading alone must not release the PTY wait predicate.
    try oracle.write("\x1b[12;1HGraphics");
    try std.testing.expect(!graphics_checks.showcaseReady(&oracle));
    for (0..2) |row| for (0..2) |column| {
        var cursor: [32]u8 = undefined;
        try oracle.write(try std.fmt.bufPrint(&cursor, "\x1b[{d};{d}H", .{ 13 + row, 11 + column }));
        var cell: [16]u8 = undefined;
        try oracle.write(try placeholder.encodeCell(&cell, @intCast(row), @intCast(column), 4001));
        try std.testing.expect(oracle.stream.ground());
        try std.testing.expectEqual(row == 1 and column == 1, graphics_checks.showcaseReady(&oracle));
    };

    showcase.requestCleanup();
    for (0..8192) |_| {
        const bytes = (try showcase.outputStep()) orelse break;
        try oracle.write(bytes);
        try showcase.consumeOutput(bytes.len);
    } else return error.GraphicsWorkLimit;
    try std.testing.expectEqual(@as(u32, 0), images.images.count());
    try std.testing.expectEqual(@as(u32, 0), images.placements.count());
    try std.testing.expectEqual(@as(usize, 0), images.total_bytes);
}
