const input = @import("input.zig");
const render = @import("render.zig");
const widget = @import("widget.zig");

pub const Driver = struct {
    const Stage = enum {
        clean,
        draw,
        layout,
    };

    stage: Stage = .layout,

    pub inline fn pending(self: *const Driver) widget.Update {
        return switch (self.stage) {
            .clean => .ignored,
            .draw => .redraw,
            .layout => .relayout,
        };
    }

    pub inline fn schedule(self: *Driver, update: widget.Update) void {
        if (update.needsLayout()) {
            self.stage = .layout;
        } else if (update.needsRedraw() and self.stage == .clean) {
            self.stage = .draw;
        }
    }

    /// Dispatches immediately because event slice payloads are callback-scoped.
    pub inline fn dispatch(self: *Driver, application: anytype, event: input.Event) widget.Update {
        const update = application.handle(event);
        self.schedule(update);
        return update;
    }

    pub fn resize(self: *Driver, renderer: *render.Renderer, size: render.Size) !bool {
        const current = renderer.size();
        if (current.width == size.width and current.height == size.height) return false;
        try renderer.resize(size);
        self.stage = .layout;
        return true;
    }

    /// Runs pending layout and drawing work without performing presentation or I/O.
    pub fn prepare(
        self: *Driver,
        renderer: *render.Renderer,
        application: anytype,
    ) !void {
        if (self.stage != .clean and renderer.isPresenting()) return error.PresentationActive;
        if (self.stage == .layout) {
            try application.layout(renderer.size());
            self.stage = .draw;
        }
        if (self.stage == .draw) {
            var surface = renderer.surface(render.Rect.fromSize(renderer.size()));
            // Draw errors are not transactional; applications must make retries overwrite partial desired state.
            try application.draw(&surface);
            self.stage = .clean;
        }
    }
};
