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
        .{ .bytes = "\x1b[13;1:3u", .event = .{ .key = .{ .code = .enter, .action = .release } } },
        .{ .bytes = "\x1b[97;;u", .event = .{ .key = .{ .code = .{ .codepoint = 'a' } } } },
        .{ .bytes = "\x1b[97:65u", .event = .malformed },
        .{ .bytes = "\x1b[97::113u", .event = .{ .key = .{ .code = .{ .codepoint = 'a' }, .base_layout_codepoint = 'q' } } },
        .{ .bytes = "\x1b[97:65:113;6:2;65:769u", .event = .{ .key = .{
            .code = .{ .codepoint = 'a' },
            .shifted_codepoint = 'A',
            .base_layout_codepoint = 'q',
            .modifiers = .{ .shift = true, .control = true },
            .action = .repeat,
            .text = "A\u{301}",
        } } },
        .{ .bytes = "\x1b[97;;27u", .event = .malformed },
        .{ .bytes = "\x1b[97;;55296u", .event = .malformed },
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

test "associated text stays owned after parser advancement and can be securely disposed" {
    var parser: tui.input.Parser = .{};
    const event = parser.next("\x1b[97;;233:769u").outcome.event;
    var owned = try tui.input.OwnedEvent(32).init(event);
    var moved = owned;
    owned.secureDeinit();
    _ = parser.next("x");
    try testing.expectEqualStrings("\u{e9}\u{301}", moved.borrow().key.text);
    moved.secureDeinit();
    try testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&moved), 0));
    _ = parser.next("\x1b[200~secret");
    try testing.expectError(error.PendingInput, parser.secureDeinit());
    _ = parser.cancelPending();
    try testing.expectError(error.PendingInput, parser.secureDeinit());
    _ = parser.next("\x1b[201~");
    try parser.secureDeinit();
    try testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&parser), 0));
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
    const repeated_z: [1024]u8 = @splat('z');
    const payload = "j\r\t\x1b[A\x1b[200~\x1b[201X" ++ repeated_z ++ "\x1b\x1b[201~x";
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
    const full_payload: [limit]u8 = @splat('a');
    const oversized_payload: [limit + 1]u8 = @splat('a');
    const cases = .{
        "\x1b]title\x1b\x1b\\x",
        "\x1b]title\x1b\x07x",
        "\x1b]" ++ full_payload ++ "\x1b\x1b\\x",
        "\x1b]" ++ oversized_payload ++ "\x1b\x07x",
        "\x1b_Gi=1;bad\x1b\x1b\\x",
        "\x1b_" ++ full_payload ++ "\x1b\x1b\\x",
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
    const full_payload: [tui.input.Parser.max_terminal_reply_bytes]u8 = @splat('a');
    inline for (.{ .{ "\x1b]", "\x07", ReplyKind.osc }, .{ "\x1b]", "\x1b\\", ReplyKind.osc }, .{ "\x1b_", "\x1b\\", ReplyKind.apc } }) |case| {
        const bytes = case[0] ++ full_payload ++ case[1];
        var parser: tui.input.Parser = .{};
        for (bytes, 0..) |byte, index| {
            const parsed = parser.next(&.{byte});
            try testing.expectEqual(@as(usize, 1), parsed.consumed);
            if (index + 1 < bytes.len) {
                try testing.expect(parsed.outcome == .need_more);
            } else {
                const reply = parsed.outcome.event.terminal_reply;
                try testing.expectEqual(case[2], reply.kind);
                try testing.expectEqualStrings(&full_payload, reply.raw);
            }
        }
    }
}
