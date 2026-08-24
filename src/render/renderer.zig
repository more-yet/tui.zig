const std = @import("std");
const geometry = @import("../core/geometry.zig");
const grapheme = @import("../text/grapheme.zig");
const line_layout = @import("../text/line.zig");
const line_break = @import("../text/line_break.zig");
const text_wrap = @import("../text/wrap.zig");
const ansi = @import("../terminal/ansi.zig");
const capabilities_module = @import("../terminal/capabilities.zig");
const image_module = @import("../terminal/image.zig");
const cell_module = @import("cell.zig");
const cursor_module = @import("cursor.zig");
const damage_module = @import("damage.zig");
const glyph_store = @import("glyph_store.zig");
const style_module = @import("style.zig");

pub const Limits = struct {
    /// Bounds framebuffer allocation for dimensions reported by an untrusted terminal.
    max_cells: usize = 1_000_000,
    grapheme_capacity: u32 = 2048,
    style_capacity: u16 = 256,
    tile_width: u8 = 8,
    tile_height: u8 = 4,
    image_capacity: u16 = 16,
};

pub const FrameStats = struct {
    bytes: usize = 0,
    // A u16-by-u16 terminal contains fewer than maxInt(u32) cells.
    cells_compared: u32 = 0,
    cells_changed: u32 = 0,
    runs: u32 = 0,
    dirty_rows: u16 = 0,
    full_repaint: bool = false,
};

pub const StyledSpan = struct {
    text: []const u8,
    style: style_module.Style = .{},
};

pub const CellView = struct {
    glyph: []const u8,
    style: style_module.Style,
    width: cell_module.Width,
};

pub const AsciiFill = struct {
    rect: geometry.Rect,
    glyph: u8,
};

pub const ImageOptions = struct {
    image_id: u32,
    placement_id: u32 = 1,
    background: image_module.Rgb = .{},
};

pub const ImageError = image_module.ValidationError || error{
    ImageCapacityExceeded,
    InvalidImageBounds,
};

const ImageCommand = struct {
    rect: geometry.Rect,
    image: image_module.Image,
    options: ImageOptions,
};

const StyledPosition = struct {
    span: usize = 0,
    byte: usize = 0,
};

const StyledWrappedLine = struct {
    start: StyledPosition,
    end: StyledPosition,
    width: u16,
};

const StyledCluster = struct {
    start: StyledPosition,
    end: StyledPosition,
    bytes: []const u8,
    width: u2,
};

const StyledClusterIterator = struct {
    spans: []const StyledSpan,
    position: StyledPosition,
    width_profile: grapheme.WidthProfile,

    fn next(self: *StyledClusterIterator) ?StyledCluster {
        while (self.position.span < self.spans.len) {
            const text = self.spans[self.position.span].text;
            if (self.position.byte == text.len) {
                self.position.span += 1;
                self.position.byte = 0;
                continue;
            }
            var clusters = grapheme.Iterator{ .input = text, .index = self.position.byte };
            const cluster = clusters.next().?;
            const start = self.position;
            self.position.byte = clusters.index;
            return .{
                .start = start,
                .end = self.position,
                .bytes = cluster.bytes,
                .width = if (styledLineBreak(cluster.bytes))
                    0
                else
                    cluster.displayWidthAssumeValid(self.width_profile) catch unreachable,
            };
        }
        return null;
    }
};

const StyledAsciiToken = struct {
    start: StyledPosition,
    end: StyledPosition,
    byte: u8,
    line_break: bool,
};

const StyledAsciiIterator = struct {
    spans: []const StyledSpan,
    position: StyledPosition,

    fn next(self: *StyledAsciiIterator) ?StyledAsciiToken {
        while (self.position.span < self.spans.len) {
            const text = self.spans[self.position.span].text;
            if (self.position.byte == text.len) {
                self.position.span += 1;
                self.position.byte = 0;
                continue;
            }
            const start = self.position;
            const byte = text[self.position.byte];
            self.position.byte += if (byte == '\r') 2 else 1;
            return .{
                .start = start,
                .end = self.position,
                .byte = byte,
                .line_break = byte == '\n' or byte == '\r',
            };
        }
        return null;
    }
};

const StyledScalarIterator = struct {
    spans: []const StyledSpan,
    position: StyledPosition,

    fn next(self: *StyledScalarIterator) ?u21 {
        while (self.position.span < self.spans.len) {
            const text = self.spans[self.position.span].text;
            if (self.position.byte == text.len) {
                self.position.span += 1;
                self.position.byte = 0;
                continue;
            }
            const start = self.position.byte;
            const sequence_len = std.unicode.utf8ByteSequenceLength(text[self.position.byte]) catch unreachable;
            self.position.byte += sequence_len;
            return std.unicode.utf8Decode(text[start..self.position.byte]) catch unreachable;
        }
        return null;
    }
};

const StyledWrapIterator = struct {
    spans: []const StyledSpan,
    line_width: u16,
    width_profile: grapheme.WidthProfile,
    position: StyledPosition = .{},
    need_line: bool = true,
    ascii: bool,
    simple_ascii: bool,
    break_machine: line_break.Machine = .{},

    fn init(
        spans: []const StyledSpan,
        line_width: u16,
        width_profile: grapheme.WidthProfile,
    ) !StyledWrapIterator {
        if (line_width == 0) return error.InvalidWidth;
        var ascii = true;
        var simple_ascii = true;
        for (spans) |span| {
            var byte_index: usize = 0;
            while (byte_index < span.text.len) : (byte_index += 1) {
                const byte = span.text[byte_index];
                if (byte >= 0x80) {
                    ascii = false;
                    simple_ascii = false;
                    continue;
                }
                if (byte == '\r') {
                    if (byte_index + 1 == span.text.len or span.text[byte_index + 1] != '\n') {
                        return error.ControlCharacter;
                    }
                    byte_index += 1;
                    continue;
                }
                if ((byte < 0x20 and byte != '\n') or byte == 0x7F) return error.ControlCharacter;
                if (!simpleStyledAsciiByte(byte) and byte != '\n') simple_ascii = false;
            }
        }
        if (ascii) {
            return .{
                .spans = spans,
                .line_width = line_width,
                .width_profile = width_profile,
                .ascii = true,
                .simple_ascii = simple_ascii,
            };
        }
        for (spans) |span| {
            var validation = try grapheme.Iterator.init(span.text);
            while (validation.next()) |cluster| {
                if (styledLineBreak(cluster.bytes)) continue;
                if (cluster.bytes.len > grapheme.max_cluster_bytes) return error.GraphemeTooLong;
                const width = try cluster.displayWidthAssumeValid(width_profile);
                if (width == 0) return error.ZeroWidthGrapheme;
                if (width > line_width) return error.GraphemeTooWide;
            }
        }
        return .{
            .spans = spans,
            .line_width = line_width,
            .width_profile = width_profile,
            .ascii = false,
            .simple_ascii = false,
        };
    }

    fn next(self: *StyledWrapIterator) !?StyledWrappedLine {
        if (self.simple_ascii) return self.nextSimpleAscii();
        if (self.ascii) return self.nextAscii();
        return self.nextUnicode();
    }

    fn nextSimpleAscii(self: *StyledWrapIterator) ?StyledWrappedLine {
        var tokens = StyledAsciiIterator{ .spans = self.spans, .position = self.position };
        var line_start: StyledPosition = undefined;
        while (true) {
            const token = tokens.next() orelse {
                self.position = tokens.position;
                if (!self.need_line) return null;
                self.need_line = false;
                return .{ .start = self.position, .end = self.position, .width = 0 };
            };
            if (token.line_break) {
                self.position = token.end;
                self.need_line = true;
                return .{ .start = token.start, .end = token.start, .width = 0 };
            }
            if (token.byte != ' ') {
                line_start = token.start;
                tokens.position = token.start;
                break;
            }
            self.position = token.end;
        }

        var line_width: u16 = 0;
        var content_end = line_start;
        var content_width: u16 = 0;
        var break_end: ?StyledPosition = null;
        var break_width: u16 = 0;
        var break_resume: StyledPosition = .{};
        var previous_space = false;
        while (tokens.next()) |token| {
            if (token.line_break) {
                self.position = token.end;
                self.need_line = true;
                return .{ .start = line_start, .end = content_end, .width = content_width };
            }
            const space = token.byte == ' ';
            if (previous_space and !space) {
                break_end = content_end;
                break_width = content_width;
                break_resume = token.start;
            }
            if (line_width == self.line_width) {
                if (space) {
                    self.position = token.end;
                } else if (break_end) |end| {
                    self.position = break_resume;
                    self.need_line = false;
                    return .{ .start = line_start, .end = end, .width = break_width };
                } else {
                    self.position = token.start;
                }
                self.need_line = false;
                return .{ .start = line_start, .end = content_end, .width = content_width };
            }

            line_width += 1;
            if (!space) {
                content_end = token.end;
                content_width = line_width;
            }
            previous_space = space;
        }

        self.position = tokens.position;
        self.need_line = false;
        return .{ .start = line_start, .end = content_end, .width = content_width };
    }

    fn nextAscii(self: *StyledWrapIterator) ?StyledWrappedLine {
        var tokens = StyledAsciiIterator{ .spans = self.spans, .position = self.position };
        var breaks = self.break_machine;
        var line_start: StyledPosition = undefined;
        while (true) {
            const token = tokens.next() orelse {
                self.position = tokens.position;
                self.break_machine = breaks;
                if (!self.need_line) return null;
                self.need_line = false;
                return .{ .start = self.position, .end = self.position, .width = 0 };
            };
            if (token.line_break) {
                pushStyledAsciiToken(&breaks, token);
                self.position = token.end;
                self.break_machine = breaks;
                self.need_line = true;
                return .{ .start = token.start, .end = token.start, .width = 0 };
            }
            if (token.byte != ' ') {
                line_start = token.start;
                tokens.position = token.start;
                break;
            }
            breaks.push(token.byte);
            self.position = token.end;
        }

        var line_width: u16 = 0;
        var content_end = line_start;
        var content_width: u16 = 0;
        var break_end: ?StyledPosition = null;
        var break_width: u16 = 0;
        var break_resume: StyledPosition = .{};
        var break_machine: line_break.Machine = .{};

        while (tokens.next()) |token| {
            if (token.line_break) {
                pushStyledAsciiToken(&breaks, token);
                self.position = token.end;
                self.break_machine = breaks;
                self.need_line = true;
                return .{ .start = line_start, .end = content_end, .width = content_width };
            }
            const space = token.byte == ' ';
            if (styledBoundaryAt(&breaks, self.spans, token.start) != .prohibited and
                !styledPositionEql(token.start, line_start))
            {
                break_end = content_end;
                break_width = content_width;
                break_resume = token.start;
                break_machine = breaks;
            }
            if (line_width == self.line_width) {
                if (space) {
                    breaks.push(token.byte);
                    self.position = token.end;
                    self.break_machine = breaks;
                } else if (break_end) |end| {
                    self.position = break_resume;
                    self.break_machine = break_machine;
                    self.need_line = false;
                    return .{ .start = line_start, .end = end, .width = break_width };
                } else {
                    self.position = token.start;
                    self.break_machine = breaks;
                }
                self.need_line = false;
                return .{ .start = line_start, .end = content_end, .width = content_width };
            }

            breaks.push(token.byte);
            line_width += 1;
            if (!space) {
                content_end = token.end;
                content_width = line_width;
            }
        }

        self.position = tokens.position;
        self.break_machine = breaks;
        self.need_line = false;
        return .{ .start = line_start, .end = content_end, .width = content_width };
    }

    fn nextUnicode(self: *StyledWrapIterator) !?StyledWrappedLine {
        var clusters = StyledClusterIterator{
            .spans = self.spans,
            .position = self.position,
            .width_profile = self.width_profile,
        };
        var breaks = self.break_machine;
        var line_start: StyledPosition = undefined;
        while (true) {
            const cluster = clusters.next() orelse {
                self.position = clusters.position;
                self.break_machine = breaks;
                if (!self.need_line) return null;
                self.need_line = false;
                return .{ .start = self.position, .end = self.position, .width = 0 };
            };
            if (styledLineBreak(cluster.bytes)) {
                pushStyledBytes(&breaks, cluster.bytes);
                self.position = cluster.end;
                self.break_machine = breaks;
                self.need_line = true;
                return .{ .start = cluster.start, .end = cluster.start, .width = 0 };
            }
            if (!std.mem.eql(u8, cluster.bytes, " ")) {
                line_start = cluster.start;
                clusters.position = cluster.start;
                break;
            }
            pushStyledBytes(&breaks, cluster.bytes);
            self.position = cluster.end;
        }
        var line_width: u16 = 0;
        var content_end = line_start;
        var content_width: u16 = 0;
        var break_end: ?StyledPosition = null;
        var break_width: u16 = 0;
        var break_resume: StyledPosition = .{};
        var break_machine: line_break.Machine = .{};

        while (clusters.next()) |cluster| {
            if (styledLineBreak(cluster.bytes)) {
                pushStyledBytes(&breaks, cluster.bytes);
                self.position = cluster.end;
                self.break_machine = breaks;
                self.need_line = true;
                return .{ .start = line_start, .end = content_end, .width = content_width };
            }
            const width = cluster.width;
            const space = std.mem.eql(u8, cluster.bytes, " ");
            if (styledBoundaryAt(&breaks, self.spans, cluster.start) != .prohibited and
                !styledPositionEql(cluster.start, line_start))
            {
                break_end = content_end;
                break_width = content_width;
                break_resume = cluster.start;
                break_machine = breaks;
            }
            const next_width = @as(u32, line_width) + width;
            if (next_width > self.line_width) {
                if (space) {
                    pushStyledBytes(&breaks, cluster.bytes);
                    self.position = cluster.end;
                    self.break_machine = breaks;
                } else if (break_end) |end| {
                    self.position = break_resume;
                    self.break_machine = break_machine;
                    self.need_line = false;
                    return .{ .start = line_start, .end = end, .width = break_width };
                } else {
                    self.position = cluster.start;
                    self.break_machine = breaks;
                }
                self.need_line = false;
                return .{ .start = line_start, .end = content_end, .width = content_width };
            }

            pushStyledBytes(&breaks, cluster.bytes);
            line_width = @intCast(next_width);
            if (!space) {
                content_end = cluster.end;
                content_width = line_width;
            }
        }

        self.position = clusters.position;
        self.break_machine = breaks;
        self.need_line = false;
        return .{ .start = line_start, .end = content_end, .width = content_width };
    }
};

fn styledBoundaryAt(
    machine: *const line_break.Machine,
    spans: []const StyledSpan,
    start: StyledPosition,
) line_break.Kind {
    var codepoints: [3]?u21 = .{ null, null, null };
    var scalars = StyledScalarIterator{ .spans = spans, .position = start };
    for (&codepoints) |*codepoint| {
        codepoint.* = scalars.next() orelse break;
    }
    return machine.boundary(codepoints[0].?, codepoints[1], codepoints[2]);
}

fn pushStyledBytes(machine: *line_break.Machine, bytes: []const u8) void {
    var index: usize = 0;
    while (index < bytes.len) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(bytes[index]) catch unreachable;
        const end = index + sequence_len;
        machine.push(std.unicode.utf8Decode(bytes[index..end]) catch unreachable);
        index = end;
    }
}

fn pushStyledAsciiToken(machine: *line_break.Machine, token: StyledAsciiToken) void {
    machine.push(token.byte);
    if (token.byte == '\r') machine.push('\n');
}

inline fn simpleStyledAsciiByte(byte: u8) bool {
    return byte == ' ' or byte >= '0' and byte <= '9' or byte >= 'A' and byte <= 'Z' or
        byte >= 'a' and byte <= 'z' or switch (byte) {
        '#', '&', '*', '<', '=', '>', '@', '^', '_', '`', '~' => true,
        else => false,
    };
}

inline fn styledPositionEql(lhs: StyledPosition, rhs: StyledPosition) bool {
    return lhs.span == rhs.span and lhs.byte == rhs.byte;
}

inline fn styledLineBreak(bytes: []const u8) bool {
    return std.mem.eql(u8, bytes, "\n") or std.mem.eql(u8, bytes, "\r\n");
}

const RowMeta = struct {
    physical_row: u16 = 0,
    desired_has_references: bool = false,
    presented_has_references: bool = false,
    desired_blank: bool = true,
};

const PendingScroll = struct {
    top: u16,
    bottom: u16,
};

const UniformFillState = struct {
    valid: bool = false,
    transition_valid: bool = false,
    rect: geometry.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    previous: cell_module.Cell = .{},
    cell: cell_module.Cell = .{},
};

const PendingAscii = struct {
    valid: bool = false,
    x: u16 = 0,
    y: u16 = 0,
    len: u8 = 0,
    changed: u8 = 0,
    bytes: [128]u8 = undefined,
};

const UniformOutputCache = struct {
    valid: bool = false,
    size: geometry.Size = .{ .width = 0, .height = 0 },
    style: style_module.Style = .{},
    color_depth: capabilities_module.ColorDepth = .ansi16,
    synchronized_output: bool = false,
    len: u16 = 0,
    bytes: [1024]u8 = undefined,
    terminal_state: ansi.State = .{},
    output_stats: ansi.Stats = .{},
};

const ShapedGlyph = struct {
    start: u8,
    end: u8,
    width: cell_module.Width,
};

const ShapedTextCache = struct {
    bytes: [128]u8 = undefined,
    glyphs: [32]ShapedGlyph = undefined,
    byte_len: u8 = 0,
    glyph_count: u8 = 0,
    width_profile: grapheme.WidthProfile = .narrow,
    valid: bool = false,
};

const paragraph_cache_bytes = 128;
const paragraph_cache_lines = 8;

const CachedParagraphLine = struct {
    start: u8 = 0,
    end: u8 = 0,
    width: u16 = 0,
};

const ParagraphLayoutCache = struct {
    valid: bool = false,
    complete: bool = false,
    ascii: bool = false,
    byte_len: u8 = 0,
    line_count: u8 = 0,
    line_width: u16 = 0,
    width_profile: grapheme.WidthProfile = .narrow,
    bytes: [paragraph_cache_bytes]u8 = undefined,
    lines: [paragraph_cache_lines]CachedParagraphLine = @splat(.{}),
};

const AsciiFieldMode = enum {
    padded,
    line,
};

const ascii_line_cache_rows = 40;
const ascii_line_cache_fields = 4;

const AsciiLineCacheEntry = struct {
    valid: bool = false,
    x: u16 = 0,
    width: u16 = 0,
    content_start: u16 = 0,
    content_end: u16 = 0,
};

const AsciiLineRowCache = struct {
    entries: [ascii_line_cache_fields]AsciiLineCacheEntry = @splat(.{}),
    next: u2 = 0,
};

const cached_span_limit = 128;
const cached_row_limit = 40;
const cached_cell_limit = 1024;
const cached_delta_limit = 8;
const cached_output_limit = 2048;
const cached_tile_word_limit = 4;

const CachedSpan = struct {
    y: u16 = 0,
    start: u16 = 0,
    end: u16 = 0,
    // Keep indexed cache traversal on a power-of-two stride.
    _padding: u16 = 0,
};

const CachedRow = struct {
    y: u16 = 0,
    start: u16 = 0,
    end: u16 = 0,
};

const GlyphDelta = struct {
    next: glyph_store.Glyph = 0,
    previous: glyph_store.Glyph = 0,
    count: u16 = 0,
};

const StyleDelta = struct {
    next: style_module.Id = 0,
    previous: style_module.Id = 0,
    count: u16 = 0,
};

const DiffOutputCache = struct {
    valid: bool = false,
    color_depth: capabilities_module.ColorDepth = .ansi16,
    synchronized_output: bool = false,
    background_color_erase: bool = false,
    glyph_revision: u64 = 0,
    style_revision: u64 = 0,
    before_state: ansi.State = .{},
    after_state: ansi.State = .{},
    span_count: u8 = 0,
    row_count: u8 = 0,
    cell_count: u16 = 0,
    tile_word_count: u8 = 0,
    glyph_delta_count: u8 = 0,
    style_delta_count: u8 = 0,
    spans: [cached_span_limit]CachedSpan = @splat(.{}),
    rows: [cached_row_limit]CachedRow = @splat(.{}),
    tile_words: [cached_tile_word_limit]usize = @splat(0),
    desired: [cached_cell_limit]cell_module.Cell = undefined,
    presented: [cached_cell_limit]cell_module.Cell = undefined,
    glyph_deltas: [cached_delta_limit]GlyphDelta = @splat(.{}),
    style_deltas: [cached_delta_limit]StyleDelta = @splat(.{}),
    output: [cached_output_limit]u8 = undefined,
    output_len: u16 = 0,
    frame_stats: FrameStats = .{},
    uniform_fill: UniformFillState = .{},
};

