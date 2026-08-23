const std = @import("std");
const event = @import("event.zig");

const paste_end = "\x1b[201~";

/// Bracketed paste uses an in-band delimiter; it is framing, not authentication for ESC-bearing clipboard data.
pub const Parser = struct {
    pub const max_text_bytes = 4;
    pub const max_terminal_reply_bytes = 96;
    pub const max_paste_chunk_bytes = 256;
    pub const max_event_payload_bytes = @max(max_text_bytes, max_terminal_reply_bytes, max_paste_chunk_bytes);

    pub const Pending = enum {
        none,
        escape,
        sequence,
    };

    const State = enum {
        ground,
        escape,
        csi,
        discard_csi,
        ss3,
        osc,
        osc_escape,
        discard_osc,
        discard_osc_escape,
        paste,
        utf8,
        alt_utf8,
    };

    state: State = .ground,
    sequence: [max_terminal_reply_bytes]u8 = undefined,
    sequence_len: usize = 0,
    utf8: [max_text_bytes]u8 = undefined,
    utf8_len: u3 = 0,
    utf8_expected: u3 = 0,
    paste_buffer: [max_paste_chunk_bytes]u8 = undefined,
    paste_len: usize = 0,
    paste_match: usize = 0,

    pub fn feed(self: *Parser, input: []const u8, sink: anytype) anyerror!void {
        errdefer self.reset();
        for (input) |byte| try self.consume(byte, sink);
        if (self.state == .paste) try self.flushPaste(sink);
    }

    pub fn flushEscape(self: *Parser, sink: anytype) anyerror!void {
        if (self.state != .escape) return;
        errdefer self.reset();
        self.state = .ground;
        try sink.emit(.{ .key = .{ .code = .escape } });
    }

    pub fn finish(self: *Parser, sink: anytype) anyerror!void {
        defer self.reset();
        if (self.state == .escape) {
            self.state = .ground;
            return sink.emit(.{ .key = .{ .code = .escape } });
        }
        if (self.state == .paste) {
            if (self.paste_match > 0) {
                try self.appendPaste(paste_end[0..self.paste_match], sink);
                self.paste_match = 0;
            }
            try self.flushPaste(sink);
        }
        if (self.state != .ground) try sink.emit(.malformed);
    }

    pub fn reset(self: *Parser) void {
        self.state = .ground;
        self.sequence_len = 0;
        self.utf8_len = 0;
        self.utf8_expected = 0;
        self.paste_len = 0;
        self.paste_match = 0;
    }

    pub fn pending(self: *const Parser) Pending {
        return switch (self.state) {
            .ground => .none,
            .escape => .escape,
            else => .sequence,
        };
    }

    /// Cancels a caller-timed incomplete sequence and notifies the active event sink.
    pub fn abort(self: *Parser, sink: anytype) anyerror!void {
        if (self.state == .ground) return;
        self.reset();
        try sink.emit(.malformed);
    }

    fn consume(self: *Parser, byte: u8, sink: anytype) anyerror!void {
        switch (self.state) {
            .ground => try self.consumeGround(byte, sink),
            .escape => try self.consumeEscape(byte, sink),
            .csi => try self.consumeCsi(byte, sink),
            .discard_csi => {
                if (byte == 0x1B) {
                    self.state = .escape;
                    try sink.emit(.malformed);
                } else if (isFinal(byte)) {
                    self.state = .ground;
                    try sink.emit(.malformed);
                }
            },
            .ss3 => try self.consumeSs3(byte, sink),
            .osc => try self.consumeOsc(byte, sink),
            .osc_escape => try self.consumeOscEscape(byte, sink),
            .discard_osc => {
                if (byte == 0x07) {
                    self.state = .ground;
                    try sink.emit(.malformed);
                } else if (byte == 0x1B) {
                    self.state = .discard_osc_escape;
                }
            },
            .discard_osc_escape => {
                if (byte == '\\') {
                    self.state = .ground;
                    try sink.emit(.malformed);
                } else if (byte != 0x1B) {
                    self.state = .discard_osc;
                }
            },
            .paste => try self.consumePaste(byte, sink),
            .utf8, .alt_utf8 => try self.consumeUtf8(byte, sink),
        }
    }

    fn consumeGround(self: *Parser, byte: u8, sink: anytype) anyerror!void {
        switch (byte) {
            0x1B => {
                self.state = .escape;
                return;
            },
            0x0A, 0x0D => {
                try sink.emit(.{ .key = .{ .code = .enter } });
                return;
            },
            0x09 => {
                try sink.emit(.{ .key = .{ .code = .tab } });
                return;
            },
            0x08, 0x7F => {
                try sink.emit(.{ .key = .{ .code = .backspace } });
                return;
            },
            0x00 => {
                try sink.emit(.{ .key = .{
                    .code = .{ .codepoint = ' ' },
                    .modifiers = .{ .control = true },
                } });
                return;
            },
            else => {},
        }
        if (byte >= 0x01 and byte <= 0x1A) {
            try sink.emit(.{ .key = .{
                .code = .{ .codepoint = @as(u21, 'a') + byte - 1 },
                .modifiers = .{ .control = true },
            } });
        } else if (byte >= 0x20 and byte <= 0x7E) {
            const text = [1]u8{byte};
            try sink.emit(.{ .text = &text });
        } else {
            try self.startUtf8(byte, false, sink);
        }
    }

    fn consumeEscape(self: *Parser, byte: u8, sink: anytype) anyerror!void {
        switch (byte) {
            '[' => {
                self.state = .csi;
                self.sequence_len = 0;
                return;
            },
            'O' => {
                self.state = .ss3;
                return;
            },
            ']' => {
                self.state = .osc;
                self.sequence_len = 0;
                return;
            },
            0x1B => {
                try sink.emit(.{ .key = .{ .code = .escape } });
                self.state = .escape;
                return;
            },
            else => {},
        }
        if (byte >= 0x20 and byte <= 0x7E) {
            self.state = .ground;
            try sink.emit(.{ .key = .{
                .code = .{ .codepoint = byte },
                .modifiers = .{ .alt = true },
            } });
        } else {
            try self.startUtf8(byte, true, sink);
        }
    }

    fn consumeCsi(self: *Parser, byte: u8, sink: anytype) anyerror!void {
        if (byte == 0x1B) {
            self.state = .escape;
            try sink.emit(.malformed);
            return;
        }
        if (isFinal(byte)) {
            const parameters = self.sequence[0..self.sequence_len];
            self.state = .ground;
            try self.dispatchCsi(parameters, byte, sink);
            return;
        }
        if (byte < 0x20 or byte > 0x3F) {
            self.state = .ground;
            try sink.emit(.malformed);
            return;
        }
        if (self.sequence_len == self.sequence.len) {
            self.state = .discard_csi;
            return;
        }
        self.sequence[self.sequence_len] = byte;
        self.sequence_len += 1;
    }

    fn consumeSs3(self: *Parser, byte: u8, sink: anytype) anyerror!void {
        if (byte == 0x1B) {
            self.state = .escape;
            try sink.emit(.malformed);
            return;
        }
        self.state = .ground;
        const code: event.KeyCode = switch (byte) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            'P' => .{ .function = 1 },
            'Q' => .{ .function = 2 },
            'R' => .{ .function = 3 },
            'S' => .{ .function = 4 },
            else => {
                try sink.emit(.malformed);
                return;
            },
        };
        try sink.emit(.{ .key = .{ .code = code } });
    }

    fn consumeOsc(self: *Parser, byte: u8, sink: anytype) anyerror!void {
        if (byte == 0x07) {
            self.state = .ground;
            try sink.emit(.{ .terminal_reply = .{
                .kind = .osc,
                .final = byte,
                .raw = self.sequence[0..self.sequence_len],
            } });
            return;
        }
        if (byte == 0x1B) {
            self.state = .osc_escape;
            return;
        }
        if (self.sequence_len == self.sequence.len) {
            self.state = .discard_osc;
            return;
        }
        self.sequence[self.sequence_len] = byte;
        self.sequence_len += 1;
    }

    fn consumeOscEscape(self: *Parser, byte: u8, sink: anytype) anyerror!void {
        if (byte == '\\') {
            self.state = .ground;
            try sink.emit(.{ .terminal_reply = .{
                .kind = .osc,
                .final = byte,
                .raw = self.sequence[0..self.sequence_len],
            } });
            return;
        }
        if (self.sequence_len + 2 > self.sequence.len) {
            self.state = .discard_osc;
            return;
        }
        self.sequence[self.sequence_len] = 0x1B;
        self.sequence[self.sequence_len + 1] = byte;
        self.sequence_len += 2;
        self.state = .osc;
    }

    fn consumePaste(self: *Parser, byte: u8, sink: anytype) anyerror!void {
        if (byte == paste_end[self.paste_match]) {
            self.paste_match += 1;
            if (self.paste_match == paste_end.len) {
                self.paste_match = 0;
                try self.flushPaste(sink);
                self.state = .ground;
                try sink.emit(.paste_end);
            }
            return;
        }

        if (self.paste_match > 0) {
            try self.appendPaste(paste_end[0..self.paste_match], sink);
            self.paste_match = 0;
            if (byte == paste_end[0]) {
                self.paste_match = 1;
                return;
            }
        }
        try self.appendPaste(&[1]u8{byte}, sink);
    }

    fn appendPaste(self: *Parser, bytes: []const u8, sink: anytype) anyerror!void {
        var remaining = bytes;
        while (remaining.len > 0) {
            if (self.paste_len == self.paste_buffer.len) try self.flushPaste(sink);
            const count = @min(remaining.len, self.paste_buffer.len - self.paste_len);
            @memcpy(self.paste_buffer[self.paste_len..][0..count], remaining[0..count]);
            self.paste_len += count;
            remaining = remaining[count..];
        }
    }

    fn flushPaste(self: *Parser, sink: anytype) anyerror!void {
        if (self.paste_len == 0) return;
        try sink.emit(.{ .paste_chunk = self.paste_buffer[0..self.paste_len] });
        self.paste_len = 0;
    }

    fn startUtf8(self: *Parser, byte: u8, alt: bool, sink: anytype) anyerror!void {
        const expected = std.unicode.utf8ByteSequenceLength(byte) catch {
            self.state = .ground;
            try sink.emit(.malformed);
            return;
        };
        if (expected == 1) {
            self.state = .ground;
            try sink.emit(.malformed);
            return;
        }
        self.utf8[0] = byte;
        self.utf8_len = 1;
        self.utf8_expected = expected;
        self.state = if (alt) .alt_utf8 else .utf8;
    }

    fn consumeUtf8(self: *Parser, byte: u8, sink: anytype) anyerror!void {
        if (byte & 0xC0 != 0x80) {
            self.state = .ground;
            self.utf8_len = 0;
            try sink.emit(.malformed);
            try self.consumeGround(byte, sink);
            return;
        }

        self.utf8[self.utf8_len] = byte;
        self.utf8_len += 1;
        if (self.utf8_len != self.utf8_expected) return;

        const bytes = self.utf8[0..self.utf8_len];
        const codepoint = std.unicode.utf8Decode(bytes) catch {
            self.state = .ground;
            self.utf8_len = 0;
            try sink.emit(.malformed);
            return;
        };
        const alt = self.state == .alt_utf8;
        self.state = .ground;
        self.utf8_len = 0;
        if (alt) {
            try sink.emit(.{ .key = .{
                .code = .{ .codepoint = codepoint },
                .modifiers = .{ .alt = true },
            } });
        } else {
            try sink.emit(.{ .text = bytes });
        }
    }

    fn dispatchCsi(self: *Parser, parameters: []const u8, final: u8, sink: anytype) anyerror!void {
        switch (final) {
            'A', 'B', 'C', 'D', 'H', 'F' => {
                const code: event.KeyCode = switch (final) {
                    'A' => .up,
                    'B' => .down,
                    'C' => .right,
                    'D' => .left,
                    'H' => .home,
                    'F' => .end,
                    else => unreachable,
                };
                const modifiers = csiModifiers(parameters) orelse return sink.emit(.malformed);
                try sink.emit(.{ .key = .{ .code = code, .modifiers = modifiers } });
            },
            'I' => try sink.emit(.focus_in),
            'O' => try sink.emit(.focus_out),
            '~' => try self.dispatchTilde(parameters, sink),
            'u' => {
                if (parameters.len == 0 or parameters[0] < '0' or parameters[0] > '9') {
                    try emitReply(parameters, final, sink);
                } else {
                    try dispatchKitty(parameters, sink);
                }
            },
            'M', 'm' => {
                if (parameters.len > 0 and parameters[0] == '<') {
                    try dispatchMouse(parameters[1..], final, sink);
                } else {
                    try emitReply(parameters, final, sink);
                }
            },
            'R' => {
                var fields = std.mem.splitScalar(u8, parameters, ';');
                const row = parseU16(fields.next() orelse "") orelse return emitReply(parameters, final, sink);
                const column = parseU16(fields.next() orelse "") orelse return emitReply(parameters, final, sink);
                if (row == 0 or column == 0 or fields.next() != null) return emitReply(parameters, final, sink);
                try sink.emit(.{ .cursor_position = .{ .row = row - 1, .column = column - 1 } });
            },
            else => try emitReply(parameters, final, sink),
        }
    }

    fn dispatchTilde(self: *Parser, parameters: []const u8, sink: anytype) anyerror!void {
        var fields = std.mem.splitScalar(u8, parameters, ';');
        const number = parseU16(fields.next() orelse "") orelse {
            try sink.emit(.malformed);
            return;
        };
        const modifier_field = fields.next();
        if (fields.next() != null) return sink.emit(.malformed);
        if (number == 200) {
            if (modifier_field != null) return sink.emit(.malformed);
            self.state = .paste;
            self.paste_len = 0;
            self.paste_match = 0;
            try sink.emit(.paste_start);
            return;
        }
        if (number == 201) {
            try sink.emit(.malformed);
            return;
        }

        const code: event.KeyCode = switch (number) {
            1, 7 => .home,
            2 => .insert,
            3 => .delete,
            4, 8 => .end,
            5 => .page_up,
            6 => .page_down,
            11...15 => .{ .function = @intCast(number - 10) },
            17...21 => .{ .function = @intCast(number - 11) },
            23...24 => .{ .function = @intCast(number - 12) },
            else => {
                try emitReply(parameters, '~', sink);
                return;
            },
        };
        const modifiers = if (modifier_field) |field|
            decodeModifiers(parsePrefix(field) orelse return sink.emit(.malformed)) orelse
                return sink.emit(.malformed)
        else
            event.Modifiers{};
        try sink.emit(.{ .key = .{
            .code = code,
            .modifiers = modifiers,
        } });
    }

    fn dispatchKitty(parameters: []const u8, sink: anytype) anyerror!void {
        var fields = std.mem.splitScalar(u8, parameters, ';');
        const codepoint = std.fmt.parseInt(u21, prefix(fields.next() orelse ""), 10) catch {
            try sink.emit(.malformed);
            return;
        };
        var encoded_codepoint: [4]u8 = undefined;
        _ = std.unicode.utf8Encode(codepoint, &encoded_codepoint) catch {
            try sink.emit(.malformed);
            return;
        };
        const modifier_and_action = fields.next();
        if (fields.next() != null) return sink.emit(.malformed);
        var modifiers: event.Modifiers = .{};
        var action: event.KeyAction = .press;
        if (modifier_and_action) |field| {
            var parts = std.mem.splitScalar(u8, field, ':');
            const modifier_bytes = parts.next() orelse unreachable;
            const modifier_value = if (modifier_bytes.len == 0) 1 else parseU16(modifier_bytes) orelse {
                try sink.emit(.malformed);
                return;
            };
            modifiers = decodeModifiers(modifier_value) orelse {
                try sink.emit(.malformed);
                return;
            };
            if (parts.next()) |action_bytes| {
                action = switch (parseU16(action_bytes) orelse 0) {
                    1 => .press,
                    2 => .repeat,
                    3 => .release,
                    else => {
                        try sink.emit(.malformed);
                        return;
                    },
                };
            }
            if (parts.next() != null) return sink.emit(.malformed);
        }
        try sink.emit(.{ .key = .{
            .code = kittyKeyCode(codepoint),
            .modifiers = modifiers,
            .action = action,
        } });
    }

    fn kittyKeyCode(codepoint: u21) event.KeyCode {
        return switch (codepoint) {
            0xE000 => .escape,
            0xE001 => .enter,
            0xE002 => .tab,
            0xE003 => .backspace,
            0xE004 => .insert,
            0xE005 => .delete,
            0xE006 => .left,
            0xE007 => .right,
            0xE008 => .up,
            0xE009 => .down,
            0xE00A => .page_up,
            0xE00B => .page_down,
            0xE00C => .home,
            0xE00D => .end,
            0xE00E...0xF8FF => .{ .functional = codepoint },
            else => .{ .codepoint = codepoint },
        };
    }

    fn dispatchMouse(parameters: []const u8, final: u8, sink: anytype) anyerror!void {
        var fields = std.mem.splitScalar(u8, parameters, ';');
        const encoded = parseU16(fields.next() orelse "") orelse return sink.emit(.malformed);
        const x = parseU16(fields.next() orelse "") orelse return sink.emit(.malformed);
        const y = parseU16(fields.next() orelse "") orelse return sink.emit(.malformed);
        if (x == 0 or y == 0 or fields.next() != null or encoded & ~@as(u16, 0x7F) != 0) {
            return sink.emit(.malformed);
        }

        var modifiers: event.Modifiers = .{};
        modifiers.shift = encoded & 4 != 0;
        modifiers.alt = encoded & 8 != 0;
        modifiers.control = encoded & 16 != 0;
        const motion = encoded & 32 != 0;
        const wheel = encoded & 64 != 0;
        const button_bits = encoded & 3;
        const button: event.MouseButton = switch (button_bits) {
            0 => .left,
            1 => .middle,
            2 => .right,
            else => .none,
        };
        const action: event.MouseAction = if (wheel)
            switch (button_bits) {
                0 => .scroll_up,
                1 => .scroll_down,
                2 => .scroll_left,
                3 => .scroll_right,
                else => unreachable,
            }
        else if (motion)
            .move
        else if (final == 'm' or button_bits == 3)
            .release
        else
            .press;
        try sink.emit(.{ .mouse = .{
            .x = x - 1,
            .y = y - 1,
            .button = if (action == .release or wheel) .none else button,
            .action = action,
            .modifiers = modifiers,
        } });
    }

    fn emitReply(parameters: []const u8, final: u8, sink: anytype) anyerror!void {
        try sink.emit(.{ .terminal_reply = .{
            .kind = .csi,
            .final = final,
            .raw = parameters,
        } });
    }
};

