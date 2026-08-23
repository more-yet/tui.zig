const std = @import("std");
const input = @import("input.zig");
const render = @import("render.zig");
const terminal = @import("terminal.zig");
const widget = @import("widget.zig");

pub const Driver = struct {
    layout_pending: bool = true,
    draw_pending: bool = true,
    present_pending: bool = false,
    quit_requested: bool = false,

    pub inline fn pending(self: *const Driver) widget.Update {
        if (self.layout_pending) return .relayout;
        if (self.draw_pending or self.present_pending) return .redraw;
        return .ignored;
    }

    pub inline fn schedule(self: *Driver, update: widget.Update) void {
        self.layout_pending = self.layout_pending or update.needsLayout();
        self.draw_pending = self.draw_pending or update.needsRedraw();
    }

    /// Dispatches immediately because event slice payloads are callback-scoped.
    pub inline fn dispatch(self: *Driver, application: anytype, event: input.Event) widget.Update {
        const update = widget.handle(application, event);
        self.schedule(update);
        return update;
    }

    pub fn resize(self: *Driver, renderer: *render.Renderer, size: render.Size) !bool {
        const current = renderer.size();
        if (current.width == size.width and current.height == size.height) return false;
        try renderer.resize(size);
        self.layout_pending = true;
        self.draw_pending = true;
        return true;
    }

    pub fn refresh(
        self: *Driver,
        renderer: *render.Renderer,
        application: anytype,
        writer: *std.Io.Writer,
        capabilities: terminal.Capabilities,
    ) !render.FrameStats {
        if (self.layout_pending) {
            try callLayout(application, renderer.size());
            self.layout_pending = false;
            self.draw_pending = true;
        }
        if (self.draw_pending) {
            var frame = renderer.frame();
            var surface = frame.surface(render.Rect.fromSize(renderer.size()));
            // Draw errors are not transactional; applications must make retries overwrite partial desired state.
            try callDraw(application, &surface);
            self.draw_pending = false;
        }
        const stats = renderer.present(writer, capabilities) catch |err| {
            self.present_pending = true;
            return err;
        };
        self.present_pending = false;
        return stats;
    }

    pub inline fn requestQuit(self: *Driver) void {
        self.quit_requested = true;
    }

    pub inline fn running(self: *const Driver) bool {
        return !self.quit_requested;
    }
};

fn callLayout(application: anytype, size: render.Size) !void {
    const Application = switch (@typeInfo(@TypeOf(application))) {
        .pointer => |pointer| pointer.child,
        else => @compileError("app.Driver expects a pointer to caller-owned application state"),
    };
    if (!@hasDecl(Application, "layout")) return;
    const Result = @TypeOf(application.layout(size));
    switch (@typeInfo(Result)) {
        .void => application.layout(size),
        .error_union => try application.layout(size),
        else => @compileError("application.layout must return void or an error union of void"),
    }
}

fn callDraw(application: anytype, surface: *render.Surface) !void {
    const Result = @TypeOf(widget.draw(application, surface));
    switch (@typeInfo(Result)) {
        .void => widget.draw(application, surface),
        .error_union => try widget.draw(application, surface),
        else => @compileError("application.draw must return void or an error union of void"),
    }
}

