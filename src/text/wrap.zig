const std = @import("std");
const grapheme = @import("grapheme.zig");
const line_break = @import("line_break.zig");

pub const Error = grapheme.WidthError || error{
    InvalidWidth,
    ZeroWidthGrapheme,
    GraphemeTooLong,
    GraphemeTooWide,
};

pub const Line = struct {
    bytes: []const u8,
    width: u16,
    explicit_break: bool,
};

/// Lazily yields borrowed lines, trimming ASCII spaces at visual edges.
/// It prefers Unicode 17 default line-break opportunities and otherwise splits
/// at a grapheme boundary.
/// LF and CRLF create explicit breaks; other controls are rejected at initialization.
pub const Iterator = struct {
    input: []const u8,
    line_width: u16,
    width_profile: grapheme.WidthProfile,
    index: usize = 0,
    need_line: bool = true,
    ascii: bool,
    simple_ascii: bool,
    break_machine: line_break.Machine = .{},

    pub fn init(
        input: []const u8,
        line_width: u16,
        width_profile: grapheme.WidthProfile,
    ) Error!Iterator {
        if (line_width == 0) return error.InvalidWidth;
        var ascii = true;
        var simple_ascii = true;
        var index: usize = 0;
        while (index < input.len) : (index += 1) {
            const byte = input[index];
            if (byte >= 0x80) {
                ascii = false;
                simple_ascii = false;
                continue;
            }
            if (byte == '\r') {
                if (index + 1 == input.len or input[index + 1] != '\n') return error.ControlCharacter;
                index += 1;
                continue;
            }
            if ((byte < 0x20 and byte != '\n') or byte == 0x7F) return error.ControlCharacter;
            if (!simpleAsciiByte(byte) and byte != '\n') simple_ascii = false;
        }
        if (!ascii) {
            var validation = try grapheme.Iterator.init(input);
            while (validation.next()) |cluster| {
                if (isLineBreak(cluster.bytes)) continue;
                if (cluster.bytes.len > grapheme.max_cluster_bytes) return error.GraphemeTooLong;
                const width = try cluster.displayWidthAssumeValid(width_profile);
                if (width == 0) return error.ZeroWidthGrapheme;
                if (width > line_width) return error.GraphemeTooWide;
            }
        }
        return .{
            .input = input,
            .line_width = line_width,
            .width_profile = width_profile,
            .ascii = ascii,
            .simple_ascii = simple_ascii,
        };
    }

    pub inline fn next(self: *Iterator) Error!?Line {
        if (self.simple_ascii) return self.nextSimpleAscii();
        if (self.ascii) return self.nextAscii();
        return self.nextUnicode();
    }

    pub inline fn asciiOnly(self: *const Iterator) bool {
        return self.ascii;
    }

    fn nextSimpleAscii(self: *Iterator) ?Line {
        if (self.index == self.input.len) {
            if (!self.need_line) return null;
            self.need_line = false;
            return .{ .bytes = "", .width = 0, .explicit_break = false };
        }

        var index = self.index;
        while (index < self.input.len) {
            const byte = self.input[index];
            if (byte == '\n' or byte == '\r') {
                index += if (byte == '\r') 2 else 1;
                self.index = index;
                self.need_line = true;
                return .{ .bytes = "", .width = 0, .explicit_break = true };
            }
            if (byte != ' ') break;
            index += 1;
            self.index = index;
        }
        if (index == self.input.len) {
            if (!self.need_line) return null;
            self.need_line = false;
            return .{ .bytes = "", .width = 0, .explicit_break = false };
        }

        const line_start = index;
        var content_end = line_start;
        var content_width: u16 = 0;
        var break_end: ?usize = null;
        var break_width: u16 = 0;
        var break_resume: usize = 0;
        while (index < self.input.len) {
            const byte = self.input[index];
            if (byte == '\n' or byte == '\r') {
                index += if (byte == '\r') 2 else 1;
                self.index = index;
                self.need_line = true;
                return .{
                    .bytes = self.input[line_start..content_end],
                    .width = content_width,
                    .explicit_break = true,
                };
            }
            if (byte == ' ') {
                while (index < self.input.len and self.input[index] == ' ') index += 1;
                if (index - line_start > self.line_width) {
                    self.index = index;
                    self.need_line = false;
                    return .{
                        .bytes = self.input[line_start..content_end],
                        .width = content_width,
                        .explicit_break = false,
                    };
                }
                break_end = content_end;
                break_width = content_width;
                break_resume = index;
                continue;
            }

            while (index < self.input.len and simpleAsciiWordByte(self.input[index])) index += 1;
            const width = index - line_start;
            if (width > self.line_width) {
                if (break_end) |end| {
                    self.index = break_resume;
                    self.need_line = false;
                    return .{
                        .bytes = self.input[line_start..end],
                        .width = break_width,
                        .explicit_break = false,
                    };
                }
                const end = line_start + self.line_width;
                self.index = end;
                self.need_line = false;
                return .{
                    .bytes = self.input[line_start..end],
                    .width = self.line_width,
                    .explicit_break = false,
                };
            }
            content_end = index;
            content_width = @intCast(width);
        }

        self.index = self.input.len;
        self.need_line = false;
        return .{
            .bytes = self.input[line_start..content_end],
            .width = content_width,
            .explicit_break = false,
        };
    }

    fn nextAscii(self: *Iterator) ?Line {
        if (self.index == self.input.len) {
            if (!self.need_line) return null;
            self.need_line = false;
            return .{ .bytes = "", .width = 0, .explicit_break = false };
        }

        var index = self.index;
        var breaks = self.break_machine;
        while (index < self.input.len) {
            const byte = self.input[index];
            if (byte == '\n' or byte == '\r') {
                const break_len: usize = if (byte == '\r') 2 else 1;
                const end = index + break_len;
                pushBytes(&breaks, self.input[index..end]);
                index = end;
                self.index = index;
                self.break_machine = breaks;
                self.need_line = true;
                return .{ .bytes = "", .width = 0, .explicit_break = true };
            }
            if (byte != ' ') break;
            breaks.push(byte);
            index += 1;
            self.index = index;
        }
        if (index == self.input.len) {
            self.index = index;
            self.break_machine = breaks;
            if (!self.need_line) return null;
            self.need_line = false;
            return .{ .bytes = "", .width = 0, .explicit_break = false };
        }

        const line_start = index;
        var content_end = line_start;
        var content_width: u16 = 0;
        var break_end: ?usize = null;
        var break_width: u16 = 0;
        var break_resume: usize = 0;
        var break_machine: line_break.Machine = .{};

        while (index < self.input.len) {
            const byte = self.input[index];
            if (byte == '\n' or byte == '\r') {
                const break_len: usize = if (byte == '\r') 2 else 1;
                const end = index + break_len;
                pushBytes(&breaks, self.input[index..end]);
                index = end;
                self.index = index;
                self.break_machine = breaks;
                self.need_line = true;
                return .{
                    .bytes = self.input[line_start..content_end],
                    .width = content_width,
                    .explicit_break = true,
                };
            }

            const byte_start = index;
            if (boundaryAt(&breaks, self.input, byte_start) != .prohibited and byte_start != line_start) {
                break_end = content_end;
                break_width = content_width;
                break_resume = byte_start;
                break_machine = breaks;
            }
            index += 1;
            const space = byte == ' ';
            if (index - line_start > self.line_width) {
                if (space) {
                    breaks.push(byte);
                    self.index = index;
                    self.break_machine = breaks;
                } else if (break_end) |end| {
                    self.index = break_resume;
                    self.break_machine = break_machine;
                    self.need_line = false;
                    return .{
                        .bytes = self.input[line_start..end],
                        .width = break_width,
                        .explicit_break = false,
                    };
                } else {
                    self.index = byte_start;
                    self.break_machine = breaks;
                }
                self.need_line = false;
                return .{
                    .bytes = self.input[line_start..content_end],
                    .width = content_width,
                    .explicit_break = false,
                };
            }

            breaks.push(byte);
            const width: u16 = @intCast(index - line_start);
            if (!space) {
                content_end = index;
                content_width = width;
            }
        }

        self.index = self.input.len;
        self.break_machine = breaks;
        self.need_line = false;
        return .{
            .bytes = self.input[line_start..content_end],
            .width = content_width,
            .explicit_break = false,
        };
    }

    fn nextUnicode(self: *Iterator) Error!?Line {
        if (self.index == self.input.len) {
            if (!self.need_line) return null;
            self.need_line = false;
            return .{ .bytes = "", .width = 0, .explicit_break = false };
        }

        var clusters = grapheme.Iterator{ .input = self.input, .index = self.index };
        var breaks = self.break_machine;
        while (clusters.next()) |cluster| {
            if (isLineBreak(cluster.bytes)) {
                pushBytes(&breaks, cluster.bytes);
                self.index = clusters.index;
                self.break_machine = breaks;
                self.need_line = true;
                return .{ .bytes = "", .width = 0, .explicit_break = true };
            }
            if (!std.mem.eql(u8, cluster.bytes, " ")) {
                clusters.index = byteOffset(self.input, cluster.bytes);
                break;
            }
            pushBytes(&breaks, cluster.bytes);
            self.index = clusters.index;
        }
        if (clusters.index == self.input.len) {
            self.index = clusters.index;
            self.break_machine = breaks;
            if (!self.need_line) return null;
            self.need_line = false;
            return .{ .bytes = "", .width = 0, .explicit_break = false };
        }

        const line_start = clusters.index;
        var line_width: u16 = 0;
        var content_end = line_start;
        var content_width: u16 = 0;
        var break_end: ?usize = null;
        var break_width: u16 = 0;
        var break_resume: usize = 0;
        var break_machine: line_break.Machine = .{};

        while (clusters.next()) |cluster| {
            if (isLineBreak(cluster.bytes)) {
                pushBytes(&breaks, cluster.bytes);
                self.index = clusters.index;
                self.break_machine = breaks;
                self.need_line = true;
                return .{
                    .bytes = self.input[line_start..content_end],
                    .width = content_width,
                    .explicit_break = true,
                };
            }

            const width = cluster.displayWidthAssumeValid(self.width_profile) catch unreachable;
            const cluster_start = byteOffset(self.input, cluster.bytes);
            const space = std.mem.eql(u8, cluster.bytes, " ");
            if (boundaryAt(&breaks, self.input, cluster_start) != .prohibited and cluster_start != line_start) {
                break_end = content_end;
                break_width = content_width;
                break_resume = cluster_start;
                break_machine = breaks;
            }
            const next_width = @as(u32, line_width) + width;
            if (next_width > self.line_width) {
                if (space) {
                    pushBytes(&breaks, cluster.bytes);
                    self.index = clusters.index;
                    self.break_machine = breaks;
                } else if (break_end) |end| {
                    self.index = break_resume;
                    self.break_machine = break_machine;
                    self.need_line = false;
                    return .{
                        .bytes = self.input[line_start..end],
                        .width = break_width,
                        .explicit_break = false,
                    };
                } else {
                    self.index = cluster_start;
                    self.break_machine = breaks;
                }
                self.need_line = false;
                return .{
                    .bytes = self.input[line_start..content_end],
                    .width = content_width,
                    .explicit_break = false,
                };
            }

            pushBytes(&breaks, cluster.bytes);
            line_width = @intCast(next_width);
            if (!space) {
                content_end = clusters.index;
                content_width = line_width;
            }
        }

        self.index = self.input.len;
        self.break_machine = breaks;
        self.need_line = false;
        return .{
            .bytes = self.input[line_start..content_end],
            .width = content_width,
            .explicit_break = false,
        };
    }
};