fn isFinal(byte: u8) bool {
    return byte >= 0x40 and byte <= 0x7E;
}

fn prefix(value: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, value, ':') orelse value.len;
    return value[0..end];
}

fn parsePrefix(value: []const u8) ?u16 {
    return parseU16(prefix(value));
}

fn parseU16(value: []const u8) ?u16 {
    return std.fmt.parseInt(u16, value, 10) catch null;
}

fn csiModifiers(parameters: []const u8) ?event.Modifiers {
    var fields = std.mem.splitScalar(u8, parameters, ';');
    _ = fields.next();
    const modifier_field = fields.next() orelse return .{};
    if (fields.next() != null) return null;
    return decodeModifiers(parsePrefix(modifier_field) orelse return null);
}

fn decodeModifiers(encoded: u16) ?event.Modifiers {
    if (encoded == 0 or encoded > @as(u16, std.math.maxInt(u8)) + 1) return null;
    const bits: u8 = @intCast(encoded - 1);
    return @bitCast(bits);
}

test "Kitty keyboard events are independent of input fragmentation" {
    const input = "\x1b[97;6:2u";
    var split: usize = 0;
    while (split <= input.len) : (split += 1) {
        var parser: Parser = .{};
        var collector: Collector = .{};
        try parser.feed(input[0..split], &collector);
        try parser.feed(input[split..], &collector);
        try std.testing.expectEqual(@as(usize, 1), collector.keys);
        try std.testing.expectEqual(@as(u21, 'a'), collector.last_codepoint);
        try std.testing.expect(collector.last_modifiers.shift);
        try std.testing.expect(collector.last_modifiers.control);
        try std.testing.expectEqual(event.KeyAction.repeat, collector.last_action);
    }
}

