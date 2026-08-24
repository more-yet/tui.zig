const std = @import("std");

const unicode_dir = "tools/unicode/17.0.0/";
const output_path = "src/text/unicode_17.zig";

const Range = struct {
    first: u21,
    last: u21,
    value: u8,
};

const Gcb = enum(u8) {
    other,
    cr,
    lf,
    control,
    extend,
    zwj,
    regional_indicator,
    prepend,
    spacing_mark,
    l,
    v,
    t,
};

const Incb = enum(u8) {
    none,
    consonant,
    extend,
    linker,
};

const Lb = enum(u8) {
    ai,
    ak,
    al,
    ap,
    as,
    b2,
    ba,
    bb,
    bk,
    cb,
    cj,
    cl,
    cm,
    cp,
    cr,
    eb,
    em,
    ex,
    gl,
    h2,
    h3,
    hh,
    hl,
    hy,
    id,
    in,
    is,
    jl,
    jt,
    jv,
    lf,
    nl,
    ns,
    nu,
    op,
    po,
    pr,
    qu,
    ri,
    sa,
    sg,
    sp,
    sy,
    vf,
    vi,
    wj,
    xx,
    zw,
    zwj,
};

const Wb = enum(u8) {
    other,
    double_quote,
    single_quote,
    hebrew_letter,
    cr,
    lf,
    newline,
    extend,
    regional_indicator,
    format,
    katakana,
    a_letter,
    mid_letter,
    mid_num,
    mid_num_let,
    numeric,
    extend_num_let,
    zwj,
    w_seg_space,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const check = args.len == 2 and std.mem.eql(u8, args[1], "--check");
    if (args.len > 2 or (args.len == 2 and !check)) return error.InvalidArguments;

    const cwd = std.Io.Dir.cwd();
    const gcb_data = try cwd.readFileAlloc(
        io,
        unicode_dir ++ "GraphemeBreakProperty.txt",
        allocator,
        .limited(2 * 1024 * 1024),
    );
    const incb_data = try cwd.readFileAlloc(
        io,
        unicode_dir ++ "DerivedCoreProperties.txt",
        allocator,
        .limited(2 * 1024 * 1024),
    );
    const emoji_data = try cwd.readFileAlloc(
        io,
        unicode_dir ++ "emoji-data.txt",
        allocator,
        .limited(2 * 1024 * 1024),
    );
    const width_data = try cwd.readFileAlloc(
        io,
        unicode_dir ++ "EastAsianWidth.txt",
        allocator,
        .limited(2 * 1024 * 1024),
    );
    const line_break_data = try cwd.readFileAlloc(
        io,
        unicode_dir ++ "LineBreak.txt",
        allocator,
        .limited(2 * 1024 * 1024),
    );
    const word_break_data = try cwd.readFileAlloc(
        io,
        unicode_dir ++ "WordBreakProperty.txt",
        allocator,
        .limited(2 * 1024 * 1024),
    );
    const category_data = try cwd.readFileAlloc(
        io,
        unicode_dir ++ "DerivedGeneralCategory.txt",
        allocator,
        .limited(2 * 1024 * 1024),
    );

    var gcb: std.ArrayList(Range) = .empty;
    var incb: std.ArrayList(Range) = .empty;
    var extended_pictographic: std.ArrayList(Range) = .empty;
    var emoji_presentation: std.ArrayList(Range) = .empty;
    var wide: std.ArrayList(Range) = .empty;
    var ambiguous: std.ArrayList(Range) = .empty;
    var halfwidth: std.ArrayList(Range) = .empty;
    var line_break: std.ArrayList(Range) = .empty;
    var word_break: std.ArrayList(Range) = .empty;
    var combining_category: std.ArrayList(Range) = .empty;
    var initial_punctuation: std.ArrayList(Range) = .empty;
    var final_punctuation: std.ArrayList(Range) = .empty;
    var unassigned: std.ArrayList(Range) = .empty;

    try parseGcb(allocator, gcb_data, &gcb);
    try parseIncb(allocator, incb_data, &incb);
    try parseEmoji(allocator, emoji_data, &extended_pictographic, &emoji_presentation);
    try parseWidth(allocator, width_data, &wide, &ambiguous, &halfwidth);
    try parseLineBreak(allocator, line_break_data, &line_break);
    try parseWordBreak(allocator, word_break_data, &word_break);
    try parseGeneralCategories(
        allocator,
        category_data,
        &combining_category,
        &initial_punctuation,
        &final_punctuation,
        &unassigned,
    );

    sortAndMerge(&gcb);
    sortAndMerge(&incb);
    sortAndMerge(&extended_pictographic);
    sortAndMerge(&emoji_presentation);
    sortAndMerge(&wide);
    sortAndMerge(&ambiguous);
    sortAndMerge(&halfwidth);
    sortAndMerge(&line_break);
    sortAndMerge(&word_break);
    sortAndMerge(&combining_category);
    sortAndMerge(&initial_punctuation);
    sortAndMerge(&final_punctuation);
    sortAndMerge(&unassigned);

    var output: std.Io.Writer.Allocating = .init(allocator);
    try emit(
        &output.writer,
        gcb.items,
        incb.items,
        extended_pictographic.items,
        emoji_presentation.items,
        wide.items,
        ambiguous.items,
        halfwidth.items,
        line_break.items,
        word_break.items,
        combining_category.items,
        initial_punctuation.items,
        final_punctuation.items,
        unassigned.items,
    );

    if (check) {
        const existing = try cwd.readFileAlloc(io, output_path, allocator, .limited(2 * 1024 * 1024));
        if (!std.mem.eql(u8, existing, output.written())) return error.UnicodeTableOutOfDate;
    } else {
        try cwd.createDirPath(io, "src/text");
        try cwd.writeFile(io, .{ .sub_path = output_path, .data = output.written() });
    }
}