const DiffCapture = struct {
    downstream: *std.Io.Writer,
    cacheable: bool = true,
    writer: std.Io.Writer,

    fn init(downstream: *std.Io.Writer, buffer: []u8) DiffCapture {
        return .{
            .downstream = downstream,
            .writer = .{
                .buffer = buffer,
                .vtable = &.{ .drain = drain },
            },
        };
    }

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *DiffCapture = @alignCast(@fieldParentPtr("writer", writer));
        self.cacheable = false;
        if (writer.end != 0) {
            try self.downstream.writeAll(writer.buffer[0..writer.end]);
            writer.end = 0;
        }
        for (data[0 .. data.len - 1]) |bytes| try self.downstream.writeAll(bytes);
        const pattern = data[data.len - 1];
        for (0..splat) |_| try self.downstream.writeAll(pattern);
        return std.Io.Writer.countSplat(data, splat);
    }

    fn finish(self: *DiffCapture) std.Io.Writer.Error!u16 {
        const len = self.writer.end;
        if (len != 0) try self.downstream.writeAll(self.writer.buffer[0..len]);
        self.writer.end = 0;
        return if (self.cacheable) @intCast(len) else 0;
    }
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    terminal_size: geometry.Size,
    desired: []cell_module.Cell,
    presented: []cell_module.Cell,
    rows: []RowMeta,
    damage: damage_module.Map,
    glyphs: glyph_store.Store,
    styles: style_module.Table,
    terminal_state: ansi.State = .{},
    terminal_cursor_state: ansi.CursorState = .{},
    shadow_valid: bool = false,
    frame_pending: bool = true,
    desired_uniform: ?cell_module.Cell = .{},
    presented_uniform: ?cell_module.Cell = .{},
    desired_materialized: bool = false,
    presented_materialized: bool = false,
    uniform_output_cache: [2]UniformOutputCache = .{ .{}, .{} },
    uniform_output_cache_next: u1 = 0,
    shaped_text_cache: [2]ShapedTextCache = @splat(.{}),
    shaped_text_cache_next: u1 = 0,
    paragraph_layout_cache: [2]ParagraphLayoutCache = @splat(.{}),
    paragraph_layout_cache_next: u1 = 0,
    diff_output_cache: *[2]DiffOutputCache,
    diff_output_cache_next: u1 = 0,
    diff_output_cache_probe: u1 = 0,
    uniform_fill_state: UniformFillState = .{},
    pending_scroll: ?PendingScroll = null,
    pending_ascii: PendingAscii = .{},
    ascii_line_cache: [ascii_line_cache_rows]AsciiLineRowCache = @splat(.{}),
    row_mapping_identity: bool = true,
    desired_cursor: ?cursor_module.Cursor = null,
    images: []ImageCommand,
    desired_image_count: u16 = 0,
    presented_image_count: u16 = 0,
    presented_image_protocol: capabilities_module.ImageProtocol = .none,
    image_frame_active: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        dimensions: geometry.Size,
        limits: Limits,
    ) !Renderer {
        if (dimensions.width == 0 or dimensions.height == 0) return error.InvalidSize;
        const cell_count = try dimensions.cellCount();
        if (cell_count > limits.max_cells) return error.SizeLimitExceeded;

        var glyphs = try glyph_store.Store.init(allocator, limits.grapheme_capacity);
        errdefer glyphs.deinit();
        var styles = try style_module.Table.init(allocator, limits.style_capacity);
        errdefer styles.deinit();
        const desired = try allocator.alloc(cell_module.Cell, cell_count);
        errdefer allocator.free(desired);
        const presented = try allocator.alloc(cell_module.Cell, cell_count);
        errdefer allocator.free(presented);
        const rows = try allocator.alloc(RowMeta, dimensions.height);
        errdefer allocator.free(rows);
        const diff_output_cache = try allocator.create([2]DiffOutputCache);
        errdefer allocator.destroy(diff_output_cache);
        diff_output_cache.* = .{ .{}, .{} };
        const images = try allocator.alloc(ImageCommand, limits.image_capacity);
        errdefer allocator.free(images);
        var damage = try damage_module.Map.init(
            allocator,
            dimensions,
            limits.tile_width,
            limits.tile_height,
        );
        errdefer damage.deinit();

        for (rows, 0..) |*row, physical_row| {
            row.* = .{
                .physical_row = @intCast(physical_row),
            };
        }
        damage.mark(geometry.Rect.fromSize(dimensions));

        return .{
            .allocator = allocator,
            .limits = limits,
            .terminal_size = dimensions,
            .desired = desired,
            .presented = presented,
            .rows = rows,
            .diff_output_cache = diff_output_cache,
            .images = images,
            .damage = damage,
            .glyphs = glyphs,
            .styles = styles,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.damage.deinit();
        self.allocator.destroy(self.diff_output_cache);
        self.allocator.free(self.images);
        self.allocator.free(self.rows);
        self.allocator.free(self.presented);
        self.allocator.free(self.desired);
        self.styles.deinit();
        self.glyphs.deinit();
        self.* = undefined;
    }

    pub fn size(self: *const Renderer) geometry.Size {
        return self.terminal_size;
    }

    pub fn resize(self: *Renderer, new_size: geometry.Size) !void {
        if (new_size.width == 0 or new_size.height == 0) return error.InvalidSize;
        if (new_size.width == self.terminal_size.width and new_size.height == self.terminal_size.height) return;
        const new_cell_count = try new_size.cellCount();
        if (new_cell_count > self.limits.max_cells) return error.SizeLimitExceeded;
        if (new_cell_count <= self.desired.len and
            new_size.height <= self.rows.len and
            self.damage.canResize(new_size))
        {
            const old_cell_count = self.terminal_size.cellCount() catch unreachable;
            self.releaseGrid(self.desired_uniform, self.desired, old_cell_count);
            self.releaseGrid(self.presented_uniform, self.presented, old_cell_count);
            self.damage.resizeWithinCapacity(new_size);
            self.terminal_size = new_size;
            self.terminal_state = .{};
            self.terminal_cursor_state = .{};
            self.shadow_valid = false;
            self.frame_pending = true;
            self.desired_uniform = .{};
            self.presented_uniform = .{};
            self.desired_materialized = false;
            self.presented_materialized = false;
            self.pending_scroll = null;
            self.pending_ascii.valid = false;
            self.row_mapping_identity = true;
            self.uniform_fill_state.valid = false;
            self.desired_image_count = 0;
            self.image_frame_active = false;
            self.invalidateAsciiLineRows(0, new_size.height);
            for (self.diff_output_cache) |*entry| entry.valid = false;
            return;
        }

        var replacement = try Renderer.init(self.allocator, new_size, self.limits);
        replacement.desired_cursor = self.desired_cursor;
        replacement.presented_image_count = self.presented_image_count;
        replacement.presented_image_protocol = self.presented_image_protocol;
        self.deinit();
        self.* = replacement;
    }

    pub fn invalidate(self: *Renderer, rect: geometry.Rect) void {
        self.damage.mark(rect);
        self.frame_pending = true;
        self.pending_ascii.valid = false;
    }

    /// Discards the terminal shadow while retaining the desired frame.
    /// Use this after external output or terminal resume. The next presentation clears and repaints the terminal.
    pub fn invalidateTerminal(self: *Renderer) void {
        self.shadow_valid = false;
        self.frame_pending = true;
        self.pending_scroll = null;
        self.pending_ascii.valid = false;
        self.terminal_state.invalidate();
        self.terminal_cursor_state.invalidate();
        self.damage.mark(geometry.Rect.fromSize(self.terminal_size));
    }

    /// Starts cursor management and schedules any changed position, visibility, or shape.
    /// An out-of-bounds position is retained but hidden until a later resize makes it visible.
    pub fn setCursor(self: *Renderer, cursor: cursor_module.Cursor) void {
        if (self.desired_cursor) |current| {
            if (current.eql(cursor)) return;
        }
        self.desired_cursor = cursor;
        self.frame_pending = true;
        for (self.diff_output_cache) |*entry| entry.valid = false;
    }

    pub fn scrollUp(self: *Renderer, rect: geometry.Rect) !void {
        if (!self.shadow_valid or self.damage.dirtyRowCount() != 0 or self.pending_scroll != null) {
            return error.FramePending;
        }
        if (rect.x != 0 or rect.width != self.terminal_size.width or rect.height < 2 or
            rect.bottom() > self.terminal_size.height)
        {
            return error.InvalidScrollRegion;
        }
        if (self.desired_uniform != null and self.presented_uniform != null) return;

        self.materializeDesired();
        self.materializePresented();
        self.desired_uniform = null;
        self.presented_uniform = null;

        const top = rect.y;
        const bottom: u16 = @intCast(rect.bottom());
        self.invalidateAsciiLineRows(top, bottom);
        const recycled_physical_row = self.rows[top].physical_row;
        const recycled_offset = @as(usize, recycled_physical_row) * self.terminal_size.width;
        if (self.rows[top].desired_has_references) {
            for (self.desired[recycled_offset .. recycled_offset + self.terminal_size.width]) |cell| {
                if (glyph_store.isComplex(cell.glyph)) self.glyphs.release(cell.glyph);
                if (cell.style != 0) self.styles.release(cell.style);
            }
        }
        if (self.rows[top].presented_has_references) {
            for (self.presented[recycled_offset .. recycled_offset + self.terminal_size.width]) |cell| {
                if (glyph_store.isComplex(cell.glyph)) self.glyphs.release(cell.glyph);
                if (cell.style != 0) self.styles.release(cell.style);
            }
        }

        std.mem.copyForwards(
            RowMeta,
            self.rows[top .. bottom - 1],
            self.rows[top + 1 .. bottom],
        );
        self.rows[bottom - 1] = .{
            .physical_row = recycled_physical_row,
        };
        @memset(self.desired[recycled_offset .. recycled_offset + self.terminal_size.width], .{});
        @memset(self.presented[recycled_offset .. recycled_offset + self.terminal_size.width], .{});
        self.pending_scroll = .{ .top = top, .bottom = bottom };
        self.frame_pending = true;
        self.pending_ascii.valid = false;
        self.row_mapping_identity = false;
        self.uniform_fill_state.valid = false;
    }

    pub fn frame(self: *Renderer) Frame {
        self.desired_image_count = 0;
        self.image_frame_active = self.presented_image_count != 0;
        if (self.presented_image_count != 0) self.frame_pending = true;
        return .{ .renderer = self };
    }

    pub fn desiredCell(self: *const Renderer, point: geometry.Point) ?cell_module.Cell {
        if (point.x >= self.terminal_size.width or point.y >= self.terminal_size.height) return null;
        if (self.desired_uniform) |uniform| return uniform;
        return self.desired[self.index(point.x, point.y)];
    }

    pub fn desiredCellView(
        self: *const Renderer,
        point: geometry.Point,
        glyph_storage: *[grapheme.max_cluster_bytes]u8,
    ) ?CellView {
        const cell = self.desiredCell(point) orelse return null;
        var scalar: [4]u8 = undefined;
        const bytes = self.glyphs.bytes(cell.glyph, &scalar);
        @memcpy(glyph_storage[0..bytes.len], bytes);
        return .{
            .glyph = glyph_storage[0..bytes.len],
            .style = self.styles.get(cell.style),
            .width = cell.width,
        };
    }

    pub inline fn present(
        self: *Renderer,
        writer: *std.Io.Writer,
        capabilities: capabilities_module.Capabilities,
    ) std.Io.Writer.Error!FrameStats {
        if (self.shadow_valid and self.terminal_state.color_depth != capabilities.color_depth) {
            self.invalidateTerminal();
        }
        if (!self.frame_pending) return .{};
        if (!self.image_frame_active and self.presented_image_count == 0 and
            self.shadow_valid and self.pending_scroll == null and !self.pending_ascii.valid and self.desired_uniform == null)
        {
            var stats: FrameStats = undefined;
            if (try self.presentCached(writer, capabilities, &stats)) return stats;
        }
        return self.presentPending(writer, capabilities);
    }

    noinline fn presentCached(
        self: *Renderer,
        writer: *std.Io.Writer,
        capabilities: capabilities_module.Capabilities,
        stats: *FrameStats,
    ) std.Io.Writer.Error!bool {
        const dirty_row_count = self.damage.dirtyRowCount();
        var direct_entry: ?*DiffOutputCache = null;
        if (dirty_row_count == 1) {
            const dirty_rows = self.damage.dirtyRows().?;
            if (dirty_rows.end == dirty_rows.start + 1) {
                const row = self.damage.row(dirty_rows.start).?;
                if (row.end == row.start + 1) {
                    for ([_]u1{ self.diff_output_cache_probe, self.diff_output_cache_probe ^ 1 }) |cache_index| {
                        const entry = &self.diff_output_cache[cache_index];
                        if (!entry.valid or entry.cell_count != 1 or entry.span_count != 1 or
                            entry.spans[0].y != dirty_rows.start or entry.spans[0].start != row.start) continue;
                        const index_value = self.rowOffset(dirty_rows.start) + row.start;
                        if (!self.desired[index_value].eql(entry.desired[0]) or
                            !self.presented[index_value].eql(entry.presented[0]) or
                            entry.color_depth != capabilities.color_depth or
                            entry.synchronized_output != capabilities.synchronized_output or
                            entry.background_color_erase != capabilities.background_color_erase or
                            entry.glyph_revision != self.glyphs.currentRevision() or
                            entry.style_revision != self.styles.currentRevision() or
                            !terminalStateEql(entry.before_state, self.terminal_state)) continue;
                        direct_entry = entry;
                        self.diff_output_cache_probe = cache_index ^ 1;
                        break;
                    }
                } else {
                    for ([_]u1{ self.diff_output_cache_probe, self.diff_output_cache_probe ^ 1 }) |cache_index| {
                        const entry = &self.diff_output_cache[cache_index];
                        if (!entry.valid or entry.row_count != 1 or entry.span_count != 2 or entry.cell_count > 8 or
                            entry.rows[0].y != dirty_rows.start or
                            entry.rows[0].start != row.start or entry.rows[0].end != row.end or
                            entry.color_depth != capabilities.color_depth or
                            entry.synchronized_output != capabilities.synchronized_output or
                            entry.background_color_erase != capabilities.background_color_erase or
                            entry.glyph_revision != self.glyphs.currentRevision() or
                            entry.style_revision != self.styles.currentRevision() or
                            !terminalStateEql(entry.before_state, self.terminal_state)) continue;

                        const tile_words = self.damage.tileWords();
                        if (tile_words.len != entry.tile_word_count) continue;
                        var tiles_match = true;
                        for (tile_words, entry.tile_words[0..entry.tile_word_count]) |actual, cached| {
                            if (actual != cached) {
                                tiles_match = false;
                                break;
                            }
                        }
                        if (!tiles_match) continue;

                        var cell_offset: usize = 0;
                        var cells_match = true;
                        for (entry.spans[0..2]) |span| {
                            const row_offset = self.rowOffset(span.y);
                            var x = span.start;
                            while (x < span.end) : (x += 1) {
                                if (!self.desired[row_offset + x].eql(entry.desired[cell_offset]) or
                                    !self.presented[row_offset + x].eql(entry.presented[cell_offset]))
                                {
                                    cells_match = false;
                                    break;
                                }
                                cell_offset += 1;
                            }
                            if (!cells_match) break;
                        }
                        if (!cells_match or cell_offset != entry.cell_count) continue;
                        direct_entry = entry;
                        self.diff_output_cache_probe = cache_index ^ 1;
                        break;
                    }
                }
            }
        }

        if (direct_entry) |entry| {
            writer.writeAll(entry.output[0..entry.output_len]) catch |err| {
                return self.cachedWriteFailure(err);
            };
            for (entry.glyph_deltas[0..entry.glyph_delta_count]) |delta| {
                self.commitGlyphReferences(delta.next, delta.previous, delta.count);
            }
            for (entry.style_deltas[0..entry.style_delta_count]) |delta| {
                self.commitStyleReferences(delta.next, delta.previous, delta.count);
            }
            if (entry.cell_count == 1) {
                const span = entry.spans[0];
                const index_value = self.rowOffset(span.y) + span.start;
                self.presented[index_value] = self.desired[index_value];
            } else {
                for (entry.spans[0..entry.span_count]) |span| {
                    const row_offset = self.rowOffset(span.y);
                    @memcpy(
                        self.presented[row_offset + span.start .. row_offset + span.end],
                        self.desired[row_offset + span.start .. row_offset + span.end],
                    );
                }
            }
            self.rows[entry.rows[0].y].presented_has_references = self.rows[entry.rows[0].y].desired_has_references;
            self.presented_uniform = self.desired_uniform;
            self.presented_materialized = true;
            self.terminal_state = entry.after_state;
            writer.flush() catch |err| {
                self.invalidateTerminal();
                return err;
            };
            self.damage.reset();
            self.shadow_valid = true;
            self.frame_pending = false;
            stats.* = entry.frame_stats;
            return true;
        }

        stats.* = .{};
        const cache_hit = self.writeCachedDiffOutput(writer, capabilities, dirty_row_count, stats) catch |err| {
            self.invalidateTerminal();
            return err;
        };
        if (!cache_hit) return false;
        writer.flush() catch |err| {
            self.invalidateTerminal();
            return err;
        };
        self.damage.reset();
        self.shadow_valid = true;
        self.frame_pending = false;
        return true;
    }

    noinline fn cachedWriteFailure(self: *Renderer, err: std.Io.Writer.Error) std.Io.Writer.Error!bool {
        self.invalidateTerminal();
        return err;
    }

    noinline fn presentPending(
        self: *Renderer,
        writer: *std.Io.Writer,
        capabilities: capabilities_module.Capabilities,
    ) std.Io.Writer.Error!FrameStats {
        const image_frame = self.image_frame_active;
        const replacing_images = image_frame and self.presented_image_count != 0;
        if (replacing_images) self.invalidateTerminal();
        var stats = FrameStats{
            .dirty_rows = @intCast(self.damage.dirtyRowCount()),
            .full_repaint = !self.shadow_valid,
        };
        const full_repaint = stats.full_repaint;

        const cache_entry = if (!full_repaint and !image_frame) self.prepareDiffOutputCache(capabilities) else null;
        var capture: DiffCapture = undefined;
        const output_writer = if (cache_entry) |entry| output: {
            capture = DiffCapture.init(writer, &entry.output);
            break :output &capture.writer;
        } else writer;

        var output_stats: ansi.Stats = .{};
        var encoder = ansi.Encoder{
            .writer = output_writer,
            .capabilities = capabilities,
            .terminal_width = self.terminal_size.width,
            .state = &self.terminal_state,
            .cursor_state = &self.terminal_cursor_state,
            .stats = &output_stats,
        };

        if (replacing_images and self.presented_image_protocol == .kitty) {
            image_module.clearKitty(output_writer) catch |err| {
                self.invalidateTerminal();
                return err;
            };
        }

        var emitted = self.encode(&encoder, full_repaint, &stats) catch |err| {
            self.invalidateTerminal();
            return err;
        };
        if (image_frame and self.desired_image_count != 0) {
            self.emitImages(&encoder, capabilities.image_protocol) catch |err| {
                self.invalidateTerminal();
                return err;
            };
            emitted = true;
        }
        if (self.desired_cursor) |cursor| {
            const in_bounds = cursor.position.x < self.terminal_size.width and
                cursor.position.y < self.terminal_size.height;
            if (encoder.setCursor(cursor, in_bounds) catch |err| {
                self.invalidateTerminal();
                return err;
            }) emitted = true;
        }
        var captured_len: u16 = 0;
        if (cache_entry != null) {
            captured_len = capture.finish() catch |err| {
                self.invalidateTerminal();
                return err;
            };
        }
        stats.bytes = output_stats.bytes;
        if (cache_entry) |entry| {
            if (capture.cacheable) {
                entry.output_len = captured_len;
                entry.after_state = self.terminal_state;
                entry.frame_stats = stats;
                entry.valid = true;
            }
        }
        if (!full_repaint and stats.cells_changed == 0 and !emitted) {
            std.debug.assert(!emitted);
            self.damage.reset();
            self.frame_pending = false;
            if (image_frame) self.commitImageFrame(capabilities.image_protocol);
            return stats;
        }
        writer.flush() catch |err| {
            self.invalidateTerminal();
            return err;
        };

        self.pending_scroll = null;
        self.pending_ascii.valid = false;
        self.damage.reset();
        self.shadow_valid = true;
        self.frame_pending = false;
        if (image_frame) self.commitImageFrame(capabilities.image_protocol);
        return stats;
    }

    fn emitImages(
        self: *Renderer,
        encoder: *ansi.Encoder,
        protocol: capabilities_module.ImageProtocol,
    ) std.Io.Writer.Error!void {
        try encoder.beginSynchronized();
        for (self.images[0..self.desired_image_count]) |command| {
            try encoder.moveTo(command.rect.y, command.rect.x);
            switch (protocol) {
                .kitty => image_module.writeKitty(encoder.writer, command.image, .{
                    .columns = command.rect.width,
                    .rows = command.rect.height,
                    .image_id = command.options.image_id,
                    .placement_id = command.options.placement_id,
                }) catch |err| switch (err) {
                    error.WriteFailed => return error.WriteFailed,
                    else => unreachable,
                },
                .iterm2 => image_module.writeIterm2(encoder.writer, command.image, .{
                    .columns = command.rect.width,
                    .rows = command.rect.height,
                    .image_id = command.options.image_id,
                    .placement_id = command.options.placement_id,
                }) catch |err| switch (err) {
                    error.WriteFailed => return error.WriteFailed,
                    else => unreachable,
                },
                .sixel => {
                    try encoder.writer.writeAll("\x1b[?80h");
                    image_module.writeSixel(encoder.writer, command.image, command.options.background) catch |err| switch (err) {
                        error.WriteFailed => return error.WriteFailed,
                        else => unreachable,
                    };
                    try encoder.writer.writeAll("\x1b[?80l");
                },
                .none => try emitImageFallback(encoder, command),
            }
            if (protocol != .none) encoder.state.invalidate();
        }
        try encoder.endSynchronized();
    }

    fn commitImageFrame(self: *Renderer, protocol: capabilities_module.ImageProtocol) void {
        self.presented_image_count = self.desired_image_count;
        self.presented_image_protocol = protocol;
        self.desired_image_count = 0;
        self.image_frame_active = false;
    }

    fn encode(
        self: *Renderer,
        encoder: *ansi.Encoder,
        full_repaint: bool,
        stats: *FrameStats,
    ) std.Io.Writer.Error!bool {
        if (self.pending_ascii.valid) return self.encodePendingAscii(encoder, stats);
        var emitted = false;
        if (self.pending_scroll) |scroll| {
            try encoder.beginSynchronized();
            try encoder.scrollUp(scroll.top, scroll.bottom);
            emitted = true;
        } else if (try self.encodeUniform(encoder, full_repaint, stats)) |uniform_emitted| {
            return uniform_emitted;
        }
        self.materializeDesired();
        self.materializePresented();

        if (full_repaint) {
            if (!emitted) try encoder.beginSynchronized();
            try encoder.clear();
            emitted = true;
        }
        const dirty_rows = if (full_repaint)
            damage_module.Span{ .start = 0, .end = self.terminal_size.height }
        else
            self.damage.dirtyRows() orelse return emitted;
        var y = dirty_rows.start;
        while (y < dirty_rows.end) : (y += 1) {
            if (self.spanForRow(y, full_repaint) == null) continue;
            const row_offset = self.rowOffset(y);
            var from: u16 = 0;
            row_spans: while (self.nextSpan(y, from, full_repaint)) |span| {
                var first_changed: ?u16 = null;
                var last_changed: u16 = span.start;
                var glyph_next: glyph_store.Glyph = 0;
                var glyph_previous: glyph_store.Glyph = 0;
                var glyph_count: usize = 0;
                var style_next: style_module.Id = 0;
                var style_previous: style_module.Id = 0;
                var style_count: usize = 0;
                var scan = span.start;
                while (scan < span.end) : (scan += 1) {
                    stats.cells_compared += 1;
                    const index_value = row_offset + scan;
                    const next = self.desired[index_value];
                    const previous = self.presented[index_value];
                    const baseline: cell_module.Cell = if (full_repaint) .{} else self.presented[index_value];
                    if (!next.eql(previous)) {
                        if (next.glyph != previous.glyph and
                            (glyph_store.isComplex(next.glyph) or glyph_store.isComplex(previous.glyph)))
                        {
                            if (glyph_count != 0 and (glyph_next != next.glyph or glyph_previous != previous.glyph)) {
                                self.commitGlyphReferences(glyph_next, glyph_previous, glyph_count);
                                glyph_count = 0;
                            }
                            glyph_next = next.glyph;
                            glyph_previous = previous.glyph;
                            glyph_count += 1;
                        }
                        if (next.style != previous.style) {
                            if (style_count != 0 and (style_next != next.style or style_previous != previous.style)) {
                                self.commitStyleReferences(style_next, style_previous, style_count);
                                style_count = 0;
                            }
                            style_next = next.style;
                            style_previous = previous.style;
                            style_count += 1;
                        }
                        self.presented[index_value] = next;
                        self.presented_uniform = null;
                    }
                    if (next.eql(baseline)) continue;
                    stats.cells_changed += 1;
                    if (first_changed == null) first_changed = scan;
                    last_changed = scan + 1;
                }
                self.commitGlyphReferences(glyph_next, glyph_previous, glyph_count);
                self.commitStyleReferences(style_next, style_previous, style_count);
                var x = first_changed orelse {
                    from = span.end;
                    continue;
                };
                if (self.desired[row_offset + x].width == .continuation) x -= 1;

                if (!emitted) {
                    try encoder.beginSynchronized();
                    emitted = true;
                }
                if (self.blankToRowEnd(x, y)) {
                    try encoder.moveTo(y, x);
                    try encoder.setStyle(.{});
                    try encoder.eraseLineRight();
                    stats.runs += 1;
                    break :row_spans;
                }

                try encoder.moveTo(y, x);
                stats.runs += 1;
                while (x < last_changed) {
                    const cell = self.desired[row_offset + x];
                    if (cell.width == .continuation) {
                        x += 1;
                        continue;
                    }

                    try encoder.setStyle(self.styles.get(cell.style));
                    if (cell.glyph <= 0x7F and cell.width == .narrow and x + 1 < last_changed) {
                        const next = self.desired[row_offset + x + 1];
                        if (next.glyph <= 0x7F and next.width == .narrow and next.style == cell.style) {
                            x = try self.writeAsciiRun(encoder, row_offset, x, last_changed, cell.style);
                            continue;
                        }
                    }
                    if (cell.glyph == ' ' and cell.width == .narrow) {
                        var end = x + 1;
                        while (end < last_changed) : (end += 1) {
                            const next = self.desired[row_offset + end];
                            if (next.glyph != ' ' or next.width != .narrow or next.style != cell.style) break;
                        }
                        try encoder.writeSpaces(end - x);
                        x = end;
                        continue;
                    }
                    var scalar_buffer: [4]u8 = undefined;
                    const bytes = self.glyphs.bytes(cell.glyph, &scalar_buffer);
                    const width: u2 = switch (cell.width) {
                        .continuation => unreachable,
                        .narrow => 1,
                        .wide => 2,
                    };
                    try encoder.writeGlyph(bytes, width);
                    x += width;
                }
                from = span.end;
            }
            self.rows[y].presented_has_references = self.rows[y].desired_has_references;
        }
        self.presented_uniform = self.desired_uniform;
        self.presented_materialized = true;
        if (emitted) try encoder.endSynchronized();
        return emitted;
    }

    fn encodePendingAscii(
        self: *Renderer,
        encoder: *ansi.Encoder,
        stats: *FrameStats,
    ) std.Io.Writer.Error!bool {
        const pending = &self.pending_ascii;
        try encoder.beginSynchronized();
        if (self.pending_scroll) |scroll| try encoder.scrollUp(scroll.top, scroll.bottom);
        try encoder.moveTo(pending.y, pending.x);
        try encoder.setStyle(.{});
        try encoder.writeAscii(pending.bytes[0..pending.len]);
        try encoder.endSynchronized();

        self.materializePresented();
        const row_offset = self.rowOffset(pending.y);
        @memcpy(
            self.presented[row_offset + pending.x .. row_offset + pending.x + pending.len],
            self.desired[row_offset + pending.x .. row_offset + pending.x + pending.len],
        );
        const row = &self.rows[pending.y];
        row.presented_has_references = row.desired_has_references;
        self.presented_uniform = null;
        self.presented_materialized = true;
        stats.cells_compared = pending.len;
        stats.cells_changed = pending.changed;
        stats.runs = 1;
        return true;
    }

    noinline fn writeAsciiRun(
        self: *const Renderer,
        encoder: *ansi.Encoder,
        row_offset: usize,
        start: u16,
        limit: u16,
        style_id: style_module.Id,
    ) std.Io.Writer.Error!u16 {
        var buffer: [128]u8 = undefined;
        var x = start;
        while (x < limit) {
            var len: u16 = 0;
            while (x < limit and len < buffer.len) {
                const cell = self.desired[row_offset + x];
                if (cell.glyph > 0x7F or cell.width != .narrow or cell.style != style_id) break;
                buffer[len] = @intCast(cell.glyph);
                len += 1;
                x += 1;
            }
            try encoder.writeAscii(buffer[0..len]);
            if (len < buffer.len) break;
        }
        return x;
    }

    fn encodeUniform(
        self: *Renderer,
        encoder: *ansi.Encoder,
        full_repaint: bool,
        stats: *FrameStats,
    ) std.Io.Writer.Error!?bool {
        const desired = self.desired_uniform orelse return null;
        if (desired.glyph != ' ' or desired.width != .narrow) return null;
        if (!full_repaint and stats.dirty_rows == 0) return false;
        const presented = self.presented_uniform orelse return null;
        const baseline: cell_module.Cell = if (full_repaint) .{} else presented;
        const cell_count = self.terminal_size.cellCount() catch unreachable;
        stats.cells_compared = @intCast(cell_count);

        if (desired.eql(baseline)) {
            if (!full_repaint) {
                return false;
            }
            try encoder.beginSynchronized();
            try encoder.clear();
            try encoder.endSynchronized();
            if (!desired.eql(presented)) self.commitUniform(desired, presented, cell_count);
            return true;
        }

        stats.cells_changed = @intCast(cell_count);
        const style = self.styles.get(desired.style);
        if (!full_repaint and try self.writeCachedUniformOutput(encoder, style)) {
            stats.runs = self.terminal_size.height;
            self.commitUniform(desired, presented, cell_count);
            return true;
        }
        try encoder.beginSynchronized();
        if (full_repaint) try encoder.clear();
        var y: u16 = 0;
        while (y < self.terminal_size.height) : (y += 1) {
            try encoder.moveTo(y, 0);
            try encoder.setStyle(style);
            if (desired.eql(.{}) or encoder.capabilities.background_color_erase) {
                try encoder.eraseLineRight();
            } else {
                try encoder.writeSpaces(self.terminal_size.width);
            }
            stats.runs += 1;
        }
        try encoder.endSynchronized();
        self.commitUniform(desired, presented, cell_count);
        return true;
    }

    fn writeCachedUniformOutput(
        self: *Renderer,
        encoder: *ansi.Encoder,
        style: style_module.Style,
    ) std.Io.Writer.Error!bool {
        if (!encoder.capabilities.background_color_erase or self.terminal_size.height > 80) return false;

        for (&self.uniform_output_cache) |*cache| {
            if (!cache.valid or
                cache.size.width != self.terminal_size.width or
                cache.size.height != self.terminal_size.height or
                !cache.style.eql(style) or
                cache.color_depth != encoder.capabilities.color_depth or
                cache.synchronized_output != encoder.capabilities.synchronized_output) continue;
            try encoder.writer.writeAll(cache.bytes[0..cache.len]);
            encoder.state.* = cache.terminal_state;
            encoder.stats.* = cache.output_stats;
            return true;
        }

        const cache = &self.uniform_output_cache[self.uniform_output_cache_next];
        self.uniform_output_cache_next +%= 1;
        cache.valid = false;
        var fixed = std.Io.Writer.fixed(&cache.bytes);
        var terminal_state: ansi.State = .{};
        var terminal_cursor_state: ansi.CursorState = .{};
        var output_stats: ansi.Stats = .{};
        var cached_encoder = ansi.Encoder{
            .writer = &fixed,
            .capabilities = encoder.capabilities,
            .terminal_width = self.terminal_size.width,
            .state = &terminal_state,
            .cursor_state = &terminal_cursor_state,
            .stats = &output_stats,
        };
        cached_encoder.beginSynchronized() catch return false;
        var y: u16 = 0;
        while (y < self.terminal_size.height) : (y += 1) {
            cached_encoder.moveTo(y, 0) catch return false;
            cached_encoder.setStyle(style) catch return false;
            cached_encoder.eraseLineRight() catch return false;
        }
        cached_encoder.endSynchronized() catch return false;

        cache.size = self.terminal_size;
        cache.style = style;
        cache.color_depth = encoder.capabilities.color_depth;
        cache.synchronized_output = encoder.capabilities.synchronized_output;
        cache.len = @intCast(fixed.buffered().len);
        cache.terminal_state = terminal_state;
        cache.output_stats = output_stats;
        cache.valid = true;
        try encoder.writer.writeAll(cache.bytes[0..cache.len]);
        encoder.state.* = cache.terminal_state;
        encoder.stats.* = cache.output_stats;
        return true;
    }

    fn writeCachedDiffOutput(
        self: *Renderer,
        writer: *std.Io.Writer,
        capabilities: capabilities_module.Capabilities,
        dirty_row_count: usize,
        stats: *FrameStats,
    ) std.Io.Writer.Error!bool {
        self.materializeDesired();
        self.materializePresented();

        for ([_]u1{ self.diff_output_cache_probe, self.diff_output_cache_probe ^ 1 }) |cache_index| {
            const entry = &self.diff_output_cache[cache_index];
            if (!entry.valid or
                entry.color_depth != capabilities.color_depth or
                entry.synchronized_output != capabilities.synchronized_output or
                entry.background_color_erase != capabilities.background_color_erase or
                entry.glyph_revision != self.glyphs.currentRevision() or
                entry.style_revision != self.styles.currentRevision() or
                !terminalStateEql(entry.before_state, self.terminal_state) or
                !(entry.uniform_fill.transition_valid and
                    uniformFillTransitionEql(entry.uniform_fill, self.uniform_fill_state)) and
                    !self.diffCacheCellsMatch(entry, dirty_row_count)) continue;

            try writer.writeAll(entry.output[0..entry.output_len]);
            for (entry.glyph_deltas[0..entry.glyph_delta_count]) |delta| {
                self.commitGlyphReferences(delta.next, delta.previous, delta.count);
            }
            for (entry.style_deltas[0..entry.style_delta_count]) |delta| {
                self.commitStyleReferences(delta.next, delta.previous, delta.count);
            }
            for (entry.spans[0..entry.span_count]) |span| {
                const row_offset = self.rowOffset(span.y);
                @memcpy(
                    self.presented[row_offset + span.start .. row_offset + span.end],
                    self.desired[row_offset + span.start .. row_offset + span.end],
                );
            }
            for (entry.rows[0..entry.row_count]) |row| {
                self.rows[row.y].presented_has_references = self.rows[row.y].desired_has_references;
            }
            self.presented_uniform = self.desired_uniform;
            self.presented_materialized = true;
            self.terminal_state = entry.after_state;
            stats.* = entry.frame_stats;
            self.diff_output_cache_probe = cache_index ^ 1;
            return true;
        }
        return false;
    }

    fn diffCacheCellsMatch(self: *const Renderer, entry: *const DiffOutputCache, dirty_row_count: usize) bool {
        if (dirty_row_count != entry.row_count) return false;
        const tile_words = self.damage.tileWords();
        if (tile_words.len != entry.tile_word_count) return false;
        for (tile_words, entry.tile_words[0..entry.tile_word_count]) |actual, cached| {
            if (actual != cached) return false;
        }
        for (entry.rows[0..entry.row_count]) |cached| {
            const actual = self.damage.row(cached.y) orelse return false;
            if (actual.start != cached.start or actual.end != cached.end) return false;
        }

        var cell_offset: usize = 0;
        for (entry.spans[0..entry.span_count]) |span| {
            const row_offset = self.rowOffset(span.y);
            const len = span.end - span.start;
            if (len <= 4) {
                var x = span.start;
                while (x < span.end) : (x += 1) {
                    if (!self.desired[row_offset + x].eql(entry.desired[cell_offset]) or
                        !self.presented[row_offset + x].eql(entry.presented[cell_offset])) return false;
                    cell_offset += 1;
                }
                continue;
            } else {
                const desired = self.desired[row_offset + span.start .. row_offset + span.end];
                const presented = self.presented[row_offset + span.start .. row_offset + span.end];
                if (!std.mem.eql(
                    u8,
                    std.mem.sliceAsBytes(desired),
                    std.mem.sliceAsBytes(entry.desired[cell_offset .. cell_offset + len]),
                ) or !std.mem.eql(
                    u8,
                    std.mem.sliceAsBytes(presented),
                    std.mem.sliceAsBytes(entry.presented[cell_offset .. cell_offset + len]),
                )) return false;
            }
            cell_offset += len;
        }
        return cell_offset == entry.cell_count;
    }

    fn prepareDiffOutputCache(
        self: *Renderer,
        capabilities: capabilities_module.Capabilities,
    ) ?*DiffOutputCache {
        if (self.pending_scroll != null or self.desired_uniform != null) return null;
        self.materializeDesired();
        self.materializePresented();
        const dirty_rows = self.damage.dirtyRows() orelse return null;

        const entry = &self.diff_output_cache[self.diff_output_cache_next];
        self.diff_output_cache_next +%= 1;
        self.diff_output_cache_probe = self.diff_output_cache_next;
        entry.valid = false;
        entry.color_depth = capabilities.color_depth;
        entry.synchronized_output = capabilities.synchronized_output;
        entry.background_color_erase = capabilities.background_color_erase;
        entry.glyph_revision = self.glyphs.currentRevision();
        entry.style_revision = self.styles.currentRevision();
        entry.before_state = self.terminal_state;
        entry.span_count = 0;
        entry.row_count = 0;
        entry.cell_count = 0;
        entry.tile_word_count = 0;
        entry.glyph_delta_count = 0;
        entry.style_delta_count = 0;
        entry.uniform_fill = self.uniform_fill_state;

        const tile_words = self.damage.tileWords();
        if (tile_words.len > cached_tile_word_limit) return null;
        @memcpy(entry.tile_words[0..tile_words.len], tile_words);
        entry.tile_word_count = @intCast(tile_words.len);

        var y = dirty_rows.start;
        while (y < dirty_rows.end) : (y += 1) {
            const row = self.damage.row(y) orelse continue;
            if (entry.row_count == cached_row_limit) return null;
            entry.rows[entry.row_count] = .{ .y = y, .start = row.start, .end = row.end };
            entry.row_count += 1;
            var from: u16 = 0;
            while (self.damage.nextTileSpan(y, from)) |span| {
                const span_len = span.end - span.start;
                if (entry.span_count == cached_span_limit or
                    @as(usize, entry.cell_count) + span_len > cached_cell_limit) return null;
                entry.spans[entry.span_count] = .{
                    .y = y,
                    .start = span.start,
                    .end = span.end,
                };
                entry.span_count += 1;
                const row_offset = self.rowOffset(y);
                var x = span.start;
                while (x < span.end) : (x += 1) {
                    const next = self.desired[row_offset + x];
                    const previous = self.presented[row_offset + x];
                    const cell_index = entry.cell_count;
                    entry.desired[cell_index] = next;
                    entry.presented[cell_index] = previous;
                    entry.cell_count += 1;
                    if (!next.eql(previous)) {
                        if (!self.addCachedGlyphDelta(entry, next.glyph, previous.glyph) or
                            !self.addCachedStyleDelta(entry, next.style, previous.style)) return null;
                    }
                }
                from = span.end;
            }
        }
        return entry;
    }

    fn addCachedGlyphDelta(
        self: *Renderer,
        entry: *DiffOutputCache,
        next: glyph_store.Glyph,
        previous: glyph_store.Glyph,
    ) bool {
        _ = self;
        if (next == previous or (!glyph_store.isComplex(next) and !glyph_store.isComplex(previous))) return true;
        for (entry.glyph_deltas[0..entry.glyph_delta_count]) |*delta| {
            if (delta.next == next and delta.previous == previous) {
                delta.count += 1;
                return true;
            }
        }
        if (entry.glyph_delta_count == cached_delta_limit) return false;
        entry.glyph_deltas[entry.glyph_delta_count] = .{ .next = next, .previous = previous, .count = 1 };
        entry.glyph_delta_count += 1;
        return true;
    }

    fn addCachedStyleDelta(
        self: *Renderer,
        entry: *DiffOutputCache,
        next: style_module.Id,
        previous: style_module.Id,
    ) bool {
        _ = self;
        if (next == previous) return true;
        for (entry.style_deltas[0..entry.style_delta_count]) |*delta| {
            if (delta.next == next and delta.previous == previous) {
                delta.count += 1;
                return true;
            }
        }
        if (entry.style_delta_count == cached_delta_limit) return false;
        entry.style_deltas[entry.style_delta_count] = .{ .next = next, .previous = previous, .count = 1 };
        entry.style_delta_count += 1;
        return true;
    }

    fn blankToRowEnd(self: *const Renderer, start: u16, y: u16) bool {
        const row_offset = self.rowOffset(y);
        var x = start;
        while (x < self.terminal_size.width) : (x += 1) {
            if (!self.desired[row_offset + x].eql(.{})) return false;
        }
        return true;
    }

    inline fn spanForRow(self: *const Renderer, y: u16, full_repaint: bool) ?damage_module.Span {
        if (full_repaint) return .{ .start = 0, .end = self.terminal_size.width };
        return self.damage.row(y);
    }

    inline fn nextSpan(self: *const Renderer, y: u16, from: u16, full_repaint: bool) ?damage_module.Span {
        if (full_repaint) {
            if (from >= self.terminal_size.width) return null;
            return .{ .start = from, .end = self.terminal_size.width };
        }
        return self.damage.nextTileSpan(y, from);
    }

    fn commitUniform(self: *Renderer, next: cell_module.Cell, previous: cell_module.Cell, count: usize) void {
        self.glyphs.retainMany(next.glyph, count);
        self.styles.retainMany(next.style, count);
        self.glyphs.releaseMany(previous.glyph, count);
        self.styles.releaseMany(previous.style, count);
        self.presented_uniform = next;
        self.presented_materialized = false;
    }

    fn commitGlyphReferences(
        self: *Renderer,
        next: glyph_store.Glyph,
        previous: glyph_store.Glyph,
        count: usize,
    ) void {
        if (count == 0) return;
        if (glyph_store.isComplex(next)) self.glyphs.retainMany(next, count);
        if (glyph_store.isComplex(previous)) self.glyphs.releaseMany(previous, count);
    }

    fn commitStyleReferences(self: *Renderer, next: style_module.Id, previous: style_module.Id, count: usize) void {
        if (count == 0) return;
        if (next != 0) self.styles.retainMany(next, count);
        if (previous != 0) self.styles.releaseMany(previous, count);
    }

    fn setGlyph(
        self: *Renderer,
        x: u16,
        y: u16,
        glyph: glyph_store.Glyph,
        style_id: style_module.Id,
        width: cell_module.Width,
    ) void {
        self.pending_ascii.valid = false;
        std.debug.assert(width != .continuation);
        self.materializeDesired();
        const head = cell_module.Cell{ .glyph = glyph, .style = style_id, .width = width };
        const head_index = self.index(x, y);
        if (self.desired[head_index].eql(head)) {
            if (width == .narrow or self.desired[self.index(x + 1, y)].eql(.{ .style = style_id, .width = .continuation })) return;
        }

        self.frame_pending = true;
        self.desired_uniform = null;
        self.detachGlyphAt(x, y);
        if (width == .wide) self.detachGlyphAt(x + 1, y);
        self.assignDesired(x, y, head);
        if (width == .wide) {
            self.assignDesired(x + 1, y, .{ .style = style_id, .width = .continuation });
        }
    }

    fn setAscii(self: *Renderer, x: u16, y: u16, glyph: u8, style_id: style_module.Id) void {
        self.pending_ascii.valid = false;
        self.materializeDesired();
        const index_value = self.index(x, y);
        const previous = self.desired[index_value];
        const next = cell_module.Cell{ .glyph = glyph, .style = style_id };
        if (previous.eql(next)) return;
        self.invalidateAsciiLineRow(y);
        self.frame_pending = true;
        self.uniform_fill_state.valid = false;
        if (previous.width != .narrow) {
            self.setGlyph(x, y, glyph, style_id, .narrow);
            return;
        }

        self.desired_uniform = null;
        if (glyph_store.isComplex(previous.glyph)) self.glyphs.release(previous.glyph);
        if (next.style != previous.style) {
            if (next.style != 0) self.styles.retain(next.style);
            if (previous.style != 0) self.styles.release(previous.style);
        }
        self.desired[index_value] = next;
        const row = &self.rows[y];
        if (style_id != 0) row.desired_has_references = true;
        if (glyph != ' ' or style_id != 0) row.desired_blank = false;
        self.damage.markCell(x, y);
    }

    fn detachGlyphAt(self: *Renderer, x: u16, y: u16) void {
        if (x >= self.terminal_size.width) return;
        switch (self.desired[self.index(x, y)].width) {
            .continuation => {
                std.debug.assert(x > 0);
                self.assignDesired(x - 1, y, .{});
            },
            .wide => self.assignDesired(x + 1, y, .{}),
            .narrow => {},
        }
    }

    fn fillFullRows(self: *Renderer, start_y: u16, end_y: u16, style_id: style_module.Id) void {
        self.invalidateAsciiLineRows(start_y, end_y);
        self.frame_pending = true;
        self.pending_ascii.valid = false;
        self.uniform_fill_state.valid = false;
        const target = cell_module.Cell{ .style = style_id };
        const full_screen = start_y == 0 and end_y == self.terminal_size.height;
        if (full_screen) {
            if (self.desired_uniform) |previous| {
                if (previous.eql(target)) return;
                const count = self.terminal_size.cellCount() catch unreachable;
                self.glyphs.retainMany(target.glyph, count);
                self.styles.retainMany(target.style, count);
                self.glyphs.releaseMany(previous.glyph, count);
                self.styles.releaseMany(previous.style, count);
                self.damage.mark(geometry.Rect.fromSize(self.terminal_size));
                self.desired_uniform = target;
                self.desired_materialized = false;
                return;
            }
        }

        self.materializeDesired();
        var changed_cells: usize = 0;
        var changed_styles: usize = 0;
        var dirty_start: ?u16 = null;

        var y = start_y;
        while (y < end_y) : (y += 1) {
            var row_changed = false;
            var x: u16 = 0;
            while (x < self.terminal_size.width) : (x += 1) {
                const index_value = self.index(x, y);
                const previous = self.desired[index_value];
                if (previous.eql(target)) continue;
                if (glyph_store.isComplex(previous.glyph)) self.glyphs.release(previous.glyph);
                if (previous.style != target.style) {
                    if (previous.style != 0) self.styles.release(previous.style);
                    changed_styles += 1;
                }
                self.desired[index_value] = target;
                changed_cells += 1;
                row_changed = true;
            }

            if (row_changed) {
                const blank = target.eql(.{});
                self.rows[y].desired_has_references = target.style != 0;
                self.rows[y].desired_blank = blank;
                if (dirty_start == null) dirty_start = y;
            } else if (dirty_start) |first| {
                self.damage.mark(.{
                    .x = 0,
                    .y = first,
                    .width = self.terminal_size.width,
                    .height = y - first,
                });
                dirty_start = null;
            }
        }
        if (dirty_start) |first| {
            self.damage.mark(.{
                .x = 0,
                .y = first,
                .width = self.terminal_size.width,
                .height = end_y - first,
            });
        }
        self.styles.retainMany(style_id, changed_styles);
        if (full_screen) {
            self.desired_uniform = target;
            self.desired_materialized = true;
        } else if (changed_cells != 0) {
            if (self.desired_uniform) |uniform| {
                if (!uniform.eql(target)) self.desired_uniform = null;
            }
        }
    }

    fn fillCellRect(self: *Renderer, rect: geometry.Rect, target: cell_module.Cell) void {
        self.invalidateAsciiLineRows(rect.y, @intCast(rect.bottom()));
        self.frame_pending = true;
        self.pending_ascii.valid = false;
        if (self.uniform_fill_state.valid and rectEql(self.uniform_fill_state.rect, rect)) {
            const previous = self.uniform_fill_state.cell;
            if (previous.eql(target)) return;
            const count = @as(usize, rect.width) * rect.height;
            if (glyph_store.isComplex(target.glyph)) self.glyphs.retainMany(target.glyph, count);
            if (glyph_store.isComplex(previous.glyph)) self.glyphs.releaseMany(previous.glyph, count);
            if (target.style != previous.style) {
                if (target.style != 0) self.styles.retainMany(target.style, count);
                if (previous.style != 0) self.styles.releaseMany(previous.style, count);
            }
            const end_x: u16 = @intCast(rect.right());
            const end_y: u16 = @intCast(rect.bottom());
            var y = rect.y;
            while (y < end_y) : (y += 1) {
                const row_offset = self.rowOffset(y);
                @memset(self.desired[row_offset + rect.x .. row_offset + end_x], target);
                if (target.style != 0) self.rows[y].desired_has_references = true;
                if (!target.eql(.{})) self.rows[y].desired_blank = false;
            }
            self.damage.mark(rect);
            self.desired_uniform = null;
            self.uniform_fill_state.previous = previous;
            self.uniform_fill_state.cell = target;
            self.uniform_fill_state.transition_valid = !target.eql(.{});
            return;
        }

        self.uniform_fill_state.valid = false;
        self.materializeDesired();
        const target_has_references = glyph_store.isComplex(target.glyph) or target.style != 0;
        const target_blank = target.eql(.{});
        const end_x: u16 = @intCast(rect.right());
        const end_y: u16 = @intCast(rect.bottom());
        var changed_cells: usize = 0;
        var changed_glyphs: usize = 0;
        var changed_styles: usize = 0;
        var y = rect.y;
        while (y < end_y) : (y += 1) {
            if (rect.x > 0 and self.desired[self.index(rect.x, y)].width == .continuation) {
                self.desired_uniform = null;
                self.assignDesired(rect.x - 1, y, .{});
            }
            if (end_x < self.terminal_size.width and self.desired[self.index(end_x, y)].width == .continuation) {
                self.desired_uniform = null;
                self.assignDesired(end_x, y, .{});
            }

            const row_offset = self.rowOffset(y);
            const cells = self.desired[row_offset + rect.x .. row_offset + end_x];
            const previous_uniform = cells[0];
            var uniform = true;
            for (cells[1..]) |cell| {
                if (!cell.eql(previous_uniform)) {
                    uniform = false;
                    break;
                }
            }
            if (uniform and !previous_uniform.eql(target)) {
                if (previous_uniform.glyph != target.glyph) {
                    if (glyph_store.isComplex(previous_uniform.glyph)) {
                        self.glyphs.releaseMany(previous_uniform.glyph, cells.len);
                    }
                    changed_glyphs += cells.len;
                }
                if (previous_uniform.style != target.style) {
                    if (previous_uniform.style != 0) self.styles.releaseMany(previous_uniform.style, cells.len);
                    changed_styles += cells.len;
                }
                @memset(cells, target);
                changed_cells += cells.len;
                self.damage.mark(.{ .x = rect.x, .y = y, .width = rect.width, .height = 1 });
                if (target_has_references) self.rows[y].desired_has_references = true;
                if (!target_blank) self.rows[y].desired_blank = false;
                continue;
            }

            var dirty_start: ?u16 = null;
            var row_changed = false;
            var x = rect.x;
            while (x < end_x) : (x += 1) {
                const index_value = row_offset + x;
                const previous = self.desired[index_value];
                if (previous.eql(target)) {
                    if (dirty_start) |first| {
                        self.damage.mark(.{ .x = first, .y = y, .width = x - first, .height = 1 });
                        dirty_start = null;
                    }
                    continue;
                }

                if (previous.glyph != target.glyph) {
                    if (glyph_store.isComplex(previous.glyph)) self.glyphs.release(previous.glyph);
                    changed_glyphs += 1;
                }
                if (previous.style != target.style) {
                    if (previous.style != 0) self.styles.release(previous.style);
                    changed_styles += 1;
                }
                self.desired[index_value] = target;
                changed_cells += 1;
                row_changed = true;
                if (dirty_start == null) dirty_start = x;
            }
            if (dirty_start) |first| {
                self.damage.mark(.{ .x = first, .y = y, .width = end_x - first, .height = 1 });
            }
            if (row_changed) {
                if (target_has_references) self.rows[y].desired_has_references = true;
                if (!target_blank) self.rows[y].desired_blank = false;
            }
        }
        if (changed_cells != 0) self.desired_uniform = null;
        self.glyphs.retainMany(target.glyph, changed_glyphs);
        self.styles.retainMany(target.style, changed_styles);
        self.uniform_fill_state = .{
            .valid = true,
            .transition_valid = false,
            .rect = rect,
            .cell = target,
        };
    }

    fn putAsciiPadded(
        self: *Renderer,
        origin: geometry.Point,
        text: []const u8,
        field_width: u16,
        style_id: style_module.Id,
    ) u16 {
        return self.putAsciiField(.padded, origin, text, field_width, 0, 0, style_id);
    }

    fn putAsciiLine(
        self: *Renderer,
        origin: geometry.Point,
        text: []const u8,
        field_width: u16,
        text_offset: u16,
        marker_width: u2,
        style_id: style_module.Id,
    ) void {
        if (style_id == 0 and !self.rows[origin.y].desired_has_references) {
            self.putAsciiLineDefault(origin, text, field_width, text_offset, marker_width);
            return;
        }
        _ = self.putAsciiField(.line, origin, text, field_width, text_offset, marker_width, style_id);
    }

    fn putAsciiLineDefault(
        self: *Renderer,
        origin: geometry.Point,
        text: []const u8,
        field_width: u16,
        text_offset: u16,
        marker_width: u2,
    ) void {
        self.materializeDesired();
        const count = @min(field_width, self.terminal_size.width - origin.x);
        if (count == 0) return;
        const text_count: u16 = @intCast(text.len);
        std.debug.assert(text_offset + text_count + marker_width <= count);
        const end_x = origin.x + count;
        if (origin.x > 0 and self.desired[self.index(origin.x, origin.y)].width == .continuation) {
            self.desired_uniform = null;
            self.assignDesired(origin.x - 1, origin.y, .{});
        }
        if (end_x < self.terminal_size.width and self.desired[self.index(end_x, origin.y)].width == .continuation) {
            self.desired_uniform = null;
            self.assignDesired(end_x, origin.y, .{});
        }

        const content_end = text_offset + text_count + marker_width;
        const previous_content = self.prepareAsciiLineCache(
            origin.y,
            origin.x,
            count,
            text_offset,
            content_end,
        );
        const scan_start: u16 = if (previous_content) |previous|
            @min(previous.start, text_offset)
        else
            0;
        const scan_end: u16 = if (previous_content) |previous|
            @max(previous.end, content_end)
        else
            count;

        const row_offset = self.rowOffset(origin.y) + origin.x;
        const cells = self.desired[row_offset .. row_offset + count];
        var first_changed: u16 = std.math.maxInt(u16);
        var last_changed: u16 = 0;
        var offset = scan_start;
        while (offset < text_offset) : (offset += 1) {
            replaceUnstyledLineCell(cells, offset, ' ', .narrow, &first_changed, &last_changed);
        }
        for (text, 0..) |byte, text_index| {
            offset = text_offset + @as(u16, @intCast(text_index));
            replaceUnstyledLineCell(cells, offset, byte, .narrow, &first_changed, &last_changed);
        }
        offset = text_offset + text_count;
        if (marker_width != 0) {
            replaceUnstyledLineCell(
                cells,
                offset,
                0x2026,
                if (marker_width == 1) .narrow else .wide,
                &first_changed,
                &last_changed,
            );
            offset += 1;
            if (marker_width == 2) {
                replaceUnstyledLineCell(cells, offset, ' ', .continuation, &first_changed, &last_changed);
                offset += 1;
            }
        }
        while (offset < scan_end) : (offset += 1) {
            replaceUnstyledLineCell(cells, offset, ' ', .narrow, &first_changed, &last_changed);
        }

        if (first_changed == std.math.maxInt(u16)) return;
        self.frame_pending = true;
        self.pending_ascii.valid = false;
        self.uniform_fill_state.valid = false;
        self.damage.markSpan(origin.y, origin.x + first_changed, origin.x + last_changed);
        self.desired_uniform = null;
        if (marker_width != 0 or !allSpaces(text)) self.rows[origin.y].desired_blank = false;
    }

    fn putAsciiStyledRange(
        self: *Renderer,
        comptime prefix_range: bool,
        origin: geometry.Point,
        spans: []const StyledSpan,
        range_start: StyledPosition,
        range_end: StyledPosition,
        field_width: u16,
        text_offset: u16,
        marker_width: u2,
        base_style: style_module.Style,
    ) !void {
        self.materializeDesired();
        const count = @min(field_width, self.terminal_size.width - origin.x);
        if (count == 0) return;
        self.invalidateAsciiLineRow(origin.y);
        const end_x = origin.x + count;
        if (origin.x > 0 and self.desired[self.index(origin.x, origin.y)].width == .continuation) {
            self.desired_uniform = null;
            self.assignDesired(origin.x - 1, origin.y, .{});
        }
        if (end_x < self.terminal_size.width and self.desired[self.index(end_x, origin.y)].width == .continuation) {
            self.desired_uniform = null;
            self.assignDesired(end_x, origin.y, .{});
        }

        const row_offset = self.rowOffset(origin.y) + origin.x;
        const cells = self.desired[row_offset .. row_offset + count];
        var first_changed: u16 = std.math.maxInt(u16);
        var last_changed: u16 = 0;
        var has_references = false;
        var nonblank = marker_width != 0;
        errdefer self.finishAsciiStyledLine(
            origin,
            first_changed,
            last_changed,
            has_references,
            nonblank,
        );
        const base_id = try self.styles.intern(base_style);
        defer self.styles.release(base_id);
        if (base_id != 0) {
            has_references = true;
            nonblank = true;
        }

        var offset: u16 = 0;
        replaceStyledFill(
            self,
            cells,
            0,
            text_offset,
            .{ .style = base_id },
            &first_changed,
            &last_changed,
        );
        offset = text_offset;
        if (!styledPositionEql(range_start, range_end)) {
            if (prefix_range) {
                std.debug.assert(range_start.span == 0 and range_start.byte == 0);
                for (spans[0..range_end.span]) |span| {
                    try self.replaceAsciiSpanSlice(
                        cells,
                        &offset,
                        span,
                        span.text,
                        &first_changed,
                        &last_changed,
                        &has_references,
                        &nonblank,
                    );
                }
                const span = spans[range_end.span];
                try self.replaceAsciiSpanSlice(
                    cells,
                    &offset,
                    span,
                    span.text[0..range_end.byte],
                    &first_changed,
                    &last_changed,
                    &has_references,
                    &nonblank,
                );
            } else {
                var span_index = range_start.span;
                while (span_index < spans.len) : (span_index += 1) {
                    const span = spans[span_index];
                    const byte_start = if (span_index == range_start.span) range_start.byte else 0;
                    const byte_end = if (span_index == range_end.span) range_end.byte else span.text.len;
                    try self.replaceAsciiSpanSlice(
                        cells,
                        &offset,
                        span,
                        span.text[byte_start..byte_end],
                        &first_changed,
                        &last_changed,
                        &has_references,
                        &nonblank,
                    );
                    if (span_index == range_end.span) break;
                }
            }
        }
        if (marker_width != 0) {
            replaceStyledFill(
                self,
                cells,
                offset,
                offset + 1,
                .{ .glyph = 0x2026, .style = base_id, .width = if (marker_width == 1) .narrow else .wide },
                &first_changed,
                &last_changed,
            );
            offset += 1;
            if (marker_width == 2) {
                replaceStyledFill(
                    self,
                    cells,
                    offset,
                    offset + 1,
                    .{ .style = base_id, .width = .continuation },
                    &first_changed,
                    &last_changed,
                );
                offset += 1;
            }
        }
        std.debug.assert(offset <= count);
        replaceStyledFill(
            self,
            cells,
            offset,
            count,
            .{ .style = base_id },
            &first_changed,
            &last_changed,
        );

        self.finishAsciiStyledLine(origin, first_changed, last_changed, has_references, nonblank);
    }

    inline fn replaceAsciiSpanSlice(
        self: *Renderer,
        cells: []cell_module.Cell,
        offset: *u16,
        span: StyledSpan,
        text: []const u8,
        first_changed: *u16,
        last_changed: *u16,
        has_references: *bool,
        nonblank: *bool,
    ) !void {
        const style_id = try self.styles.intern(span.style);
        defer self.styles.release(style_id);
        replaceStyledAscii(self, cells, offset.*, text, style_id, first_changed, last_changed);
        offset.* += @intCast(text.len);
        if (style_id != 0) has_references.* = true;
        if (style_id != 0 or !allSpaces(text)) nonblank.* = true;
    }

    fn finishAsciiStyledLine(
        self: *Renderer,
        origin: geometry.Point,
        first_changed: u16,
        last_changed: u16,
        has_references: bool,
        nonblank: bool,
    ) void {
        if (first_changed == std.math.maxInt(u16)) return;
        self.frame_pending = true;
        self.pending_ascii.valid = false;
        self.uniform_fill_state.valid = false;
        self.damage.markSpan(origin.y, origin.x + first_changed, origin.x + last_changed);
        self.desired_uniform = null;
        if (has_references) self.rows[origin.y].desired_has_references = true;
        if (nonblank) self.rows[origin.y].desired_blank = false;
    }

    fn putAsciiField(
        self: *Renderer,
        comptime mode: AsciiFieldMode,
        origin: geometry.Point,
        text: []const u8,
        field_width: u16,
        text_offset: u16,
        marker_width: u2,
        style_id: style_module.Id,
    ) u16 {
        self.frame_pending = true;
        const record_pending_ascii = mode == .padded and self.damage.dirtyRowCount() == 0;
        self.pending_ascii.valid = false;
        self.uniform_fill_state.valid = false;
        self.materializeDesired();
        const available = self.terminal_size.width - origin.x;
        const count = @min(field_width, available);
        const text_count: u16 = if (mode == .padded)
            @intCast(@min(text.len, count))
        else
            @intCast(text.len);
        if (count == 0) return 0;
        self.invalidateAsciiLineRow(origin.y);
        std.debug.assert(mode == .padded or text_offset + text_count + marker_width <= count);
        const end_x = origin.x + count;
        if (origin.x > 0 and self.desired[self.index(origin.x, origin.y)].width == .continuation) {
            self.desired_uniform = null;
            self.assignDesired(origin.x - 1, origin.y, .{});
        }
        if (end_x < self.terminal_size.width and self.desired[self.index(end_x, origin.y)].width == .continuation) {
            self.desired_uniform = null;
            self.assignDesired(end_x, origin.y, .{});
        }

        const row_offset = self.rowOffset(origin.y);
        const row = &self.rows[origin.y];
        if (style_id == 0 and row.desired_blank) {
            const content_width = text_count + marker_width;
            if (content_width == 0) return 0;
            var offset: u16 = 0;
            while (offset < text_count) : (offset += 1) {
                const x = origin.x + text_offset + offset;
                const target = cell_module.Cell{ .glyph = text[offset] };
                self.desired[row_offset + x] = target;
            }
            if (mode == .line and marker_width != 0) {
                const marker_x = origin.x + text_offset + text_count;
                self.desired[row_offset + marker_x] = .{
                    .glyph = 0x2026,
                    .width = if (marker_width == 1) .narrow else .wide,
                };
                if (marker_width == 2) {
                    self.desired[row_offset + marker_x + 1] = .{ .width = .continuation };
                }
            }
            self.damage.markSpan(
                origin.y,
                origin.x + text_offset,
                origin.x + text_offset + content_width,
            );
            self.desired_uniform = null;
            row.desired_blank = false;
            if (mode == .padded and record_pending_ascii and text_count <= self.pending_ascii.bytes.len) {
                var changed: u8 = 0;
                for (text[0..text_count]) |byte| changed += @intFromBool(byte != ' ');
                @memcpy(self.pending_ascii.bytes[0..text_count], text[0..text_count]);
                self.pending_ascii.valid = true;
                self.pending_ascii.x = origin.x;
                self.pending_ascii.y = origin.y;
                self.pending_ascii.len = @intCast(text_count);
                self.pending_ascii.changed = changed;
            }
            return text_count;
        }
        var changed_cells: usize = 0;
        var changed_styles: usize = 0;
        var wrote_nonblank = false;
        var dirty_start: ?u16 = null;
        var offset: u16 = 0;
        while (offset < count) : (offset += 1) {
            const x = origin.x + offset;
            const index_value = row_offset + x;
            const target: cell_module.Cell = if (mode == .padded)
                .{
                    .glyph = if (offset < text_count) text[offset] else ' ',
                    .style = style_id,
                }
            else line: {
                if (offset >= text_offset and offset < text_offset + text_count) {
                    break :line .{ .glyph = text[offset - text_offset], .style = style_id };
                }
                const marker_offset = text_offset + text_count;
                if (marker_width != 0 and offset == marker_offset) {
                    break :line .{
                        .glyph = 0x2026,
                        .style = style_id,
                        .width = if (marker_width == 1) .narrow else .wide,
                    };
                }
                if (marker_width == 2 and offset == marker_offset + 1) {
                    break :line .{ .style = style_id, .width = .continuation };
                }
                break :line .{ .style = style_id };
            };
            const previous = self.desired[index_value];
            if (previous.eql(target)) {
                if (dirty_start) |first| {
                    self.damage.markSpan(origin.y, first, x);
                    dirty_start = null;
                }
                continue;
            }

            if (glyph_store.isComplex(previous.glyph)) self.glyphs.release(previous.glyph);
            if (previous.style != target.style) {
                if (previous.style != 0) self.styles.release(previous.style);
                changed_styles += 1;
            }
            self.desired[index_value] = target;
            if (target.glyph != ' ' or target.style != 0 or target.width != .narrow) wrote_nonblank = true;
            changed_cells += 1;
            if (dirty_start == null) dirty_start = x;
        }
        if (dirty_start) |first| {
            self.damage.markSpan(origin.y, first, end_x);
        }
        if (changed_cells != 0) {
            self.desired_uniform = null;
            if (style_id != 0) row.desired_has_references = true;
            if (wrote_nonblank) row.desired_blank = false;
        }
        self.styles.retainMany(style_id, changed_styles);
        return text_count;
    }

    fn materializeDesired(self: *Renderer) void {
        if (self.desired_materialized) return;
        self.invalidateAsciiLineRows(0, self.terminal_size.height);
        const uniform = self.desired_uniform orelse unreachable;
        const count = self.terminal_size.cellCount() catch unreachable;
        @memset(self.desired[0..count], uniform);
        const has_references = glyph_store.isComplex(uniform.glyph) or uniform.style != 0;
        const blank = uniform.eql(.{});
        for (self.rows[0..self.terminal_size.height], 0..) |*row, physical_row| {
            row.desired_has_references = has_references;
            row.desired_blank = blank;
            if (self.row_mapping_identity) row.physical_row = @intCast(physical_row);
        }
        self.desired_materialized = true;
    }

    fn materializePresented(self: *Renderer) void {
        if (self.presented_materialized) return;
        const uniform = self.presented_uniform orelse unreachable;
        const count = self.terminal_size.cellCount() catch unreachable;
        @memset(self.presented[0..count], uniform);
        const has_references = glyph_store.isComplex(uniform.glyph) or uniform.style != 0;
        for (self.rows[0..self.terminal_size.height], 0..) |*row, physical_row| {
            row.presented_has_references = has_references;
            if (self.row_mapping_identity) row.physical_row = @intCast(physical_row);
        }
        self.presented_materialized = true;
    }

    fn releaseGrid(
        self: *Renderer,
        uniform: ?cell_module.Cell,
        cells: []const cell_module.Cell,
        count: usize,
    ) void {
        if (uniform) |cell| {
            self.glyphs.releaseMany(cell.glyph, count);
            self.styles.releaseMany(cell.style, count);
            return;
        }
        for (cells[0..count]) |cell| {
            self.glyphs.release(cell.glyph);
            self.styles.release(cell.style);
        }
    }

    fn shapeText(
        self: *Renderer,
        text: []const u8,
        width_profile: grapheme.WidthProfile,
    ) !?[]const ShapedGlyph {
        for (&self.shaped_text_cache) |*entry| {
            if (entry.valid and entry.width_profile == width_profile and
                std.mem.eql(u8, entry.bytes[0..entry.byte_len], text))
            {
                return entry.glyphs[0..entry.glyph_count];
            }
        }
        const cache = &self.shaped_text_cache[self.shaped_text_cache_next];
        if (text.len > cache.bytes.len) return null;

        var iterator = try grapheme.Iterator.init(text);
        var shaped: [32]ShapedGlyph = undefined;
        var count: usize = 0;
        while (iterator.next()) |cluster| {
            if (count == shaped.len) return null;
            const cluster_width = try cluster.displayWidthAssumeValid(width_profile);
            if (cluster_width == 0) return error.ZeroWidthGrapheme;
            const start = @intFromPtr(cluster.bytes.ptr) - @intFromPtr(text.ptr);
            shaped[count] = .{
                .start = @intCast(start),
                .end = @intCast(start + cluster.bytes.len),
                .width = if (cluster_width == 1) .narrow else .wide,
            };
            count += 1;
        }

        @memcpy(cache.bytes[0..text.len], text);
        @memcpy(cache.glyphs[0..count], shaped[0..count]);
        cache.byte_len = @intCast(text.len);
        cache.glyph_count = @intCast(count);
        cache.width_profile = width_profile;
        cache.valid = true;
        self.shaped_text_cache_next +%= 1;
        return cache.glyphs[0..count];
    }

    fn cachedParagraphLayout(
        self: *Renderer,
        text: []const u8,
        line_width: u16,
        width_profile: grapheme.WidthProfile,
        requested_lines: u8,
    ) !?*const ParagraphLayoutCache {
        if (text.len > paragraph_cache_bytes) return null;
        var selected: ?*ParagraphLayoutCache = null;
        for (&self.paragraph_layout_cache) |*entry| {
            if (entry.valid and entry.byte_len == text.len and entry.line_width == line_width and
                entry.width_profile == width_profile and std.mem.eql(u8, entry.bytes[0..entry.byte_len], text))
            {
                if (entry.complete or entry.line_count >= requested_lines) return entry;
                selected = entry;
                break;
            }
        }

        const entry = selected orelse entry: {
            const next = &self.paragraph_layout_cache[self.paragraph_layout_cache_next];
            self.paragraph_layout_cache_next +%= 1;
            break :entry next;
        };
        entry.valid = false;
        entry.complete = false;
        var iterator = try text_wrap.Iterator.init(text, line_width, width_profile);
        entry.ascii = iterator.asciiOnly();
        entry.byte_len = @intCast(text.len);
        entry.line_count = 0;
        entry.line_width = line_width;
        entry.width_profile = width_profile;
        @memcpy(entry.bytes[0..text.len], text);
        while (entry.line_count < requested_lines) {
            const line = try iterator.next() orelse {
                entry.complete = true;
                break;
            };
            const line_index = entry.line_count;
            if (line.bytes.len != 0) {
                entry.lines[line_index].start = @intCast(@intFromPtr(line.bytes.ptr) - @intFromPtr(text.ptr));
                entry.lines[line_index].end = entry.lines[line_index].start + @as(u8, @intCast(line.bytes.len));
            } else {
                entry.lines[line_index].start = 0;
                entry.lines[line_index].end = 0;
            }
            entry.lines[line_index].width = line.width;
            entry.line_count += 1;
        }
        entry.valid = true;
        return entry;
    }

    fn assignDesired(self: *Renderer, x: u16, y: u16, next: cell_module.Cell) void {
        self.pending_ascii.valid = false;
        std.debug.assert(self.desired_materialized);
        const index_value = self.index(x, y);
        const previous = self.desired[index_value];
        if (previous.eql(next)) return;
        self.invalidateAsciiLineRow(y);
        self.frame_pending = true;
        self.uniform_fill_state.valid = false;

        if (next.glyph != previous.glyph) {
            if (glyph_store.isComplex(next.glyph)) self.glyphs.retain(next.glyph);
            if (glyph_store.isComplex(previous.glyph)) self.glyphs.release(previous.glyph);
        }
        if (next.style != previous.style) {
            if (next.style != 0) self.styles.retain(next.style);
            if (previous.style != 0) self.styles.release(previous.style);
        }
        self.desired[index_value] = next;

        const row = &self.rows[y];
        if (glyph_store.isComplex(next.glyph) or next.style != 0) row.desired_has_references = true;
        if (next.glyph != ' ' or next.style != 0 or next.width != .narrow) row.desired_blank = false;
        self.damage.markCell(x, y);
    }

    fn prepareAsciiLineCache(
        self: *Renderer,
        y: u16,
        x: u16,
        width: u16,
        content_start: u16,
        content_end: u16,
    ) ?damage_module.Span {
        if (y >= ascii_line_cache_rows) return null;
        const row = &self.ascii_line_cache[y];
        const end_x = x + width;
        var exact: ?usize = null;
        var replacement: usize = row.next;
        for (&row.entries, 0..) |*entry, index_value| {
            if (!entry.valid) {
                replacement = index_value;
                continue;
            }
            if (entry.x == x and entry.width == width) {
                if (exact == null) {
                    exact = index_value;
                } else {
                    entry.valid = false;
                }
                continue;
            }
            if (entry.x < end_x and x < entry.x + entry.width) entry.valid = false;
        }

        if (exact) |index_value| {
            const entry = &row.entries[index_value];
            const previous = damage_module.Span{
                .start = entry.content_start,
                .end = entry.content_end,
            };
            entry.content_start = content_start;
            entry.content_end = content_end;
            return previous;
        }

        row.entries[replacement] = .{
            .valid = true,
            .x = x,
            .width = width,
            .content_start = content_start,
            .content_end = content_end,
        };
        row.next = @intCast((replacement + 1) % ascii_line_cache_fields);
        return null;
    }

    inline fn invalidateAsciiLineRow(self: *Renderer, y: u16) void {
        if (y < ascii_line_cache_rows) self.ascii_line_cache[y] = .{};
    }

    fn invalidateAsciiLineRows(self: *Renderer, start: u16, end: u16) void {
        var y = start;
        const cache_end: u16 = @intCast(@min(end, ascii_line_cache_rows));
        while (y < cache_end) : (y += 1) self.ascii_line_cache[y] = .{};
    }

    fn index(self: *const Renderer, x: u16, y: u16) usize {
        return self.rowOffset(y) + x;
    }

    inline fn rowOffset(self: *const Renderer, y: u16) usize {
        const physical_row = if (self.row_mapping_identity) y else self.rows[y].physical_row;
        return @as(usize, physical_row) * self.terminal_size.width;
    }
};