test "bracketed paste streams and preserves fragmented terminators" {
    const input = "\x1b[200~hello \x1bworld\x1b[201~";
    var split: usize = 0;
    while (split <= input.len) : (split += 1) {
        var parser: Parser = .{};
        var collector: Collector = .{};
        try parser.feed(input[0..split], &collector);
        try parser.feed(input[split..], &collector);
        try std.testing.expectEqual(@as(usize, 1), collector.paste_starts);
        try std.testing.expectEqual(@as(usize, 1), collector.paste_ends);
        try std.testing.expectEqualStrings("hello \x1bworld", collector.paste[0..collector.paste_len]);
    }
}

test "standalone escape is emitted only when its timeout is flushed" {
    var parser: Parser = .{};
    var collector: Collector = .{};
    try parser.feed("\x1b", &collector);
    try std.testing.expectEqual(@as(usize, 0), collector.keys);
    try parser.flushEscape(&collector);
    try std.testing.expectEqual(@as(usize, 1), collector.keys);
    try std.testing.expect(collector.last_escape);
}

test "oversized control sequences are bounded and recover at their final byte" {
    var parser: Parser = .{};
    var collector: Collector = .{};
    const oversized: [128]u8 = @splat('1');
    try parser.feed("\x1b[", &collector);
    try parser.feed(&oversized, &collector);
    try parser.feed("Ax", &collector);
    try std.testing.expectEqual(@as(usize, 1), collector.malformed);
    try std.testing.expectEqualStrings("x", collector.text[0..collector.text_len]);
}

