const std = @import("std");
const tui = @import("tui");

test "parser maps ground control text and Alt input" {
    var parser: tui.input.Parser = .{};
    var collector: Collector = .{};

    try parser.feed("\r\t\x7f\x01A\xC3\xA9", &collector);
    try std.testing.expectEqual(@as(usize, 4), collector.key_count);
    try expectKeyCode(.enter, collector.keys[0].code);
    try expectKeyCode(.tab, collector.keys[1].code);
    try expectKeyCode(.backspace, collector.keys[2].code);
    try expectKeyCode(.{ .codepoint = 'a' }, collector.keys[3].code);
    try std.testing.expect(collector.keys[3].modifiers.control);
    try std.testing.expectEqualStrings("A\xC3\xA9", collector.text[0..collector.text_len]);

    try parser.feed("\x1bx\x1b\xC3\xA9", &collector);
    try std.testing.expectEqual(@as(usize, 6), collector.key_count);
    try expectKeyCode(.{ .codepoint = 'x' }, collector.keys[4].code);
    try expectKeyCode(.{ .codepoint = 0xE9 }, collector.keys[5].code);
    try std.testing.expect(collector.keys[4].modifiers.alt);
    try std.testing.expect(collector.keys[5].modifiers.alt);
}

test "modifier lock bits do not count as command modifiers" {
    try std.testing.expect(!(tui.input.Modifiers{}).hasNonLock());
    try std.testing.expect(!(tui.input.Modifiers{ .caps_lock = true, .num_lock = true }).hasNonLock());
    try std.testing.expect((tui.input.Modifiers{ .shift = true }).hasNonLock());
    try std.testing.expect((tui.input.Modifiers{ .alt = true }).hasNonLock());
    try std.testing.expect((tui.input.Modifiers{ .control = true }).hasNonLock());
    try std.testing.expect((tui.input.Modifiers{ .super = true }).hasNonLock());
    try std.testing.expect((tui.input.Modifiers{ .hyper = true }).hasNonLock());
    try std.testing.expect((tui.input.Modifiers{ .meta = true }).hasNonLock());
}

test "parser maps SS3 CSI and tilde key families at every split" {
    const cases = [_]struct {
        sequence: []const u8,
        code: tui.input.KeyCode,
        control: bool = false,
    }{
        .{ .sequence = "\x1bOA", .code = .up },
        .{ .sequence = "\x1bOB", .code = .down },
        .{ .sequence = "\x1bOC", .code = .right },
        .{ .sequence = "\x1bOD", .code = .left },
        .{ .sequence = "\x1bOP", .code = .{ .function = 1 } },
        .{ .sequence = "\x1b[A", .code = .up },
        .{ .sequence = "\x1b[1;5A", .code = .up, .control = true },
        .{ .sequence = "\x1b[2~", .code = .insert },
        .{ .sequence = "\x1b[3~", .code = .delete },
        .{ .sequence = "\x1b[5~", .code = .page_up },
        .{ .sequence = "\x1b[6~", .code = .page_down },
        .{ .sequence = "\x1b[15~", .code = .{ .function = 5 } },
        .{ .sequence = "\x1b[17~", .code = .{ .function = 6 } },
    };

    for (cases) |case| {
        var split: usize = 0;
        while (split <= case.sequence.len) : (split += 1) {
            var parser: tui.input.Parser = .{};
            var collector: Collector = .{};
            try parser.feed(case.sequence[0..split], &collector);
            try parser.feed(case.sequence[split..], &collector);
            try std.testing.expectEqual(@as(usize, 1), collector.key_count);
            try expectKeyCode(case.code, collector.keys[0].code);
            try std.testing.expectEqual(case.control, collector.keys[0].modifiers.control);
        }
    }
}