fn emitImageFallback(encoder: *ansi.Encoder, command: ImageCommand) std.Io.Writer.Error!void {
    const pixel_rows = @as(usize, command.rect.height) * 2;
    var row: u16 = 0;
    while (row < command.rect.height) : (row += 1) {
        try encoder.moveTo(command.rect.y + row, command.rect.x);
        var column: u16 = 0;
        while (column < command.rect.width) : (column += 1) {
            const source_x: u32 = @intCast((@as(u128, column) * command.image.width) / command.rect.width);
            const top_y: u32 = @intCast((@as(u128, row) * 2 * command.image.height) / pixel_rows);
            const bottom_y: u32 = @intCast(@min(
                command.image.height - 1,
                (@as(u128, row) * 2 + 1) * command.image.height / pixel_rows,
            ));
            const top = image_module.colorAt(command.image, source_x, top_y, command.options.background);
            const bottom = image_module.colorAt(command.image, source_x, bottom_y, command.options.background);
            try encoder.setStyle(.{
                .foreground = .{ .rgb = .{ .r = top.red, .g = top.green, .b = top.blue } },
                .background = .{ .rgb = .{ .r = bottom.red, .g = bottom.green, .b = bottom.blue } },
            });
            try encoder.writeGlyph("\xE2\x96\x80", 1);
        }
    }
}

