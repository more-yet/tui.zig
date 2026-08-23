const std = @import("std");
const unicode = @import("unicode_17.zig");

pub const WidthProfile = enum {
    narrow,
    wide_ambiguous,
};

pub const max_cluster_bytes = 48;

pub const Cluster = struct {
    bytes: []const u8,

    pub fn displayWidth(self: Cluster, profile: WidthProfile) WidthError!u2 {
        return width(self.bytes, profile);
    }

    /// Requires valid UTF-8 and is intended for clusters returned by `Iterator`.
    pub fn displayWidthAssumeValid(self: Cluster, profile: WidthProfile) WidthError!u2 {
        return widthValidated(self.bytes, profile);
    }
};

pub const Iterator = struct {
    input: []const u8,
    index: usize = 0,

    pub fn init(input: []const u8) error{InvalidUtf8}!Iterator {
        if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
        return .{ .input = input };
    }

    pub fn next(self: *Iterator) ?Cluster {
        if (self.index == self.input.len) return null;

        const start = self.index;
        var decoded = decode(self.input, self.index);
        self.index = decoded.end;

        var previous = unicode.graphemeBreak(decoded.codepoint);
        var state = State.init(decoded.codepoint, previous);

        while (self.index < self.input.len) {
            decoded = decode(self.input, self.index);
            const current = unicode.graphemeBreak(decoded.codepoint);
            if (breaks(previous, current, decoded.codepoint, state)) break;

            state.add(decoded.codepoint, current);
            previous = current;
            self.index = decoded.end;
        }

        return .{ .bytes = self.input[start..self.index] };
    }
};

pub const WidthError = error{ ControlCharacter, InvalidUtf8 };

pub fn width(cluster: []const u8, profile: WidthProfile) WidthError!u2 {
    if (!std.unicode.utf8ValidateSlice(cluster)) return error.InvalidUtf8;
    return widthValidated(cluster, profile);
}

fn widthValidated(cluster: []const u8, profile: WidthProfile) WidthError!u2 {
    var index: usize = 0;
    var result: u2 = 0;
    var has_extended_pictographic = false;
    var has_emoji_presentation = false;
    var has_text_selector = false;
    var has_emoji_selector = false;
    var has_zwj = false;

    while (index < cluster.len) {
        const decoded = decode(cluster, index);
        index = decoded.end;
        const codepoint = decoded.codepoint;
        const property = unicode.graphemeBreak(codepoint);

        switch (property) {
            .cr, .lf, .control => return error.ControlCharacter,
            .extend, .zwj => {},
            else => {
                const codepoint_width: u2 = switch (unicode.eastAsianWidth(codepoint)) {
                    .wide => 2,
                    .ambiguous => if (profile == .wide_ambiguous) 2 else 1,
                    .narrow => 1,
                };
                result = @max(result, codepoint_width);
            },
        }

        has_extended_pictographic = has_extended_pictographic or unicode.isExtendedPictographic(codepoint);
        has_emoji_presentation = has_emoji_presentation or unicode.isEmojiPresentation(codepoint);
        has_text_selector = has_text_selector or codepoint == 0xFE0E;
        has_emoji_selector = has_emoji_selector or codepoint == 0xFE0F;
        has_zwj = has_zwj or property == .zwj;
    }

    if (has_emoji_selector or (has_extended_pictographic and has_zwj)) return 2;
    if (has_emoji_presentation and !has_text_selector) return 2;
    return result;
}

const State = struct {
    ri_count: usize,
    emoji: enum { none, pictographic, pictographic_zwj },
    indic: enum { none, consonant, linked },

    fn init(codepoint: u21, grapheme_break: unicode.GraphemeBreak) State {
        var state: State = .{
            .ri_count = 0,
            .emoji = .none,
            .indic = .none,
        };
        state.add(codepoint, grapheme_break);
        return state;
    }

    fn add(self: *State, codepoint: u21, grapheme_break: unicode.GraphemeBreak) void {
        if (grapheme_break == .regional_indicator) {
            self.ri_count += 1;
        } else if (grapheme_break != .extend) {
            self.ri_count = 0;
        }

        if (unicode.isExtendedPictographic(codepoint)) {
            self.emoji = .pictographic;
        } else switch (grapheme_break) {
            .extend => {},
            .zwj => self.emoji = if (self.emoji == .pictographic) .pictographic_zwj else .none,
            else => self.emoji = .none,
        }

        switch (unicode.indicConjunct(codepoint)) {
            .consonant => self.indic = .consonant,
            .extend => {},
            .linker => self.indic = switch (self.indic) {
                .consonant, .linked => .linked,
                .none => .none,
            },
            .none => self.indic = .none,
        }
    }
};

