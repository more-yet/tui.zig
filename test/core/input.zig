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

test "function key encodings preserve framing and metadata at every read split" {
    const cases = [_]struct { bytes: []const u8, event: tui.input.Event }{
        .{ .bytes = "\x1b[[A", .event = .{ .key = .{ .code = .{ .function = 1 } } } },
        .{ .bytes = "\x1b[[B", .event = .{ .key = .{ .code = .{ .function = 2 } } } },
        .{ .bytes = "\x1b[[C", .event = .{ .key = .{ .code = .{ .function = 3 } } } },
        .{ .bytes = "\x1b[[D", .event = .{ .key = .{ .code = .{ .function = 4 } } } },
        .{ .bytes = "\x1b[[E", .event = .{ .key = .{ .code = .{ .function = 5 } } } },
        .{ .bytes = "\x1b[17~", .event = .{ .key = .{ .code = .{ .function = 6 } } } },
        .{ .bytes = "\x1bOP", .event = .{ .key = .{ .code = .{ .function = 1 } } } },
        .{ .bytes = "\x1bOR", .event = .{ .key = .{ .code = .{ .function = 3 } } } },
        .{ .bytes = "\x1b[P", .event = .{ .key = .{ .code = .{ .function = 1 } } } },
        .{ .bytes = "\x1b[1Q", .event = .{ .key = .{ .code = .{ .function = 2 } } } },
        .{ .bytes = "\x1b[1;2:2S", .event = .{ .key = .{ .code = .{ .function = 4 }, .modifiers = .{ .shift = true }, .action = .repeat } } },
        .{ .bytes = "\x1b[1;5:3P", .event = .{ .key = .{ .code = .{ .function = 1 }, .modifiers = .{ .control = true }, .action = .release } } },
        .{ .bytes = "\x1b[13~", .event = .{ .key = .{ .code = .{ .function = 3 } } } },
        .{ .bytes = "\x1b[1;2R", .event = .{ .cursor_position = .{ .row = 0, .column = 1 } } },
        .{ .bytes = "\x1b[?1P", .event = .{ .terminal_reply = .{ .kind = .csi, .final = 'P', .raw = "?1" } } },
        .{ .bytes = "\x1b[[Z", .event = .malformed },
    };
    for (cases) |case| {
        for (0..case.bytes.len + 1) |split| {
            var parser: tui.input.Parser = .{};
            try expectEvents(&parser, &.{ case.bytes[0..split], case.bytes[split..], "x" }, &.{ case.event, .{ .text = "x" } });
            try testing.expectEqual(.none, parser.pending());
        }
    }
}

test "cancelled paste discards payload and preserves every partial terminator" {
    const end = "\x1b[201~";
    for (0..end.len) |prefix| {
        var parser: tui.input.Parser = .{};
        try expectEvents(&parser, &.{ "\x1b[200~", "zzz", end[0..prefix] }, &.{ .paste_start, .{ .paste_chunk = "zzz" } });
        try testing.expectEqual(.paste, parser.pending());
        try testing.expectEqual(.malformed_sequence, parser.cancelPending().outcome.failure);
        try testing.expect(parser.cancelPending().outcome == .done);
        try testing.expectEqual(.paste, parser.pending());
        try expectEvents(&parser, &.{ end[prefix..], "x" }, &.{.{ .text = "x" }});
        try testing.expectEqual(.none, parser.pending());
    }
    const payload = "j\r\t\x1b[A\x1b[200~\x1b[201X" ++ ("z" ** 1024) ++ "\x1b\x1b[201~x";
    for (0..payload.len + 1) |split| {
        var parser: tui.input.Parser = .{};
        try expectEvents(&parser, &.{"\x1b[200~"}, &.{.paste_start});
        try testing.expect(parser.cancelPending().outcome == .failure);
        try expectEvents(&parser, &.{ payload[0..split], payload[split..] }, &.{.{ .text = "x" }});
        try testing.expectEqual(.none, parser.pending());
    }
}