test "parser emits focus cursor CSI OSC and mouse events" {
    var parser: tui.input.Parser = .{};
    var collector: Collector = .{};

    try parser.feed("\x1b[I\x1b[O\x1b[12;34R\x1b[?7u\x1b]66;ok\x07", &collector);
    try std.testing.expectEqual(@as(usize, 1), collector.focus_in);
    try std.testing.expectEqual(@as(usize, 1), collector.focus_out);
    try std.testing.expectEqual(@as(usize, 1), collector.cursor_count);
    try std.testing.expectEqual(@as(u16, 11), collector.cursor_row);
    try std.testing.expectEqual(@as(u16, 33), collector.cursor_column);
    try std.testing.expectEqual(@as(usize, 2), collector.reply_count);
    try std.testing.expectEqualStrings("66;ok", collector.last_reply[0..collector.last_reply_len]);
    try std.testing.expectEqual(@as(u8, 0x07), collector.last_reply_final);
    try std.testing.expect(!collector.last_reply_csi);

    try parser.feed("\x1b[<28;3;4M\x1b[<0;3;4m\x1b[<32;5;6M", &collector);
    try std.testing.expectEqual(@as(usize, 3), collector.mouse_count);
    const press = collector.mice[0];
    try std.testing.expectEqual(@as(u16, 2), press.x);
    try std.testing.expectEqual(@as(u16, 3), press.y);
    try std.testing.expectEqual(.left, press.button);
    try std.testing.expectEqual(.press, press.action);
    try std.testing.expect(press.modifiers.shift and press.modifiers.alt and press.modifiers.control);
    try std.testing.expectEqual(.none, collector.mice[1].button);
    try std.testing.expectEqual(.release, collector.mice[1].action);
    try std.testing.expectEqual(.left, collector.mice[2].button);
    try std.testing.expectEqual(.move, collector.mice[2].action);
}

test "parser reset drops incomplete protocol state" {
    var parser: tui.input.Parser = .{};
    var collector: Collector = .{};
    try parser.feed("\x1b[12", &collector);
    parser.reset();
    try parser.feed("x", &collector);
    try std.testing.expectEqualStrings("x", collector.text[0..collector.text_len]);
    try std.testing.expectEqual(@as(usize, 0), collector.malformed);
}

test "capability negotiation accepts only parser events from an active query" {
    var negotiator: tui.terminal.CapabilityNegotiator = .{};
    var query_buffer: [256]u8 = undefined;
    var query_writer = std.Io.Writer.fixed(&query_buffer);
    try negotiator.writeQueries(&query_writer);
    try std.testing.expect(negotiator.queriesPending());

    var parser: tui.input.Parser = .{};
    var sink = NegotiationSink{ .negotiator = &negotiator };
    const replies = "\x1b[?7u\x1b[?62;4c\x1b[>1;4000;0c\x1b[?2026;1$y" ++
        "\x1b]10;rgb:ffff/8000/0000\x1b\\\x1b]11;rgb:0000/1111/ffff\x07" ++
        "\x1b[1;1R\x1b[1;3R\x1b[1;5R";
    for (replies) |byte| try parser.feed(&.{byte}, &sink);

    try std.testing.expect(negotiator.capabilities.kitty_keyboard);
    try std.testing.expect(negotiator.capabilities.synchronized_output);
    try std.testing.expectEqual(tui.terminal.TextSizing.scaling, negotiator.capabilities.text_sizing);
    try std.testing.expectEqual(
        tui.terminal.CapabilitySupport.supported,
        negotiator.observations.kitty_keyboard,
    );
    try std.testing.expectEqualSlices(
        u16,
        &.{ 62, 4 },
        negotiator.observations.primary_device_attributes.?.parameters(),
    );
    try std.testing.expectEqual(@as(u32, 4000), negotiator.observations.secondary_device_attributes.?.firmware_version);
    try std.testing.expectEqual(@as(u16, 0x8000), negotiator.observations.default_foreground.?.green);
    try std.testing.expectEqual(@as(u16, 0x1111), negotiator.observations.default_background.?.green);
    try std.testing.expect(!negotiator.queriesPending());

    var cancelled: tui.terminal.CapabilityNegotiator = .{};
    var cancelled_buffer: [256]u8 = undefined;
    var cancelled_writer = std.Io.Writer.fixed(&cancelled_buffer);
    try cancelled.writeQueries(&cancelled_writer);
    cancelled.cancelQueries();
    var cancelled_sink = NegotiationSink{ .negotiator = &cancelled };
    var cancelled_parser: tui.input.Parser = .{};
    try cancelled_parser.feed("\x1b[?7u\x1b[?2026;1$y", &cancelled_sink);
    try std.testing.expect(!cancelled.capabilities.kitty_keyboard);
    try std.testing.expect(!cancelled.capabilities.synchronized_output);
    try std.testing.expect(!cancelled.queriesPending());
}

