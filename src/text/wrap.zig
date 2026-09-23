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

pub const SpanPosition = struct {
    span: usize = 0,
    byte: usize = 0,

    pub inline fn eql(lhs: SpanPosition, rhs: SpanPosition) bool {
        return lhs.span == rhs.span and lhs.byte == rhs.byte;
    }
};

pub const SpanLine = struct {
    start: SpanPosition,
    end: SpanPosition,
    width: u16,
    explicit_break: bool,
};

const InputKind = enum {
    simple_ascii,
    ascii,
    unicode,
};

const Bytes = struct {
    const Input = []const u8;
    const Position = usize;
    const LineType = Line;

    input: []const u8,

    inline fn init(input: Input) Bytes {
        return .{ .input = input };
    }

    inline fn segmentCount(_: Bytes) usize {
        return 1;
    }

    inline fn segment(self: Bytes, index: usize) []const u8 {
        std.debug.assert(index == 0);
        return self.input;
    }

    inline fn start(_: Bytes) Position {
        return 0;
    }

    inline fn end(self: Bytes) Position {
        return self.input.len;
    }

    inline fn normalize(_: Bytes, position: Position) Position {
        return position;
    }

    inline fn remaining(self: Bytes, position: Position) []const u8 {
        return self.input[position..];
    }

    inline fn advance(_: Bytes, position: Position, count: usize) Position {
        return position + count;
    }

    inline fn eql(_: Bytes, lhs: Position, rhs: Position) bool {
        return lhs == rhs;
    }

    inline fn line(self: Bytes, start_position: Position, end_position: Position, width: u16, explicit_break: bool) Line {
        return .{
            .bytes = self.input[start_position..end_position],
            .width = width,
            .explicit_break = explicit_break,
        };
    }
};

fn Spans(comptime Span: type) type {
    return struct {
        const Self = @This();
        const Input = []const Span;
        const Position = SpanPosition;
        const LineType = SpanLine;

        spans: []const Span,

        inline fn init(spans: Input) Self {
            comptime std.debug.assert(@hasField(Span, "text"));
            return .{ .spans = spans };
        }

        inline fn segmentCount(self: Self) usize {
            return self.spans.len;
        }

        inline fn segment(self: Self, index: usize) []const u8 {
            return self.spans[index].text;
        }

        inline fn start(_: Self) Position {
            return .{};
        }

        inline fn end(self: Self) Position {
            return .{ .span = self.spans.len };
        }

        fn normalize(self: Self, initial: Position) Position {
            var position = initial;
            while (position.span < self.spans.len and position.byte == self.spans[position.span].text.len) {
                position.span += 1;
                position.byte = 0;
            }
            return position;
        }

        inline fn remaining(self: Self, position: Position) []const u8 {
            return self.spans[position.span].text[position.byte..];
        }

        inline fn advance(_: Self, position: Position, count: usize) Position {
            return .{ .span = position.span, .byte = position.byte + count };
        }

        inline fn eql(_: Self, lhs: Position, rhs: Position) bool {
            return lhs.eql(rhs);
        }

        inline fn line(_: Self, start_position: Position, end_position: Position, width: u16, explicit_break: bool) SpanLine {
            return .{
                .start = start_position,
                .end = end_position,
                .width = width,
                .explicit_break = explicit_break,
            };
        }
    };
}

/// Lazily yields borrowed lines, trimming ASCII spaces at visual edges.
/// It prefers Unicode 17 default line-break opportunities and otherwise splits
/// at a grapheme boundary.
/// LF and CRLF create explicit breaks; other controls are rejected at initialization.
pub const Iterator = WrapIterator(Bytes);

/// Internal span-aware instantiation used by styled rendering. Each span must
/// expose a borrowed `text: []const u8` field and remains an independent UTF-8
/// and grapheme segment while line-break state continues between spans.
pub fn SpanIterator(comptime Span: type) type {
    return WrapIterator(Spans(Span));
}