pub const Frame = struct {
    renderer: *Renderer,

    pub inline fn surface(self: *Frame, rect: geometry.Rect) Surface {
        return Surface.init(
            self.renderer,
            rect.x,
            rect.y,
            .{ .width = rect.width, .height = rect.height },
            geometry.Rect.fromSize(self.renderer.terminal_size),
        );
    }

    /// Records a native image. Pixel bytes must remain valid until `Renderer.present` succeeds.
    pub fn putImage(
        self: *Frame,
        rect: geometry.Rect,
        image: image_module.Image,
        options: ImageOptions,
    ) ImageError!void {
        try image_module.validate(image);
        if (rect.width == 0 or rect.height == 0 or rect.right() > self.renderer.terminal_size.width or
            rect.bottom() > self.renderer.terminal_size.height) return error.InvalidImageBounds;
        if (options.image_id == 0 or options.placement_id == 0) return error.InvalidIdentifier;
        if (self.renderer.desired_image_count == self.renderer.images.len) return error.ImageCapacityExceeded;
        self.renderer.images[self.renderer.desired_image_count] = .{
            .rect = rect,
            .image = image,
            .options = options,
        };
        self.renderer.desired_image_count += 1;
        self.renderer.image_frame_active = true;
        self.renderer.frame_pending = true;
    }

    pub fn putText(
        self: *Frame,
        origin: geometry.Point,
        text: []const u8,
        style: style_module.Style,
        width_profile: grapheme.WidthProfile,
    ) !u16 {
        return self.putTextUntil(origin, text, style, width_profile, self.renderer.terminal_size.width);
    }

    inline fn putTextUntil(
        self: *Frame,
        origin: geometry.Point,
        text: []const u8,
        style: style_module.Style,
        width_profile: grapheme.WidthProfile,
        end_x: u16,
    ) !u16 {
        std.debug.assert(end_x <= self.renderer.terminal_size.width);
        if (origin.x >= end_x or origin.y >= self.renderer.terminal_size.height) return 0;
        if (text.len == 1 and text[0] >= 0x20 and text[0] <= 0x7E and style.eql(.{})) {
            self.renderer.setAscii(origin.x, origin.y, text[0], 0);
            return 1;
        }
        if (printableAscii(text)) {
            const style_id = try self.renderer.styles.intern(style);
            defer self.renderer.styles.release(style_id);
            if (text.len >= 4) {
                return self.renderer.putAsciiPadded(
                    origin,
                    text,
                    @intCast(@min(text.len, end_x - origin.x)),
                    style_id,
                );
            }
            var x = origin.x;
            for (text) |byte| {
                if (x >= end_x) break;
                self.renderer.setAscii(x, origin.y, byte, style_id);
                x += 1;
            }
            return x - origin.x;
        }
        if (singleBrailleGlyph(text)) |glyph| {
            const style_id = try self.renderer.styles.intern(style);
            defer self.renderer.styles.release(style_id);
            self.renderer.setGlyph(origin.x, origin.y, glyph, style_id, .narrow);
            return 1;
        }

        return self.putUnicodeText(origin, text, style, width_profile, end_x);
    }

    fn putUnicodeText(
        self: *Frame,
        origin: geometry.Point,
        text: []const u8,
        style: style_module.Style,
        width_profile: grapheme.WidthProfile,
        end_x: u16,
    ) !u16 {
        const style_id = try self.renderer.styles.intern(style);
        defer self.renderer.styles.release(style_id);

        if (try self.renderer.shapeText(text, width_profile)) |shaped| {
            var x = origin.x;
            for (shaped) |entry| {
                if (x >= end_x) break;
                if (entry.width == .wide and x + 1 >= end_x) {
                    self.renderer.setGlyph(x, origin.y, ' ', style_id, .narrow);
                    x += 1;
                    break;
                }
                const glyph = try self.renderer.glyphs.intern(text[entry.start..entry.end]);
                self.renderer.setGlyph(x, origin.y, glyph, style_id, entry.width);
                self.renderer.glyphs.release(glyph);
                x += @intFromEnum(entry.width);
            }
            return x - origin.x;
        }

        var iterator = try grapheme.Iterator.init(text);
        var x = origin.x;
        while (iterator.next()) |cluster| {
            const cluster_width = try cluster.displayWidthAssumeValid(width_profile);
            if (cluster_width == 0) return error.ZeroWidthGrapheme;
            if (x >= end_x) break;

            if (cluster_width == 2 and x + 1 >= end_x) {
                self.renderer.setGlyph(x, origin.y, ' ', style_id, .narrow);
                x += 1;
                break;
            }

            const glyph = try self.renderer.glyphs.intern(cluster.bytes);
            defer self.renderer.glyphs.release(glyph);
            self.renderer.setGlyph(
                x,
                origin.y,
                glyph,
                style_id,
                if (cluster_width == 1) .narrow else .wide,
            );
            x += cluster_width;
        }
        return x - origin.x;
    }

    pub fn putTextPadded(
        self: *Frame,
        origin: geometry.Point,
        text: []const u8,
        field_width: u16,
        style: style_module.Style,
        width_profile: grapheme.WidthProfile,
    ) !u16 {
        return self.putTextPaddedUntil(
            origin,
            text,
            field_width,
            style,
            width_profile,
            self.renderer.terminal_size.width,
        );
    }

    inline fn putTextPaddedUntil(
        self: *Frame,
        origin: geometry.Point,
        text: []const u8,
        field_width: u16,
        style: style_module.Style,
        width_profile: grapheme.WidthProfile,
        end_x: u16,
    ) !u16 {
        std.debug.assert(end_x <= self.renderer.terminal_size.width);
        if (origin.x >= end_x or origin.y >= self.renderer.terminal_size.height) return 0;
        const available = @min(field_width, end_x - origin.x);
        if (printableAscii(text)) {
            const style_id = try self.renderer.styles.intern(style);
            defer self.renderer.styles.release(style_id);
            return self.renderer.putAsciiPadded(origin, text, available, style_id);
        }

        return self.putUnicodeTextPadded(origin, text, available, style, width_profile, end_x);
    }

    fn putUnicodeTextPadded(
        self: *Frame,
        origin: geometry.Point,
        text: []const u8,
        field_width: u16,
        style: style_module.Style,
        width_profile: grapheme.WidthProfile,
        end_x: u16,
    ) !u16 {
        const available = @min(field_width, end_x - origin.x);
        var iterator = try grapheme.Iterator.init(text);
        var used: u16 = 0;
        var byte_end: usize = 0;
        while (iterator.next()) |cluster| {
            const width = try cluster.displayWidthAssumeValid(width_profile);
            if (width == 0) return error.ZeroWidthGrapheme;
            if (used + width > available) break;
            used += width;
            byte_end = @intFromPtr(cluster.bytes.ptr) - @intFromPtr(text.ptr) + cluster.bytes.len;
        }
        try self.fill(.{ .x = origin.x, .y = origin.y, .width = available, .height = 1 }, style);
        _ = try self.putTextUntil(origin, text[0..byte_end], style, width_profile, end_x);
        return used;
    }

    pub fn fill(self: *Frame, rect: geometry.Rect, style: style_module.Style) !void {
        const clipped = rect.intersection(geometry.Rect.fromSize(self.renderer.terminal_size));
        if (clipped.isEmpty()) return;
        const style_id = try self.renderer.styles.intern(style);
        defer self.renderer.styles.release(style_id);

        const end_x: u16 = @intCast(clipped.right());
        const end_y: u16 = @intCast(clipped.bottom());
        if (clipped.x == 0 and end_x == self.renderer.terminal_size.width) {
            self.renderer.fillFullRows(clipped.y, end_y, style_id);
            return;
        }
        self.renderer.fillCellRect(clipped, .{ .style = style_id });
    }

    pub fn fillAscii(self: *Frame, rect: geometry.Rect, glyph: u8, style: style_module.Style) !void {
        if (glyph < 0x20 or glyph > 0x7E) return error.InvalidAsciiGlyph;
        const clipped = rect.intersection(geometry.Rect.fromSize(self.renderer.terminal_size));
        if (clipped.isEmpty()) return;
        const style_id = try self.renderer.styles.intern(style);
        defer self.renderer.styles.release(style_id);
        self.renderer.fillCellRect(clipped, .{ .glyph = glyph, .style = style_id });
    }
};

