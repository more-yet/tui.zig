const std = @import("std");
const unicode = @import("unicode_17.zig");

const Class = unicode.LineBreak;

pub const Kind = enum {
    prohibited,
    allowed,
    mandatory,
};

pub const Boundary = struct {
    offset: usize,
    kind: Kind,
};

const Scalar = struct {
    codepoint: u21,
    start: usize,
    end: usize,
    raw: Class,
    class: Class,
    attached: bool,
    initial_punctuation: bool,
    final_punctuation: bool,
    east_asian: bool,
    unassigned: bool,
    extended_pictographic: bool,
};

const Lookahead = struct {
    first: Scalar,
    second: ?Scalar,
    third: ?Scalar,
};

const State = struct {
    left: ?Scalar = null,
    previous: ?Scalar = null,
    last_non_space: ?Scalar = null,
    last_non_space_predecessor: ?Scalar = null,
    regional_indicator_run: usize = 0,
    numeric_run: bool = false,
    numeric_run_before_left: bool = false,

    fn consume(self: *State, scalar: Scalar) void {
        const old_left = self.left;
        if (scalar.attached) {
            self.left = scalar;
            self.last_non_space = scalar;
            return;
        }
        self.previous = old_left;
        self.left = scalar;

        if (scalar.class != .sp) {
            self.last_non_space = scalar;
            self.last_non_space_predecessor = old_left;
        }

        self.numeric_run_before_left = self.numeric_run;
        self.numeric_run = scalar.class == .nu or
            ((scalar.class == .sy or scalar.class == .is) and self.numeric_run);
        self.regional_indicator_run = if (scalar.class == .ri) self.regional_indicator_run +% 1 else 0;
    }

    fn classify(self: *const State, ahead: Lookahead) Kind {
        const left = self.left.?;
        const right = ahead.first;
        const right2 = ahead.second;
        const right3 = ahead.third;

        // LB4-LB6: mandatory breaks.
        if (left.class == .bk) return .mandatory;
        if (left.class == .cr and right.class == .lf) return .prohibited;
        if (isHard(left.class)) return .mandatory;
        if (isHard(right.class)) return .prohibited;

        // LB7-LB10: spaces, zero-width controls, and combining sequences.
        if (right.class == .sp or right.class == .zw) return .prohibited;
        if (self.last_non_space != null and self.last_non_space.?.class == .zw) return .allowed;
        if (left.raw == .zwj) return .prohibited;
        if (right.attached) return .prohibited;

        // LB11-LB12a: word joiners and glue.
        if (left.class == .wj or right.class == .wj) return .prohibited;
        if (left.class == .gl) return .prohibited;
        if (right.class == .gl and !in(left.class, &.{ .sp, .ba, .hy, .hh })) return .prohibited;

        // LB13-LB17: punctuation with space-sensitive context.
        if (in(right.class, &.{ .cl, .cp, .ex, .sy })) return .prohibited;
        if (self.last_non_space != null and self.last_non_space.?.class == .op) return .prohibited;
        if (self.last_non_space) |quote| {
            if (quote.class == .qu and quote.initial_punctuation and
                isInitialQuotePredecessor(self.last_non_space_predecessor)) return .prohibited;
        }
        if (right.class == .qu and right.final_punctuation and isFinalQuoteFollower(right2)) {
            return .prohibited;
        }
        if (left.class == .sp and right.class == .is and right2 != null and right2.?.class == .nu) {
            return .allowed;
        }
        if (right.class == .is) return .prohibited;
        if (self.last_non_space) |previous_non_space| {
            if (in(previous_non_space.class, &.{ .cl, .cp }) and right.class == .ns) return .prohibited;
            if (previous_non_space.class == .b2 and right.class == .b2) return .prohibited;
        }

        // LB18: spaces break unless an earlier rule prohibited the boundary.
        if (left.class == .sp) return .allowed;

        // LB19-LB20a: quotation marks, contingent breaks, and initial hyphens.
        if (right.class == .qu and !right.initial_punctuation) return .prohibited;
        if (left.class == .qu and !left.final_punctuation) return .prohibited;
        if (!left.east_asian and right.class == .qu) return .prohibited;
        if (right.class == .qu and (right2 == null or !right2.?.east_asian)) return .prohibited;
        if (left.class == .qu and !right.east_asian) return .prohibited;
        if (left.class == .qu and (self.previous == null or !self.previous.?.east_asian)) return .prohibited;
        if (left.class == .cb or right.class == .cb) return .allowed;
        if (in(left.class, &.{ .hy, .hh }) and in(right.class, &.{ .al, .hl }) and
            isWordInitialPredecessor(self.previous)) return .prohibited;

        // LB21-LB22: hyphens, nonstarters, and inseparables.
        if (in(right.class, &.{ .ba, .hh, .hy, .ns }) or left.class == .bb) return .prohibited;
        if (in(left.class, &.{ .hy, .hh }) and right.class != .hl and
            self.previous != null and self.previous.?.class == .hl) return .prohibited;
        if (left.class == .sy and right.class == .hl) return .prohibited;
        if (right.class == .in) return .prohibited;

        // LB23-LB25: alphanumeric and numeric expressions.
        if (in(left.class, &.{ .al, .hl }) and right.class == .nu) return .prohibited;
        if (left.class == .nu and in(right.class, &.{ .al, .hl })) return .prohibited;
        if (left.class == .pr and in(right.class, &.{ .id, .eb, .em })) return .prohibited;
        if (in(left.class, &.{ .id, .eb, .em }) and right.class == .po) return .prohibited;
        if (in(left.class, &.{ .pr, .po }) and in(right.class, &.{ .al, .hl })) return .prohibited;
        if (in(left.class, &.{ .al, .hl }) and in(right.class, &.{ .pr, .po })) return .prohibited;
        if (in(left.class, &.{ .cl, .cp }) and in(right.class, &.{ .po, .pr }) and
            self.numeric_run_before_left) return .prohibited;
        if (self.numeric_run and in(right.class, &.{ .po, .pr, .nu })) return .prohibited;
        if (in(left.class, &.{ .po, .pr })) {
            if (right.class == .nu) return .prohibited;
            if (right.class == .op and right2 != null) {
                if (right2.?.class == .nu) return .prohibited;
                if (right2.?.class == .is and right3 != null and right3.?.class == .nu) return .prohibited;
            }
        }
        if (in(left.class, &.{ .hy, .is }) and right.class == .nu) return .prohibited;

        // LB26-LB27: Hangul syllable blocks.
        if (left.class == .jl and in(right.class, &.{ .jl, .jv, .h2, .h3 })) return .prohibited;
        if (in(left.class, &.{ .jv, .h2 }) and in(right.class, &.{ .jv, .jt })) return .prohibited;
        if (in(left.class, &.{ .jt, .h3 }) and right.class == .jt) return .prohibited;
        if (isHangul(left.class) and right.class == .po) return .prohibited;
        if (left.class == .pr and isHangul(right.class)) return .prohibited;

        // LB28-LB29: alphabetic and Brahmic orthographic syllables.
        if (in(left.class, &.{ .al, .hl }) and in(right.class, &.{ .al, .hl })) return .prohibited;
        if (left.class == .ap and isAksaraBase(right)) return .prohibited;
        if (isAksaraBase(left) and in(right.class, &.{ .vf, .vi })) return .prohibited;
        if (left.class == .vi and isAksaraBaseWithoutStart(right) and
            self.previous != null and isAksaraBase(self.previous.?)) return .prohibited;
        if (isAksaraBase(left) and isAksaraBase(right) and right2 != null and right2.?.class == .vf) {
            return .prohibited;
        }
        if (left.class == .is and in(right.class, &.{ .al, .hl })) return .prohibited;

        // LB30-LB30b: parentheses, flags, and emoji modifiers.
        if (in(left.class, &.{ .al, .hl, .nu }) and right.class == .op and !right.east_asian) {
            return .prohibited;
        }
        if (left.class == .cp and !left.east_asian and in(right.class, &.{ .al, .hl, .nu })) {
            return .prohibited;
        }
        if (left.class == .ri and right.class == .ri and self.regional_indicator_run % 2 == 1) {
            return .prohibited;
        }
        if ((left.class == .eb or left.extended_pictographic and left.unassigned) and right.class == .em) {
            return .prohibited;
        }

        // LB31: break everywhere else.
        return .allowed;
    }
};