fn boundaryAt(machine: *const line_break.Machine, input: []const u8, start: usize) line_break.Kind {
    var codepoints: [3]?u21 = .{ null, null, null };
    var index = start;
    for (&codepoints) |*codepoint| {
        if (index == input.len) break;
        const sequence_len = std.unicode.utf8ByteSequenceLength(input[index]) catch unreachable;
        const end = index + sequence_len;
        codepoint.* = std.unicode.utf8Decode(input[index..end]) catch unreachable;
        index = end;
    }
    return machine.boundary(codepoints[0].?, codepoints[1], codepoints[2]);
}

fn pushBytes(machine: *line_break.Machine, bytes: []const u8) void {
    var index: usize = 0;
    while (index < bytes.len) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(bytes[index]) catch unreachable;
        const end = index + sequence_len;
        machine.push(std.unicode.utf8Decode(bytes[index..end]) catch unreachable);
        index = end;
    }
}

inline fn simpleAsciiByte(byte: u8) bool {
    return byte == ' ' or simpleAsciiWordByte(byte);
}

inline fn simpleAsciiWordByte(byte: u8) bool {
    return byte >= '0' and byte <= '9' or byte >= 'A' and byte <= 'Z' or
        byte >= 'a' and byte <= 'z' or switch (byte) {
        '#', '&', '*', '<', '=', '>', '@', '^', '_', '`', '~' => true,
        else => false,
    };
}

