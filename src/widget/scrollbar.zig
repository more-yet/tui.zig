const std = @import("std");
const render = @import("../render.zig");
const theme = @import("../ui/theme.zig");

pub const Scrollbar = struct {
    pub const Thumb = struct {
        start: u16,
        height: u16,
    };

    total_rows: usize = 0,
    visible_rows: usize = 0,
    top_row: usize = 0,
    track_role: theme.Role = .{},
    thumb_role: theme.Role = .{},
    state: theme.State = .normal,

    /// Track-local cell geometry for custom drawing, e.g. `bar.geometry(surface.size().height)`.
    /// Returns null for an empty track, content, or viewport; clamps top_row to the scroll range.
    pub fn geometry(self: *const Scrollbar, track_height: u16) ?Thumb {
        if (track_height == 0 or self.total_rows == 0 or self.visible_rows == 0) return null;
        const visible = @min(self.visible_rows, self.total_rows);
        if (visible == self.total_rows) return .{ .start = 0, .height = track_height };

        const proportional = (@as(u128, visible) * track_height) / self.total_rows;
        const thumb_height: u16 = @intCast(@max(@as(u128, 1), proportional));
        const travel = track_height - thumb_height;
        const max_top = self.total_rows - visible;
        const top = @min(self.top_row, max_top);
        const start: u16 = @intCast((@as(u128, top) * travel) / max_top);
        return .{ .start = start, .height = thumb_height };
    }

    /// Only draws; update `top_row`, `visible_rows`, and `total_rows` yourself.
    pub fn draw(self: *const Scrollbar, surface: *render.Surface) !void {
        const size = surface.size();
        std.debug.assert(size.width <= 1);
        if (size.width == 0 or size.height == 0) return;

        try surface.fillAscii(render.Rect.fromSize(size), '|', self.track_role.resolve(self.state));
        const thumb = self.geometry(size.height) orelse return;
        try surface.fillAscii(.{
            .x = 0,
            .y = thumb.start,
            .width = 1,
            .height = thumb.height,
        }, '#', self.thumb_role.resolve(self.state));
    }
};
