const std = @import("std");
const tui = @import("tui");

test "headless assertions report each public failure" {
    const App = struct {
        pub fn draw(_: *@This(), surface: *tui.render.Surface) !void {
            _ = try surface.putText(
                .{ .x = 0, .y = 0 },
                "ab",
                .{ .foreground = .{ .indexed = 2 } },
                .narrow,
            );
        }
    };

    var screen = try tui.testing.Headless.init(std.testing.allocator, .{ .width = 4, .height = 1 }, .{});
    defer screen.deinit();
    var app: App = .{};
    _ = try screen.render(&app, .{});

    try std.testing.expectError(
        error.OutOfBounds,
        screen.expectCell(.{ .x = 4, .y = 0 }, .{}),
    );
    try std.testing.expectError(
        error.GlyphMismatch,
        screen.expectCell(.{ .x = 0, .y = 0 }, .{ .glyph = "z" }),
    );
    try std.testing.expectError(
        error.StyleMismatch,
        screen.expectCell(.{ .x = 0, .y = 0 }, .{ .glyph = "a" }),
    );
    try std.testing.expectError(
        error.WidthMismatch,
        screen.expectCell(.{ .x = 0, .y = 0 }, .{
            .glyph = "a",
            .style = .{ .foreground = .{ .indexed = 2 } },
            .width = .wide,
        }),
    );
    try std.testing.expectError(
        error.InvalidExpectedText,
        screen.expectText(.{ .x = 0, .y = 0 }, "\xC0\x80"),
    );
    try std.testing.expectError(error.TrailingContent, screen.expectRow(0, "a"));
}

test "headless finish and abort forward parser lifecycle events" {
    const App = struct {
        malformed: usize = 0,
        escapes: usize = 0,

        pub fn draw(_: *@This(), _: *tui.render.Surface) void {}

        pub fn handle(self: *@This(), event: tui.input.Event) tui.widget.Update {
            switch (event) {
                .malformed => self.malformed += 1,
                .key => |key| if (key.code == .escape) {
                    self.escapes += 1;
                },
                else => {},
            }
            return .handled;
        }
    };

    var screen = try tui.testing.Headless.init(std.testing.allocator, .{ .width = 2, .height = 1 }, .{});
    defer screen.deinit();
    var app: App = .{};

    try screen.feed(&app, "\x1b[12");
    try screen.abortInput(&app);
    try std.testing.expectEqual(@as(usize, 1), app.malformed);
    try screen.feed(&app, "\x1b");
    try screen.finishInput(&app);
    try std.testing.expectEqual(@as(usize, 1), app.escapes);
}

test "driver supports void draw and an application without handle" {
    const App = struct {
        draws: usize = 0,

        pub fn draw(self: *@This(), surface: *tui.render.Surface) void {
            self.draws += 1;
            _ = surface;
        }
    };

    var renderer = try tui.render.Renderer.init(std.testing.allocator, .{ .width = 2, .height = 1 }, .{});
    defer renderer.deinit();
    var driver: tui.app.Driver = .{};
    var app: App = .{};
    var output_buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);

    try std.testing.expectEqual(tui.widget.Update.ignored, driver.dispatch(&app, .focus_in));
    _ = try driver.refresh(&renderer, &app, &output, .{});
    try std.testing.expectEqual(@as(usize, 1), app.draws);
    driver.schedule(.handled);
    try std.testing.expectEqual(tui.widget.Update.ignored, driver.pending());
    driver.schedule(.redraw);
    try std.testing.expectEqual(tui.widget.Update.redraw, driver.pending());
}

