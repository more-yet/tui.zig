const std = @import("std");
const tui = @import("tui");
const demo_app = @import("demo_app");

test "portfolio renders tabs, adapts its palette, and supports mouse selection" {
    var input_storage: [256]u8 = undefined;
    var editor_storage: [1024]u8 = undefined;
    var editor = try tui.editor.Model.init(&editor_storage, "é界 text in this multiline editor.");
    var app = try demo_app.DemoApp.init(&input_storage, &editor);
    var screen = try tui.testing.Headless.init(std.testing.allocator, .{ .width = 120, .height = 30 }, .{});
    defer screen.deinit();

    _ = try screen.render(&app, .{});
    try expectAnsi16Palette(&screen);
    try screen.expectText(.{ .x = 2, .y = 0 }, "tui.zig");
    try screen.expectText(.{ .x = 13, .y = 0 }, "OVERVIEW");
    try screen.expectText(.{ .x = 24, .y = 0 }, "WIDGETS");
    try screen.expectText(.{ .x = 2, .y = 1 }, "frame 0.000 ms");
    try screen.expectText(.{ .x = 0, .y = 2 }, "›");
    try screen.expectText(.{ .x = 2, .y = 8 }, "▁");

    try std.testing.expect(app.setTerminalBackground(.{ .red = 0xffff, .green = 0xffff, .blue = 0xffff }));
    screen.driver.schedule(.redraw);
    _ = try screen.render(&app, .{});
    try expectAnsi16Palette(&screen);
    try expectIndexedForeground(&screen, .{ .x = 2, .y = 0 }, 4);
    try expectIndexedForeground(&screen, .{ .x = 2, .y = 2 }, 6);
    try expectIndexedForeground(&screen, .{ .x = 82, .y = 2 }, 5);
    try expectIndexedForeground(&screen, .{ .x = 2, .y = 16 }, 2);
    try std.testing.expect(!app.setTerminalBackground(.{ .red = 0xffff, .green = 0xffff, .blue = 0xffff }));
    try std.testing.expect(app.setTerminalBackground(.{ .red = 0, .green = 0, .blue = 0 }));
    screen.driver.schedule(.redraw);
    _ = try screen.render(&app, .{});
    try expectIndexedForeground(&screen, .{ .x = 2, .y = 0 }, 12);

    try std.testing.expectEqual(tui.widget.Update.redraw, screen.dispatch(&app, .{ .key = .{ .code = .{ .codepoint = '2' } } }));
    _ = try screen.render(&app, .{});
    try screen.expectText(.{ .x = 2, .y = 2 }, "Demo preferences");
    try screen.expectText(.{ .x = 25, .y = 4 }, "Session label");
    try std.testing.expectEqualStrings("Lovelace", app.text_input.selectedText().?);
    try std.testing.expectEqual(tui.widget.Update.redraw, screen.dispatch(&app, .{ .mouse = .{
        .x = 29,
        .y = 5,
        .button = .left,
        .action = .press,
    } }));
    try std.testing.expectEqual(tui.widget.Update.redraw, screen.dispatch(&app, .{ .mouse = .{
        .x = 37,
        .y = 5,
        .button = .left,
        .action = .move,
    } }));
    try std.testing.expectEqual(tui.widget.Update.redraw, screen.dispatch(&app, .{ .mouse = .{
        .x = 37,
        .y = 5,
        .button = .none,
        .action = .release,
    } }));
    try std.testing.expectEqualStrings("Lovelace", app.text_input.selectedText().?);

    try std.testing.expectEqual(tui.widget.Update.redraw, screen.dispatch(&app, .{ .key = .{
        .code = .{ .codepoint = '4' },
        .modifiers = .{ .alt = true },
    } }));
    _ = try screen.render(&app, .{});
    try std.testing.expectEqual(tui.widget.Update.redraw, screen.dispatch(&app, .{ .mouse = .{
        .x = 2,
        .y = 4,
        .button = .left,
        .action = .press,
    } }));
    try std.testing.expectEqual(tui.widget.Update.redraw, screen.dispatch(&app, .{ .mouse = .{
        .x = 5,
        .y = 4,
        .button = .left,
        .action = .move,
    } }));
    try std.testing.expectEqual(tui.widget.Update.redraw, screen.dispatch(&app, .{ .mouse = .{
        .x = 5,
        .y = 4,
        .button = .none,
        .action = .release,
    } }));
    try std.testing.expectEqualStrings("é界", editor.selectedText().?);

    try std.testing.expectEqual(tui.widget.Update.handled, screen.dispatch(&app, .{ .key = .{
        .code = .{ .codepoint = 'q' },
        .modifiers = .{ .control = true },
    } }));
    try std.testing.expect(app.quit);
}