/// Lazily yields Unicode 17 default line-break boundaries without allocation.
pub const Iterator = struct {
    input: []const u8,
    offset: usize = 0,
    started: bool = false,
    finished: bool = false,
    state: State = .{},
    ahead: [3]?Scalar = .{ null, null, null },

    pub fn init(input: []const u8) error{InvalidUtf8}!Iterator {
        if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
        return .{ .input = input };
    }

    pub fn next(self: *Iterator) ?Boundary {
        if (!self.started) {
            self.started = true;
            if (self.input.len == 0) {
                self.finished = true;
                return .{ .offset = 0, .kind = .mandatory };
            }
            const first = decodeScalar(self.input, 0, null);
            self.state.consume(first);
            self.offset = first.end;
            return .{ .offset = 0, .kind = .prohibited };
        }
        if (self.finished) return null;
        if (self.offset == self.input.len) {
            self.finished = true;
            return .{ .offset = self.offset, .kind = .mandatory };
        }

        const ahead = self.lookahead();
        const boundary = Boundary{
            .offset = ahead.first.start,
            .kind = self.state.classify(ahead),
        };
        self.state.consume(ahead.first);
        self.offset = ahead.first.end;
        self.ahead = .{ ahead.second, ahead.third, null };
        return boundary;
    }

    fn lookahead(self: *Iterator) Lookahead {
        var start = self.offset;
        var previous = self.state.left;
        for (&self.ahead) |*entry| {
            if (entry.* == null and start < self.input.len) {
                entry.* = decodeScalar(self.input, start, previous);
            }
            const scalar = entry.* orelse break;
            start = scalar.end;
            previous = scalar;
        }
        return .{
            .first = self.ahead[0].?,
            .second = self.ahead[1],
            .third = self.ahead[2],
        };
    }
};

