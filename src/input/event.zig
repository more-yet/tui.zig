const std = @import("std");
const memory = @import("../core/memory.zig");

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
    shifted_codepoint: ?u21 = null,
    base_layout_codepoint: ?u21 = null,
    text: []const u8 = &.{},
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

/// Parser payloads expire on its next operation. Use `OwnedEvent` to retain a copy.
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
                .key => |key| key.text,
                .text, .paste_chunk => |payload| payload,
                .terminal_reply => |reply| reply.raw,
                else => return result,
            };
            if (bytes.len > max_payload_bytes) return error.PayloadTooLarge;
            @memcpy(result.payload[0..bytes.len], bytes);
            result.payload_len = bytes.len;
            switch (result.metadata) {
                .key => result.metadata.key.text = &.{},
                .text => result.metadata.text = &.{},
                .paste_chunk => result.metadata.paste_chunk = &.{},
                .terminal_reply => result.metadata.terminal_reply.raw = &.{},
                else => unreachable,
            }
            return result;
        }

        /// Keep this value unmoved and unchanged while using the returned event.
        pub fn borrow(self: *const Self) Event {
            var result = self.metadata;
            switch (result) {
                .key => result.key.text = self.payload[0..self.payload_len],
                .text => result.text = self.payload[0..self.payload_len],
                .paste_chunk => result.paste_chunk = self.payload[0..self.payload_len],
                .terminal_reply => result.terminal_reply.raw = self.payload[0..self.payload_len],
                else => {},
            }
            return result;
        }

        /// Expires all borrowed payloads. Reinitialize before reuse.
        pub fn secureDeinit(self: *Self) void {
            memory.secureZero(std.mem.asBytes(self));
        }
    };
}