fn WrapIterator(comptime Storage: type) type {
    return struct {
        const Self = @This();
        const Position = Storage.Position;
        const ResultLine = Storage.LineType;
        const View = struct {
            position: Position,
            bytes: []const u8,
        };
        const Token = struct {
            start: Position,
            end: Position,
            bytes: []const u8,
            width: u2,
            line_break: bool,
        };

        storage: Storage,
        line_width: u16,
        width_profile: grapheme.WidthProfile,
        position: Position,
        need_line: bool = true,
        kind: InputKind,
        break_machine: line_break.Machine = .{},

        pub fn init(input: Storage.Input, line_width: u16, width_profile: grapheme.WidthProfile) Error!Self {
            if (line_width == 0) return error.InvalidWidth;
            const storage = Storage.init(input);
            const kind = try classifyAndValidate(storage, line_width, width_profile);
            return .{
                .storage = storage,
                .line_width = line_width,
                .width_profile = width_profile,
                .position = storage.start(),
                .kind = kind,
            };
        }

        pub inline fn next(self: *Self) Error!?ResultLine {
            return switch (self.kind) {
                .simple_ascii => self.nextSimpleAscii(),
                .ascii => self.nextGeneral(false),
                .unicode => self.nextGeneral(true),
            };
        }

        pub inline fn asciiOnly(self: *const Self) bool {
            return self.kind != .unicode;
        }

        fn nextSimpleAscii(self: *Self) ?ResultLine {
            var cursor = self.storage.normalize(self.position);
            if (self.storage.eql(cursor, self.storage.end())) return self.finishAtEnd(cursor);

            while (true) {
                const byte = self.peekByte(cursor) orelse return self.finishAtEnd(self.storage.end());
                if (byte == '\n' or byte == '\r') {
                    const start_position = self.storage.normalize(cursor);
                    cursor = self.consumeNewline(start_position, byte);
                    self.position = cursor;
                    self.need_line = true;
                    return self.storage.line(start_position, start_position, 0, true);
                }
                if (byte != ' ') break;
                self.consumeSpaces(&cursor, null);
                self.position = cursor;
            }

            const line_start = self.storage.normalize(cursor);
            var scanned_width: u32 = 0;
            var content_end = line_start;
            var content_width: u16 = 0;
            var break_end: ?Position = null;
            var break_width: u16 = 0;
            var break_resume = line_start;

            while (true) {
                const byte = self.peekByte(cursor) orelse {
                    self.position = self.storage.end();
                    self.need_line = false;
                    return self.storage.line(line_start, content_end, content_width, false);
                };
                if (byte == '\n' or byte == '\r') {
                    cursor = self.consumeNewline(self.storage.normalize(cursor), byte);
                    self.position = cursor;
                    self.need_line = true;
                    return self.storage.line(line_start, content_end, content_width, true);
                }
                if (byte == ' ') {
                    self.consumeSpaces(&cursor, &scanned_width);
                    if (scanned_width > self.line_width) {
                        self.position = cursor;
                        self.need_line = false;
                        return self.storage.line(line_start, content_end, content_width, false);
                    }
                    break_end = content_end;
                    break_width = content_width;
                    break_resume = cursor;
                    continue;
                }

                const available: u32 = self.line_width - scanned_width;
                scanned_width += self.consumeSimpleWord(&cursor, available);
                const next_byte = self.peekByte(cursor);
                if (scanned_width == self.line_width and next_byte != null and simpleAsciiWordByte(next_byte.?)) {
                    if (break_end) |end_position| {
                        self.position = break_resume;
                        self.need_line = false;
                        return self.storage.line(line_start, end_position, break_width, false);
                    }
                    self.position = cursor;
                    self.need_line = false;
                    return self.storage.line(line_start, cursor, self.line_width, false);
                }
                content_end = cursor;
                content_width = @intCast(scanned_width);
            }
        }

        fn nextGeneral(self: *Self, comptime unicode: bool) Error!?ResultLine {
            var cursor = self.storage.normalize(self.position);
            if (self.storage.eql(cursor, self.storage.end())) return self.finishAtEnd(cursor);

            var breaks = self.break_machine;
            var line_start: Position = undefined;
            while (true) {
                const token = self.readToken(cursor, unicode) orelse {
                    self.position = self.storage.end();
                    self.break_machine = breaks;
                    return self.finishAtEnd(self.position);
                };
                cursor = token.end;
                if (token.line_break) {
                    pushToken(&breaks, token.bytes, unicode);
                    self.position = cursor;
                    self.break_machine = breaks;
                    self.need_line = true;
                    return self.storage.line(token.start, token.start, 0, true);
                }
                if (!std.mem.eql(u8, token.bytes, " ")) {
                    line_start = token.start;
                    cursor = token.start;
                    break;
                }
                pushToken(&breaks, token.bytes, unicode);
                self.position = cursor;
            }

            var scanned_width: u16 = 0;
            var content_end = line_start;
            var content_width: u16 = 0;
            var break_end: ?Position = null;
            var break_width: u16 = 0;
            var break_resume = line_start;
            var saved_break_machine: line_break.Machine = .{};

            while (self.readToken(cursor, unicode)) |token| {
                cursor = token.end;
                if (token.line_break) {
                    pushToken(&breaks, token.bytes, unicode);
                    self.position = cursor;
                    self.break_machine = breaks;
                    self.need_line = true;
                    return self.storage.line(line_start, content_end, content_width, true);
                }

                const space = std.mem.eql(u8, token.bytes, " ");
                if (self.boundaryAt(&breaks, token.start) != .prohibited and
                    !self.storage.eql(token.start, line_start))
                {
                    break_end = content_end;
                    break_width = content_width;
                    break_resume = token.start;
                    saved_break_machine = breaks;
                }
                const next_width = @as(u32, scanned_width) + token.width;
                if (next_width > self.line_width) {
                    self.need_line = false;
                    if (space) {
                        pushToken(&breaks, token.bytes, unicode);
                        self.position = token.end;
                        self.break_machine = breaks;
                        return self.storage.line(line_start, content_end, content_width, false);
                    }
                    if (break_end) |end_position| {
                        self.position = break_resume;
                        self.break_machine = saved_break_machine;
                        return self.storage.line(line_start, end_position, break_width, false);
                    }
                    self.position = token.start;
                    self.break_machine = breaks;
                    return self.storage.line(line_start, content_end, content_width, false);
                }

                pushToken(&breaks, token.bytes, unicode);
                scanned_width = @intCast(next_width);
                if (!space) {
                    content_end = token.end;
                    content_width = scanned_width;
                }
            }

            self.position = self.storage.end();
            self.break_machine = breaks;
            self.need_line = false;
            return self.storage.line(line_start, content_end, content_width, false);
        }

        fn finishAtEnd(self: *Self, position: Position) ?ResultLine {
            self.position = position;
            if (!self.need_line) return null;
            self.need_line = false;
            return self.storage.line(position, position, 0, false);
        }

        inline fn view(self: *const Self, initial: Position) ?View {
            const position = self.storage.normalize(initial);
            if (self.storage.eql(position, self.storage.end())) return null;
            return .{ .position = position, .bytes = self.storage.remaining(position) };
        }

        inline fn peekByte(self: *const Self, position: Position) ?u8 {
            const current = self.view(position) orelse return null;
            return current.bytes[0];
        }

        inline fn consumeNewline(self: *const Self, position: Position, byte: u8) Position {
            return self.storage.advance(position, if (byte == '\r') 2 else 1);
        }

        fn consumeSpaces(self: *const Self, cursor: *Position, scanned_width: ?*u32) void {
            const limit = @as(u32, self.line_width) + 1;
            while (self.view(cursor.*)) |current| {
                var count: usize = 0;
                while (count < current.bytes.len and current.bytes[count] == ' ') count += 1;
                if (count == 0) return;
                cursor.* = self.storage.advance(current.position, count);
                if (scanned_width) |width| {
                    const room = limit - width.*;
                    width.* += @min(room, std.math.cast(u32, count) orelse room);
                }
                if (count != current.bytes.len) return;
            }
        }

        fn consumeSimpleWord(self: *const Self, cursor: *Position, maximum: u32) u32 {
            var consumed: u32 = 0;
            while (consumed < maximum) {
                const current = self.view(cursor.*) orelse break;
                const available: usize = @intCast(maximum - consumed);
                const limit = @min(current.bytes.len, available);
                var count: usize = 0;
                while (count < limit and simpleAsciiWordByte(current.bytes[count])) count += 1;
                cursor.* = self.storage.advance(current.position, count);
                consumed += @intCast(count);
                if (count != current.bytes.len or consumed == maximum) break;
                const next_byte = self.peekByte(cursor.*) orelse break;
                if (!simpleAsciiWordByte(next_byte)) break;
            }
            return consumed;
        }

        fn readToken(self: *const Self, initial: Position, comptime unicode: bool) ?Token {
            const current = self.view(initial) orelse return null;
            if (unicode) {
                var clusters = grapheme.Iterator{ .input = current.bytes };
                const cluster = clusters.next().?;
                return .{
                    .start = current.position,
                    .end = self.storage.advance(current.position, cluster.bytes.len),
                    .bytes = cluster.bytes,
                    .width = if (isLineBreak(cluster.bytes))
                        0
                    else
                        cluster.displayWidthAssumeValid(self.width_profile) catch unreachable,
                    .line_break = isLineBreak(cluster.bytes),
                };
            }
            const length: usize = if (current.bytes[0] == '\r') 2 else 1;
            const bytes = current.bytes[0..length];
            return .{
                .start = current.position,
                .end = self.storage.advance(current.position, length),
                .bytes = bytes,
                .width = if (isLineBreak(bytes)) 0 else 1,
                .line_break = isLineBreak(bytes),
            };
        }

        fn boundaryAt(self: *const Self, machine: *const line_break.Machine, start_position: Position) line_break.Kind {
            var codepoints: [3]?u21 = .{ null, null, null };
            var position = start_position;
            for (&codepoints) |*codepoint| codepoint.* = self.nextScalar(&position) orelse break;
            return machine.boundary(codepoints[0].?, codepoints[1], codepoints[2]);
        }

        fn nextScalar(self: *const Self, position: *Position) ?u21 {
            const current = self.view(position.*) orelse return null;
            const sequence_len = std.unicode.utf8ByteSequenceLength(current.bytes[0]) catch unreachable;
            position.* = self.storage.advance(current.position, sequence_len);
            return std.unicode.utf8Decode(current.bytes[0..sequence_len]) catch unreachable;
        }

        fn classifyAndValidate(
            storage: Storage,
            line_width: u16,
            width_profile: grapheme.WidthProfile,
        ) Error!InputKind {
            var kind: InputKind = .simple_ascii;
            for (0..storage.segmentCount()) |segment_index| {
                const input = storage.segment(segment_index);
                var byte_index: usize = 0;
                while (byte_index < input.len) : (byte_index += 1) {
                    const byte = input[byte_index];
                    if (byte >= 0x80) {
                        kind = .unicode;
                        continue;
                    }
                    if (byte == '\r') {
                        if (byte_index + 1 == input.len or input[byte_index + 1] != '\n') {
                            return error.ControlCharacter;
                        }
                        byte_index += 1;
                        continue;
                    }
                    if ((byte < 0x20 and byte != '\n') or byte == 0x7F) return error.ControlCharacter;
                    if (kind == .simple_ascii and !simpleAsciiByte(byte) and byte != '\n') kind = .ascii;
                }
            }
            if (kind == .unicode) {
                for (0..storage.segmentCount()) |segment_index| {
                    var validation = try grapheme.Iterator.init(storage.segment(segment_index));
                    while (validation.next()) |cluster| {
                        if (isLineBreak(cluster.bytes)) continue;
                        if (cluster.bytes.len > grapheme.max_cluster_bytes) return error.GraphemeTooLong;
                        const width = try cluster.displayWidthAssumeValid(width_profile);
                        if (width == 0) return error.ZeroWidthGrapheme;
                        if (width > line_width) return error.GraphemeTooWide;
                    }
                }
            }
            return kind;
        }
    };
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

inline fn pushToken(machine: *line_break.Machine, bytes: []const u8, comptime unicode: bool) void {
    if (unicode) {
        pushBytes(machine, bytes);
    } else {
        machine.push(bytes[0]);
        if (bytes[0] == '\r') machine.push('\n');
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

inline fn isLineBreak(bytes: []const u8) bool {
    return std.mem.eql(u8, bytes, "\n") or std.mem.eql(u8, bytes, "\r\n");
}
