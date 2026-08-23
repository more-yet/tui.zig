pub const Event = @import("input/event.zig").Event;
pub const OwnedEvent = @import("input/event.zig").OwnedEvent;
pub const OwnedEventError = @import("input/event.zig").OwnedEventError;
pub const Key = @import("input/event.zig").Key;
pub const KeyCode = @import("input/event.zig").KeyCode;
pub const KeyAction = @import("input/event.zig").KeyAction;
pub const Modifiers = @import("input/event.zig").Modifiers;
pub const Mouse = @import("input/event.zig").Mouse;
pub const Parser = @import("input/parser.zig").Parser;

test {
    _ = @import("input/event.zig");
    _ = @import("input/parser.zig");
}
