const std = @import("std");
const tui = @import("tui");
const testing = std.testing;

test "single-line editing paste and undo use compact row storage" {
    var text: [16]u8 = undefined;
    var boundaries: [17]tui.editor.Boundary = undefined;
    var rows: [1]tui.editor.VisualRow = undefined;
    var paste: [16]u8 = undefined;
    var model = try tui.editor.Model.initSingleLine(.{
        .text = &text,
        .boundaries = &boundaries,
        .visual_rows = &rows,
        .paste = &paste,
    }, "a\u{754c}");
    var records: [4]tui.editor.HistoryRecord = undefined;
    var bytes: [64]u8 = undefined;
    var history = try tui.editor.History.init(&records, &bytes);
    try model.setHistory(&history);

    _ = try model.replaceSelection("e\u{301}");
    _ = model.handle(.paste_start);
    _ = model.handle(.{ .paste_chunk = "!" });
    try testing.expect(model.handle(.paste_end).failure == null);
    try testing.expectEqualStrings("a\u{754c}e\u{301}!", model.value());
    try testing.expect(try model.undo());
    try testing.expectEqualStrings("a\u{754c}e\u{301}", model.value());
    try testing.expect(try model.redo());
    try testing.expectEqualStrings("a\u{754c}e\u{301}!", model.value());
}

test "history transactions preserve edits when wrapping storage is exhausted" {
    inline for (.{ false, true }) |redo| {
        var text: [8]u8 = undefined;
        var boundaries: [9]tui.editor.Boundary = undefined;
        var rows: [3]tui.editor.VisualRow = undefined;
        var paste: [8]u8 = undefined;
        var model = try tui.editor.Model.initSingleLine(.{
            .text = &text,
            .boundaries = &boundaries,
            .visual_rows = &rows,
            .paste = &paste,
        }, if (redo) "" else "abcdef");
        var records: [4]tui.editor.HistoryRecord = undefined;
        var bytes: [32]u8 = undefined;
        var history = try tui.editor.History.init(&records, &bytes);
        try model.setHistory(&history);
        history.beginTransaction();
        if (redo) {
            _ = try model.replaceSelection("a");
            _ = try model.replaceSelection("bcdef");
        } else {
            _ = try model.setSelection(1, 6);
            _ = try model.replaceSelection("");
            _ = model.selectAll();
            _ = try model.replaceSelection("");
        }
        history.endTransaction();
        if (redo) _ = try model.undo();
        _ = try model.setSoftWrap(true);
        try testing.expectError(error.CapacityExceeded, if (redo) model.redo() else model.undo());
        try testing.expectEqualStrings("", model.value());
        _ = try model.setSoftWrap(false);
        try testing.expect(if (redo) try model.redo() else try model.undo());
        try testing.expectEqualStrings("abcdef", model.value());
    }
}

test "word navigation and deletion keep prepended graphemes together" {
    const value = "\u{0600}\u{1f600}";
    var storage: tui.editor.FixedStorage(32) = .{};
    var model = try tui.editor.Model.initSingleLine(storage.slices(), value);

    _ = model.applyAction(.{ .move_word_left = false });
    try testing.expectEqual(@as(usize, 0), model.cursorOffset());
    _ = model.applyAction(.{ .move_word_right = true });
    try testing.expectEqualStrings(value, model.selectedText().?);
    _ = model.applyAction(.delete_word_backward);
    try testing.expectEqualStrings("", model.value());

    _ = try model.replaceSelection(value);
    _ = try model.setCursor(0);
    _ = model.applyAction(.delete_word_forward);
    try testing.expectEqualStrings("", model.value());
}

test "visual hit testing shares grapheme boundaries and soft-wrap affinity with editing" {
    var storage: tui.editor.FixedStorage(64) = .{};
    var model = try tui.editor.Model.init(storage.slices(), "a界e\u{301}z\n\nlast");
    _ = model.setViewportSize(4, 3);
    _ = try model.setSoftWrap(true);

    try testing.expectEqual(@as(?usize, 1), model.offsetAtVisualPosition(.{ .row = 0, .column = 2 }));
    try testing.expectEqual(@as(?usize, 4), model.offsetAtVisualPosition(.{ .row = 0, .column = 3 }));
    _ = try model.setVisualCursor(.{ .row = 0, .column = 99 }, false);
    try testing.expectEqual(@as(usize, 7), model.cursorOffset());
    try testing.expectEqualDeep(tui.editor.Position{ .row = 0, .column = 4 }, model.visualCursorPosition());
    _ = try model.setVisualCursor(.{ .row = 1, .column = 0 }, false);
    try testing.expectEqual(@as(usize, 7), model.cursorOffset());
    try testing.expectEqualDeep(tui.editor.Position{ .row = 1, .column = 0 }, model.visualCursorPosition());
    _ = try model.setVisualCursor(.{ .row = 0, .column = 1 }, true);
    try testing.expectEqualStrings("界e\u{301}", model.selectedText().?);
    try testing.expectEqual(@as(?usize, 9), model.offsetAtVisualPosition(.{ .row = 2, .column = 99 }));

    _ = model.setViewportSize(2, 2);
    try testing.expectEqual(@as(?usize, 1), model.offsetAtVisualPosition(.{ .row = 1, .column = 1 }));
    _ = try model.setSoftWrap(false);
    _ = model.setViewportSize(3, 2);
    _ = try model.setCursor(4);
    try testing.expectEqual(@as(?usize, 1), model.offsetAtVisualPosition(.{ .row = model.viewport.top_row, .column = model.viewport.left_column + 1 }));
    _ = try model.setSelection(1, 7);
    _ = try model.replaceSelection("X");
    try testing.expectEqualStrings("aXz\n\nlast", model.value());
}