pub const Surface = struct {
    renderer: *Renderer,
    origin: geometry.Point,
    extent: geometry.Size,
    clip: geometry.Rect,

    fn init(
        renderer: *Renderer,
        origin_x: u32,
        origin_y: u32,
        extent: geometry.Size,
        parent_clip: geometry.Rect,
    ) Surface {
        return .{
            .renderer = renderer,
            .origin = .{
                .x = @intCast(@min(origin_x, std.math.maxInt(u16))),
                .y = @intCast(@min(origin_y, std.math.maxInt(u16))),
            },
            .extent = extent,
            .clip = clipTranslated(origin_x, origin_y, extent, parent_clip),
        };
    }

    pub inline fn size(self: *const Surface) geometry.Size {
        return self.extent;
    }

    pub inline fn surface(self: *const Surface, rect: geometry.Rect) Surface {
        return Surface.init(
            self.renderer,
            @as(u32, self.origin.x) + rect.x,
            @as(u32, self.origin.y) + rect.y,
            .{ .width = rect.width, .height = rect.height },
            self.clip,
        );
    }

    /// Records an unclipped image in surface-local coordinates.
    pub fn putImage(
        self: *Surface,
        rect: geometry.Rect,
        image: image_module.Image,
        options: ImageOptions,
    ) ImageError!void {
        if (rect.width == 0 or rect.height == 0 or rect.right() > self.extent.width or rect.bottom() > self.extent.height) {
            return error.InvalidImageBounds;
        }
        const x = @as(u32, self.origin.x) + rect.x;
        const y = @as(u32, self.origin.y) + rect.y;
        const right = x + rect.width;
        const bottom = y + rect.height;
        if (x < self.clip.x or y < self.clip.y or right > self.clip.right() or bottom > self.clip.bottom()) {
            return error.InvalidImageBounds;
        }
        var frame = Frame{ .renderer = self.renderer };
        try frame.putImage(.{
            .x = @intCast(x),
            .y = @intCast(y),
            .width = rect.width,
            .height = rect.height,
        }, image, options);
    }

    pub fn putText(
        self: *Surface,
        origin: geometry.Point,
        text: []const u8,
        style: style_module.Style,
        width_profile: grapheme.WidthProfile,
    ) !u16 {
        const placement = self.place(origin) orelse return 0;
        var frame = Frame{ .renderer = self.renderer };
        return frame.putTextUntil(placement.point, text, style, width_profile, placement.end_x);
    }

    pub fn putTextPadded(
        self: *Surface,
        origin: geometry.Point,
        text: []const u8,
        field_width: u16,
        style: style_module.Style,
        width_profile: grapheme.WidthProfile,
    ) !u16 {
        const placement = self.place(origin) orelse return 0;
        var frame = Frame{ .renderer = self.renderer };
        return frame.putTextPaddedUntil(
            placement.point,
            text,
            field_width,
            style,
            width_profile,
            placement.end_x,
        );
    }

    pub fn putTextLine(
        self: *Surface,
        origin: geometry.Point,
        text: []const u8,
        field_width: u16,
        style: style_module.Style,
        width_profile: grapheme.WidthProfile,
        options: line_layout.Options,
    ) !u16 {
        const placement = self.place(origin) orelse return 0;
        const available = @min(
            field_width,
            @min(self.extent.width - origin.x, placement.end_x - placement.point.x),
        );
        if (available == 0) return 0;
        const ascii_fits = text.len <= available and printableAscii(text);
        const line: line_layout.Layout = if (ascii_fits) line: {
            const width: u16 = @intCast(text.len);
            const remaining = available - width;
            break :line .{
                .prefix = text,
                .offset = switch (options.alignment) {
                    .left => 0,
                    .center => remaining / 2,
                    .right => remaining,
                },
                .width = width,
                .ellipsis = false,
            };
        } else try line_layout.layout(text, available, width_profile, options);
        if (ascii_fits or printableAscii(line.prefix)) {
            const style_id = try self.renderer.styles.intern(style);
            defer self.renderer.styles.release(style_id);
            self.renderer.putAsciiLine(
                placement.point,
                line.prefix,
                available,
                line.offset,
                if (line.ellipsis) @intCast(line_layout.ellipsisWidth(width_profile)) else 0,
                style_id,
            );
            return line.width;
        }

        try self.fill(.{ .x = origin.x, .y = origin.y, .width = available, .height = 1 }, style);

        var frame = Frame{ .renderer = self.renderer };
        const x = placement.point.x + line.offset;
        _ = try frame.putTextUntil(
            .{ .x = x, .y = placement.point.y },
            line.prefix,
            style,
            width_profile,
            placement.end_x,
        );
        if (line.ellipsis) {
            const marker_width = line_layout.ellipsisWidth(width_profile);
            _ = try frame.putTextUntil(
                .{ .x = x + line.width - marker_width, .y = placement.point.y },
                line_layout.ellipsis,
                style,
                width_profile,
                placement.end_x,
            );
        }
        return line.width;
    }

    pub fn putStyledLine(
        self: *Surface,
        origin: geometry.Point,
        spans: []const StyledSpan,
        field_width: u16,
        base_style: style_module.Style,
        width_profile: grapheme.WidthProfile,
        options: line_layout.Options,
    ) !u16 {
        const placement = self.place(origin) orelse return 0;
        const available = @min(
            field_width,
            @min(self.extent.width - origin.x, placement.end_x - placement.point.x),
        );
        if (available == 0) return 0;

        var total_width: usize = 0;
        var all_ascii = true;
        for (spans) |span| {
            total_width = std.math.add(
                usize,
                total_width,
                try line_layout.measure(span.text, width_profile),
            ) catch return error.WidthOverflow;
            all_ascii = all_ascii and printableAscii(span.text);
        }

        const truncated = total_width > available;
        const marker_width = line_layout.ellipsisWidth(width_profile);
        const append_ellipsis = truncated and options.overflow == .ellipsis and marker_width <= available;
        const content_limit = if (append_ellipsis) available - marker_width else available;
        var prefix_width: u16 = 0;
        var full_spans: usize = 0;
        var partial_span: ?usize = null;
        var partial_end: usize = 0;

        if (!truncated) {
            prefix_width = @intCast(total_width);
            full_spans = spans.len;
        } else {
            var remaining = content_limit;
            for (spans, 0..) |span, index| {
                const part_width: u16, const part_end: usize = if (all_ascii) part: {
                    const width: u16 = @intCast(@min(span.text.len, remaining));
                    break :part .{ width, width };
                } else part: {
                    const layout = try line_layout.layout(span.text, remaining, width_profile, .{});
                    break :part .{ layout.width, layout.prefix.len };
                };
                prefix_width += part_width;
                remaining -= part_width;
                if (part_end != span.text.len) {
                    partial_span = index;
                    partial_end = part_end;
                    break;
                }
                full_spans = index + 1;
                if (remaining == 0) break;
            }
        }

        const rendered_width = prefix_width + if (append_ellipsis) marker_width else 0;
        const offset = switch (options.alignment) {
            .left => 0,
            .center => (available - rendered_width) / 2,
            .right => available - rendered_width,
        };
        if (all_ascii) {
            const range_end: StyledPosition = if (partial_span) |span_index|
                .{ .span = span_index, .byte = partial_end }
            else if (full_spans != 0)
                .{ .span = full_spans - 1, .byte = spans[full_spans - 1].text.len }
            else
                .{};
            try self.renderer.putAsciiStyledRange(
                true,
                placement.point,
                spans,
                .{},
                range_end,
                available,
                offset,
                if (append_ellipsis) @intCast(marker_width) else 0,
                base_style,
            );
            return rendered_width;
        }
        try self.fill(.{ .x = origin.x, .y = origin.y, .width = available, .height = 1 }, base_style);

        var frame = Frame{ .renderer = self.renderer };
        var x = placement.point.x + offset;
        for (spans[0..full_spans]) |span| {
            x += try frame.putTextUntil(
                .{ .x = x, .y = placement.point.y },
                span.text,
                span.style,
                width_profile,
                placement.end_x,
            );
        }
        if (partial_span) |index| {
            const span = spans[index];
            x += try frame.putTextUntil(
                .{ .x = x, .y = placement.point.y },
                span.text[0..partial_end],
                span.style,
                width_profile,
                placement.end_x,
            );
        }
        if (append_ellipsis) {
            _ = try frame.putTextUntil(
                .{ .x = x, .y = placement.point.y },
                line_layout.ellipsis,
                base_style,
                width_profile,
                placement.end_x,
            );
        }
        return rendered_width;
    }

    pub fn putWrappedText(
        self: *Surface,
        rect: geometry.Rect,
        text: []const u8,
        style: style_module.Style,
        width_profile: grapheme.WidthProfile,
        alignment: line_layout.Alignment,
    ) !u16 {
        if (rect.width == 0 or rect.height == 0) return 0;
        var paragraph = self.surface(rect);
        if (paragraph.clip.isEmpty()) return 0;

        const visible_lines = @min(rect.height, paragraph.clip.height);
        var y: u16 = 0;
        const cached_layout = if (visible_lines <= paragraph_cache_lines)
            try self.renderer.cachedParagraphLayout(text, rect.width, width_profile, @intCast(visible_lines))
        else
            null;
        if (cached_layout) |layout| {
            const direct_ascii = layout.ascii and paragraph.clip.width == rect.width;
            const style_id = if (direct_ascii) try self.renderer.styles.intern(style) else 0;
            defer if (direct_ascii) self.renderer.styles.release(style_id);
            while (y < visible_lines and y < layout.line_count) : (y += 1) {
                const line = layout.lines[y];
                try paragraph.putMeasuredWrappedLine(
                    y,
                    text[line.start..line.end],
                    line.width,
                    rect.width,
                    style,
                    width_profile,
                    alignment,
                    direct_ascii,
                    style_id,
                );
            }
        } else {
            var lines = try text_wrap.Iterator.init(text, rect.width, width_profile);
            const direct_ascii = lines.asciiOnly() and paragraph.clip.width == rect.width;
            const style_id = if (direct_ascii) try self.renderer.styles.intern(style) else 0;
            defer if (direct_ascii) self.renderer.styles.release(style_id);
            while (y < visible_lines) : (y += 1) {
                const line = try lines.next() orelse break;
                try paragraph.putMeasuredWrappedLine(
                    y,
                    line.bytes,
                    line.width,
                    rect.width,
                    style,
                    width_profile,
                    alignment,
                    direct_ascii,
                    style_id,
                );
            }
        }
        if (y < visible_lines) {
            var needs_clear = !style.eql(.{});
            var clear_y = y;
            while (!needs_clear and clear_y < visible_lines) : (clear_y += 1) {
                needs_clear = !self.renderer.rows[paragraph.origin.y + clear_y].desired_blank;
            }
            if (needs_clear) {
                try paragraph.fill(.{
                    .x = 0,
                    .y = y,
                    .width = rect.width,
                    .height = visible_lines - y,
                }, style);
            }
        }
        return y;
    }

    pub fn putWrappedStyledText(
        self: *Surface,
        rect: geometry.Rect,
        spans: []const StyledSpan,
        base_style: style_module.Style,
        width_profile: grapheme.WidthProfile,
        alignment: line_layout.Alignment,
    ) !u16 {
        if (rect.width == 0 or rect.height == 0) return 0;
        var paragraph = self.surface(rect);
        if (paragraph.clip.isEmpty()) return 0;

        var lines = try StyledWrapIterator.init(spans, rect.width, width_profile);
        const visible_lines = @min(rect.height, paragraph.clip.height);
        const direct_ascii = lines.ascii and paragraph.clip.width == rect.width;
        var y: u16 = 0;
        while (y < visible_lines) : (y += 1) {
            const line = try lines.next() orelse break;
            const offset = switch (alignment) {
                .left => 0,
                .center => (rect.width - line.width) / 2,
                .right => rect.width - line.width,
            };
            if (direct_ascii) {
                const placement = paragraph.place(.{ .x = 0, .y = y }).?;
                try self.renderer.putAsciiStyledRange(
                    false,
                    placement.point,
                    spans,
                    line.start,
                    line.end,
                    rect.width,
                    offset,
                    0,
                    base_style,
                );
            } else {
                try paragraph.fill(.{ .x = 0, .y = y, .width = rect.width, .height = 1 }, base_style);
                try paragraph.putStyledRange(
                    y,
                    offset,
                    spans,
                    line.start,
                    line.end,
                    width_profile,
                );
            }
        }
        if (y < visible_lines) {
            var needs_clear = !base_style.eql(.{});
            var clear_y = y;
            while (!needs_clear and clear_y < visible_lines) : (clear_y += 1) {
                needs_clear = !self.renderer.rows[paragraph.origin.y + clear_y].desired_blank;
            }
            if (needs_clear) {
                try paragraph.fill(.{
                    .x = 0,
                    .y = y,
                    .width = rect.width,
                    .height = visible_lines - y,
                }, base_style);
            }
        }
        return y;
    }

    fn putStyledRange(
        self: *Surface,
        y: u16,
        x_offset: u16,
        spans: []const StyledSpan,
        start: StyledPosition,
        end: StyledPosition,
        width_profile: grapheme.WidthProfile,
    ) !void {
        if (styledPositionEql(start, end)) return;
        const placement = self.place(.{ .x = x_offset, .y = y }) orelse return;
        var frame = Frame{ .renderer = self.renderer };
        var x = placement.point.x;
        var span_index = start.span;
        while (span_index < spans.len) : (span_index += 1) {
            const span = spans[span_index];
            const byte_start = if (span_index == start.span) start.byte else 0;
            const byte_end = if (span_index == end.span) end.byte else span.text.len;
            if (byte_start < byte_end) {
                x += try frame.putTextUntil(
                    .{ .x = x, .y = placement.point.y },
                    span.text[byte_start..byte_end],
                    span.style,
                    width_profile,
                    placement.end_x,
                );
            }
            if (span_index == end.span) break;
        }
    }

    inline fn putMeasuredWrappedLine(
        self: *Surface,
        y: u16,
        text: []const u8,
        text_width: u16,
        field_width: u16,
        style: style_module.Style,
        width_profile: grapheme.WidthProfile,
        alignment: line_layout.Alignment,
        direct_ascii: bool,
        style_id: style_module.Id,
    ) !void {
        if (direct_ascii) {
            const offset = switch (alignment) {
                .left => 0,
                .center => (field_width - text_width) / 2,
                .right => field_width - text_width,
            };
            const placement = self.place(.{ .x = 0, .y = y }).?;
            self.renderer.putAsciiLine(placement.point, text, field_width, offset, 0, style_id);
            return;
        }
        _ = try self.putTextLine(
            .{ .x = 0, .y = y },
            text,
            field_width,
            style,
            width_profile,
            .{ .alignment = alignment },
        );
    }

    pub fn fill(self: *Surface, rect: geometry.Rect, style: style_module.Style) !void {
        const local = rect.intersection(geometry.Rect.fromSize(self.extent));
        if (local.isEmpty()) return;
        const clipped = clipTranslated(
            @as(u32, self.origin.x) + local.x,
            @as(u32, self.origin.y) + local.y,
            .{ .width = local.width, .height = local.height },
            self.clip,
        );
        if (clipped.isEmpty()) return;
        var frame = Frame{ .renderer = self.renderer };
        try frame.fill(clipped, style);
    }

    pub fn fillAscii(self: *Surface, rect: geometry.Rect, glyph: u8, style: style_module.Style) !void {
        if (glyph < 0x20 or glyph > 0x7E) return error.InvalidAsciiGlyph;
        const local = rect.intersection(geometry.Rect.fromSize(self.extent));
        if (local.isEmpty()) return;
        const clipped = clipTranslated(
            @as(u32, self.origin.x) + local.x,
            @as(u32, self.origin.y) + local.y,
            .{ .width = local.width, .height = local.height },
            self.clip,
        );
        if (clipped.isEmpty()) return;
        var frame = Frame{ .renderer = self.renderer };
        try frame.fillAscii(clipped, glyph, style);
    }

    pub fn fillAsciiBatch(self: *Surface, fills: []const AsciiFill, style: style_module.Style) !void {
        for (fills) |entry| {
            if (entry.glyph < 0x20 or entry.glyph > 0x7E) return error.InvalidAsciiGlyph;
        }

        var style_id: ?style_module.Id = null;
        defer if (style_id) |id| self.renderer.styles.release(id);
        for (fills) |entry| {
            const local = entry.rect.intersection(geometry.Rect.fromSize(self.extent));
            if (local.isEmpty()) continue;
            const clipped = clipTranslated(
                @as(u32, self.origin.x) + local.x,
                @as(u32, self.origin.y) + local.y,
                .{ .width = local.width, .height = local.height },
                self.clip,
            );
            if (clipped.isEmpty()) continue;
            const id = style_id orelse id: {
                const interned = try self.renderer.styles.intern(style);
                style_id = interned;
                break :id interned;
            };
            self.renderer.fillCellRect(clipped, .{ .glyph = entry.glyph, .style = id });
        }
    }

    const Placement = struct {
        point: geometry.Point,
        end_x: u16,
    };

    inline fn place(self: *const Surface, point: geometry.Point) ?Placement {
        if (point.x >= self.extent.width or point.y >= self.extent.height or self.clip.isEmpty()) return null;
        const x = @as(u32, self.origin.x) + point.x;
        const y = @as(u32, self.origin.y) + point.y;
        if (x < self.clip.x or x >= self.clip.right() or y < self.clip.y or y >= self.clip.bottom()) return null;
        return .{
            .point = .{ .x = @intCast(x), .y = @intCast(y) },
            .end_x = @intCast(self.clip.right()),
        };
    }
};

