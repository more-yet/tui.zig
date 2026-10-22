//! Terminal UI primitives with caller-owned storage and I/O.
//! Start with `editor.Model`, `widget.TextInput`, and `render.Renderer`.

pub const text = @import("text.zig");
pub const secureZero = @import("core/memory.zig").secureZero;
pub const render = @import("render.zig");
pub const graphics = @import("graphics.zig");
pub const terminal = @import("terminal.zig");
pub const input = @import("input.zig");
pub const runtime = @import("runtime.zig");
pub const subprocess = @import("subprocess.zig");
pub const scroll = @import("scroll.zig");
pub const editor = @import("editor/model.zig");
pub const layout = @import("layout.zig");
pub const widget = @import("widget.zig");
pub const focus = @import("ui/focus.zig");
pub const command = @import("ui/command.zig");
pub const theme = @import("ui/theme.zig");
pub const overlay = @import("ui/overlay.zig");