fn breaks(
    previous: unicode.GraphemeBreak,
    current: unicode.GraphemeBreak,
    current_codepoint: u21,
    state: State,
) bool {
    if (previous == .cr and current == .lf) return false;
    if (previous == .cr or previous == .lf or previous == .control) return true;
    if (current == .cr or current == .lf or current == .control) return true;

    if (previous == .l and switch (current) {
        .l, .v, .lv, .lvt => true,
        else => false,
    }) return false;
    if ((previous == .lv or previous == .v) and switch (current) {
        .v, .t => true,
        else => false,
    }) return false;
    if ((previous == .lvt or previous == .t) and current == .t) return false;

    if (current == .extend or current == .zwj or current == .spacing_mark) return false;
    if (previous == .prepend) return false;
    if (state.indic == .linked and unicode.indicConjunct(current_codepoint) == .consonant) return false;
    if (state.emoji == .pictographic_zwj and unicode.isExtendedPictographic(current_codepoint)) return false;
    if (previous == .regional_indicator and current == .regional_indicator and state.ri_count % 2 == 1) return false;
    return true;
}

fn decode(input: []const u8, start: usize) struct { codepoint: u21, end: usize } {
    const length = std.unicode.utf8ByteSequenceLength(input[start]) catch unreachable;
    const end = start + length;
    return .{
        .codepoint = std.unicode.utf8Decode(input[start..end]) catch unreachable,
        .end = end,
    };
}

test "extended grapheme boundaries" {
    const testing = std.testing;

    var iterator = try Iterator.init("e\xCC\x81\r\n\xF0\x9F\x87\xBA\xF0\x9F\x87\xB8x");
    try testing.expectEqualStrings("e\xCC\x81", iterator.next().?.bytes);
    try testing.expectEqualStrings("\r\n", iterator.next().?.bytes);
    try testing.expectEqualStrings("\xF0\x9F\x87\xBA\xF0\x9F\x87\xB8", iterator.next().?.bytes);
    try testing.expectEqualStrings("x", iterator.next().?.bytes);
    try testing.expect(iterator.next() == null);
}

test "emoji ZWJ and Indic conjunct sequences stay intact" {
    const testing = std.testing;

    const family = "\xF0\x9F\x91\xA9\xE2\x80\x8D\xF0\x9F\x91\xA9\xE2\x80\x8D\xF0\x9F\x91\xA6";
    var emoji = try Iterator.init(family);
    try testing.expectEqualStrings(family, emoji.next().?.bytes);
    try testing.expect(emoji.next() == null);

    const devanagari = "\xE0\xA4\x95\xE0\xA5\x8D\xE0\xA4\x95";
    var indic = try Iterator.init(devanagari);
    try testing.expectEqualStrings(devanagari, indic.next().?.bytes);
    try testing.expect(indic.next() == null);
}

test "terminal display width profiles" {
    const testing = std.testing;

    try testing.expectEqual(@as(u2, 1), try width("A", .narrow));
    try testing.expectEqual(@as(u2, 1), try width("e\xCC\x81", .narrow));
    try testing.expectEqual(@as(u2, 2), try width("\xE7\x95\x8C", .narrow));
    try testing.expectEqual(@as(u2, 2), try width("\xF0\x9F\x98\x80", .narrow));
    try testing.expectEqual(@as(u2, 1), try width("\xC2\xB7", .narrow));
    try testing.expectEqual(@as(u2, 2), try width("\xC2\xB7", .wide_ambiguous));
    try testing.expectError(error.ControlCharacter, width("\x1B", .narrow));
    try testing.expectError(error.InvalidUtf8, width("\xC0\x80", .narrow));
}

test "invalid UTF-8 is rejected once at ingress" {
    try std.testing.expectError(error.InvalidUtf8, Iterator.init("\xC0\x80"));
    try std.testing.expectError(error.InvalidUtf8, (Cluster{ .bytes = "\xC0\x80" }).displayWidth(.narrow));
}
