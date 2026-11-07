const std = @import("std");
const tui = @import("tui");
const testing = std.testing;
const ReplyKind = @FieldType(tui.input.TerminalReply, "kind");

fn expectEvents(parser: *tui.input.Parser, parts: []const []const u8, expected: []const tui.input.Event) !void {
    var index: usize = 0;
    for (parts) |part| {
        var offset: usize = 0;
        while (offset < part.len or parser.hasQueuedEvent()) {
            const result = parser.next(part[offset..]);
            offset += result.consumed;
            const event: tui.input.Event = switch (result.outcome) {
                .event => |event| event,
                .failure => .malformed,
                .need_more => {
                    try testing.expectEqual(part.len, offset);
                    continue;
                },
                .done => return error.UnexpectedEnd,
            };
            try testing.expect(index < expected.len);
            try testing.expectEqualDeep(expected[index], event);
            index += 1;
        }
    }
    try testing.expectEqual(expected.len, index);
}

test "fragmented keys preserve identity modifiers and associated text" {
    const cases = [_]struct { bytes: []const u8, event: tui.input.Event }{
        .{ .bytes = "\x1bOP", .event = .{ .key = .{ .code = .{ .function = 1 } } } },
        .{ .bytes = "\x1b[1;2:2S", .event = .{ .key = .{ .code = .{ .function = 4 }, .modifiers = .{ .shift = true }, .action = .repeat } } },
        .{ .bytes = "\x1b[97:65:113;6:2;65:769u", .event = .{ .key = .{
            .code = .{ .codepoint = 'a' },
            .shifted_codepoint = 'A',
            .base_layout_codepoint = 'q',
            .modifiers = .{ .shift = true, .control = true },
            .action = .repeat,
            .text = "A\u{301}",
        } } },
        .{ .bytes = "\x1b[57375;5:3u", .event = .{ .key = .{ .code = .{ .function = 12 }, .modifiers = .{ .control = true }, .action = .release } } },
        .{ .bytes = "\x1b\x01", .event = .{ .key = .{ .code = .{ .codepoint = 'a' }, .modifiers = .{ .alt = true, .control = true } } } },
        .{ .bytes = "\u{e9}", .event = .{ .text = "\u{e9}" } },
        .{ .bytes = "\x1b[1;2R", .event = .{ .cursor_position = .{ .row = 0, .column = 1 } } },
    };
    for (cases) |case| {
        for (0..case.bytes.len + 1) |split| {
            var parser: tui.input.Parser = .{};
            try expectEvents(&parser, &.{ case.bytes[0..split], case.bytes[split..], "x" }, &.{ case.event, .{ .text = "x" } });
        }
    }
}

test "owned events retain text across parser advancement and moves" {
    var parser: tui.input.Parser = .{};
    var owned = try tui.input.OwnedEvent(32).init(parser.next("\x1b[97;;233:769u").outcome.event);
    const moved = owned;
    owned = try tui.input.OwnedEvent(32).init(parser.next("x").outcome.event);
    try testing.expectEqualStrings("\u{e9}\u{301}", moved.borrow().key.text);
}

test "paste cancellation resumes after a fragmented terminator" {
    const end = "\x1b[201~";
    for (0..end.len) |prefix| {
        var parser: tui.input.Parser = .{};
        try expectEvents(&parser, &.{ "\x1b[200~", "zzz", end[0..prefix] }, &.{ .paste_start, .{ .paste_chunk = "zzz" } });
        try testing.expect(parser.cancelPending().outcome == .failure);
        try expectEvents(&parser, &.{ end[prefix..], "x" }, &.{.{ .text = "x" }});
    }
    var parser: tui.input.Parser = .{};
    _ = parser.next("\x1b[200~");
    _ = parser.cancelPending();
    try expectEvents(&parser, &.{"j\r\t\x1b[A\x1b[200~\x1b[201X\x1b\x1b[201~x"}, &.{.{ .text = "x" }});
}

test "EOF drains paste payload and incomplete framing" {
    for ([_]bool{ false, true }) |cancel| {
        var parser: tui.input.Parser = .{};
        _ = parser.next("\x1b[200~");
        if (cancel) _ = parser.cancelPending();
        try expectEvents(&parser, &.{"\x1b[20"}, &.{});
        if (!cancel) {
            try testing.expectEqualStrings("\x1b[20", parser.endInput().outcome.event.paste_chunk);
            try testing.expect(parser.endInput().outcome == .failure);
        }
        try testing.expect(parser.endInput().outcome == .done);
    }
}

test "control string framing survives read splits and rejected replies" {
    inline for (.{
        .{ "\x1b]", "\x07", ReplyKind.osc },
        .{ "\x1b]", "\x1b\\", ReplyKind.osc },
        .{ "\x1b_", "\x1b\\", ReplyKind.apc },
        .{ "\x1bP", "\x1b\\", ReplyKind.dcs },
        .{ "\x1b^", "\x1b\\", ReplyKind.pm },
        .{ "\x1bX", "\x1b\\", ReplyKind.sos },
    }) |case| {
        const bytes = case[0] ++ "reply" ++ case[1];
        for (0..bytes.len + 1) |split| {
            var parser: tui.input.Parser = .{};
            try expectEvents(&parser, &.{ bytes[0..split], bytes[split..], "x" }, &.{
                .{ .terminal_reply = .{ .kind = case[2], .final = case[1][case[1].len - 1], .raw = "reply" } },
                .{ .text = "x" },
            });
        }
    }
    const oversized: [tui.input.Parser.max_terminal_reply_bytes + 1]u8 = @splat('a');
    inline for (.{ "\x1b]title\x1b\x1b\\x", "\x1b]title\x1b\x07x", "\x1bP" ++ oversized ++ "\x1b\\x" }) |bytes| {
        for (0..bytes.len + 1) |split| {
            var parser: tui.input.Parser = .{};
            try expectEvents(&parser, &.{ bytes[0..split], bytes[split..] }, &.{ .malformed, .{ .text = "x" } });
        }
    }
}
