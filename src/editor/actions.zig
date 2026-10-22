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

pub inline fn defaultAction(event: input.Event, mode: Mode) ?Action {
    return switch (event) {
        .text => |bytes| .{ .insert_text = bytes },
        .key => |key| keyAction(key, mode),
        else => null,
    };
}

inline fn keyAction(key: input.Key, mode: Mode) ?Action {
    if (key.action == .release) return null;
    if (key.text.len != 0) return .{ .insert_text = key.text };
    if (key.modifiers.alt or key.modifiers.super or
        key.modifiers.hyper or key.modifiers.meta) return null;
    const extend = key.modifiers.shift;
    if (key.modifiers.control) {
        return switch (key.code) {
            .left => .{ .move_word_left = extend },
            .right => .{ .move_word_right = extend },
            .backspace => if (!extend) .delete_word_backward else null,
            .delete => if (!extend) .delete_word_forward else null,
            .codepoint => |codepoint| if (!extend and codepoint <= std.math.maxInt(u8))
                switch (std.ascii.toLower(@as(u8, @intCast(codepoint)))) {
                    'a' => .select_all,
                    'z' => .undo,
                    'y' => .redo,
                    else => null,
                }
            else
                null,
            else => null,
        };
    }
    return switch (key.code) {
        .left => .{ .move_left = extend },
        .right => .{ .move_right = extend },
        .up => if (mode == .multiline) .{ .move_up = extend } else null,
        .down => if (mode == .multiline) .{ .move_down = extend } else null,
        .home => .{ .move_home = extend },
        .end => .{ .move_end = extend },
        .page_up => if (mode == .multiline) .{ .page_up = extend } else null,
        .page_down => if (mode == .multiline) .{ .page_down = extend } else null,
        .backspace => if (!extend) .delete_backward else null,
        .delete => if (!extend) .delete_forward else null,
        .enter => if (!extend and mode == .multiline) .insert_newline else null,
        .codepoint => |codepoint| .{ .insert_codepoint = if (extend) key.shifted_codepoint orelse codepoint else codepoint },
        else => null,
    };
}

pub fn previousWordStart(value: []const u8, cursor: usize) usize {
    std.debug.assert(cursor <= value.len);
    var boundaries = word_break.Iterator{ .input = value };
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
    var boundaries = word_break.Iterator{ .input = value };
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