/// Stateful boundary classifier for segmented or styled input.
pub const Machine = struct {
    state: State = .{},

    pub fn push(self: *Machine, codepoint: u21) void {
        self.state.consume(makeScalar(codepoint, 0, 0, self.state.left));
    }

    /// Classifies the boundary before `right`; `second` and `third` are bounded lookahead.
    pub fn boundary(self: *const Machine, right: u21, second: ?u21, third: ?u21) Kind {
        if (self.state.left == null) return .prohibited;
        const first_scalar = makeScalar(right, 0, 0, self.state.left);
        const second_scalar = if (second) |codepoint| makeScalar(codepoint, 0, 0, first_scalar) else null;
        const third_scalar = if (third) |codepoint|
            makeScalar(codepoint, 0, 0, second_scalar orelse first_scalar)
        else
            null;
        return self.state.classify(.{
            .first = first_scalar,
            .second = second_scalar,
            .third = third_scalar,
        });
    }
};

fn decodeScalar(input: []const u8, start: usize, previous: ?Scalar) Scalar {
    const sequence_len = std.unicode.utf8ByteSequenceLength(input[start]) catch unreachable;
    const end = start + sequence_len;
    const codepoint = std.unicode.utf8Decode(input[start..end]) catch unreachable;
    return makeScalar(codepoint, start, end, previous);
}