test "escape resynchronizes a malformed CSI sequence" {
    var parser: Parser = .{};
    var collector: Collector = .{};
    try parser.feed("\x1b[12\x1bx", &collector);
    try std.testing.expectEqual(@as(usize, 1), collector.malformed);
    try std.testing.expectEqual(@as(usize, 1), collector.keys);
    try std.testing.expectEqual(@as(u21, 'x'), collector.last_codepoint);
    try std.testing.expect(collector.last_modifiers.alt);
}

test "Kitty canonical functional keys map to named key codes" {
    const sequences = [_][]const u8{
        "\x1b[57344u", "\x1b[57345u", "\x1b[57346u", "\x1b[57347u", "\x1b[57348u", "\x1b[57349u", "\x1b[57350u",
        "\x1b[57351u", "\x1b[57352u", "\x1b[57353u", "\x1b[57354u", "\x1b[57355u", "\x1b[57356u", "\x1b[57357u",
    };
    const expected = [_]event.KeyCode{
        .escape, .enter, .tab,  .backspace, .insert,    .delete, .left,
        .right,  .up,    .down, .page_up,   .page_down, .home,   .end,
    };
    for (sequences, expected) |sequence, key_code| {
        var parser: Parser = .{};
        var collector: Collector = .{};
        try parser.feed(sequence, &collector);
        try std.testing.expect(std.meta.eql(key_code, collector.last_key_code));
    }

    var parser: Parser = .{};
    var collector: Collector = .{};
    try parser.feed("\x1b[57358u", &collector);
    try std.testing.expectEqual(@as(u21, 0xE00E), collector.last_functional);
}

