const std = @import("std");
const tui = @import("tui");

pub const Decoder = tui.scroll.LineDecoder(128);
pub const Ring = Decoder.Ring;

pub const App = struct {
    decoder: Decoder = .{},
    ring: *Ring,
    viewport: tui.scroll.Viewport = .{},
    rejected_rows: usize = 0,
    size: tui.render.Size = .{ .width = 0, .height = 0 },

    pub fn layout(self: *App, size: tui.render.Size) void {
        self.size = size;
        _ = self.viewport.update(self.ring.count(), bodyRect(size).height, 0);
    }

    pub fn feed(self: *App, bytes: []const u8) error{BatchTooLarge}!tui.scroll.DecodeResult {
        if (bytes.len > 4096) return error.BatchTooLarge;
        const result = self.decoder.feed(self.ring, bytes);
        self.observe(result);
        return result;
    }

    pub fn finish(self: *App) tui.scroll.DecodeResult {
        const result = self.decoder.finish(self.ring);
        self.observe(result);
        return result;
    }

    pub fn handle(self: *App, event: tui.input.Event) tui.widget.Update {
        const geometry = contentGeometry(self.size);
        var view = tui.widget.Scrollback(Ring){
            .provider = self.ring,
            .viewport = &self.viewport,
            .bounds = geometry.content,
        };
        return view.handle(event);
    }

    pub fn draw(self: *App, surface: *tui.render.Surface) !void {
        try surface.fill(tui.render.Rect.fromSize(surface.size()), .{});
        if (surface.size().height == 0) return;
        const warning_role = tui.theme.Role{ .normal = .{ .foreground = .{ .indexed = 11 }, .attributes = .{ .bold = true } } };
        const warning = tui.widget.Label{ .text = "WARNING: review output", .role = warning_role };
        var warning_surface = surface.surface(.{ .x = 0, .y = 0, .width = surface.size().width, .height = 1 });
        try warning.draw(&warning_surface);

        const geometry = contentGeometry(surface.size());
        if (!geometry.content.isEmpty()) {
            var view = tui.widget.Scrollback(Ring){
                .provider = self.ring,
                .viewport = &self.viewport,
                .bounds = geometry.content,
            };
            var content_surface = surface.surface(geometry.content);
            try view.draw(&content_surface);
            if (!geometry.scrollbar.isEmpty()) {
                const bar = tui.widget.Scrollbar{
                    .total_rows = self.ring.count(),
                    .visible_rows = geometry.content.height,
                    .top_row = self.viewport.visibleRange(self.ring.count(), geometry.content.height).start,
                };
                var bar_surface = surface.surface(geometry.scrollbar);
                try bar.draw(&bar_surface);
            }
        }

        if (surface.size().height > 1) {
            var footer_buffer: [48]u8 = undefined;
            const text = if (self.rejected_rows == 0)
                "All rows accepted"
            else
                std.fmt.bufPrint(&footer_buffer, "{d} rejected row{s}", .{ self.rejected_rows, if (self.rejected_rows == 1) "" else "s" }) catch unreachable;
            const footer = tui.widget.Label{ .text = text, .role = if (self.rejected_rows == 0) .{} else warning_role };
            var footer_surface = surface.surface(.{
                .x = 0,
                .y = surface.size().height - 1,
                .width = surface.size().width,
                .height = 1,
            });
            try footer.draw(&footer_surface);
        }
    }

    fn observe(self: *App, result: tui.scroll.DecodeResult) void {
        self.rejected_rows +|= result.rejectedRows();
        _ = self.viewport.update(self.ring.count(), bodyRect(self.size).height, result.dropped_rows);
    }
};

fn bodyRect(size: tui.render.Size) tui.render.Rect {
    return .{ .x = 0, .y = @intFromBool(size.height != 0), .width = size.width, .height = size.height -| 2 };
}

fn contentGeometry(size: tui.render.Size) struct { content: tui.render.Rect, scrollbar: tui.render.Rect } {
    const body = bodyRect(size);
    const reserve_bar = body.width >= 2 and body.height != 0;
    const content_width = body.width - @intFromBool(reserve_bar);
    return .{
        .content = .{ .x = body.x, .y = body.y, .width = content_width, .height = body.height },
        .scrollbar = if (reserve_bar)
            .{ .x = body.x + content_width, .y = body.y, .width = 1, .height = body.height }
        else
            .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    };
}