test "text input handles disabled state modifiers and paste capacity" {
    var storage: [3]u8 = undefined;
    var field = try tui.widget.TextInput.init(&storage, "");
    field.enabled = false;
    try std.testing.expectEqual(.ignored, field.handle(.paste_start));
    try std.testing.expectEqual(.ignored, field.handle(.{ .paste_chunk = "x" }));
    try std.testing.expectEqualStrings("", field.value());

    field.enabled = true;
    try std.testing.expectEqual(.ignored, field.handle(.{ .key = .{
        .code = .left,
        .action = .release,
    } }));
    try std.testing.expectEqual(.ignored, field.handle(.{ .key = .{
        .code = .left,
        .modifiers = .{ .alt = true },
    } }));
    try std.testing.expectEqual(.redraw, field.handle(.{ .key = .{ .code = .{ .codepoint = 'a' } } }));
    try std.testing.expectEqualStrings("a", field.value());

    try std.testing.expectEqual(.handled, field.handle(.paste_start));
    try std.testing.expectEqual(.redraw, field.handle(.{ .paste_chunk = "bcdef" }));
    try std.testing.expectEqualStrings("abc", field.value());
    try std.testing.expectEqual(.handled, field.handle(.{ .paste_chunk = "z" }));
    try std.testing.expectEqualStrings("abc", field.value());
    try std.testing.expectEqual(.handled, field.handle(.malformed));
    try std.testing.expectEqual(error.CapacityExceeded, field.takeFailure().?);
    try std.testing.expect(field.takeFailure() == null);
    try std.testing.expectEqual(.ignored, field.handle(.{ .paste_chunk = "z" }));
}

test "text area integrates headless input drawing caret and edit failures" {
    const App = struct {
        area: tui.widget.TextArea,

        pub fn layout(self: *@This(), size: tui.render.Size) void {
            _ = self.area.layout(size);
        }

        pub fn draw(self: *@This(), surface: *tui.render.Surface) !void {
            try self.area.draw(surface);
        }

        pub fn handle(self: *@This(), event: tui.input.Event) tui.widget.Update {
            return self.area.handle(event);
        }
    };

    var storage: [4]u8 = undefined;
    var model = try tui.editor.Model.init(&storage, "");
    var app = App{ .area = .{ .model = &model, .focused = true } };
    var screen = try tui.testing.Headless.init(std.testing.allocator, .{ .width = 4, .height = 2 }, .{});
    defer screen.deinit();

    _ = try screen.render(&app, .{});
    try screen.feed(&app, "ab\rx");
    _ = try screen.render(&app, .{});
    try screen.expectRow(0, "ab");
    try screen.expectCell(.{ .x = 1, .y = 1 }, .{
        .style = .{ .attributes = .{ .reverse = true } },
    });

    try screen.feed(&app, "y");
    try std.testing.expectEqual(.handled, app.area.handle(.paste_start));
    try std.testing.expectEqual(.handled, app.area.handle(.malformed));
    try std.testing.expectEqual(error.CapacityExceeded, app.area.takeFailure().?);
    try std.testing.expectEqual(@as(?tui.editor.EditError, null), app.area.takeFailure());
    try std.testing.expectEqualStrings("ab\nx", model.value());
}

test "display widgets handle small areas and clamped values" {
    var renderer = try tui.render.Renderer.init(std.testing.allocator, .{ .width = 10, .height = 3 }, .{});
    defer renderer.deinit();
    var frame = renderer.frame();
    var root = frame.surface(tui.render.Rect.fromSize(renderer.size()));

    var tiny_panel_surface = root.surface(.{ .x = 0, .y = 0, .width = 1, .height = 1 });
    const panel = tui.widget.Panel{ .background = .{ .normal = .{ .background = .{ .indexed = 4 } } } };
    try panel.draw(&tiny_panel_surface);

    var gauge_surface = root.surface(.{ .x = 0, .y = 1, .width = 10, .height = 1 });
    const full = tui.widget.Gauge{ .value = 20, .total = 10 };
    try full.draw(&gauge_surface);
    var x: u16 = 0;
    while (x < 10) : (x += 1) {
        try std.testing.expectEqual(@as(u32, '#'), renderer.desiredCell(.{ .x = x, .y = 1 }).?.glyph);
    }

    const half = tui.widget.Gauge{ .value = 5, .total = 10 };
    var half_surface = root.surface(.{ .x = 0, .y = 2, .width = 10, .height = 1 });
    try half.draw(&half_surface);
    try std.testing.expectEqual(@as(u32, '#'), renderer.desiredCell(.{ .x = 4, .y = 2 }).?.glyph);
    try std.testing.expectEqual(@as(u32, '-'), renderer.desiredCell(.{ .x = 5, .y = 2 }).?.glyph);
}