test "owned event transport preserves parser payloads after buffer reuse" {
    const Owned = tui.input.OwnedEvent(tui.input.Parser.max_event_payload_bytes);
    const Queue = tui.transport.Spsc(Owned);
    const Sink = struct {
        queue: *Queue,

        pub fn emit(self: *@This(), event: tui.input.Event) !void {
            try self.queue.trySend(try Owned.init(event));
        }
    };

    var slots: [8]Owned = undefined;
    var queue = try Queue.init(&slots);
    var sink = Sink{ .queue = &queue };
    var parser: tui.input.Parser = .{};
    var paste: [tui.input.Parser.max_paste_chunk_bytes]u8 = @splat('p');
    try parser.feed("a\x1b[200~", &sink);
    try parser.feed(&paste, &sink);
    try parser.feed("\x1b[201~\x1b[?2026;1$y", &sink);
    @memset(&paste, 'x');
    try parser.feed("z", &sink);

    var owned = queue.tryReceive().?;
    try std.testing.expectEqualStrings("a", owned.borrow().text);
    owned = queue.tryReceive().?;
    try std.testing.expectEqual(tui.input.Event.paste_start, owned.borrow());
    owned = queue.tryReceive().?;
    try std.testing.expectEqual(@as(usize, tui.input.Parser.max_paste_chunk_bytes), owned.borrow().paste_chunk.len);
    try std.testing.expectEqual(@as(u8, 'p'), owned.borrow().paste_chunk[0]);
    try std.testing.expectEqual(@as(u8, 'p'), owned.borrow().paste_chunk[paste.len - 1]);
    owned = queue.tryReceive().?;
    try std.testing.expectEqual(tui.input.Event.paste_end, owned.borrow());
    owned = queue.tryReceive().?;
    const reply = owned.borrow().terminal_reply;
    try std.testing.expectEqual(.csi, reply.kind);
    try std.testing.expectEqual(@as(u8, 'y'), reply.final);
    try std.testing.expectEqualStrings("?2026;1$", reply.raw);
    owned = queue.tryReceive().?;
    try std.testing.expectEqualStrings("z", owned.borrow().text);
    try std.testing.expect(queue.tryReceive() == null);
}

const NegotiationSink = struct {
    negotiator: *tui.terminal.CapabilityNegotiator,

    pub fn emit(self: *NegotiationSink, event: tui.input.Event) !void {
        self.negotiator.observe(event);
    }
};

const Collector = struct {
    keys: [64]tui.input.Key = undefined,
    key_count: usize = 0,
    text: [256]u8 = undefined,
    text_len: usize = 0,
    mice: [16]tui.input.Mouse = undefined,
    mouse_count: usize = 0,
    focus_in: usize = 0,
    focus_out: usize = 0,
    cursor_count: usize = 0,
    cursor_row: u16 = 0,
    cursor_column: u16 = 0,
    reply_count: usize = 0,
    last_reply: [128]u8 = undefined,
    last_reply_len: usize = 0,
    last_reply_final: u8 = 0,
    last_reply_csi: bool = false,
    malformed: usize = 0,

    pub fn emit(self: *Collector, event: tui.input.Event) !void {
        switch (event) {
            .key => |key| {
                self.keys[self.key_count] = key;
                self.key_count += 1;
            },
            .text => |bytes| {
                @memcpy(self.text[self.text_len..][0..bytes.len], bytes);
                self.text_len += bytes.len;
            },
            .mouse => |mouse| {
                self.mice[self.mouse_count] = mouse;
                self.mouse_count += 1;
            },
            .focus_in => self.focus_in += 1,
            .focus_out => self.focus_out += 1,
            .cursor_position => |position| {
                self.cursor_count += 1;
                self.cursor_row = position.row;
                self.cursor_column = position.column;
            },
            .terminal_reply => |reply| {
                self.reply_count += 1;
                self.last_reply_len = reply.raw.len;
                @memcpy(self.last_reply[0..reply.raw.len], reply.raw);
                self.last_reply_final = reply.final;
                self.last_reply_csi = reply.kind == .csi;
            },
            .malformed => self.malformed += 1,
            else => {},
        }
    }
};

fn expectKeyCode(expected: tui.input.KeyCode, actual: tui.input.KeyCode) !void {
    try std.testing.expect(std.meta.eql(expected, actual));
}