fn makeScalar(codepoint: u21, start: usize, end: usize, previous: ?Scalar) Scalar {
    const raw = resolveClass(codepoint, unicode.lineBreak(codepoint));
    const attached = in(raw, &.{ .cm, .zwj }) and previous != null and !excludesCombiningBase(previous.?.class);
    const class = if (attached)
        previous.?.class
    else if (in(raw, &.{ .cm, .zwj }))
        .al
    else
        raw;
    const effective_codepoint: u21 = if (attached)
        previous.?.codepoint
    else if (in(raw, &.{ .cm, .zwj }))
        'A'
    else
        codepoint;
    const ascii = effective_codepoint < 0x80;
    return .{
        .codepoint = effective_codepoint,
        .start = start,
        .end = end,
        .raw = raw,
        .class = class,
        .attached = attached,
        .initial_punctuation = if (attached) previous.?.initial_punctuation else !ascii and unicode.isInitialPunctuation(effective_codepoint),
        .final_punctuation = if (attached) previous.?.final_punctuation else !ascii and unicode.isFinalPunctuation(effective_codepoint),
        .east_asian = if (attached) previous.?.east_asian else !ascii and unicode.isEastAsianForLineBreak(effective_codepoint),
        .unassigned = if (attached) previous.?.unassigned else !ascii and unicode.isUnassigned(effective_codepoint),
        .extended_pictographic = if (attached) previous.?.extended_pictographic else unicode.isExtendedPictographic(effective_codepoint),
    };
}

fn resolveClass(codepoint: u21, class: Class) Class {
    return switch (class) {
        .ai, .sg, .xx => .al,
        .cj => .ns,
        .sa => if (unicode.isCombiningCategory(codepoint)) .cm else .al,
        else => class,
    };
}

fn excludesCombiningBase(class: Class) bool {
    return in(class, &.{ .bk, .cr, .lf, .nl, .sp, .zw });
}

fn isHard(class: Class) bool {
    return in(class, &.{ .bk, .cr, .lf, .nl });
}

fn isInitialQuotePredecessor(value: ?Scalar) bool {
    if (value == null) return true;
    return in(value.?.class, &.{ .bk, .cr, .lf, .nl, .op, .qu, .gl, .sp, .zw });
}

fn isFinalQuoteFollower(value: ?Scalar) bool {
    if (value == null) return true;
    return in(value.?.class, &.{ .sp, .gl, .wj, .cl, .qu, .cp, .ex, .is, .sy, .bk, .cr, .lf, .nl, .zw });
}

fn isWordInitialPredecessor(value: ?Scalar) bool {
    if (value == null) return true;
    return in(value.?.class, &.{ .bk, .cr, .lf, .nl, .sp, .zw, .cb, .gl });
}

fn isHangul(class: Class) bool {
    return in(class, &.{ .jl, .jv, .jt, .h2, .h3 });
}

fn isAksaraBase(value: Scalar) bool {
    return in(value.class, &.{ .ak, .as }) or value.codepoint == 0x25cc;
}

fn isAksaraBaseWithoutStart(value: Scalar) bool {
    return value.class == .ak or value.codepoint == 0x25cc;
}

fn in(value: Class, comptime values: []const Class) bool {
    inline for (values) |candidate| if (value == candidate) return true;
    return false;
}

test "line break iterator handles words, spaces, CJK, glue, and mandatory breaks" {
    try expectKinds("ab cd", &.{
        .prohibited,
        .prohibited,
        .prohibited,
        .allowed,
        .prohibited,
        .mandatory,
    });
    try expectKinds("\xe7\x95\x8c\xe5\xad\x97", &.{ .prohibited, .allowed, .mandatory });
    try expectKinds("a\xc2\xa0b", &.{ .prohibited, .prohibited, .prohibited, .mandatory });
    try expectKinds("a\r\nb", &.{ .prohibited, .prohibited, .prohibited, .mandatory, .mandatory });
}

test "line break iterator keeps flag pairs and emoji modifiers together" {
    try expectKinds(
        "\xf0\x9f\x87\xba\xf0\x9f\x87\xb8\xf0\x9f\x87\xa8\xf0\x9f\x87\xa6",
        &.{ .prohibited, .prohibited, .allowed, .prohibited, .mandatory },
    );
    try expectKinds(
        "\xf0\x9f\x91\x8d\xf0\x9f\x8f\xbd",
        &.{ .prohibited, .prohibited, .mandatory },
    );
}

fn expectKinds(input: []const u8, expected: []const Kind) !void {
    var iterator = try Iterator.init(input);
    for (expected) |kind| try std.testing.expectEqual(kind, iterator.next().?.kind);
    try std.testing.expect(iterator.next() == null);
}
