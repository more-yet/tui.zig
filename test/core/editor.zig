const std = @import("std");
const tui = @import("tui");

const testing = std.testing;
const prepended_emoji = "\u{0600}\u{1f600}";

test "one-row single-line storage supports Unicode edits paste and history without enabling unsafe wrapping" {
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
    var history_bytes: [64]u8 = undefined;
    var history = try tui.editor.History.init(&records, &history_bytes);
    try model.setHistory(&history);
    _ = model.setViewportSize(1, 1);
    try expectSuccessfulRedraw(model.handle(.{ .text = "e\u{301}" }));
    try testing.expectEqualStrings("a\u{754c}e\u{301}", model.value());
    try testing.expectEqual(@as(usize, 1), model.visual_row_count);
    try testing.expectEqual(@as(usize, 4), rows[0].width);
    const viewport = model.viewport;
    try testing.expectError(error.IndexCapacityExceeded, model.setSoftWrap(true));
    try testing.expect(!model.softWrapEnabled());
    try testing.expectEqual(viewport, model.viewport);
    try testing.expectEqual(error.InvalidText, model.handle(.{ .text = "\n" }).failure.?);

    _ = model.handle(.paste_start);
    _ = model.handle(.{ .paste_chunk = "!" });
    try expectSuccessfulRedraw(model.handle(.paste_end));
    try testing.expect(try model.undo());
    try testing.expectEqualStrings("a\u{754c}e\u{301}", model.value());
    try testing.expect(try model.redo());
    try testing.expectEqualStrings("a\u{754c}e\u{301}!", model.value());
    try testing.expectEqual(@as(usize, 5), rows[0].width);
    _ = model.selectAll();
    try testing.expect(try model.replaceSelection("1234567890123456"));
    try testing.expectEqual(error.CapacityExceeded, model.handle(.{ .text = "x" }).failure.?);
    try testing.expectEqualStrings("1234567890123456", model.value());

    _ = model.selectAll();
    try testing.expect(try model.replaceSelection(""));
    try testing.expect(try model.setSoftWrap(true));
    try testing.expectEqual(error.CapacityExceeded, model.handle(.{ .text = "a" }).failure.?);
    try testing.expectEqualStrings("", model.value());
    try testing.expect(try model.setSoftWrap(false));
    try expectSuccessfulRedraw(model.handle(.{ .text = "a" }));

    var full: tui.editor.FixedStorage(8) = .{};
    var wrapped = try tui.editor.Model.initSingleLine(full.slices(), "abcd");
    _ = wrapped.setViewportSize(2, 1);
    try testing.expect(try wrapped.setSoftWrap(true));
    try testing.expectEqual(@as(usize, 2), wrapped.visual_row_count);
    _ = wrapped.setViewportSize(1, 1);
    try testing.expectEqual(@as(usize, 4), wrapped.visual_row_count);
    try testing.expect(try wrapped.setSoftWrap(false));
    try testing.expectEqual(@as(usize, 1), wrapped.visual_row_count);
}

fn expectSuccessfulRedraw(result: tui.editor.EventResult) !void {
    try testing.expectEqual(tui.editor.EventStatus.redraw, result.status);
    try testing.expect(result.failure == null);
}

test "word movement snaps candidates to the enclosing grapheme" {
    var storage: tui.editor.FixedStorage(32) = .{};
    var model = try tui.editor.Model.initSingleLine(storage.slices(), prepended_emoji);

    try expectSuccessfulRedraw(model.applyAction(.{ .move_word_left = false }));
    try testing.expectEqual(@as(usize, 0), model.cursorOffset());
    try expectSuccessfulRedraw(model.applyAction(.{ .move_word_right = false }));
    try testing.expectEqual(prepended_emoji.len, model.cursorOffset());

    _ = try model.setCursor(prepended_emoji.len);
    try expectSuccessfulRedraw(model.applyAction(.{ .move_word_left = true }));
    const backward_selection = model.selection().?;
    try testing.expectEqual(@as(usize, 0), backward_selection.start);
    try testing.expectEqual(prepended_emoji.len, backward_selection.end);

    _ = try model.setCursor(0);
    try expectSuccessfulRedraw(model.applyAction(.{ .move_word_right = true }));
    const forward_selection = model.selection().?;
    try testing.expectEqual(@as(usize, 0), forward_selection.start);
    try testing.expectEqual(prepended_emoji.len, forward_selection.end);
}

test "word movement collapses a selection only at grapheme boundaries" {
    var storage: tui.editor.FixedStorage(32) = .{};
    var model = try tui.editor.Model.initSingleLine(storage.slices(), prepended_emoji);

    _ = try model.setSelection(0, prepended_emoji.len);
    try expectSuccessfulRedraw(model.applyAction(.{ .move_word_left = false }));
    try testing.expectEqual(@as(usize, 0), model.cursorOffset());
    try testing.expect(model.selection() == null);

    _ = try model.setSelection(prepended_emoji.len, 0);
    try expectSuccessfulRedraw(model.applyAction(.{ .move_word_right = false }));
    try testing.expectEqual(prepended_emoji.len, model.cursorOffset());
    try testing.expect(model.selection() == null);
}

test "word deletion removes a whole prepended grapheme" {
    {
        var storage: tui.editor.FixedStorage(32) = .{};
        var model = try tui.editor.Model.initSingleLine(storage.slices(), prepended_emoji);

        try expectSuccessfulRedraw(model.applyAction(.delete_word_backward));
        try testing.expectEqualStrings("", model.value());
        try testing.expectEqual(@as(usize, 0), model.cursorOffset());
    }

    {
        var storage: tui.editor.FixedStorage(32) = .{};
        var model = try tui.editor.Model.initSingleLine(storage.slices(), prepended_emoji);
        _ = try model.setCursor(0);

        try expectSuccessfulRedraw(model.applyAction(.delete_word_forward));
        try testing.expectEqualStrings("", model.value());
        try testing.expectEqual(@as(usize, 0), model.cursorOffset());
    }
}

test "word deletion honors an existing whole-grapheme selection" {
    const value = "a\u{0600}\u{1f600}b";

    {
        var storage: tui.editor.FixedStorage(32) = .{};
        var model = try tui.editor.Model.initSingleLine(storage.slices(), value);
        _ = try model.setSelection(1, 7);

        try expectSuccessfulRedraw(model.applyAction(.delete_word_backward));
        try testing.expectEqualStrings("ab", model.value());
        try testing.expectEqual(@as(usize, 1), model.cursorOffset());
    }

    {
        var storage: tui.editor.FixedStorage(32) = .{};
        var model = try tui.editor.Model.initSingleLine(storage.slices(), value);
        _ = try model.setSelection(7, 1);

        try expectSuccessfulRedraw(model.applyAction(.delete_word_forward));
        try testing.expectEqualStrings("ab", model.value());
        try testing.expectEqual(@as(usize, 1), model.cursorOffset());
    }
}