fn parseGcb(allocator: std.mem.Allocator, data: []const u8, output: *std.ArrayList(Range)) !void {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = content(raw_line);
        if (line.len == 0) continue;

        var fields = std.mem.splitScalar(u8, line, ';');
        const codepoints = trim(fields.next() orelse continue);
        const property = trim(fields.next() orelse continue);
        const value: Gcb = if (std.mem.eql(u8, property, "CR"))
            .cr
        else if (std.mem.eql(u8, property, "LF"))
            .lf
        else if (std.mem.eql(u8, property, "Control"))
            .control
        else if (std.mem.eql(u8, property, "Extend"))
            .extend
        else if (std.mem.eql(u8, property, "ZWJ"))
            .zwj
        else if (std.mem.eql(u8, property, "Regional_Indicator"))
            .regional_indicator
        else if (std.mem.eql(u8, property, "Prepend"))
            .prepend
        else if (std.mem.eql(u8, property, "SpacingMark"))
            .spacing_mark
        else if (std.mem.eql(u8, property, "L"))
            .l
        else if (std.mem.eql(u8, property, "V"))
            .v
        else if (std.mem.eql(u8, property, "T"))
            .t
        else if (std.mem.eql(u8, property, "LV") or std.mem.eql(u8, property, "LVT"))
            continue
        else
            return error.UnknownGraphemeBreakProperty;

        const range = try parseRange(codepoints);
        try output.append(allocator, .{ .first = range.first, .last = range.last, .value = @intFromEnum(value) });
    }
}

fn parseIncb(allocator: std.mem.Allocator, data: []const u8, output: *std.ArrayList(Range)) !void {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = content(raw_line);
        if (line.len == 0) continue;

        var fields = std.mem.splitScalar(u8, line, ';');
        const codepoints = trim(fields.next() orelse continue);
        if (!std.mem.eql(u8, trim(fields.next() orelse continue), "InCB")) continue;
        const property = trim(fields.next() orelse continue);
        const value: Incb = if (std.mem.eql(u8, property, "Consonant"))
            .consonant
        else if (std.mem.eql(u8, property, "Extend"))
            .extend
        else if (std.mem.eql(u8, property, "Linker"))
            .linker
        else
            return error.UnknownIndicConjunctProperty;

        const range = try parseRange(codepoints);
        try output.append(allocator, .{ .first = range.first, .last = range.last, .value = @intFromEnum(value) });
    }
}

