//! Stateless vertical scrollbar over caller-owned row metrics.

const std = @import("std");
const render = @import("../render.zig");
const theme = @import("../theme.zig");

pub const Scrollbar = struct {
    total_rows: usize = 0,
    visible_rows: usize = 0,
    top_row: usize = 0,
    track_role: theme.Role = .{},
    thumb_role: theme.Role = .{},
    state: theme.State = .normal,

    /// Draws a visual indicator only. Scrolling and row measurement remain caller-owned.
    pub fn draw(self: *const Scrollbar, surface: *render.Surface) !void {
        const size = surface.size();
        std.debug.assert(size.width <= 1);
        if (size.width == 0 or size.height == 0) return;

        try surface.fillAscii(render.Rect.fromSize(size), '|', self.track_role.resolve(self.state));
        const thumb = thumbGeometry(size.height, self.total_rows, self.visible_rows, self.top_row) orelse return;
        try surface.fillAscii(.{
            .x = 0,
            .y = thumb.start,
            .width = 1,
            .height = thumb.height,
        }, '#', self.thumb_role.resolve(self.state));
    }
};

const Thumb = struct {
    start: u16,
    height: u16,
};

fn thumbGeometry(track_height: u16, total_rows: usize, visible_rows: usize, top_row: usize) ?Thumb {
    if (track_height == 0 or total_rows == 0 or visible_rows == 0) return null;
    const visible = @min(visible_rows, total_rows);
    if (visible == total_rows) return .{ .start = 0, .height = track_height };

    const proportional = (@as(u128, visible) * track_height) / total_rows;
    const thumb_height: u16 = @intCast(@max(@as(u128, 1), proportional));
    const travel = track_height - thumb_height;
    const max_top = total_rows - visible;
    const top = @min(top_row, max_top);
    const start: u16 = @intCast((@as(u128, top) * travel) / max_top);
    return .{ .start = start, .height = thumb_height };
}
