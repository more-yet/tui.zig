const std = @import("std");
const tui = @import("tui");

const testing = std.testing;
const prepended_emoji = "\u{0600}\u{1f600}";

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