fn parseEmoji(
    allocator: std.mem.Allocator,
    data: []const u8,
    extended_pictographic: *std.ArrayList(Range),
    emoji_presentation: *std.ArrayList(Range),
) !void {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = content(raw_line);
        if (line.len == 0) continue;

        var fields = std.mem.splitScalar(u8, line, ';');
        const codepoints = trim(fields.next() orelse continue);
        const property = trim(fields.next() orelse continue);
        const range = try parseRange(codepoints);
        if (std.mem.eql(u8, property, "Extended_Pictographic")) {
            try extended_pictographic.append(allocator, .{ .first = range.first, .last = range.last, .value = 1 });
        } else if (std.mem.eql(u8, property, "Emoji_Presentation")) {
            try emoji_presentation.append(allocator, .{ .first = range.first, .last = range.last, .value = 1 });
        }
    }
}

fn parseWidth(
    allocator: std.mem.Allocator,
    data: []const u8,
    wide: *std.ArrayList(Range),
    ambiguous: *std.ArrayList(Range),
    halfwidth: *std.ArrayList(Range),
) !void {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = content(raw_line);
        if (line.len == 0) continue;

        var fields = std.mem.splitScalar(u8, line, ';');
        const codepoints = trim(fields.next() orelse continue);
        const property = trim(fields.next() orelse continue);
        const range = try parseRange(codepoints);
        if (std.mem.eql(u8, property, "W") or std.mem.eql(u8, property, "F")) {
            try wide.append(allocator, .{ .first = range.first, .last = range.last, .value = 1 });
        } else if (std.mem.eql(u8, property, "A")) {
            try ambiguous.append(allocator, .{ .first = range.first, .last = range.last, .value = 1 });
        } else if (std.mem.eql(u8, property, "H")) {
            try halfwidth.append(allocator, .{ .first = range.first, .last = range.last, .value = 1 });
        }
    }
}

fn parseLineBreak(allocator: std.mem.Allocator, data: []const u8, output: *std.ArrayList(Range)) !void {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = content(raw_line);
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, ';');
        const codepoints = trim(fields.next() orelse continue);
        const property = trim(fields.next() orelse continue);
        var property_name: [3]u8 = undefined;
        if (property.len > property_name.len) return error.UnknownLineBreakProperty;
        for (property, 0..) |byte, index| property_name[index] = std.ascii.toLower(byte);
        const value = std.meta.stringToEnum(Lb, property_name[0..property.len]) orelse {
            return error.UnknownLineBreakProperty;
        };
        const range = try parseRange(codepoints);
        try output.append(allocator, .{ .first = range.first, .last = range.last, .value = @intFromEnum(value) });
    }
}

fn parseWordBreak(allocator: std.mem.Allocator, data: []const u8, output: *std.ArrayList(Range)) !void {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = content(raw_line);
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, ';');
        const codepoints = trim(fields.next() orelse continue);
        const property = trim(fields.next() orelse continue);
        const value: Wb = if (std.mem.eql(u8, property, "Double_Quote"))
            .double_quote
        else if (std.mem.eql(u8, property, "Single_Quote"))
            .single_quote
        else if (std.mem.eql(u8, property, "Hebrew_Letter"))
            .hebrew_letter
        else if (std.mem.eql(u8, property, "CR"))
            .cr
        else if (std.mem.eql(u8, property, "LF"))
            .lf
        else if (std.mem.eql(u8, property, "Newline"))
            .newline
        else if (std.mem.eql(u8, property, "Extend"))
            .extend
        else if (std.mem.eql(u8, property, "Regional_Indicator"))
            .regional_indicator
        else if (std.mem.eql(u8, property, "Format"))
            .format
        else if (std.mem.eql(u8, property, "Katakana"))
            .katakana
        else if (std.mem.eql(u8, property, "ALetter"))
            .a_letter
        else if (std.mem.eql(u8, property, "MidLetter"))
            .mid_letter
        else if (std.mem.eql(u8, property, "MidNum"))
            .mid_num
        else if (std.mem.eql(u8, property, "MidNumLet"))
            .mid_num_let
        else if (std.mem.eql(u8, property, "Numeric"))
            .numeric
        else if (std.mem.eql(u8, property, "ExtendNumLet"))
            .extend_num_let
        else if (std.mem.eql(u8, property, "ZWJ"))
            .zwj
        else if (std.mem.eql(u8, property, "WSegSpace"))
            .w_seg_space
        else
            return error.UnknownWordBreakProperty;
        const range = try parseRange(codepoints);
        try output.append(allocator, .{ .first = range.first, .last = range.last, .value = @intFromEnum(value) });
    }
}