inline fn byteOffset(input: []const u8, bytes: []const u8) usize {
    return @intFromPtr(bytes.ptr) - @intFromPtr(input.ptr);
}

inline fn isLineBreak(bytes: []const u8) bool {
    return std.mem.eql(u8, bytes, "\n") or std.mem.eql(u8, bytes, "\r\n");
}

test "word wrapping preserves content and grapheme boundaries" {
    var words = try Iterator.init("alpha beta gamma", 10, .narrow);
    try expectLine(words.next(), "alpha beta", 10, false);
    try expectLine(words.next(), "gamma", 5, false);
    try std.testing.expect((try words.next()) == null);

    var wide = try Iterator.init("ab\xE7\x95\x8Cc", 3, .narrow);
    try expectLine(wide.next(), "ab", 2, false);
    try expectLine(wide.next(), "\xE7\x95\x8Cc", 3, false);
    try std.testing.expect((try wide.next()) == null);
}

test "wrapping prefers Unicode line break opportunities" {
    var hyphenated = try Iterator.init("ab-cdef", 5, .narrow);
    try expectLine(hyphenated.next(), "ab-", 3, false);
    try expectLine(hyphenated.next(), "cdef", 4, false);
    try std.testing.expect((try hyphenated.next()) == null);
}

test "simple ASCII wrapping handles emergency and explicit breaks" {
    var lines = try Iterator.init("abcdef 12ab\r\n z", 3, .narrow);
    try expectLine(lines.next(), "abc", 3, false);
    try expectLine(lines.next(), "def", 3, false);
    try expectLine(lines.next(), "12a", 3, false);
    try expectLine(lines.next(), "b", 1, true);
    try expectLine(lines.next(), "z", 1, false);
    try std.testing.expect((try lines.next()) == null);
}

