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
    ri_odd: bool,
    emoji: enum { none, pictographic, pictographic_zwj },
    indic: enum { none, consonant, linked },

    fn init(codepoint: u21, grapheme_break: unicode.GraphemeBreak) State {
        var state: State = .{
            .ri_odd = false,
            .emoji = .none,
            .indic = .none,
        };
        state.add(codepoint, grapheme_break);
        return state;
    }

    fn add(self: *State, codepoint: u21, grapheme_break: unicode.GraphemeBreak) void {
        if (grapheme_break == .regional_indicator) {
            self.ri_odd = !self.ri_odd;
        } else if (grapheme_break != .extend) {
            self.ri_odd = false;
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
    if (previous == .zwj and state.emoji == .pictographic_zwj and
        unicode.isExtendedPictographic(current_codepoint)) return false;
    if (previous == .regional_indicator and current == .regional_indicator and state.ri_odd) return false;
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