test "oversized OSC replies are rejected rather than truncated" {
    var parser: Parser = .{};
    var collector: Collector = .{};
    const oversized: [128]u8 = @splat('a');
    try parser.feed("\x1b]", &collector);
    try parser.feed(&oversized, &collector);
    try parser.feed("\x1b\\x", &collector);
    try std.testing.expectEqual(@as(usize, 1), collector.malformed);
    try std.testing.expectEqualStrings("x", collector.text[0..collector.text_len]);
}

test "mouse wheel events do not report a pressed button" {
    var parser: Parser = .{};
    var collector: Collector = .{};
    try parser.feed("\x1b[<64;3;4M", &collector);
    try std.testing.expectEqual(event.Mouse{
        .x = 2,
        .y = 3,
        .button = .none,
        .action = .scroll_up,
    }, collector.last_mouse.?);

    try parser.feed("\x1b[<67;3;4M", &collector);
    try std.testing.expectEqual(event.MouseAction.scroll_right, collector.last_mouse.?.action);
    try std.testing.expectEqual(event.MouseButton.none, collector.last_mouse.?.button);
}

test "sink failures reset parser protocol state" {
    const Scenario = struct {
        bytes: []const u8,
        fail_at: usize,
    };
    const scenarios = [_]Scenario{
        .{ .bytes = "\x1b[200~", .fail_at = 1 },
        .{ .bytes = "\x1b[200~x", .fail_at = 2 },
        .{ .bytes = "\x1b[200~x\x1b[201~", .fail_at = 3 },
    };
    for (scenarios) |scenario| {
        var parser: Parser = .{};
        var sink = FailingSink{ .fail_at = scenario.fail_at };
        try std.testing.expectError(error.SinkFailure, parser.feed(scenario.bytes, &sink));
        sink.fail_at = std.math.maxInt(usize);
        try parser.feed("z", &sink);
        try std.testing.expectEqual(@as(u8, 'z'), sink.last_text);
    }

    var parser: Parser = .{};
    var sink = FailingSink{ .fail_at = 1 };
    try parser.feed("\x1b[", &sink);
    try std.testing.expectError(error.SinkFailure, parser.finish(&sink));
    sink.fail_at = std.math.maxInt(usize);
    try parser.feed("z", &sink);
    try std.testing.expectEqual(@as(u8, 'z'), sink.last_text);
}