test "simple ASCII wrapping matches the general classifier" {
    const inputs = [_][]const u8{
        "",
        "   ",
        "alpha",
        "alpha  beta gamma",
        "123abc 456 def",
        "# heading  snake_case  key==value  @name",
        "averylongword followed by short words",
        "one\r\n two\n\nthree ",
    };
    for (inputs) |input| {
        for (1..13) |raw_width| {
            const width: u16 = @intCast(raw_width);
            var fast = try Iterator.init(input, width, .narrow);
            var general = fast;
            general.simple_ascii = false;
            while (true) {
                const fast_line = try fast.next();
                const general_line = try general.next();
                try std.testing.expectEqual(fast_line == null, general_line == null);
                if (fast_line == null) break;
                try std.testing.expectEqualStrings(general_line.?.bytes, fast_line.?.bytes);
                try std.testing.expectEqual(general_line.?.width, fast_line.?.width);
                try std.testing.expectEqual(general_line.?.explicit_break, fast_line.?.explicit_break);
            }
        }
    }
}

test "wrapping trims edge spaces and preserves explicit empty lines" {
    var lines = try Iterator.init("  a  b \r\n\n c \n", 10, .narrow);
    try expectLine(lines.next(), "a  b", 4, true);
    try expectLine(lines.next(), "", 0, true);
    try expectLine(lines.next(), "c", 1, true);
    try expectLine(lines.next(), "", 0, false);
    try std.testing.expect((try lines.next()) == null);
}

test "wrapping rejects invalid widths and unsafe text" {
    try std.testing.expectError(error.InvalidWidth, Iterator.init("text", 0, .narrow));
    try std.testing.expectError(error.InvalidUtf8, Iterator.init("\xC0\x80", 10, .narrow));

    try std.testing.expectError(error.ControlCharacter, Iterator.init("safe\x1b[31m", 20, .narrow));
    try std.testing.expectError(error.ControlCharacter, Iterator.init("bare\rreturn", 20, .narrow));

    try std.testing.expectError(error.ControlCharacter, Iterator.init("safe\xC2\x9B31m", 20, .narrow));
    try std.testing.expectError(error.ZeroWidthGrapheme, Iterator.init("\xCC\x81", 10, .narrow));
    try std.testing.expectError(error.GraphemeTooWide, Iterator.init("\xE7\x95\x8C", 1, .narrow));

    var oversized: [grapheme.max_cluster_bytes + 1]u8 = undefined;
    oversized[0] = 'a';
    var index: usize = 1;
    while (index < oversized.len) : (index += 2) {
        oversized[index] = 0xCC;
        oversized[index + 1] = 0x81;
    }
    try std.testing.expectError(error.GraphemeTooLong, Iterator.init(&oversized, 10, .narrow));
}

fn expectLine(result: Error!?Line, expected: []const u8, width: u16, explicit_break: bool) !void {
    const line = (try result).?;
    try std.testing.expectEqualStrings(expected, line.bytes);
    try std.testing.expectEqual(width, line.width);
    try std.testing.expectEqual(explicit_break, line.explicit_break);
}