fn clipTranslated(
    origin_x: u32,
    origin_y: u32,
    extent: geometry.Size,
    parent_clip: geometry.Rect,
) geometry.Rect {
    if (parent_clip.isEmpty()) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    const right = @min(origin_x + extent.width, parent_clip.right());
    const bottom = @min(origin_y + extent.height, parent_clip.bottom());
    const x = @max(origin_x, parent_clip.x);
    const y = @max(origin_y, parent_clip.y);
    if (x >= right or y >= bottom) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    return .{
        .x = @intCast(x),
        .y = @intCast(y),
        .width = @intCast(right - x),
        .height = @intCast(bottom - y),
    };
}

fn printableAscii(text: []const u8) bool {
    for (text) |byte| {
        if (byte < 0x20 or byte > 0x7E) return false;
    }
    return true;
}

inline fn singleBrailleGlyph(text: []const u8) ?glyph_store.Glyph {
    if (text.len != 3 or text[0] != 0xe2 or text[1] < 0xa0 or text[1] > 0xa3 or
        text[2] < 0x80 or text[2] > 0xbf) return null;
    return 0x2800 + (@as(glyph_store.Glyph, text[1] - 0xa0) << 6) + (text[2] - 0x80);
}

inline fn replaceUnstyledLineCell(
    cells: []cell_module.Cell,
    offset: u16,
    glyph: glyph_store.Glyph,
    width: cell_module.Width,
    first_changed: *u16,
    last_changed: *u16,
) void {
    if (cells[offset].glyph == glyph and cells[offset].width == width) return;
    cells[offset] = .{ .glyph = glyph, .width = width };
    if (first_changed.* == std.math.maxInt(u16)) first_changed.* = offset;
    last_changed.* = offset + 1;
}