test "parser finish is idempotent" {
    var parser: Parser = .{};
    var collector: Collector = .{};
    try parser.feed("\x1b", &collector);
    try parser.finish(&collector);
    try parser.finish(&collector);
    try std.testing.expectEqual(@as(usize, 1), collector.keys);
    try std.testing.expect(collector.last_escape);
}

test "parser rejects noncanonical key and mouse domains" {
    const invalid = [_][]const u8{
        "\x1b[55296u",
        "\x1b[97;257u",
        "\x1b[97;1:4u",
        "\x1b[97;1;98u",
        "\x1b[1;257A",
        "\x1b[3;257~",
        "\x1b[<0;1;1;2M",
    };
    for (invalid) |sequence| {
        var parser: Parser = .{};
        var collector: Collector = .{};
        try parser.feed(sequence, &collector);
        try std.testing.expectEqual(@as(usize, 1), collector.malformed);
        try std.testing.expectEqual(@as(usize, 0), collector.keys);
    }

    var parser: Parser = .{};
    var collector: Collector = .{};
    try parser.feed("\x1b[1;2;3R", &collector);
    try std.testing.expectEqual(@as(usize, 0), collector.cursor_positions);
    try std.testing.expectEqual(@as(usize, 1), collector.terminal_replies);
}

test "parser abort reports and clears caller-timed incomplete input" {
    var parser: Parser = .{};
    var collector: Collector = .{};
    try parser.feed("\x1b[200~partial", &collector);
    try parser.abort(&collector);
    try std.testing.expectEqual(@as(usize, 1), collector.paste_starts);
    try std.testing.expectEqual(@as(usize, 1), collector.malformed);
    try parser.feed("z", &collector);
    try std.testing.expectEqualStrings("z", collector.text[0..collector.text_len]);
    try parser.abort(&collector);
    try std.testing.expectEqual(@as(usize, 1), collector.malformed);
}

