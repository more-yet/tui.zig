const std = @import("std");
const tui = @import("tui");
const testing = std.testing;

test "bracketed paste commits once after fragmented input" {
    const repeated_z: [300]u8 = @splat('z');
    const cases = [_]struct { bytes: []const u8, value: []const u8, failure: ?tui.editor.EditError }{
        .{ .bytes = "\x1b[200~zzzj\x1b[201~x", .value = "zzzjx", .failure = null },
        .{ .bytes = "\x1b[200~zzzj\r\x1b[201~x", .value = "x", .failure = error.InvalidText },
        .{ .bytes = "\x1b[200~" ++ repeated_z ++ "j\r\x1b[201~x", .value = "x", .failure = error.PasteCapacityExceeded },
    };
    for (cases) |case| {
        for (0..case.bytes.len + 1) |split| {
            var storage: tui.editor.FixedStorage(32) = .{};
            var model = try tui.editor.Model.initSingleLine(storage.slices(), "");
            var input = tui.widget.TextInput.init(&model);
            var parser: tui.input.Parser = .{};
            var ended = false;
            for ([_][]const u8{ case.bytes[0..split], case.bytes[split..] }) |part| {
                var offset: usize = 0;
                while (offset < part.len or parser.hasQueuedEvent()) {
                    const result = parser.next(part[offset..]);
                    offset += result.consumed;
                    switch (result.outcome) {
                        .event => |event| {
                            switch (event) {
                                .paste_start, .paste_chunk => {},
                                .paste_end => ended = true,
                                .text => {
                                    try testing.expect(ended);
                                    try testing.expectEqualStrings("x", event.text);
                                },
                                else => return error.UnexpectedEvent,
                            }
                            _ = input.handle(event);
                            if (!ended) try testing.expectEqualStrings("", model.value());
                        },
                        .need_more => try testing.expectEqual(part.len, offset),
                        else => return error.UnexpectedOutcome,
                    }
                }
            }
            try testing.expect(ended);
            try testing.expectEqualStrings(case.value, model.value());
            try testing.expectEqual(case.failure, input.takeFailure());
        }
    }
}