test "portfolio classifies terminal background luminance" {
    try std.testing.expectEqual(
        demo_app.ColorScheme.dark,
        demo_app.colorSchemeForBackground(.{ .red = 0, .green = 0, .blue = 0 }),
    );
    try std.testing.expectEqual(
        demo_app.ColorScheme.light,
        demo_app.colorSchemeForBackground(.{ .red = 0xffff, .green = 0xffff, .blue = 0xffff }),
    );
}

test "portfolio routes a complete keyboard and mouse interaction" {
    var input_storage: [256]u8 = undefined;
    var editor_storage: [1024]u8 = undefined;
    var editor = try tui.editor.Model.init(&editor_storage, "é界 editable text");
    var app = try demo_app.DemoApp.init(&input_storage, &editor);
    var screen = try tui.testing.Headless.init(std.testing.allocator, .{ .width = 160, .height = 33 }, .{});
    defer screen.deinit();

    _ = try screen.render(&app, .{});
    try screen.expectText(.{ .x = 2, .y = 0 }, "tui.zig");
    _ = screen.dispatch(&app, .{ .key = .{ .code = .{ .codepoint = ' ' } } });
    try std.testing.expect(app.chart_paused);
    _ = screen.dispatch(&app, .{ .key = .{ .code = .{ .codepoint = ' ' } } });
    try std.testing.expect(!app.chart_paused);

    _ = screen.dispatch(&app, .{ .mouse = .{
        .x = 23,
        .y = 0,
        .button = .left,
        .action = .press,
    } });
    _ = try screen.render(&app, .{});
    try screen.expectText(.{ .x = 45, .y = 4 }, "Session label");

    _ = screen.dispatch(&app, .{ .key = .{ .code = .tab } });
    _ = screen.dispatch(&app, .{ .key = .{ .code = .{ .codepoint = ' ' } } });
    try std.testing.expect(!app.highlight_selection);
    _ = screen.dispatch(&app, .{ .key = .{ .code = .tab } });
    _ = screen.dispatch(&app, .{ .key = .{ .code = .tab } });
    _ = screen.dispatch(&app, .{ .key = .{ .code = .enter } });
    try std.testing.expectEqual(@as(?u32, 1), app.spacing_selection);
    _ = screen.dispatch(&app, .{ .key = .{ .code = .tab } });
    _ = screen.dispatch(&app, .{ .key = .{ .code = .enter } });
    try std.testing.expect(app.preferences_saved);
    _ = screen.dispatch(&app, .{ .key = .{
        .code = .{ .codepoint = '3' },
        .modifiers = .{ .alt = true },
    } });
    _ = try screen.render(&app, .{});
    try screen.expectText(.{ .x = 2, .y = 2 }, "Project tree");

    _ = screen.dispatch(&app, .{ .key = .{ .code = .{ .codepoint = ' ' } } });
    try std.testing.expect(!app.tree_provider.src_expanded);
    _ = screen.dispatch(&app, .{ .mouse = .{
        .x = 82,
        .y = 6,
        .button = .left,
        .action = .press,
    } });
    try std.testing.expectEqual(@as(?usize, 2), app.list_state.selected);
    _ = screen.dispatch(&app, .{ .key = .{ .code = .tab } });
    _ = screen.dispatch(&app, .{ .key = .{ .code = .down } });
    try std.testing.expectEqual(@as(?usize, 1), app.table_state.selected);
    _ = screen.dispatch(&app, .{ .key = .{ .code = .tab } });
    _ = screen.dispatch(&app, .{ .key = .{ .code = .down } });
    _ = screen.dispatch(&app, .{ .key = .{ .code = .down } });
    _ = screen.dispatch(&app, .{ .key = .{ .code = .enter } });
    try std.testing.expectEqual(tui.widget.TaskStatus.succeeded, app.task_provider.statuses[2]);

    _ = screen.dispatch(&app, .{ .key = .{
        .code = .{ .codepoint = '4' },
        .modifiers = .{ .alt = true },
    } });
    _ = screen.dispatch(&app, .{ .key = .{ .code = .{ .function = 2 } } });
    try std.testing.expect(app.editor_soft_wrap);
    _ = screen.dispatch(&app, .{ .text = "!" });
    try std.testing.expect(std.mem.endsWith(u8, editor.value(), "!"));

    _ = screen.dispatch(&app, .{ .key = .{
        .code = .{ .codepoint = '5' },
        .modifiers = .{ .alt = true },
    } });
    try std.testing.expectEqual(tui.widget.Update.redraw, screen.dispatch(&app, .focus_in));
    _ = try screen.render(&app, .{});
    try screen.expectText(.{ .x = 2, .y = 2 }, "Display support");
    try screen.expectText(.{ .x = 82, .y = 2 }, "Active input");
    try screen.expectText(.{ .x = 2, .y = 17 }, "Session activity");
    try screen.expectText(.{ .x = 82, .y = 5 }, "Window focused");
    try std.testing.expectEqual(tui.widget.Update.redraw, screen.dispatch(&app, .{ .mouse = .{
        .x = 22,
        .y = 19,
        .button = .none,
        .action = .scroll_up,
    } }));
    try std.testing.expect(!app.log_viewport.follow);
}