fn replaceStyledFill(
    renderer: *Renderer,
    cells: []cell_module.Cell,
    start: u16,
    end: u16,
    target: cell_module.Cell,
    first_changed: *u16,
    last_changed: *u16,
) void {
    var changed_styles: usize = 0;
    var offset = start;
    while (offset < end) : (offset += 1) {
        const previous = cells[offset];
        if (previous.eql(target)) continue;
        if (glyph_store.isComplex(previous.glyph)) renderer.glyphs.release(previous.glyph);
        if (previous.style != target.style) {
            if (previous.style != 0) renderer.styles.release(previous.style);
            changed_styles += 1;
        }
        cells[offset] = target;
        if (first_changed.* == std.math.maxInt(u16)) first_changed.* = offset;
        last_changed.* = offset + 1;
    }
    renderer.styles.retainMany(target.style, changed_styles);
}

fn replaceStyledAscii(
    renderer: *Renderer,
    cells: []cell_module.Cell,
    start: u16,
    text: []const u8,
    style_id: style_module.Id,
    first_changed: *u16,
    last_changed: *u16,
) void {
    var changed_styles: usize = 0;
    for (text, 0..) |byte, text_index| {
        const offset = start + @as(u16, @intCast(text_index));
        const target = cell_module.Cell{ .glyph = byte, .style = style_id };
        const previous = cells[offset];
        if (previous.eql(target)) continue;
        if (glyph_store.isComplex(previous.glyph)) renderer.glyphs.release(previous.glyph);
        if (previous.style != style_id) {
            if (previous.style != 0) renderer.styles.release(previous.style);
            changed_styles += 1;
        }
        cells[offset] = target;
        if (first_changed.* == std.math.maxInt(u16)) first_changed.* = offset;
        last_changed.* = offset + 1;
    }
    renderer.styles.retainMany(style_id, changed_styles);
}

fn allSpaces(text: []const u8) bool {
    for (text) |byte| {
        if (byte != ' ') return false;
    }
    return true;
}

fn terminalStateEql(lhs: ansi.State, rhs: ansi.State) bool {
    if (lhs.cursor_known != rhs.cursor_known or lhs.style_known != rhs.style_known) return false;
    if (lhs.cursor_known and (lhs.row != rhs.row or lhs.column != rhs.column)) return false;
    return !lhs.style_known or lhs.color_depth == rhs.color_depth and lhs.style.eql(rhs.style);
}

fn rectEql(lhs: geometry.Rect, rhs: geometry.Rect) bool {
    return lhs.x == rhs.x and lhs.y == rhs.y and lhs.width == rhs.width and lhs.height == rhs.height;
}

fn uniformFillTransitionEql(lhs: UniformFillState, rhs: UniformFillState) bool {
    return rhs.valid and rhs.transition_valid and rectEql(lhs.rect, rhs.rect) and
        lhs.previous.eql(rhs.previous) and lhs.cell.eql(rhs.cell);
}

test "nested surfaces translate and clip without allocating" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var renderer = try Renderer.init(failing.allocator(), .{ .width = 8, .height = 4 }, .{});
    defer renderer.deinit();
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    var frame = renderer.frame();
    var parent = frame.surface(.{ .x = 2, .y = 1, .width = 4, .height = 2 });
    var child = parent.surface(.{ .x = 1, .y = 0, .width = 4, .height = 2 });
    try std.testing.expectEqual(geometry.Size{ .width = 4, .height = 2 }, child.size());

    try std.testing.expectEqual(@as(u16, 3), try child.putText(.{ .x = 0, .y = 0 }, "ABCDE", .{}, .narrow));
    try std.testing.expectEqual(@as(glyph_store.Glyph, 'A'), renderer.desiredCell(.{ .x = 3, .y = 1 }).?.glyph);
    try std.testing.expectEqual(@as(glyph_store.Glyph, 'B'), renderer.desiredCell(.{ .x = 4, .y = 1 }).?.glyph);
    try std.testing.expectEqual(@as(glyph_store.Glyph, 'C'), renderer.desiredCell(.{ .x = 5, .y = 1 }).?.glyph);
    try std.testing.expect(renderer.desiredCell(.{ .x = 6, .y = 1 }).?.eql(.{}));

    try child.fill(.{ .x = 0, .y = 1, .width = 4, .height = 1 }, .{ .background = .{ .indexed = 1 } });
    try std.testing.expect(renderer.desiredCell(.{ .x = 3, .y = 2 }).?.style != 0);
    try std.testing.expect(renderer.desiredCell(.{ .x = 5, .y = 2 }).?.style != 0);
    try std.testing.expect(renderer.desiredCell(.{ .x = 6, .y = 2 }).?.eql(.{}));

    try std.testing.expectEqual(
        @as(u16, 1),
        try child.putTextPadded(.{ .x = 0, .y = 0 }, "Z", 4, .{}, .narrow),
    );
    try std.testing.expectEqual(@as(glyph_store.Glyph, 'Z'), renderer.desiredCell(.{ .x = 3, .y = 1 }).?.glyph);
    try std.testing.expect(renderer.desiredCell(.{ .x = 4, .y = 1 }).?.eql(.{}));
    try std.testing.expect(renderer.desiredCell(.{ .x = 5, .y = 1 }).?.eql(.{}));

    var edge = frame.surface(.{ .x = 7, .y = 0, .width = 1, .height = 1 });
    try std.testing.expectEqual(@as(u16, 1), try edge.putText(.{ .x = 0, .y = 0 }, "\xE7\x95\x8C", .{}, .narrow));
    try std.testing.expect(renderer.desiredCell(.{ .x = 7, .y = 0 }).?.eql(.{}));
    try std.testing.expect(!failing.has_induced_failure);
}

test "surface text lines align safely without allocating" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var renderer = try Renderer.init(failing.allocator(), .{ .width = 12, .height = 1 }, .{});
    defer renderer.deinit();

    var frame = renderer.frame();
    _ = try frame.putText(.{ .x = 2, .y = 0 }, "XXXXXXXX", .{}, .narrow);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    var surface = frame.surface(.{ .x = 2, .y = 0, .width = 8, .height = 1 });
    try std.testing.expectEqual(
        @as(u16, 3),
        try surface.putTextLine(.{ .x = 0, .y = 0 }, "abc", 8, .{}, .narrow, .{ .alignment = .center }),
    );
    try std.testing.expect(renderer.desiredCell(.{ .x = 2, .y = 0 }).?.eql(.{}));
    try std.testing.expect(renderer.desiredCell(.{ .x = 3, .y = 0 }).?.eql(.{}));
    try std.testing.expectEqual(@as(glyph_store.Glyph, 'a'), renderer.desiredCell(.{ .x = 4, .y = 0 }).?.glyph);
    try std.testing.expectEqual(@as(glyph_store.Glyph, 'c'), renderer.desiredCell(.{ .x = 6, .y = 0 }).?.glyph);
    try std.testing.expect(renderer.desiredCell(.{ .x = 9, .y = 0 }).?.eql(.{}));

    try std.testing.expectError(
        error.ControlCharacter,
        surface.putTextLine(.{ .x = 0, .y = 0 }, "unsafe\x1b[31m", 8, .{}, .narrow, .{}),
    );
    try std.testing.expectEqual(@as(glyph_store.Glyph, 'a'), renderer.desiredCell(.{ .x = 4, .y = 0 }).?.glyph);

    try std.testing.expectEqual(
        @as(u16, 4),
        try surface.putTextLine(.{ .x = 0, .y = 0 }, "abcdef", 4, .{}, .narrow, .{ .overflow = .ellipsis }),
    );
    try std.testing.expectEqual(@as(glyph_store.Glyph, 'a'), renderer.desiredCell(.{ .x = 2, .y = 0 }).?.glyph);
    try std.testing.expectEqual(@as(glyph_store.Glyph, 'c'), renderer.desiredCell(.{ .x = 4, .y = 0 }).?.glyph);
    try std.testing.expectEqual(@as(glyph_store.Glyph, 0x2026), renderer.desiredCell(.{ .x = 5, .y = 0 }).?.glyph);

    try std.testing.expectEqual(
        @as(u16, 2),
        try surface.putTextLine(.{ .x = 0, .y = 0 }, "abcdef", 2, .{}, .wide_ambiguous, .{ .overflow = .ellipsis }),
    );
    try std.testing.expectEqual(cell_module.Width.wide, renderer.desiredCell(.{ .x = 2, .y = 0 }).?.width);
    try std.testing.expectEqual(cell_module.Width.continuation, renderer.desiredCell(.{ .x = 3, .y = 0 }).?.width);

    _ = try frame.putText(.{ .x = 9, .y = 0 }, "Z", .{}, .narrow);
    _ = try surface.putTextLine(.{ .x = 0, .y = 0 }, "a", 8, .{}, .narrow, .{});
    try std.testing.expectEqual(@as(glyph_store.Glyph, 'a'), renderer.desiredCell(.{ .x = 2, .y = 0 }).?.glyph);
    try std.testing.expect(renderer.desiredCell(.{ .x = 9, .y = 0 }).?.eql(.{}));
    try std.testing.expect(!failing.has_induced_failure);
}

test "styled lines preserve styles and reject unsafe spans before mutation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var renderer = try Renderer.init(failing.allocator(), .{ .width = 12, .height = 1 }, .{});
    defer renderer.deinit();
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    const red = style_module.Style{ .foreground = .{ .indexed = 1 } };
    const blue = style_module.Style{ .foreground = .{ .indexed = 2 } };
    const green = style_module.Style{ .foreground = .{ .indexed = 3 } };
    const spans = [_]StyledSpan{
        .{ .text = "ab", .style = red },
        .{ .text = "\xE7\x95\x8Cc", .style = blue },
        .{ .text = "def", .style = green },
    };

    var frame = renderer.frame();
    var surface = frame.surface(.{ .x = 2, .y = 0, .width = 7, .height = 1 });
    try std.testing.expectEqual(
        @as(u16, 7),
        try surface.putStyledLine(
            .{ .x = 0, .y = 0 },
            &spans,
            7,
            .{},
            .narrow,
            .{ .overflow = .ellipsis },
        ),
    );
    const red_id = renderer.desiredCell(.{ .x = 2, .y = 0 }).?.style;
    const blue_id = renderer.desiredCell(.{ .x = 4, .y = 0 }).?.style;
    const green_id = renderer.desiredCell(.{ .x = 7, .y = 0 }).?.style;
    try std.testing.expect(red_id != 0 and blue_id != 0 and green_id != 0);
    try std.testing.expect(red_id != blue_id and blue_id != green_id and red_id != green_id);
    try std.testing.expectEqual(cell_module.Width.wide, renderer.desiredCell(.{ .x = 4, .y = 0 }).?.width);
    try std.testing.expectEqual(cell_module.Width.continuation, renderer.desiredCell(.{ .x = 5, .y = 0 }).?.width);
    try std.testing.expectEqual(@as(glyph_store.Glyph, 0x2026), renderer.desiredCell(.{ .x = 8, .y = 0 }).?.glyph);
    try std.testing.expectEqual(@as(style_module.Id, 0), renderer.desiredCell(.{ .x = 8, .y = 0 }).?.style);

    const unsafe = [_]StyledSpan{
        .{ .text = "safe", .style = red },
        .{ .text = "\x1b[31m", .style = blue },
    };
    try std.testing.expectError(
        error.ControlCharacter,
        surface.putStyledLine(.{ .x = 0, .y = 0 }, &unsafe, 7, .{}, .narrow, .{}),
    );
    try std.testing.expectEqual(red_id, renderer.desiredCell(.{ .x = 2, .y = 0 }).?.style);

    const short = [_]StyledSpan{.{ .text = "ok", .style = red }};
    try std.testing.expectEqual(
        @as(u16, 2),
        try surface.putStyledLine(.{ .x = 0, .y = 0 }, &short, 7, .{}, .narrow, .{ .alignment = .right }),
    );
    try std.testing.expect(renderer.desiredCell(.{ .x = 2, .y = 0 }).?.eql(.{}));
    try std.testing.expectEqual(@as(glyph_store.Glyph, 'o'), renderer.desiredCell(.{ .x = 7, .y = 0 }).?.glyph);
    try std.testing.expect(!failing.has_induced_failure);
}

test "styled line capacity failure preserves partial frame invariants" {
    var renderer = try Renderer.init(
        std.testing.allocator,
        .{ .width = 6, .height = 1 },
        .{ .style_capacity = 3 },
    );
    defer renderer.deinit();

    const spans = [_]StyledSpan{
        .{ .text = "a", .style = .{ .foreground = .{ .indexed = 1 } } },
        .{ .text = "b", .style = .{ .foreground = .{ .indexed = 2 } } },
        .{ .text = "c", .style = .{ .foreground = .{ .indexed = 3 } } },
    };
    var frame = renderer.frame();
    var surface = frame.surface(.{ .x = 0, .y = 0, .width = 6, .height = 1 });
    try std.testing.expectError(
        error.StyleCapacityExceeded,
        surface.putStyledLine(.{ .x = 0, .y = 0 }, &spans, 6, .{}, .narrow, .{}),
    );
    try std.testing.expectEqual(@as(usize, 1), renderer.damage.dirtyRowCount());

    var output_buffer: [256]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const stats = try renderer.present(&output, .{});
    try std.testing.expectEqual(@as(u32, 2), stats.cells_changed);
}

test "wrapped styled text preserves styles across line boundaries" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var renderer = try Renderer.init(failing.allocator(), .{ .width = 12, .height = 3 }, .{});
    defer renderer.deinit();

    var frame = renderer.frame();
    _ = try frame.putText(.{ .x = 2, .y = 0 }, "XXXXXXXX", .{}, .narrow);
    _ = try frame.putText(.{ .x = 2, .y = 1 }, "XXXXXXXX", .{}, .narrow);
    _ = try frame.putText(.{ .x = 2, .y = 2 }, "XXXXXXXX", .{}, .narrow);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    const red = style_module.Style{ .foreground = .{ .indexed = 1 } };
    const blue = style_module.Style{ .foreground = .{ .indexed = 2 } };
    const spans = [_]StyledSpan{
        .{ .text = "one ", .style = red },
        .{ .text = "two three", .style = blue },
    };
    var surface = frame.surface(.{ .x = 2, .y = 0, .width = 8, .height = 3 });
    try std.testing.expectEqual(
        @as(u16, 2),
        try surface.putWrappedStyledText(
            .{ .x = 0, .y = 0, .width = 7, .height = 3 },
            &spans,
            .{},
            .narrow,
            .center,
        ),
    );
    const red_id = renderer.desiredCell(.{ .x = 2, .y = 0 }).?.style;
    const blue_id = renderer.desiredCell(.{ .x = 6, .y = 0 }).?.style;
    try std.testing.expect(red_id != 0 and blue_id != 0 and red_id != blue_id);
    try std.testing.expectEqual(@as(glyph_store.Glyph, 't'), renderer.desiredCell(.{ .x = 6, .y = 0 }).?.glyph);
    try std.testing.expectEqual(@as(glyph_store.Glyph, 't'), renderer.desiredCell(.{ .x = 3, .y = 1 }).?.glyph);
    try std.testing.expectEqual(blue_id, renderer.desiredCell(.{ .x = 3, .y = 1 }).?.style);
    try std.testing.expect(renderer.desiredCell(.{ .x = 2, .y = 2 }).?.eql(.{}));

    const unsafe = [_]StyledSpan{
        .{ .text = "safe", .style = red },
        .{ .text = "\x1b[31m", .style = blue },
    };
    try std.testing.expectError(
        error.ControlCharacter,
        surface.putWrappedStyledText(
            .{ .x = 0, .y = 0, .width = 7, .height = 3 },
            &unsafe,
            .{},
            .narrow,
            .left,
        ),
    );
    try std.testing.expectEqual(red_id, renderer.desiredCell(.{ .x = 2, .y = 0 }).?.style);

    const explicit_break = [_]StyledSpan{
        .{ .text = "a\n", .style = red },
        .{ .text = "b", .style = blue },
    };
    try std.testing.expectEqual(
        @as(u16, 2),
        try surface.putWrappedStyledText(
            .{ .x = 0, .y = 0, .width = 7, .height = 3 },
            &explicit_break,
            .{},
            .narrow,
            .left,
        ),
    );
    try std.testing.expectEqual(@as(glyph_store.Glyph, 'a'), renderer.desiredCell(.{ .x = 2, .y = 0 }).?.glyph);
    try std.testing.expectEqual(@as(glyph_store.Glyph, 'b'), renderer.desiredCell(.{ .x = 2, .y = 1 }).?.glyph);

    const unicode = [_]StyledSpan{
        .{ .text = "A", .style = red },
        .{ .text = "\xE7\x95\x8CB", .style = blue },
    };
    var unicode_surface = frame.surface(.{ .x = 10, .y = 0, .width = 2, .height = 3 });
    try std.testing.expectEqual(
        @as(u16, 3),
        try unicode_surface.putWrappedStyledText(
            .{ .x = 0, .y = 0, .width = 2, .height = 3 },
            &unicode,
            .{},
            .narrow,
            .left,
        ),
    );
    try std.testing.expectEqual(@as(glyph_store.Glyph, 'A'), renderer.desiredCell(.{ .x = 10, .y = 0 }).?.glyph);
    try std.testing.expectEqual(cell_module.Width.wide, renderer.desiredCell(.{ .x = 10, .y = 1 }).?.width);
    try std.testing.expectEqual(cell_module.Width.continuation, renderer.desiredCell(.{ .x = 11, .y = 1 }).?.width);
    try std.testing.expectEqual(@as(glyph_store.Glyph, 'B'), renderer.desiredCell(.{ .x = 10, .y = 2 }).?.glyph);

    const hyphenated = [_]StyledSpan{
        .{ .text = "ab-", .style = red },
        .{ .text = "cdef", .style = blue },
    };
    try std.testing.expectEqual(
        @as(u16, 2),
        try surface.putWrappedStyledText(
            .{ .x = 0, .y = 0, .width = 5, .height = 2 },
            &hyphenated,
            .{},
            .narrow,
            .left,
        ),
    );
    try std.testing.expectEqual(@as(glyph_store.Glyph, '-'), renderer.desiredCell(.{ .x = 4, .y = 0 }).?.glyph);
    try std.testing.expect(renderer.desiredCell(.{ .x = 5, .y = 0 }).?.eql(.{}));
    try std.testing.expectEqual(@as(glyph_store.Glyph, 'c'), renderer.desiredCell(.{ .x = 2, .y = 1 }).?.glyph);

    const split_grapheme = [_]StyledSpan{
        .{ .text = "e", .style = red },
        .{ .text = "\xCC\x81", .style = blue },
    };
    try std.testing.expectError(
        error.ZeroWidthGrapheme,
        surface.putWrappedStyledText(
            .{ .x = 0, .y = 0, .width = 7, .height = 3 },
            &split_grapheme,
            .{},
            .narrow,
            .left,
        ),
    );
    var oversized: [grapheme.max_cluster_bytes + 1]u8 = undefined;
    oversized[0] = 'a';
    var oversized_index: usize = 1;
    while (oversized_index < oversized.len) : (oversized_index += 2) {
        oversized[oversized_index] = 0xCC;
        oversized[oversized_index + 1] = 0x81;
    }
    const oversized_span = [1]StyledSpan{.{ .text = &oversized, .style = red }};
    try std.testing.expectError(
        error.GraphemeTooLong,
        surface.putWrappedStyledText(
            .{ .x = 0, .y = 0, .width = 7, .height = 3 },
            &oversized_span,
            .{},
            .narrow,
            .left,
        ),
    );
    try std.testing.expect(!failing.has_induced_failure);
}

test "simple styled wrapping matches the general classifier" {
    const spans = [_]StyledSpan{
        .{ .text = "alpha  ", .style = .{ .foreground = .{ .indexed = 1 } } },
        .{ .text = "beta 123abc", .style = .{} },
        .{ .text = " # heading key==value", .style = .{} },
        .{ .text = "\r\n ", .style = .{ .attributes = .{ .bold = true } } },
        .{ .text = "averylongword end", .style = .{} },
    };
    for (1..13) |raw_width| {
        const width: u16 = @intCast(raw_width);
        var fast = try StyledWrapIterator.init(&spans, width, .narrow);
        var general = fast;
        general.simple_ascii = false;
        while (true) {
            const fast_line = try fast.next();
            const general_line = try general.next();
            try std.testing.expectEqual(fast_line == null, general_line == null);
            if (fast_line == null) break;
            try std.testing.expect(std.meta.eql(general_line.?, fast_line.?));
        }
    }
}