fn parseGeneralCategories(
    allocator: std.mem.Allocator,
    data: []const u8,
    combining: *std.ArrayList(Range),
    initial: *std.ArrayList(Range),
    final: *std.ArrayList(Range),
    unassigned: *std.ArrayList(Range),
) !void {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = content(raw_line);
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, ';');
        const codepoints = trim(fields.next() orelse continue);
        const property = trim(fields.next() orelse continue);
        const target = if (std.mem.eql(u8, property, "Mn") or std.mem.eql(u8, property, "Mc"))
            combining
        else if (std.mem.eql(u8, property, "Pi"))
            initial
        else if (std.mem.eql(u8, property, "Pf"))
            final
        else if (std.mem.eql(u8, property, "Cn"))
            unassigned
        else
            continue;
        const range = try parseRange(codepoints);
        try target.append(allocator, .{ .first = range.first, .last = range.last, .value = 1 });
    }
}

fn content(raw_line: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, raw_line, '#') orelse raw_line.len;
    return trim(raw_line[0..end]);
}

fn trim(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r");
}

fn parseRange(value: []const u8) !struct { first: u21, last: u21 } {
    if (std.mem.indexOf(u8, value, "..")) |separator| {
        return .{
            .first = try std.fmt.parseInt(u21, value[0..separator], 16),
            .last = try std.fmt.parseInt(u21, value[separator + 2 ..], 16),
        };
    }
    const codepoint = try std.fmt.parseInt(u21, value, 16);
    return .{ .first = codepoint, .last = codepoint };
}

fn sortAndMerge(ranges: *std.ArrayList(Range)) void {
    std.mem.sort(Range, ranges.items, {}, struct {
        fn lessThan(_: void, lhs: Range, rhs: Range) bool {
            return lhs.first < rhs.first;
        }
    }.lessThan);

    var write: usize = 0;
    for (ranges.items) |range| {
        if (write > 0) {
            const previous = &ranges.items[write - 1];
            if (previous.value == range.value and @as(u22, previous.last) + 1 == range.first) {
                previous.last = range.last;
                continue;
            }
        }
        ranges.items[write] = range;
        write += 1;
    }
    ranges.items.len = write;
}

