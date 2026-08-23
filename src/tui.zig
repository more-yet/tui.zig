//! Runtime-neutral, bounded terminal user interface primitives for POSIX systems.

pub const text = @import("text.zig");
pub const render = @import("render.zig");
pub const terminal = @import("terminal.zig");
pub const input = @import("input.zig");
pub const transport = @import("transport.zig");
pub const runtime = @import("runtime.zig");
pub const subprocess = @import("subprocess.zig");
pub const scroll = @import("scroll.zig");
pub const editor = @import("editor.zig");
pub const layout = @import("layout.zig");
pub const widget = @import("widget.zig");
pub const focus = @import("focus.zig");
pub const command = @import("command.zig");
pub const app = @import("app.zig");
pub const theme = @import("theme.zig");
pub const overlay = @import("overlay.zig");
pub const testing = @import("testing.zig");

test {
    _ = text;
    _ = render;
    _ = terminal;
    _ = input;
    _ = transport;
    _ = runtime;
    _ = subprocess;
    _ = scroll;
    _ = editor;
    _ = layout;
    _ = widget;
    _ = focus;
    _ = command;
    _ = app;
    _ = theme;
    _ = overlay;
    _ = testing;
}