test "wrapped surface text clips, aligns, and clears safely without allocating" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var renderer = try Renderer.init(failing.allocator(), .{ .width = 12, .height = 4 }, .{});
    defer renderer.deinit();

    var frame = renderer.frame();
    _ = try frame.putText(.{ .x = 2, .y = 0 }, "XXXXXXXX", .{}, .narrow);
    _ = try frame.putText(.{ .x = 2, .y = 1 }, "XXXXXXXX", .{}, .narrow);
    _ = try frame.putText(.{ .x = 2, .y = 2 }, "XXXXXXXX", .{}, .narrow);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    var surface = frame.surface(.{ .x = 2, .y = 0, .width = 8, .height = 3 });
    try std.testing.expectEqual(
        @as(u16, 2),
        try surface.putWrappedText(
            .{ .x = 0, .y = 0, .width = 7, .height = 3 },
            "one two three",
            .{},
            .narrow,
            .center,
        ),
    );
    try std.testing.expectEqual(@as(glyph_store.Glyph, 'o'), renderer.desiredCell(.{ .x = 2, .y = 0 }).?.glyph);
    try std.testing.expectEqual(@as(glyph_store.Glyph, 't'), renderer.desiredCell(.{ .x = 6, .y = 0 }).?.glyph);
    try std.testing.expectEqual(@as(glyph_store.Glyph, 't'), renderer.desiredCell(.{ .x = 3, .y = 1 }).?.glyph);
    try std.testing.expect(renderer.desiredCell(.{ .x = 2, .y = 2 }).?.eql(.{}));
    try std.testing.expect(renderer.desiredCell(.{ .x = 7, .y = 2 }).?.eql(.{}));

    var cached_text = "one two three".*;
    _ = try surface.putWrappedText(
        .{ .x = 0, .y = 0, .width = 7, .height = 3 },
        &cached_text,
        .{},
        .narrow,
        .center,
    );
    cached_text[0] = 0x1B;
    try std.testing.expectError(
        error.ControlCharacter,
        surface.putWrappedText(
            .{ .x = 0, .y = 0, .width = 7, .height = 3 },
            &cached_text,
            .{},
            .narrow,
            .center,
        ),
    );
    try std.testing.expectEqual(@as(glyph_store.Glyph, 'o'), renderer.desiredCell(.{ .x = 2, .y = 0 }).?.glyph);

    try std.testing.expectError(
        error.ControlCharacter,
        surface.putWrappedText(
            .{ .x = 0, .y = 0, .width = 6, .height = 3 },
            "safe\x1b[31m",
            .{},
            .narrow,
            .left,
        ),
    );
    try std.testing.expectEqual(@as(glyph_store.Glyph, 'o'), renderer.desiredCell(.{ .x = 2, .y = 0 }).?.glyph);
    var clipped = frame.surface(.{ .x = 8, .y = 3, .width = 4, .height = 3 });
    try std.testing.expectEqual(
        @as(u16, 1),
        try clipped.putWrappedText(
            .{ .x = 0, .y = 0, .width = 4, .height = 3 },
            "a b c",
            .{},
            .narrow,
            .left,
        ),
    );
    try std.testing.expectEqual(@as(glyph_store.Glyph, 'a'), renderer.desiredCell(.{ .x = 8, .y = 3 }).?.glyph);
    try std.testing.expect(!failing.has_induced_failure);
}

test "unchanged invalidation emits no output" {
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 12, .height = 2 }, .{});
    defer renderer.deinit();

    var frame = renderer.frame();
    _ = try frame.putText(.{ .x = 1, .y = 0 }, "hello", .{}, .narrow);

    var output: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    const first = try renderer.present(&writer, .{});
    try std.testing.expect(first.bytes > 0);

    renderer.invalidate(.{ .x = 1, .y = 0, .width = 5, .height = 1 });
    frame = renderer.frame();
    _ = try frame.putText(.{ .x = 1, .y = 0 }, "hello", .{}, .narrow);
    const second = try renderer.present(&writer, .{});
    try std.testing.expectEqual(@as(usize, 0), second.bytes);
    try std.testing.expectEqual(@as(usize, 0), second.cells_changed);
}

test "overwriting a wide grapheme clears its continuation" {
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 4, .height = 1 }, .{});
    defer renderer.deinit();

    var frame = renderer.frame();
    _ = try frame.putText(.{ .x = 0, .y = 0 }, "\xE7\x95\x8C", .{}, .narrow);
    try std.testing.expectEqual(cell_module.Width.wide, renderer.desiredCell(.{ .x = 0, .y = 0 }).?.width);
    try std.testing.expectEqual(cell_module.Width.continuation, renderer.desiredCell(.{ .x = 1, .y = 0 }).?.width);

    _ = try frame.putText(.{ .x = 1, .y = 0 }, "x", .{}, .narrow);
    try std.testing.expect(renderer.desiredCell(.{ .x = 0, .y = 0 }).?.eql(.{}));
    try std.testing.expectEqual(@as(glyph_store.Glyph, 'x'), renderer.desiredCell(.{ .x = 1, .y = 0 }).?.glyph);
}

test "partial fill clears a wide glyph crossing its boundary" {
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 4, .height = 1 }, .{});
    defer renderer.deinit();
    var frame = renderer.frame();
    _ = try frame.putText(.{ .x = 0, .y = 0 }, "\xE7\x95\x8C", .{}, .narrow);
    try frame.fill(.{ .x = 1, .y = 0, .width = 1, .height = 1 }, .{});
    try std.testing.expect(renderer.desiredCell(.{ .x = 0, .y = 0 }).?.eql(.{}));
    try std.testing.expect(renderer.desiredCell(.{ .x = 1, .y = 0 }).?.eql(.{}));
}

test "text shaping interns only visible live graphemes" {
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 1, .height = 1 }, .{
        .grapheme_capacity = 1,
    });
    defer renderer.deinit();

    var frame = renderer.frame();
    try std.testing.expectEqual(
        @as(u16, 1),
        try frame.putText(.{ .x = 0, .y = 0 }, "e\xCC\x81a\xCC\x81", .{}, .narrow),
    );
    try frame.fill(.{ .x = 0, .y = 0, .width = 1, .height = 1 }, .{});
    try std.testing.expectEqual(
        @as(u16, 1),
        try frame.putText(.{ .x = 0, .y = 0 }, "a\xCC\x81", .{}, .narrow),
    );
}

test "color depth changes repaint unchanged RGB styles" {
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 1, .height = 1 }, .{});
    defer renderer.deinit();
    var frame = renderer.frame();
    _ = try frame.putText(.{ .x = 0, .y = 0 }, "x", .{
        .foreground = .{ .rgb = .{ .r = 255, .g = 64, .b = 32 } },
    }, .narrow);

    var first_buffer: [256]u8 = undefined;
    var first = std.Io.Writer.fixed(&first_buffer);
    _ = try renderer.present(&first, .{ .color_depth = .ansi16 });

    var second_buffer: [256]u8 = undefined;
    var second = std.Io.Writer.fixed(&second_buffer);
    const stats = try renderer.present(&second, .{ .color_depth = .truecolor });
    try std.testing.expect(stats.full_repaint);
    try std.testing.expect(std.mem.indexOf(u8, second.buffered(), "\x1b[38;2;255;64;32m") != null);
}

test "ordinary frames do not call the allocator after initialization" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var renderer = try Renderer.init(failing.allocator(), .{ .width = 8, .height = 2 }, .{
        .grapheme_capacity = 8,
        .style_capacity = 8,
    });
    defer renderer.deinit();

    var output_buffer: [1024]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    _ = try renderer.present(&output, .{});

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    renderer.invalidate(.{ .x = 0, .y = 0, .width = 4, .height = 1 });
    var frame = renderer.frame();
    _ = try frame.putText(.{ .x = 0, .y = 0 }, "e\xCC\x81!", .{
        .foreground = .{ .indexed = 2 },
    }, .narrow);
    _ = try renderer.present(&output, .{});
    try std.testing.expect(!failing.has_induced_failure);
}

test "writer failure invalidates the shadow and forces recovery repaint" {
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 8, .height = 1 }, .{});
    defer renderer.deinit();
    var output_buffer: [1024]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    _ = try renderer.present(&output, .{});
    inline for (.{ "x", "y", "x" }) |text| {
        var frame = renderer.frame();
        _ = try frame.putText(.{ .x = 0, .y = 0 }, text, .{}, .narrow);
        _ = try renderer.present(&output, .{});
    }

    var frame = renderer.frame();
    _ = try frame.putText(.{ .x = 0, .y = 0 }, "y", .{}, .narrow);

    var tiny_buffer: [1]u8 = undefined;
    var failing_writer = std.Io.Writer.fixed(&tiny_buffer);
    try std.testing.expectError(error.WriteFailed, renderer.present(&failing_writer, .{}));

    var recovery_buffer: [1024]u8 = undefined;
    var recovery_writer = std.Io.Writer.fixed(&recovery_buffer);
    const recovery = try renderer.present(&recovery_writer, .{});
    try std.testing.expect(recovery.full_repaint);
    try std.testing.expect(std.mem.indexOf(u8, recovery_writer.buffered(), "\x1b[2J") != null);
}

test "disjoint tile damage skips the clean cells between mutations" {
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 40, .height = 1 }, .{
        .tile_width = 8,
        .tile_height = 1,
    });
    defer renderer.deinit();
    var output_buffer: [2048]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    _ = try renderer.present(&output, .{});

    var frame = renderer.frame();
    _ = try frame.putText(.{ .x = 1, .y = 0 }, "x", .{}, .narrow);
    _ = try frame.putText(.{ .x = 33, .y = 0 }, "y", .{}, .narrow);
    const stats = try renderer.present(&output, .{});
    try std.testing.expectEqual(@as(usize, 9), stats.cells_compared);
    try std.testing.expectEqual(@as(usize, 2), stats.cells_changed);
}

test "a mutation reverted before presentation remains a no-op" {
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 4, .height = 1 }, .{});
    defer renderer.deinit();
    var output_buffer: [256]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    _ = try renderer.present(&output, .{});

    var frame = renderer.frame();
    _ = try frame.putText(.{ .x = 1, .y = 0 }, "x", .{}, .narrow);
    try frame.fill(.{ .x = 1, .y = 0, .width = 1, .height = 1 }, .{});
    const stats = try renderer.present(&output, .{});
    try std.testing.expectEqual(@as(usize, 0), stats.cells_changed);
    try std.testing.expectEqual(@as(usize, 0), stats.bytes);
}

test "padded text clears the remainder of its field" {
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 8, .height = 1 }, .{});
    defer renderer.deinit();
    var frame = renderer.frame();
    _ = try frame.putTextPadded(.{ .x = 0, .y = 0 }, "hello", 8, .{}, .narrow);
    frame = renderer.frame();
    _ = try frame.putTextPadded(.{ .x = 0, .y = 0 }, "hi", 8, .{}, .narrow);
    try std.testing.expectEqual(@as(glyph_store.Glyph, 'h'), renderer.desiredCell(.{ .x = 0, .y = 0 }).?.glyph);
    try std.testing.expectEqual(@as(glyph_store.Glyph, 'i'), renderer.desiredCell(.{ .x = 1, .y = 0 }).?.glyph);
    try std.testing.expect(renderer.desiredCell(.{ .x = 2, .y = 0 }).?.eql(.{}));
    try std.testing.expect(renderer.desiredCell(.{ .x = 7, .y = 0 }).?.eql(.{}));
}

test "ASCII fill batches validate before mutating" {
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 4, .height = 1 }, .{});
    defer renderer.deinit();
    var frame = renderer.frame();
    var surface = frame.surface(geometry.Rect.fromSize(renderer.size()));
    const invalid = [_]AsciiFill{
        .{ .rect = .{ .x = 0, .y = 0, .width = 2, .height = 1 }, .glyph = '#' },
        .{ .rect = .{ .x = 2, .y = 0, .width = 2, .height = 1 }, .glyph = '\n' },
    };
    try std.testing.expectError(error.InvalidAsciiGlyph, surface.fillAsciiBatch(&invalid, .{}));
    try std.testing.expect(renderer.desiredCell(.{ .x = 0, .y = 0 }).?.eql(.{}));

    const valid = [_]AsciiFill{
        .{ .rect = .{ .x = 0, .y = 0, .width = 2, .height = 1 }, .glyph = '#' },
        .{ .rect = .{ .x = 2, .y = 0, .width = 2, .height = 1 }, .glyph = '-' },
    };
    try surface.fillAsciiBatch(&valid, .{});
    try std.testing.expectEqual(@as(glyph_store.Glyph, '#'), renderer.desiredCell(.{ .x = 1, .y = 0 }).?.glyph);
    try std.testing.expectEqual(@as(glyph_store.Glyph, '-'), renderer.desiredCell(.{ .x = 2, .y = 0 }).?.glyph);
}

test "scroll rotates row storage and emits one terminal scroll" {
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 6, .height = 4 }, .{});
    defer renderer.deinit();
    var output_buffer: [1024]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    _ = try renderer.present(&output, .{});
    var frame = renderer.frame();
    _ = try frame.putTextPadded(.{ .x = 0, .y = 1 }, "a", 6, .{}, .narrow);
    _ = try frame.putTextPadded(.{ .x = 0, .y = 2 }, "b", 6, .{}, .narrow);
    _ = try frame.putTextPadded(.{ .x = 0, .y = 3 }, "c", 6, .{}, .narrow);
    _ = try renderer.present(&output, .{});

    try renderer.scrollUp(.{ .x = 0, .y = 1, .width = 6, .height = 3 });
    frame = renderer.frame();
    _ = try frame.putTextPadded(.{ .x = 0, .y = 3 }, "d", 6, .{}, .narrow);
    var scroll_buffer: [512]u8 = undefined;
    var scroll_output = std.Io.Writer.fixed(&scroll_buffer);
    _ = try renderer.present(&scroll_output, .{});

    try std.testing.expectEqual(@as(glyph_store.Glyph, 'b'), renderer.desiredCell(.{ .x = 0, .y = 1 }).?.glyph);
    try std.testing.expectEqual(@as(glyph_store.Glyph, 'c'), renderer.desiredCell(.{ .x = 0, .y = 2 }).?.glyph);
    try std.testing.expectEqual(@as(glyph_store.Glyph, 'd'), renderer.desiredCell(.{ .x = 0, .y = 3 }).?.glyph);
    try std.testing.expect(std.mem.indexOf(u8, scroll_output.buffered(), "\x1b[2;4r\x1b[S\x1b[r") != null);
}

test "resize reuses retained framebuffer capacity" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var renderer = try Renderer.init(failing.allocator(), .{ .width = 8, .height = 2 }, .{});
    defer renderer.deinit();
    var output_buffer: [1024]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var frame = renderer.frame();
    _ = try frame.putText(.{ .x = 0, .y = 0 }, "e\xCC\x81", .{ .foreground = .{ .indexed = 1 } }, .narrow);
    _ = try renderer.present(&output, .{});

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    try renderer.resize(.{ .width = 4, .height = 2 });
    try renderer.resize(.{ .width = 8, .height = 2 });
    frame = renderer.frame();
    _ = try frame.putText(.{ .x = 0, .y = 0 }, "a\xCC\x81", .{ .foreground = .{ .indexed = 4 } }, .narrow);
    _ = try renderer.present(&output, .{});
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(geometry.Size{ .width = 8, .height = 2 }, renderer.size());
}

test "failed renderer growth preserves the previous frame" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var renderer = try Renderer.init(failing.allocator(), .{ .width = 2, .height = 1 }, .{});
    defer renderer.deinit();
    var frame = renderer.frame();
    _ = try frame.putText(.{ .x = 0, .y = 0 }, "x", .{}, .narrow);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    try std.testing.expectError(error.OutOfMemory, renderer.resize(.{ .width = 80, .height = 24 }));
    try std.testing.expectEqual(geometry.Size{ .width = 2, .height = 1 }, renderer.size());
    try std.testing.expectEqual(@as(glyph_store.Glyph, 'x'), renderer.desiredCell(.{ .x = 0, .y = 0 }).?.glyph);
}

test "renderer rejects oversized dimensions before allocation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    try std.testing.expectError(
        error.SizeLimitExceeded,
        Renderer.init(
            failing.allocator(),
            .{ .width = std.math.maxInt(u16), .height = std.math.maxInt(u16) },
            .{},
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "renderer presents Kitty images and clears removed placements" {
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 2, .height = 1 }, .{ .image_capacity = 1 });
    defer renderer.deinit();
    const pixels = [_]u8{ 255, 0, 0 };
    var frame = renderer.frame();
    try frame.putImage(
        .{ .x = 0, .y = 0, .width = 2, .height = 1 },
        .{ .pixels = &pixels, .width = 1, .height = 1, .format = .rgb8 },
        .{ .image_id = 7 },
    );
    var image_buffer: [1024]u8 = undefined;
    var image_output = std.Io.Writer.fixed(&image_buffer);
    _ = try renderer.present(&image_output, .{ .image_protocol = .kitty });
    try std.testing.expect(std.mem.indexOf(u8, image_output.buffered(), "\x1b_Ga=T,i=7") != null);

    _ = renderer.frame();
    var clear_buffer: [1024]u8 = undefined;
    var clear_output = std.Io.Writer.fixed(&clear_buffer);
    const stats = try renderer.present(&clear_output, .{ .image_protocol = .kitty });
    try std.testing.expect(stats.full_repaint);
    try std.testing.expect(std.mem.indexOf(u8, clear_output.buffered(), "\x1b_Ga=d,d=A\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, clear_output.buffered(), "\x1b[2J") != null);
}

test "renderer uses half-block image fallback without allocation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var renderer = try Renderer.init(failing.allocator(), .{ .width = 1, .height = 1 }, .{ .image_capacity = 1 });
    defer renderer.deinit();
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    const pixels = [_]u8{ 255, 0, 0, 0, 0, 255 };
    var frame = renderer.frame();
    try frame.putImage(
        .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .{ .pixels = &pixels, .width = 1, .height = 2, .format = .rgb8 },
        .{ .image_id = 1 },
    );
    var output_buffer: [1024]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    _ = try renderer.present(&output, .{ .color_depth = .truecolor });
    try std.testing.expect(std.mem.indexOf(u8, output.buffered(), "\xE2\x96\x80") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.buffered(), "38;2;255;0;0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.buffered(), "48;2;0;0;255") != null);
    try std.testing.expect(!failing.has_induced_failure);
}

test "renderer image capacity and clipping fail before presentation" {
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 2, .height = 1 }, .{ .image_capacity = 1 });
    defer renderer.deinit();
    const pixels = [_]u8{ 0, 0, 0 };
    var frame = renderer.frame();
    var surface = frame.surface(.{ .x = 1, .y = 0, .width = 1, .height = 1 });
    try std.testing.expectError(
        error.InvalidImageBounds,
        surface.putImage(
            .{ .x = 0, .y = 0, .width = 2, .height = 1 },
            .{ .pixels = &pixels, .width = 1, .height = 1, .format = .rgb8 },
            .{ .image_id = 1 },
        ),
    );
    try frame.putImage(
        .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .{ .pixels = &pixels, .width = 1, .height = 1, .format = .rgb8 },
        .{ .image_id = 1 },
    );
    try std.testing.expectError(
        error.ImageCapacityExceeded,
        frame.putImage(
            .{ .x = 1, .y = 0, .width = 1, .height = 1 },
            .{ .pixels = &pixels, .width = 1, .height = 1, .format = .rgb8 },
            .{ .image_id = 2 },
        ),
    );
}

test "ordinary frames remain eligible for diff output caching" {
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 8, .height = 2 }, .{});
    defer renderer.deinit();
    var buffer: [256]u8 = undefined;
    var output = std.Io.Writer.fixed(&buffer);
    _ = try renderer.present(&output, .{});

    var iteration: usize = 0;
    while (iteration < 5) : (iteration += 1) {
        var frame = renderer.frame();
        try std.testing.expect(!renderer.image_frame_active);
        var surface = frame.surface(.{ .x = 0, .y = 0, .width = 8, .height = 2 });
        try surface.fill(geometry.Rect.fromSize(surface.size()), .{});
        _ = try surface.putText(.{ .x = 0, .y = 0 }, if (iteration & 1 == 0) "a" else "b", .{}, .narrow);
        output = std.Io.Writer.fixed(&buffer);
        if (iteration >= 3) {
            var stats: FrameStats = undefined;
            try std.testing.expect(try renderer.presentCached(&output, .{}, &stats));
            try std.testing.expectEqual(@as(u32, 8), stats.cells_compared);
        } else {
            _ = try renderer.present(&output, .{});
        }
    }
}
