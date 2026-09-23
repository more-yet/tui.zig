const std = @import("std");
const Oracle = @import("oracle.zig");
const expect = std.testing.expect;

const rgba = [_]u8{ 255, 64, 32, 255, 32, 255, 64, 128, 32, 64, 255, 128, 255, 255, 255, 0 };

pub fn showcaseReady(oracle: *Oracle) bool {
    const t = &oracle.terminal;
    if (!oracle.stream.ground() or t.modes.get(.synchronized_output)) return false;
    const images = &t.screens.active.kitty_images;
    if (images.images.count() != 4 or images.placements.count() != 5) return false;
    const image = images.images.get(4004) orelse return false;
    const animation = image.animation orelse return false;
    if (animation.state != .stopped or animation.frameCount() != 1 or animation.root_gap_ms != 160) return false;
    const placement = images.placements.get(.{ .image_id = 4001, .placement_id = .{ .tag = .external, .id = 1 } }) orelse return false;
    if (placement.location != .pin) return false;
    const point = t.screens.active.pages.pointFromPin(.active, placement.location.pin.*) orelse return false;
    if (point.coord().x != 2 or point.coord().y != t.rows - 4) return false;
    const heading = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = t.rows - 5 } }) orelse return false;
    if (heading.cell.codepoint() != 'G') return false;
    // Image replay precedes the text frame. A ground parser between commands
    // is not evidence that the renderer has painted the complete footer.
    for (0..2) |row| for (0..2) |column| {
        const cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = @intCast(10 + column),
            .y = @intCast(t.rows - 4 + row),
        } }) orelse return false;
        if (cell.cell.codepoint() != 0x10eeee) return false;
    };
    return true;
}

pub fn expectShowcase(oracle: *Oracle) !void {
    const t = &oracle.terminal;
    const screen = t.screens.active;
    const images = &screen.kitty_images;
    try expect(showcaseReady(oracle));
    try std.testing.expectEqualSlices(u8, &rgba, images.images.get(4001).?.data.complete);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, images.images.get(4002).?.data.complete);
    try std.testing.expectEqualSlices(u8, &(@as([12]u8, @splat(0))), images.images.get(4003).?.data.complete);
    try std.testing.expectEqualSlices(u8, &rgba, images.images.get(4004).?.data.complete);
    try expect(images.loading == null);
    for (0..2) |row| for (0..2) |column| {
        const cell = screen.pages.getCell(.{ .active = .{
            .x = @intCast(10 + column),
            .y = @intCast(t.rows - 4 + row),
        } }).?;
        try std.testing.expectEqual(@as(u21, 0x10eeee), cell.cell.codepoint());
        try expect(cell.style().fg_color.eql(.{ .rgb = .{ .r = 0, .g = 15, .b = 161 } }));
        try expect(cell.style().underline_color.eql(.{ .rgb = .{ .r = 0, .g = 0, .b = 10 } }));
    };
    var placements = images.placements.iterator();
    while (placements.next()) |entry| {
        const placement = entry.value_ptr;
        switch (placement.location) {
            .pin => |pin| {
                const point = (screen.pages.pointFromPin(.active, pin.*) orelse return error.OffscreenImage).coord();
                try expect(point.x == 2 and point.y == t.rows - 4);
                try expect(point.x + placement.columns <= t.cols);
                try expect(point.y + placement.rows < t.rows);
            },
            .virtual => {
                try expect(entry.key_ptr.image_id == 4001 and entry.key_ptr.placement_id.id == 10);
                try expect(placement.columns == 2 and placement.rows == 2);
            },
            .relative => |relative| {
                try expect(relative.parent.image_id == 4001 and relative.parent.placement_id.id == 10);
                try expect(relative.horizontal_offset == 3 and relative.vertical_offset == 0);
            },
        }
    }
    const text = try t.plainString(oracle.allocator);
    defer oracle.allocator.free(text);
    try expect(std.mem.startsWith(u8, text, "tui.zig  OVERVIEW"));
    try expect(std.mem.indexOf(u8, text, "Graphics error") == null);
}

pub fn expectEmpty(oracle: *Oracle) !void {
    var screens = oracle.terminal.screens.all.iterator();
    while (screens.next()) |entry| {
        const images = &entry.value.*.kitty_images;
        try expect(images.images.count() == 0);
        try expect(images.placements.count() == 0);
        try expect(images.loading == null);
        try expect(images.total_bytes == 0);
    }
}
