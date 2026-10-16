const std = @import("std");
const tui = @import("tui");
const testing = std.testing;

test "text input caret geometry matches painting without losing focus styling" {
    const focused_style: tui.render.Style = .{ .foreground = .{ .indexed = 2 } };
    for ([_]tui.widget.TextInput.DisplayMode{ .plain, .masked }) |mode| {
        for ([_][]const u8{ "", "abcd", "abcdef", "a\u{754c}e\u{301}" }) |value| {
            var editor_storage: tui.editor.FixedStorage(32) = .{};
            var model = try tui.editor.Model.initSingleLine(editor_storage.slices(), value);
            var input = tui.widget.TextInput.init(&model);
            input.display_mode = mode;
            input.focused = true;
            input.role.focused = focused_style;
            var storage: tui.render.FixedRendererStorage(8, 2, 4, 4) = .{};
            var renderer = try tui.render.Renderer.init(storage.slices(), .{ .width = 8, .height = 2 });
            defer renderer.deinit();
            for ([_]u16{ 4, 1, 6 }) |width| {
                var surface = renderer.surface(.{ .x = 1, .y = 1, .width = width, .height = 1 });
                for ([_]usize{ value.len, 0 }) |offset| {
                    _ = try model.setCursor(offset);
                    input.paint_caret = false;
                    try input.draw(&surface);
                    const local = input.caretPosition(surface.size()).?;
                    const point = surface.screenPoint(local).?;
                    var scratch: [tui.text.max_grapheme_bytes]u8 = undefined;
                    const cell = renderer.desiredCellView(point, &scratch).?;
                    try testing.expect(cell.style.eql(focused_style));
                    if (mode == .masked) try testing.expect(std.mem.eql(u8, cell.glyph, "*") or std.mem.eql(u8, cell.glyph, " "));
                    try renderer.setCursor(.{ .position = point });
                    try testing.expectEqual(point, renderer.desired_cursor.?.position);
                    input.paint_caret = true;
                    try input.draw(&surface);
                    try testing.expectEqual(local, input.caretPosition(surface.size()).?);
                    var painted_style = focused_style;
                    painted_style.attributes.reverse = true;
                    try testing.expect(renderer.desiredCellView(point, &scratch).?.style.eql(painted_style));
                }
            }
            input.focused = false;
            try testing.expect(input.caretPosition(.{ .width = 4, .height = 1 }) == null);
            input.focused = true;
            input.enabled = false;
            try testing.expect(input.caretPosition(.{ .width = 4, .height = 1 }) == null);
            input.enabled = true;
            try testing.expect(input.caretPosition(.{ .width = 0, .height = 1 }) == null);
            try testing.expect(input.caretPosition(.{ .width = 4, .height = 0 }) == null);
            var parent = renderer.surface(.{ .x = 6, .y = 1, .width = 2, .height = 1 });
            const clipped = parent.surface(.{ .x = 1, .y = 0, .width = 4, .height = 1 });
            try testing.expectEqual(tui.render.Point{ .x = 7, .y = 1 }, clipped.screenPoint(.{ .x = 0, .y = 0 }).?);
            try testing.expect(clipped.screenPoint(.{ .x = 1, .y = 0 }) == null);
        }
    }
}

test "accepted and rejected pastes cannot become commands across read splits" {
    const cases = [_]struct { bytes: []const u8, value: []const u8, failure: ?tui.editor.EditError }{
        .{ .bytes = "\x1b[200~zzzj\x1b[201~x", .value = "zzzjx", .failure = null },
        .{ .bytes = "\x1b[200~zzzj\r\x1b[201~x", .value = "x", .failure = error.InvalidText },
        .{ .bytes = "\x1b[200~" ++ ("z" ** 300) ++ "j\r\x1b[201~x", .value = "x", .failure = error.PasteCapacityExceeded },
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
