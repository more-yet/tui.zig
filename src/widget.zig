const std = @import("std");
const input = @import("input.zig");
const render = @import("render.zig");
const display = @import("widget/display.zig");
const form = @import("widget/form.zig");
const text_input = @import("widget/text_input.zig");
const text_area = @import("widget/text_area.zig");
const scrollback = @import("widget/scrollback.zig");
const data = @import("widget/data.zig");
const navigation = @import("widget/navigation.zig");

pub const Update = @import("widget/update.zig").Update;
pub const Label = display.Label;
pub const Paragraph = display.Paragraph;
pub const Panel = display.Panel;
pub const Gauge = display.Gauge;
pub const Button = form.Button;
pub const Checkbox = form.Checkbox;
pub const Radio = form.Radio;
pub const TextInput = text_input.TextInput;
pub const TextInputInitError = text_input.InitError;
pub const TextInputEditError = text_input.EditError;
pub const TextInputSelection = text_input.Selection;
pub const TextArea = text_area.TextArea;
pub const Scrollback = scrollback.Scrollback;
pub const ScrollState = data.ScrollState;
pub const Column = data.Column;
pub const List = data.List;
pub const Table = data.Table;
pub const MenuState = navigation.MenuState;
pub const Menu = navigation.Menu;

/// Calls a caller-owned widget's mandatory `draw` method with no runtime dispatch.
pub inline fn draw(widget: anytype, surface: *render.Surface) @TypeOf(widget.draw(surface)) {
    return widget.draw(surface);
}

/// Calls a caller-owned widget's optional `handle` method.
/// Slice payloads in `event` remain valid only for this call.
pub inline fn handle(widget: anytype, event: input.Event) Update {
    const Widget = switch (@typeInfo(@TypeOf(widget))) {
        .pointer => |pointer| pointer.child,
        else => @compileError("widget.handle expects a pointer to caller-owned widget state"),
    };
    if (!@hasDecl(Widget, "handle")) return .ignored;
    return widget.handle(event);
}

test "widget contract is caller-owned and allocation-free" {
    const TestLabel = struct {
        text: []const u8,

        fn draw(self: *const @This(), surface: *render.Surface) !void {
            _ = try surface.putText(.{ .x = 0, .y = 0 }, self.text, .{}, .narrow);
        }
    };

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var renderer = try render.Renderer.init(failing.allocator(), .{ .width = 8, .height = 1 }, .{});
    defer renderer.deinit();
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    var frame = renderer.frame();
    var surface = frame.surface(.{ .x = 2, .y = 0, .width = 4, .height = 1 });
    const label = TestLabel{ .text = "fast" };
    try draw(&label, &surface);

    try std.testing.expectEqual(@as(u32, 'f'), renderer.desiredCell(.{ .x = 2, .y = 0 }).?.glyph);
    try std.testing.expectEqual(Update.ignored, handle(&label, .focus_in));
    try std.testing.expect(!failing.has_induced_failure);
}

test "widget updates compose without dispatch" {
    const Control = struct {
        active: bool = false,

        fn draw(_: *const @This(), _: *render.Surface) void {}

        fn handle(self: *@This(), event: input.Event) Update {
            switch (event) {
                .key => |key| switch (key.code) {
                    .enter => {
                        self.active = !self.active;
                        return .redraw;
                    },
                    else => {},
                },
                else => {},
            }
            return .ignored;
        }
    };

    var control: Control = .{};
    try std.testing.expectEqual(Update.redraw, handle(&control, .{ .key = .{ .code = .enter } }));
    try std.testing.expect(control.active);
    try std.testing.expectEqual(Update.ignored, handle(&control, .focus_out));
    try std.testing.expectEqual(Update.relayout, Update.handled.merge(.relayout));
    try std.testing.expect(Update.relayout.isHandled());
    try std.testing.expect(Update.redraw.needsRedraw());
    try std.testing.expect(Update.relayout.needsLayout());
}

test {
    _ = display;
    _ = form;
    _ = text_input;
    _ = text_area;
    _ = scrollback;
    _ = data;
    _ = navigation;
}
