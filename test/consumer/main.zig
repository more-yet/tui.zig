const std = @import("std");
const tui = @import("tui");

pub fn main(init: std.process.Init) !void {
    var renderer = try tui.render.Renderer.init(init.gpa, .{ .width = 16, .height = 3 }, .{});
    defer renderer.deinit();
    var frame = renderer.frame();
    var surface = frame.surface(tui.render.Rect.fromSize(renderer.size()));
    const label = tui.widget.Label{ .text = "tui.zig v1" };
    try label.draw(&surface);

    var input_storage: [32]u8 = undefined;
    var field = try tui.widget.TextInput.init(&input_storage, "ready");
    _ = field.handle(.{ .text = "!" });
    _ = field.takeFailure();

    var editor_storage: [64]u8 = undefined;
    var editor = try tui.editor.Model.init(&editor_storage, "one\ntwo");
    var area = tui.widget.TextArea{ .model = &editor };
    try area.draw(&surface);

    const Decoder = tui.scroll.LineDecoder(32);
    var slots: [4]Decoder.Ring.Slot = undefined;
    var ring = Decoder.Ring.init(&slots);
    var decoder: Decoder = .{};
    _ = decoder.feed(&ring, "safe\r\n");
    var viewport: tui.scroll.Viewport = .{};
    var scrollback = tui.widget.Scrollback(Decoder.Ring){
        .provider = &ring,
        .viewport = &viewport,
        .bounds = tui.render.Rect.fromSize(renderer.size()),
    };
    try scrollback.draw(&surface);
}