test "unterminated paste ends safely at EOF and ordinary sequences still cancel" {
    for ([_]bool{ false, true }) |cancel| {
        var parser: tui.input.Parser = .{};
        try expectEvents(&parser, &.{"\x1b[200~"}, &.{.paste_start});
        if (cancel) try testing.expect(parser.cancelPending().outcome == .failure);
        try expectEvents(&parser, &.{"\x1b[20"}, &.{});
        if (!cancel) {
            try testing.expectEqualStrings("\x1b[20", parser.endInput().outcome.event.paste_chunk);
            try testing.expect(parser.endInput().outcome == .failure);
        }
        try testing.expect(parser.endInput().outcome == .done);
        try testing.expectEqual(.none, parser.pending());
    }
    var parser: tui.input.Parser = .{};
    try expectEvents(&parser, &.{"\x1b[["}, &.{});
    try testing.expectEqual(.sequence, parser.pending());
    try testing.expect(parser.cancelPending().outcome == .failure);
    try expectEvents(&parser, &.{"x"}, &.{.{ .text = "x" }});
}

test "control strings share bounded framing and preserve input after rejection" {
    const limit = tui.input.Parser.max_terminal_reply_bytes;
    const cases = .{
        "\x1b]title\x1b\x1b\\x",
        "\x1b]title\x1b\x07x",
        "\x1b]" ++ ("a" ** limit) ++ "\x1b\x1b\\x",
        "\x1b]" ++ ("a" ** (limit + 1)) ++ "\x1b\x07x",
        "\x1b_Gi=1;bad\x1b\x1b\\x",
        "\x1b_" ++ ("a" ** limit) ++ "\x1b\x1b\\x",
    };
    inline for (cases) |bytes| {
        for (0..bytes.len + 1) |split| {
            var parser: tui.input.Parser = .{};
            var failures: usize = 0;
            var text_count: usize = 0;
            for ([_][]const u8{ bytes[0..split], bytes[split..] }) |part| {
                var offset: usize = 0;
                while (offset < part.len or parser.hasQueuedEvent()) {
                    const parsed = parser.next(part[offset..]);
                    offset += parsed.consumed;
                    switch (parsed.outcome) {
                        .failure => failures += 1,
                        .event => |event| {
                            try testing.expect(event == .text);
                            try testing.expectEqualStrings("x", event.text);
                            text_count += 1;
                        },
                        .need_more => try testing.expectEqual(part.len, offset),
                        .done => return error.UnexpectedEnd,
                    }
                }
            }
            try testing.expectEqual(@as(usize, 1), failures);
            try testing.expectEqual(@as(usize, 1), text_count);
            try testing.expectEqual(tui.input.Parser.Pending.none, parser.pending());
        }
    }
}

test "OSC accepts BEL and ST while APC accepts ST with the full payload capacity" {
    inline for (.{ .{ "\x1b]", "\x07", ReplyKind.osc }, .{ "\x1b]", "\x1b\\", ReplyKind.osc }, .{ "\x1b_", "\x1b\\", ReplyKind.apc } }) |case| {
        const bytes = case[0] ++ ("a" ** tui.input.Parser.max_terminal_reply_bytes) ++ case[1];
        var parser: tui.input.Parser = .{};
        for (bytes, 0..) |byte, index| {
            const parsed = parser.next(&.{byte});
            try testing.expectEqual(@as(usize, 1), parsed.consumed);
            if (index + 1 < bytes.len) {
                try testing.expect(parsed.outcome == .need_more);
            } else {
                const reply = parsed.outcome.event.terminal_reply;
                try testing.expectEqual(case[2], reply.kind);
                try testing.expectEqualStrings("a" ** tui.input.Parser.max_terminal_reply_bytes, reply.raw);
            }
        }
    }
}
