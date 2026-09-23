pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    alt: bool = false,
    control: bool = false,
    super: bool = false,
    hyper: bool = false,
    meta: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,

    pub inline fn hasNonLock(self: Modifiers) bool {
        return self.shift or self.alt or self.control or self.super or self.hyper or self.meta;
    }
};

pub const KeyAction = enum {
    press,
    repeat,
    release,
};

pub const KeyCode = union(enum) {
    codepoint: u21,
    functional: u21,
    escape,
    enter,
    tab,
    backspace,
    up,
    down,
    left,
    right,
    home,
    end,
    insert,
    delete,
    page_up,
    page_down,
    function: u8,
};

pub const Key = struct {
    code: KeyCode,
    modifiers: Modifiers = .{},
    action: KeyAction = .press,
};

pub const MouseButton = enum {
    none,
    left,
    middle,
    right,
};

pub const MouseAction = enum {
    press,
    release,
    move,
    scroll_up,
    scroll_down,
    scroll_left,
    scroll_right,
};

pub const Mouse = struct {
    x: u16,
    y: u16,
    button: MouseButton,
    action: MouseAction,
    modifiers: Modifiers = .{},
};

pub const CursorPosition = struct {
    row: u16,
    column: u16,
};

pub const TerminalReply = struct {
    kind: enum { csi, osc, apc },
    final: u8,
    raw: []const u8,
};

/// Slice payload lifetime is defined by the producer. Parser results remain
/// valid until the next parser operation; use `OwnedEvent` to retain them.
pub const Event = union(enum) {
    key: Key,
    text: []const u8,
    mouse: Mouse,
    paste_start,
    paste_chunk: []const u8,
    paste_end,
    focus_in,
    focus_out,
    cursor_position: CursorPosition,
    terminal_reply: TerminalReply,
    malformed,
};

pub const OwnedEventError = error{PayloadTooLarge};

/// Owns the slice payload of an `Event` in fixed inline storage.
pub fn OwnedEvent(comptime max_payload_bytes: usize) type {
    return struct {
        const Self = @This();

        pub const payload_capacity = max_payload_bytes;

        metadata: Event,
        payload_len: usize = 0,
        payload: [max_payload_bytes]u8 = undefined,

        pub fn init(value: Event) OwnedEventError!Self {
            var result = Self{ .metadata = value };
            const bytes = switch (value) {
                .text, .paste_chunk => |payload| payload,
                .terminal_reply => |reply| reply.raw,
                else => return result,
            };
            if (bytes.len > max_payload_bytes) return error.PayloadTooLarge;
            @memcpy(result.payload[0..bytes.len], bytes);
            result.payload_len = bytes.len;
            result.metadata = switch (value) {
                .text => .{ .text = &.{} },
                .paste_chunk => .{ .paste_chunk = &.{} },
                .terminal_reply => |reply| .{ .terminal_reply = .{
                    .kind = reply.kind,
                    .final = reply.final,
                    .raw = &.{},
                } },
                else => unreachable,
            };
            return result;
        }

        /// The returned payload borrows this value until it is moved or overwritten.
        pub fn borrow(self: *const Self) Event {
            return switch (self.metadata) {
                .text => .{ .text = self.payload[0..self.payload_len] },
                .paste_chunk => .{ .paste_chunk = self.payload[0..self.payload_len] },
                .terminal_reply => |reply| .{ .terminal_reply = .{
                    .kind = reply.kind,
                    .final = reply.final,
                    .raw = self.payload[0..self.payload_len],
                } },
                else => self.metadata,
            };
        }
    };
}