test "parser remains bounded under arbitrary fragmented bytes" {
    const Sink = struct {
        emissions: usize = 0,

        pub fn emit(self: *@This(), _: event.Event) !void {
            self.emissions += 1;
        }
    };
    var parser: Parser = .{};
    var sink: Sink = .{};
    var random: u64 = 0x6A09_E667_F3BC_C909;
    for (0..10_000) |index| {
        random = random *% 6_364_136_223_846_793_005 +% 1_442_695_040_888_963_407;
        const byte: u8 = @truncate(random >> 24);
        try parser.feed(&.{byte}, &sink);
        if (index % 257 == 0) try parser.abort(&sink);
    }
    try parser.finish(&sink);
    try std.testing.expect(sink.emissions != 0);
}

const FailingSink = struct {
    fail_at: usize,
    emissions: usize = 0,
    last_text: u8 = 0,

    pub fn emit(self: *FailingSink, value: event.Event) !void {
        self.emissions += 1;
        if (self.emissions == self.fail_at) return error.SinkFailure;
        switch (value) {
            .text => |bytes| if (bytes.len != 0) {
                self.last_text = bytes[bytes.len - 1];
            },
            else => {},
        }
    }
};

const Collector = struct {
    keys: usize = 0,
    last_codepoint: u21 = 0,
    last_functional: u21 = 0,
    last_modifiers: event.Modifiers = .{},
    last_action: event.KeyAction = .press,
    last_key_code: event.KeyCode = .escape,
    last_escape: bool = false,
    paste_starts: usize = 0,
    paste_ends: usize = 0,
    paste: [512]u8 = undefined,
    paste_len: usize = 0,
    text: [32]u8 = undefined,
    text_len: usize = 0,
    malformed: usize = 0,
    cursor_positions: usize = 0,
    terminal_replies: usize = 0,
    last_mouse: ?event.Mouse = null,

    fn emit(self: *Collector, value: event.Event) !void {
        switch (value) {
            .key => |key| {
                self.keys += 1;
                self.last_modifiers = key.modifiers;
                self.last_action = key.action;
                self.last_key_code = key.code;
                switch (key.code) {
                    .codepoint => |codepoint| self.last_codepoint = codepoint,
                    .functional => |functional| self.last_functional = functional,
                    .escape => self.last_escape = true,
                    else => {},
                }
            },
            .paste_start => self.paste_starts += 1,
            .paste_chunk => |chunk| {
                @memcpy(self.paste[self.paste_len..][0..chunk.len], chunk);
                self.paste_len += chunk.len;
            },
            .paste_end => self.paste_ends += 1,
            .text => |text| {
                @memcpy(self.text[self.text_len..][0..text.len], text);
                self.text_len += text.len;
            },
            .malformed => self.malformed += 1,
            .cursor_position => self.cursor_positions += 1,
            .terminal_reply => self.terminal_replies += 1,
            .mouse => |mouse| self.last_mouse = mouse,
            else => {},
        }
    }
};