test "application driver schedules dispatch layout draw resize and quit" {
    const Application = struct {
        layouts: u8 = 0,
        draws: u8 = 0,
        value: u8 = 'a',

        pub fn layout(self: *@This(), _: render.Size) void {
            self.layouts += 1;
        }

        pub fn draw(self: *@This(), surface: *render.Surface) !void {
            _ = try surface.putText(.{ .x = 0, .y = 0 }, &.{self.value}, .{}, .narrow);
            self.draws += 1;
        }

        pub fn handle(self: *@This(), event: input.Event) widget.Update {
            if (event == .key) {
                self.value +%= 1;
                return .redraw;
            }
            return .handled;
        }
    };

    var allocator_state = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var renderer = try render.Renderer.init(allocator_state.allocator(), .{ .width = 4, .height = 2 }, .{});
    defer renderer.deinit();
    var output_buffer: [256]u8 = undefined;
    var output = std.Io.Writer.Discarding.init(&output_buffer);
    var application: Application = .{};
    var driver: Driver = .{};

    allocator_state.fail_index = allocator_state.alloc_index;
    allocator_state.resize_fail_index = allocator_state.resize_index;
    _ = try driver.refresh(&renderer, &application, &output.writer, .{});
    try std.testing.expectEqual(@as(u8, 1), application.layouts);
    try std.testing.expectEqual(@as(u8, 1), application.draws);
    try std.testing.expectEqual(widget.Update.ignored, driver.pending());
    _ = try driver.refresh(&renderer, &application, &output.writer, .{});
    try std.testing.expectEqual(@as(u8, 1), application.layouts);
    try std.testing.expectEqual(@as(u8, 1), application.draws);
    try std.testing.expectEqual(widget.Update.handled, driver.dispatch(&application, .focus_in));
    try std.testing.expectEqual(widget.Update.ignored, driver.pending());

    try std.testing.expectEqual(
        widget.Update.redraw,
        driver.dispatch(&application, .{ .key = .{ .code = .enter } }),
    );
    _ = try driver.refresh(&renderer, &application, &output.writer, .{});
    try std.testing.expectEqual(@as(u8, 1), application.layouts);
    try std.testing.expectEqual(@as(u8, 2), application.draws);

    try std.testing.expect(!try driver.resize(&renderer, renderer.size()));
    try std.testing.expect(try driver.resize(&renderer, .{ .width = 3, .height = 2 }));
    try std.testing.expectEqual(widget.Update.relayout, driver.pending());
    _ = try driver.refresh(&renderer, &application, &output.writer, .{});
    try std.testing.expectEqual(@as(u8, 2), application.layouts);
    try std.testing.expectEqual(@as(u8, 3), application.draws);
    try std.testing.expect(!allocator_state.has_induced_failure);

    try std.testing.expect(driver.running());
    driver.requestQuit();
    try std.testing.expect(!driver.running());
}

test "application driver retains only the failed refresh stage" {
    const Application = struct {
        fail_layout: bool = true,
        fail_draw: bool = true,

        pub fn layout(self: *@This(), _: render.Size) !void {
            if (self.fail_layout) return error.LayoutFailed;
        }

        pub fn draw(self: *@This(), _: *render.Surface) !void {
            if (self.fail_draw) return error.DrawFailed;
        }
    };

    var renderer = try render.Renderer.init(std.testing.allocator, .{ .width = 2, .height = 1 }, .{});
    defer renderer.deinit();
    var output_buffer: [128]u8 = undefined;
    var output = std.Io.Writer.Discarding.init(&output_buffer);
    var application: Application = .{};
    var driver: Driver = .{};

    try std.testing.expectError(
        error.LayoutFailed,
        driver.refresh(&renderer, &application, &output.writer, .{}),
    );
    try std.testing.expectEqual(widget.Update.relayout, driver.pending());

    application.fail_layout = false;
    try std.testing.expectError(
        error.DrawFailed,
        driver.refresh(&renderer, &application, &output.writer, .{}),
    );
    try std.testing.expectEqual(widget.Update.redraw, driver.pending());

    application.fail_draw = false;
    _ = try driver.refresh(&renderer, &application, &output.writer, .{});
    try std.testing.expectEqual(widget.Update.ignored, driver.pending());
}

test "application driver retains presentation retry without redrawing" {
    const Application = struct {
        draws: u8 = 0,

        pub fn draw(self: *@This(), surface: *render.Surface) !void {
            self.draws += 1;
            _ = try surface.putText(.{ .x = 0, .y = 0 }, "x", .{}, .narrow);
        }
    };

    var renderer = try render.Renderer.init(std.testing.allocator, .{ .width = 2, .height = 1 }, .{});
    defer renderer.deinit();
    var application: Application = .{};
    var driver: Driver = .{};
    var tiny_buffer: [1]u8 = undefined;
    var tiny = std.Io.Writer.fixed(&tiny_buffer);
    try std.testing.expectError(
        error.WriteFailed,
        driver.refresh(&renderer, &application, &tiny, .{}),
    );
    try std.testing.expectEqual(widget.Update.redraw, driver.pending());
    try std.testing.expectEqual(@as(u8, 1), application.draws);

    var output_buffer: [256]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    _ = try driver.refresh(&renderer, &application, &output, .{});
    try std.testing.expectEqual(@as(u8, 1), application.draws);
    try std.testing.expectEqual(widget.Update.ignored, driver.pending());
}
