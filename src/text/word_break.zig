const std = @import("std");
const unicode = @import("unicode_17.zig");

pub const Boundary = struct {
    offset: usize,
};

/// Iterates Unicode default word boundaries without retaining or allocating input.
pub const Iterator = struct {
    input: []const u8,
    index: usize = 0,
    emitted_start: bool = false,
    emitted_end: bool = false,
    previous_raw: ?Token = null,
    previous: ?Token = null,
    previous_previous: ?Token = null,
    regional_indicator_count: usize = 0,

    pub fn init(input: []const u8) error{InvalidUtf8}!Iterator {
        if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
        return .{ .input = input };
    }

    pub fn next(self: *Iterator) ?Boundary {
        if (!self.emitted_start) {
            self.emitted_start = true;
            return .{ .offset = 0 };
        }
        while (self.index < self.input.len) {
            const current = decode(self.input, self.index);
            self.index = current.end;
            if (self.previous_raw == null) {
                self.push(current);
                continue;
            }
            const boundary = self.breaksBefore(current);
            self.push(current);
            if (boundary) return .{ .offset = current.start };
        }
        if (!self.emitted_end and self.input.len != 0) {
            self.emitted_end = true;
            return .{ .offset = self.input.len };
        }
        return null;
    }

    fn breaksBefore(self: *const Iterator, current: Token) bool {
        const raw = self.previous_raw.?;
        const raw_property = raw.property;
        const property = current.property;

        if (raw_property == .cr and property == .lf) return false;
        if (isNewline(raw_property) or isNewline(property)) return true;
        if (raw_property == .zwj and unicode.isExtendedPictographic(current.codepoint)) return false;
        if (raw_property == .w_seg_space and property == .w_seg_space) return false;
        if (isIgnored(property)) return false;

        const previous = self.previous orelse return true;
        const left = previous.property;
        if (isNewline(left)) return true;
        const before_left = if (self.previous_previous) |token| token.property else null;
        const after_right = nextEffective(self.input, current.end);

        if (isAhLetter(left) and isAhLetter(property)) return false;
        if (isAhLetter(left) and isMidLetterOrQuote(property) and
            after_right != null and isAhLetter(after_right.?.property)) return false;
        if (before_left != null and isAhLetter(before_left.?) and
            isMidLetterOrQuote(left) and isAhLetter(property)) return false;
        if (left == .hebrew_letter and property == .single_quote) return false;
        if (left == .hebrew_letter and property == .double_quote and
            after_right != null and after_right.?.property == .hebrew_letter) return false;
        if (before_left == .hebrew_letter and left == .double_quote and property == .hebrew_letter) return false;
        if (left == .numeric and property == .numeric) return false;
        if (isAhLetter(left) and property == .numeric) return false;
        if (left == .numeric and isAhLetter(property)) return false;
        if (left == .numeric and isMidNumberOrQuote(property) and
            after_right != null and after_right.?.property == .numeric) return false;
        if (before_left == .numeric and isMidNumberOrQuote(left) and property == .numeric) return false;
        if (left == .katakana and property == .katakana) return false;
        if (isWordCore(left) and property == .extend_num_let) return false;
        if (left == .extend_num_let and isWordBase(property)) return false;
        if (left == .regional_indicator and property == .regional_indicator and
            self.regional_indicator_count & 1 == 1) return false;
        return true;
    }

    fn push(self: *Iterator, token: Token) void {
        self.previous_raw = token;
        if (isIgnored(token.property)) return;
        self.previous_previous = self.previous;
        self.previous = token;
        if (token.property == .regional_indicator) {
            self.regional_indicator_count = if (self.previous_previous != null and
                self.previous_previous.?.property == .regional_indicator)
                self.regional_indicator_count + 1
            else
                1;
        } else {
            self.regional_indicator_count = 0;
        }
    }
};

const Token = struct {
    start: usize,
    end: usize,
    codepoint: u21,
    property: unicode.WordBreak,
};

fn decode(input: []const u8, start: usize) Token {
    const len = std.unicode.utf8ByteSequenceLength(input[start]) catch unreachable;
    const end = start + len;
    const codepoint = std.unicode.utf8Decode(input[start..end]) catch unreachable;
    return .{
        .start = start,
        .end = end,
        .codepoint = codepoint,
        .property = unicode.wordBreak(codepoint),
    };
}

fn nextEffective(input: []const u8, start: usize) ?Token {
    var index = start;
    while (index < input.len) {
        const token = decode(input, index);
        if (!isIgnored(token.property)) return token;
        index = token.end;
    }
    return null;
}

inline fn isIgnored(property: unicode.WordBreak) bool {
    return property == .extend or property == .format or property == .zwj;
}

inline fn isNewline(property: unicode.WordBreak) bool {
    return property == .cr or property == .lf or property == .newline;
}

inline fn isAhLetter(property: unicode.WordBreak) bool {
    return property == .a_letter or property == .hebrew_letter;
}

inline fn isMidLetterOrQuote(property: unicode.WordBreak) bool {
    return property == .mid_letter or property == .mid_num_let or property == .single_quote;
}

inline fn isMidNumberOrQuote(property: unicode.WordBreak) bool {
    return property == .mid_num or property == .mid_num_let or property == .single_quote;
}

inline fn isWordBase(property: unicode.WordBreak) bool {
    return isAhLetter(property) or property == .numeric or property == .katakana;
}

inline fn isWordCore(property: unicode.WordBreak) bool {
    return isWordBase(property) or property == .extend_num_let;
}

test "word boundaries preserve letters numbers punctuation and regional indicators" {
    const input = "can't 3.14 \xF0\x9F\x87\xBA\xF0\x9F\x87\xB8\xF0\x9F\x87\xA8\xF0\x9F\x87\xA6";
    var iterator = try Iterator.init(input);
    var offsets: [16]usize = undefined;
    var len: usize = 0;
    while (iterator.next()) |boundary| {
        offsets[len] = boundary.offset;
        len += 1;
    }
    try std.testing.expectEqualSlices(usize, &.{ 0, 5, 6, 10, 11, 19, 27 }, offsets[0..len]);
}

test "word boundaries reject invalid UTF-8" {
    try std.testing.expectError(error.InvalidUtf8, Iterator.init("\xC0\x80"));
}
