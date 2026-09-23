const std = @import("std");
const tui = @import("tui");
const testing = std.testing;
const ReplyKind = @FieldType(tui.input.TerminalReply, "kind");

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
        // Each possible split includes an empty prefix/suffix and splits the
        // introducer, capacity boundary, and terminator.
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
