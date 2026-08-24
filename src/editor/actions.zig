const std = @import("std");
const input = @import("../input/event.zig");
const unicode = @import("../text/unicode_17.zig");
const word_break = @import("../text/word_break.zig");

pub const Mode = enum {
    single_line,
    multiline,
};

pub const Action = union(enum) {
    move_left: bool,
    move_right: bool,
    move_up: bool,
    move_down: bool,
    move_home: bool,
    move_end: bool,
    page_up: bool,
    page_down: bool,
    move_word_left: bool,
    move_word_right: bool,
    delete_backward,
    delete_forward,
    delete_word_backward,
    delete_word_forward,
    insert_codepoint: u21,
    insert_text: []const u8,
    insert_newline,
    select_all,
    undo,
    redo,
};

/// Maps conventional key bindings to semantic actions. Applications may bypass it.
pub inline fn defaultAction(event: input.Event, mode: Mode) ?Action {
    return switch (event) {
        .text => |bytes| .{ .insert_text = bytes },
        .key => |key| mapKey(Action, {}, key, mode, returnAction),
        else => null,
    };
}

/// Applies conventional bindings without forcing callers through an intermediate action value.
pub inline fn applyDefault(context: anytype, event: input.Event, mode: Mode) ?ApplyResult(@TypeOf(context)) {
    const Result = ApplyResult(@TypeOf(context));
    return switch (event) {
        .text => |bytes| applyAction(context, .{ .insert_text = bytes }),
        .key => |key| mapKey(Result, context, key, mode, applyAction),
        else => null,
    };
}

inline fn mapKey(
    comptime Result: type,
    context: anytype,
    key: input.Key,
    mode: Mode,
    comptime emit: anytype,
) ?Result {
    if (key.action == .release or key.modifiers.alt or key.modifiers.super or
        key.modifiers.hyper or key.modifiers.meta) return null;
    const extend = key.modifiers.shift;
    if (key.modifiers.control) {
        return switch (key.code) {
            .left => emit(context, .{ .move_word_left = extend }),
            .right => emit(context, .{ .move_word_right = extend }),
            .backspace => if (!extend) emit(context, .delete_word_backward) else null,
            .delete => if (!extend) emit(context, .delete_word_forward) else null,
            .codepoint => |codepoint| if (!extend and codepoint <= std.math.maxInt(u8))
                switch (std.ascii.toLower(@as(u8, @intCast(codepoint)))) {
                    'a' => emit(context, .select_all),
                    'z' => emit(context, .undo),
                    'y' => emit(context, .redo),
                    else => null,
                }
            else
                null,
            else => null,
        };
    }
    return switch (key.code) {
        .left => emit(context, .{ .move_left = extend }),
        .right => emit(context, .{ .move_right = extend }),
        .up => if (mode == .multiline) emit(context, .{ .move_up = extend }) else null,
        .down => if (mode == .multiline) emit(context, .{ .move_down = extend }) else null,
        .home => emit(context, .{ .move_home = extend }),
        .end => emit(context, .{ .move_end = extend }),
        .page_up => if (mode == .multiline) emit(context, .{ .page_up = extend }) else null,
        .page_down => if (mode == .multiline) emit(context, .{ .page_down = extend }) else null,
        .backspace => if (!extend) emit(context, .delete_backward) else null,
        .delete => if (!extend) emit(context, .delete_forward) else null,
        .enter => if (!extend and mode == .multiline) emit(context, .insert_newline) else null,
        .codepoint => |codepoint| if (!extend) emit(context, .{ .insert_codepoint = codepoint }) else null,
        else => null,
    };
}

inline fn applyAction(context: anytype, action: Action) @TypeOf(context.applyAction(action)) {
    return context.applyAction(action);
}

inline fn returnAction(_: void, action: Action) Action {
    return action;
}

fn ApplyResult(comptime Context: type) type {
    const Target = std.meta.Child(Context);
    return @typeInfo(@TypeOf(Target.applyAction)).@"fn".return_type.?;
}

pub fn previousWordStart(value: []const u8, cursor: usize) usize {
    std.debug.assert(cursor <= value.len);
    var boundaries = word_break.Iterator.init(value) catch unreachable;
    var start: usize = 0;
    var candidate: usize = 0;
    _ = boundaries.next().?;
    while (boundaries.next()) |boundary| {
        const end = boundary.offset;
        if (start < cursor and segmentIsWord(value[start..end])) candidate = start;
        if (end >= cursor) break;
        start = end;
    }
    return candidate;
}

pub fn nextWordEnd(value: []const u8, cursor: usize) usize {
    std.debug.assert(cursor <= value.len);
    var boundaries = word_break.Iterator.init(value) catch unreachable;
    var start: usize = 0;
    _ = boundaries.next().?;
    while (boundaries.next()) |boundary| {
        const end = boundary.offset;
        if (end > cursor and segmentIsWord(value[start..end])) return end;
        start = end;
    }
    return value.len;
}

fn segmentIsWord(value: []const u8) bool {
    var index: usize = 0;
    while (index < value.len) {
        const len = std.unicode.utf8ByteSequenceLength(value[index]) catch unreachable;
        const codepoint = std.unicode.utf8Decode(value[index .. index + len]) catch unreachable;
        const property = unicode.wordBreak(codepoint);
        if (property == .a_letter or property == .hebrew_letter or property == .numeric or
            property == .katakana or property == .extend_num_let or property == .regional_indicator or
            unicode.isExtendedPictographic(codepoint)) return true;
        index += len;
    }
    return false;
}

test "word targets skip separator segments" {
    const value = "one,  two";
    try std.testing.expectEqual(@as(usize, 6), previousWordStart(value, value.len));
    try std.testing.expectEqual(@as(usize, 0), previousWordStart(value, 6));
    try std.testing.expectEqual(@as(usize, 3), nextWordEnd(value, 0));
    try std.testing.expectEqual(value.len, nextWordEnd(value, 3));
}

test "default bindings expose semantic word actions" {
    try std.testing.expectEqual(
        Action{ .move_word_left = true },
        defaultAction(.{ .key = .{
            .code = .left,
            .modifiers = .{ .control = true, .shift = true },
        } }, .single_line).?,
    );
    try std.testing.expect(defaultAction(.{ .key = .{ .code = .up } }, .single_line) == null);
}