fn emit(
    writer: *std.Io.Writer,
    gcb: []const Range,
    incb: []const Range,
    extended_pictographic: []const Range,
    emoji_presentation: []const Range,
    wide: []const Range,
    ambiguous: []const Range,
    halfwidth: []const Range,
    line_break: []const Range,
    word_break: []const Range,
    combining_category: []const Range,
    initial_punctuation: []const Range,
    final_punctuation: []const Range,
    unassigned: []const Range,
) !void {
    try writer.writeAll(
        \\// Generated by tools/gen_unicode.zig from Unicode 17.0.0 data.
        \\// Do not edit directly.
        \\
        \\pub const version = "17.0.0";
        \\
        \\pub const GraphemeBreak = enum(u8) {
        \\    other,
        \\    cr,
        \\    lf,
        \\    control,
        \\    extend,
        \\    zwj,
        \\    regional_indicator,
        \\    prepend,
        \\    spacing_mark,
        \\    l,
        \\    v,
        \\    t,
        \\    lv,
        \\    lvt,
        \\};
        \\
        \\pub const IndicConjunct = enum(u8) {
        \\    none,
        \\    consonant,
        \\    extend,
        \\    linker,
        \\};
        \\
        \\pub const EastAsianWidth = enum(u2) {
        \\    narrow,
        \\    wide,
        \\    ambiguous,
        \\};
        \\
        \\pub const LineBreak = enum(u8) {
        \\    ai, ak, al, ap, as, b2, ba, bb, bk, cb, cj, cl, cm, cp, cr,
        \\    eb, em, ex, gl, h2, h3, hh, hl, hy, id, in, is, jl, jt, jv,
        \\    lf, nl, ns, nu, op, po, pr, qu, ri, sa, sg, sp, sy, vf, vi,
        \\    wj, xx, zw, zwj,
        \\};
        \\
        \\pub const WordBreak = enum(u8) {
        \\    other, double_quote, single_quote, hebrew_letter, cr, lf, newline,
        \\    extend, regional_indicator, format, katakana, a_letter, mid_letter,
        \\    mid_num, mid_num_let, numeric, extend_num_let, zwj, w_seg_space,
        \\};
        \\
        \\const PropertyRange = struct { first: u21, last: u21, value: u8 };
        \\const Range = struct { first: u21, last: u21 };
        \\
    );

    try emitAsciiLineBreak(writer, line_break);
    try emitPropertyRanges(writer, "grapheme_break_ranges", gcb);
    try emitPropertyRanges(writer, "indic_conjunct_ranges", incb);
    try emitRanges(writer, "extended_pictographic_ranges", extended_pictographic);
    try emitRanges(writer, "emoji_presentation_ranges", emoji_presentation);
    try emitRanges(writer, "wide_ranges", wide);
    try emitRanges(writer, "ambiguous_ranges", ambiguous);
    try emitRanges(writer, "halfwidth_ranges", halfwidth);
    try emitPropertyRanges(writer, "line_break_ranges", line_break);
    try emitPropertyRanges(writer, "word_break_ranges", word_break);
    try emitRanges(writer, "combining_category_ranges", combining_category);
    try emitRanges(writer, "initial_punctuation_ranges", initial_punctuation);
    try emitRanges(writer, "final_punctuation_ranges", final_punctuation);
    try emitRanges(writer, "unassigned_ranges", unassigned);

    try writer.writeAll(
        \\pub fn graphemeBreak(codepoint: u21) GraphemeBreak {
        \\    if (codepoint >= 0x20 and codepoint <= 0x7E) return .other;
        \\    if (codepoint >= 0xAC00 and codepoint <= 0xD7A3) {
        \\        return if ((codepoint - 0xAC00) % 28 == 0) .lv else .lvt;
        \\    }
        \\    return @enumFromInt(lookupProperty(grapheme_break_ranges[0..], codepoint, 0));
        \\}
        \\
        \\pub fn indicConjunct(codepoint: u21) IndicConjunct {
        \\    if (codepoint < 0x300) return .none;
        \\    return @enumFromInt(lookupProperty(indic_conjunct_ranges[0..], codepoint, 0));
        \\}
        \\
        \\pub fn eastAsianWidth(codepoint: u21) EastAsianWidth {
        \\    if (codepoint < 0xA1) return .narrow;
        \\    if (contains(wide_ranges[0..], codepoint)) return .wide;
        \\    if (contains(ambiguous_ranges[0..], codepoint)) return .ambiguous;
        \\    return .narrow;
        \\}
        \\
        \\pub fn isExtendedPictographic(codepoint: u21) bool {
        \\    if (codepoint < 0xA9) return false;
        \\    return contains(extended_pictographic_ranges[0..], codepoint);
        \\}
        \\
        \\pub fn isEmojiPresentation(codepoint: u21) bool {
        \\    if (codepoint < 0x231A) return false;
        \\    return contains(emoji_presentation_ranges[0..], codepoint);
        \\}
        \\
        \\pub fn lineBreak(codepoint: u21) LineBreak {
        \\    if (codepoint < ascii_line_break.len) return ascii_line_break[codepoint];
        \\    const explicit = lookupProperty(line_break_ranges[0..], codepoint, 0xFF);
        \\    if (explicit != 0xFF) return @enumFromInt(explicit);
        \\    if ((codepoint >= 0x3400 and codepoint <= 0x4DBF) or
        \\        (codepoint >= 0x4E00 and codepoint <= 0x9FFF) or
        \\        (codepoint >= 0xF900 and codepoint <= 0xFAFF) or
        \\        (codepoint >= 0x1F000 and codepoint <= 0x1F7FF) or
        \\        (codepoint >= 0x1F900 and codepoint <= 0x1FAFF) or
        \\        (codepoint >= 0x1FC00 and codepoint <= 0x1FFFD) or
        \\        (codepoint >= 0x20000 and codepoint <= 0x2FFFD) or
        \\        (codepoint >= 0x30000 and codepoint <= 0x3FFFD)) return .id;
        \\    if (codepoint >= 0x20A0 and codepoint <= 0x20CF) return .pr;
        \\    return .xx;
        \\}
        \\
        \\pub fn wordBreak(codepoint: u21) WordBreak {
        \\    return @enumFromInt(lookupProperty(word_break_ranges[0..], codepoint, 0));
        \\}
        \\
        \\pub fn isCombiningCategory(codepoint: u21) bool {
        \\    return contains(combining_category_ranges[0..], codepoint);
        \\}
        \\
        \\pub fn isInitialPunctuation(codepoint: u21) bool {
        \\    return contains(initial_punctuation_ranges[0..], codepoint);
        \\}
        \\
        \\pub fn isFinalPunctuation(codepoint: u21) bool {
        \\    return contains(final_punctuation_ranges[0..], codepoint);
        \\}
        \\
        \\pub fn isUnassigned(codepoint: u21) bool {
        \\    return contains(unassigned_ranges[0..], codepoint);
        \\}
        \\
        \\pub fn isEastAsianForLineBreak(codepoint: u21) bool {
        \\    return contains(wide_ranges[0..], codepoint) or contains(halfwidth_ranges[0..], codepoint);
        \\}
        \\
        \\fn lookupProperty(ranges: []const PropertyRange, codepoint: u21, default: u8) u8 {
        \\    var low: usize = 0;
        \\    var high: usize = ranges.len;
        \\    while (low < high) {
        \\        const middle = low + (high - low) / 2;
        \\        const range = ranges[middle];
        \\        if (codepoint < range.first) {
        \\            high = middle;
        \\        } else if (codepoint > range.last) {
        \\            low = middle + 1;
        \\        } else {
        \\            return range.value;
        \\        }
        \\    }
        \\    return default;
        \\}
        \\
        \\fn contains(ranges: []const Range, codepoint: u21) bool {
        \\    var low: usize = 0;
        \\    var high: usize = ranges.len;
        \\    while (low < high) {
        \\        const middle = low + (high - low) / 2;
        \\        const range = ranges[middle];
        \\        if (codepoint < range.first) {
        \\            high = middle;
        \\        } else if (codepoint > range.last) {
        \\            low = middle + 1;
        \\        } else {
        \\            return true;
        \\        }
        \\    }
        \\    return false;
        \\}
    );
}

