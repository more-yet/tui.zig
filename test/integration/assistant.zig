const std = @import("std");
const tui = @import("tui");
const assistant_demo = @import("assistant_demo");

test "coding assistant reference composes prompt transcript and streaming" {
    var slots: [16]assistant_demo.Ring.Slot = undefined;
    var ring = assistant_demo.Ring.init(&slots);
    var prompt_storage: [128]u8 = undefined;
    var prompt = try tui.editor.Model.init(&prompt_storage, "");
    var app = try assistant_demo.AssistantApp.init(&ring, &prompt);
    var screen = try tui.testing.Headless.init(std.testing.allocator, .{ .width = 80, .height = 12 }, .{});
    defer screen.deinit();

    _ = try screen.render(&app, .{});
    try screen.feed(&app, "hello");
    try std.testing.expectEqual(
        tui.widget.Update.redraw,
        screen.dispatch(&app, .{ .key = .{
            .code = .{ .codepoint = 's' },
            .modifiers = .{ .control = true },
        } }),
    );
    while (app.streaming) _ = app.streamStep();
    _ = try screen.render(&app, .{});

    try screen.expectText(.{ .x = 0, .y = 1 }, "assistant: tui.zig coding-assistant reference");
    try screen.expectText(.{ .x = 0, .y = 2 }, "you:");
    try screen.expectText(.{ .x = 0, .y = 3 }, "hello");
    try screen.expectText(.{ .x = 0, .y = 5 }, "assistant: received the prompt safely");
    try screen.expectText(.{ .x = 0, .y = 6 }, "assistant: streamed output uses bounded chunks");
    try std.testing.expectEqualStrings("", prompt.value());

    try std.testing.expectEqual(tui.widget.Update.redraw, screen.dispatch(&app, .{ .key = .{ .code = .tab } }));
    try std.testing.expect(app.transcript_focused);
    try std.testing.expectEqual(tui.widget.Update.handled, screen.dispatch(&app, .{ .key = .{ .code = .escape } }));
    try std.testing.expect(app.quit);
}
