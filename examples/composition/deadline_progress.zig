const std = @import("std");
const tui = @import("tui");

pub const cadence_ns: u64 = 100 * std.time.ns_per_ms;

pub const App = struct {
    start: std.Io.Clock.Timestamp,
    duration_ns: u64,
    elapsed_ns: u64 = 0,
    size: tui.render.Size = .{ .width = 0, .height = 0 },

    pub fn init(start: std.Io.Clock.Timestamp, duration_ns: u64) !App {
        if (start.clock != .awake) return error.WrongClock;
        if (duration_ns == 0) return error.InvalidDuration;
        _ = std.math.add(i96, start.raw.nanoseconds, duration_ns) catch return error.DeadlineOverflow;
        return .{ .start = start, .duration_ns = duration_ns };
    }

    pub fn layout(self: *App, size: tui.render.Size) void {
        self.size = size;
    }

    pub fn draw(self: *App, surface: *tui.render.Surface) !void {
        try surface.fill(tui.render.Rect.fromSize(surface.size()), .{});
        if (surface.size().width == 0 or surface.size().height == 0) return;
        const gauge = tui.widget.Gauge{ .value = self.elapsed_ns, .total = self.duration_ns };
        var gauge_surface = surface.surface(.{ .x = 0, .y = 0, .width = surface.size().width, .height = 1 });
        try gauge.draw(&gauge_surface);
    }

    pub fn advance(self: *App, now: std.Io.Clock.Timestamp) !tui.widget.Update {
        if (now.clock != .awake) return error.WrongClock;
        const before = self.visibleCells();
        const sampled: u64 = if (now.raw.nanoseconds <= self.start.raw.nanoseconds)
            0
        else
            @intCast(@min(
                now.raw.nanoseconds - self.start.raw.nanoseconds,
                @as(i96, self.duration_ns),
            ));
        self.elapsed_ns = @max(self.elapsed_ns, sampled);
        return if (self.visibleCells() == before) .handled else .redraw;
    }

    pub fn nextDeadline(self: *const App) ?std.Io.Clock.Timestamp {
        if (self.size.width == 0 or self.size.height == 0 or self.elapsed_ns >= self.duration_ns) return null;
        const next_step = ((@as(u128, self.elapsed_ns) / cadence_ns) + 1) * cadence_ns;
        const next_elapsed: u64 = @intCast(@min(next_step, self.duration_ns));
        return .{
            .raw = .{ .nanoseconds = self.start.raw.nanoseconds + @as(i96, next_elapsed) },
            .clock = .awake,
        };
    }

    pub fn arm(self: *const App, runtime: *tui.runtime.Posix, timer_id: tui.runtime.TimerId) !void {
        if (self.nextDeadline()) |deadline| {
            _ = try runtime.setTimer(timer_id, deadline);
        } else {
            _ = runtime.cancelTimer(timer_id);
        }
    }

    fn visibleCells(self: *const App) u16 {
        if (self.size.width == 0) return 0;
        return @intCast((@as(u128, self.elapsed_ns) * self.size.width) / self.duration_ns);
    }
};

pub fn timestamp(nanoseconds: i96) std.Io.Clock.Timestamp {
    return .{ .raw = .{ .nanoseconds = nanoseconds }, .clock = .awake };
}