fn emitAsciiLineBreak(writer: *std.Io.Writer, ranges: []const Range) !void {
    try writer.writeAll("const ascii_line_break = [128]LineBreak{\n");
    for (0..128) |codepoint| {
        if (codepoint % 8 == 0) try writer.writeAll("    ");
        const value: Lb = @enumFromInt(propertyAt(ranges, @intCast(codepoint), @intFromEnum(Lb.xx)));
        try writer.print(".{s},", .{@tagName(value)});
        try writer.writeByte(if (codepoint % 8 == 7) '\n' else ' ');
    }
    try writer.writeAll("};\n\n");
}

fn propertyAt(ranges: []const Range, codepoint: u21, default: u8) u8 {
    for (ranges) |range| {
        if (codepoint < range.first) break;
        if (codepoint <= range.last) return range.value;
    }
    return default;
}

fn emitPropertyRanges(writer: *std.Io.Writer, name: []const u8, ranges: []const Range) !void {
    try writer.print("const {s} = [_]PropertyRange{{\n", .{name});
    for (ranges) |range| {
        try writer.print("    .{{ .first = 0x{X}, .last = 0x{X}, .value = {d} }},\n", .{ range.first, range.last, range.value });
    }
    try writer.writeAll("};\n\n");
}

fn emitRanges(writer: *std.Io.Writer, name: []const u8, ranges: []const Range) !void {
    try writer.print("const {s} = [_]Range{{\n", .{name});
    for (ranges) |range| {
        try writer.print("    .{{ .first = 0x{X}, .last = 0x{X} }},\n", .{ range.first, range.last });
    }
    try writer.writeAll("};\n\n");
}
