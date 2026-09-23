const std = @import("std");
const event = @import("event.zig");

const paste_end = "\x1b[201~";

/// Bracketed paste uses an in-band delimiter; it is framing, not authentication for ESC-bearing clipboard data.
pub const Parser = struct {
    pub const max_text_bytes = 4;
    pub const max_terminal_reply_bytes = 1_024;
    pub const max_paste_chunk_bytes = 256;
    pub const max_event_payload_bytes = @max(max_text_bytes, max_terminal_reply_bytes, max_paste_chunk_bytes);

    pub const Pending = enum {
        none,
        escape,
        sequence,
    };

    pub const Failure = enum {
        malformed_sequence,
    };

    pub const Outcome = union(enum) {
        event: event.Event,
        need_more,
        failure: Failure,
        done,
    };

    pub const Result = struct {
        consumed: usize,
        outcome: Outcome,
    };

    const State = enum {
        ground,
        escape,
        csi,
        discard_csi,
        ss3,
        control_string,
        control_string_escape,
        discard_string,
        discard_string_escape,
        paste,
        utf8,
        alt_utf8,
    };

    state: State = .ground,
    string_kind: enum { osc, apc } = .osc,
    sequence: [max_terminal_reply_bytes]u8 = undefined,
    sequence_len: usize = 0,
    utf8: [max_text_bytes]u8 = undefined,
    utf8_len: u3 = 0,
    utf8_expected: u3 = 0,
    paste_buffer: [max_paste_chunk_bytes]u8 = undefined,
    paste_len: usize = 0,
    paste_match: usize = 0,
    pending_events: [2]event.OwnedEvent(max_event_payload_bytes) = undefined,
    pending_index: u2 = 0,
    pending_len: u2 = 0,

    /// Consumes at most `input.len` bytes and returns at most one borrowed event.
    /// Event payloads remain valid until the next parser operation.
    pub fn next(self: *Parser, input: []const u8) Result {
        if (self.popPending(0)) |result| return result;
        self.preparePending();
        var consumed: usize = 0;
        while (consumed < input.len) {
            self.consume(input[consumed]);
            consumed += 1;
            if (self.pending_len != 0) break;
        }
        if (self.pending_len == 0 and consumed == input.len and self.state == .paste) {
            self.flushPaste();
        }
        return self.popPending(consumed) orelse .{ .consumed = consumed, .outcome = .need_more };
    }

    /// Resolves a lone escape after the caller's escape deadline expires.
    pub fn resolveEscape(self: *Parser) Result {
        if (self.popPending(0)) |result| return result;
        self.preparePending();
        self.flushEscape();
        return self.popPending(0) orelse .{ .consumed = 0, .outcome = .need_more };
    }

    /// Ends the byte stream and drains any final event or parse failure.
    pub fn endInput(self: *Parser) Result {
        if (self.popPending(0)) |result| return result;
        self.preparePending();
        self.finish();
        return self.popPending(0) orelse .{ .consumed = 0, .outcome = .done };
    }

    /// Cancels an incomplete sequence and reports it as a parse failure.
    pub fn cancelPending(self: *Parser) Result {
        if (self.popPending(0)) |result| return result;
        self.preparePending();
        self.abort();
        return self.popPending(0) orelse .{ .consumed = 0, .outcome = .done };
    }

    fn flushEscape(self: *Parser) void {
        if (self.state != .escape) return;
        self.state = .ground;
        self.emit(.{ .key = .{ .code = .escape } });
    }

    fn finish(self: *Parser) void {
        defer self.resetState();
        if (self.state == .escape) {
            self.state = .ground;
            self.emit(.{ .key = .{ .code = .escape } });
            return;
        }
        if (self.state == .paste) {
            if (self.paste_match > 0) {
                self.appendPaste(paste_end[0..self.paste_match]);
                self.paste_match = 0;
            }
            self.flushPaste();
        }
        if (self.state != .ground) self.emit(.malformed);
    }

    pub fn reset(self: *Parser) void {
        self.resetState();
        self.pending_index = 0;
        self.pending_len = 0;
    }

    fn resetState(self: *Parser) void {
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

    /// Reports a complete event or failure that `next` can return without
    /// consuming another input byte.
    pub fn hasQueuedEvent(self: *const Parser) bool {
        return self.pending_index != self.pending_len;
    }

    /// Cancels a caller-timed incomplete sequence and queues a malformed outcome.
    fn abort(self: *Parser) void {
        if (self.state == .ground) return;
        self.resetState();
        self.emit(.malformed);
    }

    fn emit(self: *Parser, value: event.Event) void {
        std.debug.assert(self.pending_len < self.pending_events.len);
        self.pending_events[self.pending_len] = event.OwnedEvent(max_event_payload_bytes).init(value) catch unreachable;
        self.pending_len += 1;
    }

    fn preparePending(self: *Parser) void {
        std.debug.assert(self.pending_index == self.pending_len);
        self.pending_index = 0;
        self.pending_len = 0;
    }

    fn popPending(self: *Parser, consumed: usize) ?Result {
        if (self.pending_index == self.pending_len) return null;
        const value = self.pending_events[self.pending_index].borrow();
        self.pending_index += 1;
        return if (value == .malformed)
            .{ .consumed = consumed, .outcome = .{ .failure = .malformed_sequence } }
        else
            .{ .consumed = consumed, .outcome = .{ .event = value } };
    }

    fn consume(self: *Parser, byte: u8) void {
        switch (self.state) {
            .ground => self.consumeGround(byte),
            .escape => self.consumeEscape(byte),
            .csi => self.consumeCsi(byte),
            .discard_csi => {
                if (byte == 0x1B) {
                    self.state = .escape;
                    self.emit(.malformed);
                } else if (isFinal(byte)) {
                    self.state = .ground;
                    self.emit(.malformed);
                }
            },
            .ss3 => self.consumeSs3(byte),
            .control_string => self.consumeString(byte),
            .control_string_escape => {
                if (byte == '\\') {
                    self.finishString(byte);
                } else if (self.string_kind == .osc and byte == 0x07) {
                    self.state = .ground;
                    self.emit(.malformed);
                } else {
                    // Embedded ESC invalidates the payload. Keep framing until
                    // BEL (OSC) or ST, including ST after consecutive ESC bytes.
                    self.state = if (byte == 0x1b) .discard_string_escape else .discard_string;
                }
            },
            .discard_string, .discard_string_escape => {
                if ((self.string_kind == .osc and byte == 0x07) or
                    (self.state == .discard_string_escape and byte == '\\'))
                {
                    self.state = .ground;
                    self.emit(.malformed);
                } else {
                    self.state = if (byte == 0x1b) .discard_string_escape else .discard_string;
                }
            },
            .paste => self.consumePaste(byte),
            .utf8, .alt_utf8 => self.consumeUtf8(byte),
        }
    }

    fn consumeGround(self: *Parser, byte: u8) void {
        switch (byte) {
            0x1B => {
                self.state = .escape;
                return;
            },
            0x0A, 0x0D => {
                self.emit(.{ .key = .{ .code = .enter } });
                return;
            },
            0x09 => {
                self.emit(.{ .key = .{ .code = .tab } });
                return;
            },
            0x08, 0x7F => {
                self.emit(.{ .key = .{ .code = .backspace } });
                return;
            },
            0x00 => {
                self.emit(.{ .key = .{
                    .code = .{ .codepoint = ' ' },
                    .modifiers = .{ .control = true },
                } });
                return;
            },
            else => {},
        }
        if (byte >= 0x01 and byte <= 0x1A) {
            self.emit(.{ .key = .{
                .code = .{ .codepoint = @as(u21, 'a') + byte - 1 },
                .modifiers = .{ .control = true },
            } });
        } else if (byte >= 0x20 and byte <= 0x7E) {
            const text = [1]u8{byte};
            self.emit(.{ .text = &text });
        } else {
            self.startUtf8(byte, false);
        }
    }

    fn consumeEscape(self: *Parser, byte: u8) void {
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
            ']', '_' => {
                self.state = .control_string;
                self.string_kind = if (byte == ']') .osc else .apc;
                self.sequence_len = 0;
                return;
            },
            0x1B => {
                self.emit(.{ .key = .{ .code = .escape } });
                self.state = .escape;
                return;
            },
            else => {},
        }
        if (byte >= 0x20 and byte <= 0x7E) {
            self.state = .ground;
            self.emit(.{ .key = .{
                .code = .{ .codepoint = byte },
                .modifiers = .{ .alt = true },
            } });
        } else {
            self.startUtf8(byte, true);
        }
    }

    fn consumeCsi(self: *Parser, byte: u8) void {
        if (byte == 0x1B) {
            self.state = .escape;
            self.emit(.malformed);
            return;
        }
        if (isFinal(byte)) {
            const parameters = self.sequence[0..self.sequence_len];
            self.state = .ground;
            if (!validCsiBody(parameters)) {
                self.emit(.malformed);
                return;
            }
            self.dispatchCsi(parameters, byte);
            return;
        }
        if (byte < 0x20 or byte > 0x3F) {
            self.state = .ground;
            self.emit(.malformed);
            return;
        }
        if (self.sequence_len == self.sequence.len) {
            self.state = .discard_csi;
            return;
        }
        self.sequence[self.sequence_len] = byte;
        self.sequence_len += 1;
    }

    fn consumeSs3(self: *Parser, byte: u8) void {
        if (byte == 0x1B) {
            self.state = .escape;
            self.emit(.malformed);
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
                self.emit(.malformed);
                return;
            },
        };
        self.emit(.{ .key = .{ .code = code } });
    }

    fn consumeString(self: *Parser, byte: u8) void {
        if (self.string_kind == .osc and byte == 0x07) {
            self.finishString(byte);
            return;
        }
        if (byte == 0x1B) {
            self.state = .control_string_escape;
            return;
        }
        if (self.sequence_len == self.sequence.len) {
            self.state = .discard_string;
            return;
        }
        self.sequence[self.sequence_len] = byte;
        self.sequence_len += 1;
    }

    fn finishString(self: *Parser, final: u8) void {
        self.state = .ground;
        const bytes = self.sequence[0..self.sequence_len];
        if (!validTerminalReply(bytes)) {
            self.emit(.malformed);
            return;
        }
        self.emit(.{ .terminal_reply = .{
            .kind = switch (self.string_kind) {
                .osc => .osc,
                .apc => .apc,
            },
            .final = final,
            .raw = bytes,
        } });
    }

    fn consumePaste(self: *Parser, byte: u8) void {
        if (byte == paste_end[self.paste_match]) {
            self.paste_match += 1;
            if (self.paste_match == paste_end.len) {
                self.paste_match = 0;
                self.flushPaste();
                self.state = .ground;
                self.emit(.paste_end);
            }
            return;
        }

        if (self.paste_match > 0) {
            self.appendPaste(paste_end[0..self.paste_match]);
            self.paste_match = 0;
            if (byte == paste_end[0]) {
                self.paste_match = 1;
                return;
            }
        }
        self.appendPaste(&[1]u8{byte});
    }

    fn appendPaste(self: *Parser, bytes: []const u8) void {
        var remaining = bytes;
        while (remaining.len > 0) {
            if (self.paste_len == self.paste_buffer.len) self.flushPaste();
            const count = @min(remaining.len, self.paste_buffer.len - self.paste_len);
            @memcpy(self.paste_buffer[self.paste_len..][0..count], remaining[0..count]);
            self.paste_len += count;
            remaining = remaining[count..];
        }
    }

    fn flushPaste(self: *Parser) void {
        if (self.paste_len == 0) return;
        self.emit(.{ .paste_chunk = self.paste_buffer[0..self.paste_len] });
        self.paste_len = 0;
    }

    fn startUtf8(self: *Parser, byte: u8, alt: bool) void {
        const expected = std.unicode.utf8ByteSequenceLength(byte) catch {
            self.state = .ground;
            self.emit(.malformed);
            return;
        };
        if (expected == 1) {
            self.state = .ground;
            self.emit(.malformed);
            return;
        }
        self.utf8[0] = byte;
        self.utf8_len = 1;
        self.utf8_expected = expected;
        self.state = if (alt) .alt_utf8 else .utf8;
    }

    fn consumeUtf8(self: *Parser, byte: u8) void {
        if (byte & 0xC0 != 0x80) {
            self.state = .ground;
            self.utf8_len = 0;
            self.emit(.malformed);
            self.consumeGround(byte);
            return;
        }

        self.utf8[self.utf8_len] = byte;
        self.utf8_len += 1;
        if (self.utf8_len != self.utf8_expected) return;

        const bytes = self.utf8[0..self.utf8_len];
        const codepoint = std.unicode.utf8Decode(bytes) catch {
            self.state = .ground;
            self.utf8_len = 0;
            self.emit(.malformed);
            return;
        };
        const alt = self.state == .alt_utf8;
        self.state = .ground;
        self.utf8_len = 0;
        if (alt) {
            self.emit(.{ .key = .{
                .code = .{ .codepoint = codepoint },
                .modifiers = .{ .alt = true },
            } });
        } else {
            self.emit(.{ .text = bytes });
        }
    }

    fn dispatchCsi(self: *Parser, parameters: []const u8, final: u8) void {
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
                const metadata = csiKeyMetadata(parameters) orelse {
                    self.emit(.malformed);
                    return;
                };
                self.emit(.{ .key = .{
                    .code = code,
                    .modifiers = metadata.modifiers,
                    .action = metadata.action,
                } });
            },
            'I' => if (parameters.len == 0) self.emit(.focus_in) else self.emitReply(parameters, final),
            'O' => if (parameters.len == 0) self.emit(.focus_out) else self.emitReply(parameters, final),
            'Z' => if (parameters.len == 0)
                self.emit(.{ .key = .{ .code = .tab, .modifiers = .{ .shift = true } } })
            else
                self.emitReply(parameters, final),
            '~' => self.dispatchTilde(parameters),
            'u' => {
                if (parameters.len == 0 or parameters[0] < '0' or parameters[0] > '9') {
                    self.emitReply(parameters, final);
                } else {
                    self.dispatchKitty(parameters);
                }
            },
            'M', 'm' => {
                if (parameters.len > 0 and parameters[0] == '<') {
                    self.dispatchMouse(parameters[1..], final);
                } else {
                    self.emitReply(parameters, final);
                }
            },
            'R' => {
                var fields = std.mem.splitScalar(u8, parameters, ';');
                const row = parseU16(fields.next() orelse "") orelse {
                    self.emitReply(parameters, final);
                    return;
                };
                const column = parseU16(fields.next() orelse "") orelse {
                    self.emitReply(parameters, final);
                    return;
                };
                if (row == 0 or column == 0 or fields.next() != null) {
                    self.emitReply(parameters, final);
                    return;
                }
                self.emit(.{ .cursor_position = .{ .row = row - 1, .column = column - 1 } });
            },
            else => self.emitReply(parameters, final),
        }
    }

    fn dispatchTilde(self: *Parser, parameters: []const u8) void {
        var fields = std.mem.splitScalar(u8, parameters, ';');
        const number = parseU16(fields.next() orelse "") orelse {
            self.emit(.malformed);
            return;
        };
        const modifier_field = fields.next();
        if (fields.next() != null) {
            self.emit(.malformed);
            return;
        }
        if (number == 200) {
            if (modifier_field != null) {
                self.emit(.malformed);
                return;
            }
            self.state = .paste;
            self.paste_len = 0;
            self.paste_match = 0;
            self.emit(.paste_start);
            return;
        }
        if (number == 201) {
            self.emit(.malformed);
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
                self.emitReply(parameters, '~');
                return;
            },
        };
        const metadata = keyMetadata(modifier_field) orelse {
            self.emit(.malformed);
            return;
        };
        self.emit(.{ .key = .{
            .code = code,
            .modifiers = metadata.modifiers,
            .action = metadata.action,
        } });
    }

    fn dispatchKitty(self: *Parser, parameters: []const u8) void {
        var fields = std.mem.splitScalar(u8, parameters, ';');
        const codepoint = parseKittyKeyField(fields.next() orelse "") orelse {
            self.emit(.malformed);
            return;
        };
        const modifier_and_action = fields.next();
        if (fields.next() != null) {
            self.emit(.malformed);
            return;
        }
        const metadata = keyMetadata(modifier_and_action) orelse {
            self.emit(.malformed);
            return;
        };
        self.emit(.{ .key = .{
            .code = kittyKeyCode(codepoint),
            .modifiers = metadata.modifiers,
            .action = metadata.action,
        } });
    }

    fn kittyKeyCode(codepoint: u21) event.KeyCode {
        return switch (codepoint) {
            27, 0xE000 => .escape,
            13, 0xE001 => .enter,
            9, 0xE002 => .tab,
            127, 0xE003 => .backspace,
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

    fn dispatchMouse(self: *Parser, parameters: []const u8, final: u8) void {
        var fields = std.mem.splitScalar(u8, parameters, ';');
        const encoded = parseU16(fields.next() orelse "") orelse {
            self.emit(.malformed);
            return;
        };
        const x = parseU16(fields.next() orelse "") orelse {
            self.emit(.malformed);
            return;
        };
        const y = parseU16(fields.next() orelse "") orelse {
            self.emit(.malformed);
            return;
        };
        if (x == 0 or y == 0 or fields.next() != null or encoded & ~@as(u16, 0x7F) != 0) {
            self.emit(.malformed);
            return;
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
        self.emit(.{ .mouse = .{
            .x = x - 1,
            .y = y - 1,
            .button = if (action == .release or wheel) .none else button,
            .action = action,
            .modifiers = modifiers,
        } });
    }

    fn emitReply(self: *Parser, parameters: []const u8, final: u8) void {
        self.emit(.{ .terminal_reply = .{
            .kind = .csi,
            .final = final,
            .raw = parameters,
        } });
    }
};

fn validTerminalReply(bytes: []const u8) bool {
    var index: usize = 0;
    while (index < bytes.len) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(bytes[index]) catch return false;
        if (sequence_len > bytes.len - index) return false;
        const codepoint = std.unicode.utf8Decode(bytes[index .. index + sequence_len]) catch return false;
        if (codepoint < 0x20 or codepoint >= 0x7f and codepoint <= 0x9f) return false;
        index += sequence_len;
    }
    return true;
}

fn isFinal(byte: u8) bool {
    return byte >= 0x40 and byte <= 0x7E;
}

fn validCsiBody(value: []const u8) bool {
    var saw_intermediate = false;
    for (value) |byte| {
        if (byte >= 0x30 and byte <= 0x3F) {
            if (saw_intermediate) return false;
        } else if (byte >= 0x20 and byte <= 0x2F) {
            saw_intermediate = true;
        } else {
            return false;
        }
    }
    return true;
}

fn parseU16(value: []const u8) ?u16 {
    if (value.len == 0) return null;
    for (value) |byte| if (byte < '0' or byte > '9') return null;
    return std.fmt.parseInt(u16, value, 10) catch null;
}

const KeyMetadata = struct {
    modifiers: event.Modifiers = .{},
    action: event.KeyAction = .press,
};

fn csiKeyMetadata(parameters: []const u8) ?KeyMetadata {
    if (parameters.len == 0) return .{};
    var fields = std.mem.splitScalar(u8, parameters, ';');
    const first = fields.next() orelse unreachable;
    if (first.len != 0 and !std.mem.eql(u8, first, "1")) return null;
    const modifier_field = fields.next();
    if (fields.next() != null) return null;
    return keyMetadata(modifier_field);
}

fn keyMetadata(field: ?[]const u8) ?KeyMetadata {
    const value = field orelse return .{};
    var parts = std.mem.splitScalar(u8, value, ':');
    const modifier_bytes = parts.next() orelse unreachable;
    const modifier_value = if (modifier_bytes.len == 0) 1 else parseU16(modifier_bytes) orelse return null;
    const modifiers = decodeModifiers(modifier_value) orelse return null;
    const action_bytes = parts.next();
    const action: event.KeyAction = if (action_bytes) |bytes| switch (parseU16(bytes) orelse return null) {
        1 => .press,
        2 => .repeat,
        3 => .release,
        else => return null,
    } else .press;
    if (parts.next() != null) return null;
    return .{ .modifiers = modifiers, .action = action };
}

fn parseKittyKeyField(value: []const u8) ?u21 {
    var keys = std.mem.splitScalar(u8, value, ':');
    const primary = parseUnicodeScalar(keys.next() orelse return null) orelse return null;
    var optional_count: u2 = 0;
    while (keys.next()) |alternate| {
        if (optional_count == 2) return null;
        optional_count += 1;
        if (alternate.len != 0 and parseUnicodeScalar(alternate) == null) return null;
    }
    return primary;
}

fn parseUnicodeScalar(value: []const u8) ?u21 {
    if (value.len == 0) return null;
    for (value) |byte| if (byte < '0' or byte > '9') return null;
    const codepoint = std.fmt.parseInt(u21, value, 10) catch return null;
    var encoded: [4]u8 = undefined;
    _ = std.unicode.utf8Encode(codepoint, &encoded) catch return null;
    return codepoint;
}

fn decodeModifiers(encoded: u16) ?event.Modifiers {
    if (encoded == 0 or encoded > @as(u16, std.math.maxInt(u8)) + 1) return null;
    const bits: u8 = @intCast(encoded - 1);
    return @bitCast(bits);
}