test "portfolio centers its expanded workspace on large terminals" {
    var input_storage: [256]u8 = undefined;
    var editor_storage: [1024]u8 = undefined;
    var editor = try tui.editor.Model.init(&editor_storage, "centered workspace");
    var app = try demo_app.DemoApp.init(&input_storage, &editor);
    var screen = try tui.testing.Headless.init(std.testing.allocator, .{ .width = 200, .height = 80 }, .{});
    defer screen.deinit();

    _ = try screen.render(&app, .{});
    try screen.expectRow(0, "");
    try screen.expectText(.{ .x = 22, .y = 23 }, "tui.zig");
    try screen.expectText(.{ .x = 33, .y = 23 }, "OVERVIEW");
    try screen.expectRow(70, "");
}

fn expectAnsi16Palette(screen: *const tui.testing.Headless) !void {
    for (0..screen.size().height) |y| {
        for (0..screen.size().width) |x| {
            var glyph_storage: [tui.text.max_grapheme_bytes]u8 = undefined;
            const cell = screen.cell(.{ .x = @intCast(x), .y = @intCast(y) }, &glyph_storage).?;
            try std.testing.expect(isAnsi16Color(cell.style.foreground));
            try std.testing.expect(isAnsi16Color(cell.style.background));
        }
    }
}

fn isAnsi16Color(color: tui.render.Color) bool {
    return switch (color) {
        .default => true,
        .indexed => |index| index < 16,
        .rgb => false,
    };
}

fn expectIndexedForeground(screen: *const tui.testing.Headless, point: tui.render.Point, expected: u8) !void {
    var glyph_storage: [tui.text.max_grapheme_bytes]u8 = undefined;
    const cell = screen.cell(point, &glyph_storage).?;
    switch (cell.style.foreground) {
        .indexed => |index| try std.testing.expectEqual(expected, index),
        else => return error.ExpectedIndexedForeground,
    }
}
