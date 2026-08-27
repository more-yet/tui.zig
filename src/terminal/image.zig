const std = @import("std");

pub const PixelFormat = enum {
    rgb8,
    rgba8,
};

pub const Image = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    format: PixelFormat,
};

pub const Placement = struct {
    columns: u16,
    rows: u16,
    image_id: u32,
    placement_id: u32 = 1,
};

pub const Rgb = struct {
    red: u8 = 0,
    green: u8 = 0,
    blue: u8 = 0,
};

pub const ValidationError = error{
    EmptyImage,
    InvalidPixelLength,
    InvalidIdentifier,
    InvalidPlacement,
    ImageTooLarge,
};

pub fn writeKitty(writer: *std.Io.Writer, image: Image, placement: Placement) (ValidationError || std.Io.Writer.Error)!void {
    try validate(image);
    if (placement.image_id == 0 or placement.placement_id == 0) return error.InvalidIdentifier;
    if (placement.columns == 0 or placement.rows == 0) return error.InvalidPlacement;

    const raw_chunk_bytes = 3072;
    var encoded: [4096]u8 = undefined;
    var offset: usize = 0;
    var first = true;
    while (offset < image.pixels.len) {
        const end = @min(image.pixels.len, offset + raw_chunk_bytes);
        const final = end == image.pixels.len;
        const payload = std.base64.standard.Encoder.encode(&encoded, image.pixels[offset..end]);
        if (first) {
            try writer.print(
                "\x1b_Ga=T,i={d},p={d},f={d},s={d},v={d},c={d},r={d},z=1,C=1,m={d};",
                .{
                    placement.image_id,
                    placement.placement_id,
                    if (image.format == .rgb8) @as(u8, 24) else @as(u8, 32),
                    image.width,
                    image.height,
                    placement.columns,
                    placement.rows,
                    @intFromBool(!final),
                },
            );
            first = false;
        } else {
            try writer.print("\x1b_Gm={d};", .{@intFromBool(!final)});
        }
        try writer.writeAll(payload);
        try writer.writeAll("\x1b\\");
        offset = end;
    }
}

pub fn clearKitty(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("\x1b_Ga=d,d=A\x1b\\");
}

/// Streams a minimal uncompressed PNG through iTerm2's multipart OSC 1337 protocol.
pub fn writeIterm2(writer: *std.Io.Writer, image: Image, placement: Placement) (ValidationError || std.Io.Writer.Error)!void {
    const png_size = try pngSize(image);
    if (placement.columns == 0 or placement.rows == 0) return error.InvalidPlacement;
    try writer.print(
        "\x1b]1337;MultipartFile=inline=1;size={d};width={d};height={d};preserveAspectRatio=0\x1b\\",
        .{ png_size, placement.columns, placement.rows },
    );
    var sink = MultipartBase64{ .writer = writer };
    try writePng(&sink, image);
    try sink.finish();
    try writer.writeAll("\x1b]1337;FileEnd\x1b\\");
}

/// Emits a 3-3-2 palette Sixel image. RGBA input is composited over `background`.
pub fn writeSixel(writer: *std.Io.Writer, image: Image, background: Rgb) (ValidationError || std.Io.Writer.Error)!void {
    try validate(image);
    const count = pixelCount(image);
    var palette_indices: [16 * 1024]u8 = undefined;
    const cache_pixels = count <= palette_indices.len;
    var used: [256]bool = @splat(false);
    for (0..count) |index| {
        const color_index = paletteIndex(pixel(image, index, background));
        used[color_index] = true;
        if (cache_pixels) palette_indices[index] = color_index;
    }

    try writer.print("\x1bP0;1;0q\"1;1;{d};{d}", .{ image.width, image.height });
    var used_colors: [256]u8 = undefined;
    var color_slots: [256]u8 = undefined;
    var used_count: usize = 0;
    for (used, 0..) |present, index| {
        if (!present) continue;
        used_colors[used_count] = @intCast(index);
        color_slots[index] = @intCast(used_count);
        used_count += 1;
        const color = paletteColor(@intCast(index));
        try writer.print(
            "#{d};2;{d};{d};{d}",
            .{ index, percent(color.red), percent(color.green), percent(color.blue) },
        );
    }

    var band_values: [16 * 1024]u8 = undefined;
    const cache_bands = image.width <= band_values.len / used_count;
    var band_y: u32 = 0;
    while (band_y < image.height) : (band_y += 6) {
        const width: usize = image.width;
        if (cache_bands) {
            @memset(band_values[0 .. used_count * width], 0);
            var row: u3 = 0;
            while (row < 6 and band_y + row < image.height) : (row += 1) {
                var x: u32 = 0;
                while (x < image.width) : (x += 1) {
                    const index = @as(usize, band_y + row) * image.width + x;
                    const color_index = if (cache_pixels)
                        palette_indices[index]
                    else
                        paletteIndex(pixel(image, index, background));
                    const slot = color_slots[color_index];
                    band_values[@as(usize, slot) * width + x] |= @as(u6, 1) << row;
                }
            }
        }

        var first_color = true;
        for (used_colors[0..used_count], 0..) |color_index, color_slot| {
            if (!first_color) try writer.writeByte('$');
            first_color = false;
            try writeSixelColor(writer, color_index);
            var run_value: u8 = 0;
            var run_len: u32 = 0;
            var x: u32 = 0;
            while (x < image.width) : (x += 1) {
                const value: u8 = if (cache_bands)
                    0x3f + band_values[color_slot * width + x]
                else value: {
                    var bits: u6 = 0;
                    var row: u3 = 0;
                    while (row < 6 and band_y + row < image.height) : (row += 1) {
                        const index = @as(usize, band_y + row) * image.width + x;
                        if (paletteIndex(pixel(image, index, background)) == color_index) {
                            bits |= @as(u6, 1) << row;
                        }
                    }
                    break :value 0x3f + @as(u8, bits);
                };
                if (run_len != 0 and value != run_value) {
                    try writeSixelRun(writer, run_value, run_len);
                    run_len = 0;
                }
                run_value = value;
                run_len += 1;
            }
            try writeSixelRun(writer, run_value, run_len);
        }
        if (band_y + 6 < image.height) try writer.writeByte('-');
    }
    try writer.writeAll("\x1b\\");
}

pub fn validate(image: Image) ValidationError!void {
    if (image.width == 0 or image.height == 0) return error.EmptyImage;
    const channels: usize = if (image.format == .rgb8) 3 else 4;
    const count = std.math.mul(usize, image.width, image.height) catch return error.ImageTooLarge;
    const expected = std.math.mul(usize, count, channels) catch return error.ImageTooLarge;
    if (image.pixels.len != expected) return error.InvalidPixelLength;
}

pub fn colorAt(image: Image, x: u32, y: u32, background: Rgb) Rgb {
    std.debug.assert(x < image.width and y < image.height);
    return pixel(image, @as(usize, y) * image.width + x, background);
}

fn pixelCount(image: Image) usize {
    return @as(usize, image.width) * image.height;
}

fn pixel(image: Image, index: usize, background: Rgb) Rgb {
    const channels: usize = if (image.format == .rgb8) 3 else 4;
    const offset = index * channels;
    if (image.format == .rgb8) return .{
        .red = image.pixels[offset],
        .green = image.pixels[offset + 1],
        .blue = image.pixels[offset + 2],
    };
    const alpha = image.pixels[offset + 3];
    return .{
        .red = composite(image.pixels[offset], background.red, alpha),
        .green = composite(image.pixels[offset + 1], background.green, alpha),
        .blue = composite(image.pixels[offset + 2], background.blue, alpha),
    };
}

fn composite(foreground: u8, background: u8, alpha: u8) u8 {
    const inverse = 255 - @as(u32, alpha);
    const mixed = @as(u32, foreground) * alpha + @as(u32, background) * inverse + 127;
    return divideBy255(mixed);
}

fn divideBy255(value: u32) u8 {
    return @intCast((value + 1 + (value >> 8)) >> 8);
}

fn paletteIndex(value: Rgb) u8 {
    return (value.red & 0xe0) | ((value.green >> 3) & 0x1c) | (value.blue >> 6);
}

fn paletteColor(index: u8) Rgb {
    return .{
        .red = @intCast((@as(u16, index >> 5) * 255 + 3) / 7),
        .green = @intCast((@as(u16, (index >> 2) & 7) * 255 + 3) / 7),
        .blue = @intCast((@as(u16, index & 3) * 255 + 1) / 3),
    };
}

fn percent(value: u8) u8 {
    return @intCast((@as(u16, value) * 100 + 127) / 255);
}

fn writeSixelRun(writer: *std.Io.Writer, value: u8, count: u32) std.Io.Writer.Error!void {
    if (count >= 4) {
        var encoded: [12]u8 = undefined;
        encoded[0] = '!';
        const digits = writeDecimal(encoded[1..11], count);
        encoded[digits + 1] = value;
        try writer.writeAll(encoded[0 .. digits + 2]);
    } else {
        const encoded: [3]u8 = @splat(value);
        try writer.writeAll(encoded[0..count]);
    }
}

fn writeSixelColor(writer: *std.Io.Writer, color_index: u8) std.Io.Writer.Error!void {
    var encoded: [4]u8 = undefined;
    encoded[0] = '#';
    const digits = writeDecimal(encoded[1..], color_index);
    try writer.writeAll(encoded[0 .. digits + 1]);
}

fn writeDecimal(destination: []u8, value: u32) usize {
    var reversed: [10]u8 = undefined;
    var remaining = value;
    var len: usize = 0;
    while (true) {
        reversed[len] = @intCast('0' + remaining % 10);
        len += 1;
        remaining /= 10;
        if (remaining == 0) break;
    }
    for (0..len) |index| destination[index] = reversed[len - index - 1];
    return len;
}

fn pngSize(image: Image) ValidationError!u32 {
    try validate(image);
    const channels: usize = if (image.format == .rgb8) 3 else 4;
    const stride = std.math.mul(usize, image.width, channels) catch return error.ImageTooLarge;
    const filtered = std.math.mul(usize, stride + 1, image.height) catch return error.ImageTooLarge;
    const blocks = filtered / 65_535 + @intFromBool(filtered % 65_535 != 0);
    const zlib_size = std.math.add(usize, filtered, blocks * 5 + 6) catch return error.ImageTooLarge;
    const total = std.math.add(usize, zlib_size, 57) catch return error.ImageTooLarge;
    return std.math.cast(u32, total) orelse error.ImageTooLarge;
}

fn writePng(sink: *MultipartBase64, image: Image) std.Io.Writer.Error!void {
    const channels: usize = if (image.format == .rgb8) 3 else 4;
    const stride = @as(usize, image.width) * channels;
    const filtered_len = (stride + 1) * image.height;
    const blocks = filtered_len / 65_535 + @intFromBool(filtered_len % 65_535 != 0);
    const zlib_size: u32 = @intCast(filtered_len + blocks * 5 + 6);

    try sink.writeAll("\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = @splat(0);
    writeU32Be(ihdr[0..4], image.width);
    writeU32Be(ihdr[4..8], image.height);
    ihdr[8] = 8;
    ihdr[9] = if (image.format == .rgb8) 2 else 6;
    try writeChunk(sink, "IHDR", &ihdr);

    var length: [4]u8 = undefined;
    writeU32Be(&length, zlib_size);
    try sink.writeAll(&length);
    try sink.writeAll("IDAT");
    var crc: u32 = crcUpdate(0xffff_ffff, "IDAT");
    try emitIdat(sink, &crc, "\x78\x01");
    var adler = Adler{};
    var filtered_offset: usize = 0;
    while (filtered_offset < filtered_len) {
        const block_len: u16 = @intCast(@min(@as(usize, 65_535), filtered_len - filtered_offset));
        const final = filtered_offset + block_len == filtered_len;
        const header = [5]u8{
            @intFromBool(final),
            @truncate(block_len),
            @truncate(block_len >> 8),
            @truncate(~block_len),
            @truncate((~block_len) >> 8),
        };
        try emitIdat(sink, &crc, &header);
        var remaining: usize = block_len;
        while (remaining != 0) {
            const column = filtered_offset % (stride + 1);
            if (column == 0) {
                const filter = [1]u8{0};
                try emitIdat(sink, &crc, &filter);
                adler.update(&filter);
                filtered_offset += 1;
                remaining -= 1;
                continue;
            }
            const row = filtered_offset / (stride + 1);
            const pixel_offset = row * stride + column - 1;
            const count = @min(remaining, stride - (column - 1));
            const bytes = image.pixels[pixel_offset .. pixel_offset + count];
            try emitIdat(sink, &crc, bytes);
            adler.update(bytes);
            filtered_offset += count;
            remaining -= count;
        }
    }
    var checksum: [4]u8 = undefined;
    writeU32Be(&checksum, adler.value());
    try emitIdat(sink, &crc, &checksum);
    writeU32Be(&checksum, ~crc);
    try sink.writeAll(&checksum);
    try writeChunk(sink, "IEND", "");
}

fn writeChunk(sink: *MultipartBase64, chunk_type: *const [4]u8, data: []const u8) std.Io.Writer.Error!void {
    var encoded: [4]u8 = undefined;
    writeU32Be(&encoded, @intCast(data.len));
    try sink.writeAll(&encoded);
    try sink.writeAll(chunk_type);
    try sink.writeAll(data);
    var crc = crcUpdate(0xffff_ffff, chunk_type);
    crc = crcUpdate(crc, data);
    writeU32Be(&encoded, ~crc);
    try sink.writeAll(&encoded);
}

fn emitIdat(sink: *MultipartBase64, crc: *u32, bytes: []const u8) std.Io.Writer.Error!void {
    crc.* = crcUpdate(crc.*, bytes);
    try sink.writeAll(bytes);
}

fn writeU32Be(output: []u8, value: u32) void {
    output[0] = @truncate(value >> 24);
    output[1] = @truncate(value >> 16);
    output[2] = @truncate(value >> 8);
    output[3] = @truncate(value);
}

fn crcUpdate(initial: u32, bytes: []const u8) u32 {
    var crc = initial;
    var offset: usize = 0;
    while (bytes.len - offset >= 8) : (offset += 8) {
        const first = crc ^ std.mem.readInt(u32, bytes[offset..][0..4], .little);
        const second = std.mem.readInt(u32, bytes[offset + 4 ..][0..4], .little);
        crc = crc_tables[7][@as(u8, @truncate(first))] ^
            crc_tables[6][@as(u8, @truncate(first >> 8))] ^
            crc_tables[5][@as(u8, @truncate(first >> 16))] ^
            crc_tables[4][@as(u8, @truncate(first >> 24))] ^
            crc_tables[3][@as(u8, @truncate(second))] ^
            crc_tables[2][@as(u8, @truncate(second >> 8))] ^
            crc_tables[1][@as(u8, @truncate(second >> 16))] ^
            crc_tables[0][@as(u8, @truncate(second >> 24))];
    }
    for (bytes[offset..]) |byte| crc = (crc >> 8) ^ crc_tables[0][@as(u8, @truncate(crc)) ^ byte];
    return crc;
}

const crc_tables: [8][256]u32 = tables: {
    @setEvalBranchQuota(20_000);
    var values: [8][256]u32 = undefined;
    for (&values[0], 0..) |*value, index| {
        var crc: u32 = @intCast(index);
        for (0..8) |_| crc = if (crc & 1 != 0) (crc >> 1) ^ 0xedb8_8320 else crc >> 1;
        value.* = crc;
    }
    for (1..values.len) |table_index| {
        for (&values[table_index], 0..) |*value, index| {
            const previous = values[table_index - 1][index];
            value.* = (previous >> 8) ^ values[0][@as(u8, @truncate(previous))];
        }
    }
    break :tables values;
};

const Adler = struct {
    first: u32 = 1,
    second: u32 = 0,

    fn update(self: *Adler, bytes: []const u8) void {
        var first = self.first;
        var second = self.second;
        var offset: usize = 0;
        while (offset < bytes.len) {
            const end = @min(bytes.len, offset + 5_552);
            while (end - offset >= 16) : (offset += 16) {
                var sum: u32 = 0;
                var weighted: u32 = 0;
                inline for (0..16) |index| {
                    const byte = bytes[offset + index];
                    sum += byte;
                    weighted += @as(u32, byte) * @as(u32, @intCast(16 - index));
                }
                second += 16 * first + weighted;
                first += sum;
            }
            for (bytes[offset..end]) |byte| {
                first += byte;
                second += first;
            }
            first %= 65_521;
            second %= 65_521;
            offset = end;
        }
        self.first = first;
        self.second = second;
    }

    fn value(self: Adler) u32 {
        return (self.second << 16) | self.first;
    }
};

const MultipartBase64 = struct {
    writer: *std.Io.Writer,
    payload: [4096]u8 = undefined,
    payload_len: usize = 0,
    tail: [3]u8 = undefined,
    tail_len: u2 = 0,

    fn writeAll(self: *MultipartBase64, bytes: []const u8) std.Io.Writer.Error!void {
        var offset: usize = 0;
        if (self.tail_len != 0) {
            while (offset < bytes.len and self.tail_len < 3) : (offset += 1) {
                self.tail[self.tail_len] = bytes[offset];
                self.tail_len += 1;
            }
            if (self.tail_len == 3) {
                try self.appendQuartet(self.tail, 3);
                self.tail_len = 0;
            }
        }
        if (offset == bytes.len) return;

        while (bytes.len - offset >= 3) {
            if (self.payload_len == self.payload.len) try self.flush();
            const source_len = @min(
                (bytes.len - offset) / 3 * 3,
                (self.payload.len - self.payload_len) / 4 * 3,
            );
            const encoded = std.base64.standard.Encoder.encode(
                self.payload[self.payload_len..],
                bytes[offset .. offset + source_len],
            );
            self.payload_len += encoded.len;
            offset += source_len;
        }
        @memcpy(self.tail[0 .. bytes.len - offset], bytes[offset..]);
        self.tail_len = @intCast(bytes.len - offset);
    }

    fn finish(self: *MultipartBase64) std.Io.Writer.Error!void {
        if (self.tail_len != 0) try self.appendQuartet(self.tail, self.tail_len);
        try self.flush();
    }

    fn appendQuartet(self: *MultipartBase64, bytes: [3]u8, len: u2) std.Io.Writer.Error!void {
        if (self.payload_len == self.payload.len) try self.flush();
        const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        const second = if (len > 1) bytes[1] else 0;
        const third = if (len > 2) bytes[2] else 0;
        self.payload[self.payload_len] = alphabet[bytes[0] >> 2];
        self.payload[self.payload_len + 1] = alphabet[((bytes[0] & 3) << 4) | (second >> 4)];
        self.payload[self.payload_len + 2] = if (len > 1) alphabet[((second & 15) << 2) | (third >> 6)] else '=';
        self.payload[self.payload_len + 3] = if (len > 2) alphabet[third & 63] else '=';
        self.payload_len += 4;
    }

    fn flush(self: *MultipartBase64) std.Io.Writer.Error!void {
        if (self.payload_len == 0) return;
        try self.writer.writeAll("\x1b]1337;FilePart=");
        try self.writer.writeAll(self.payload[0..self.payload_len]);
        try self.writer.writeAll("\x1b\\");
        self.payload_len = 0;
    }
};

test "Kitty output chunks raw pixels and carries controls only on the first APC" {
    var pixels: [3075]u8 = @splat(0xff);
    var output_bytes: [5000]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_bytes);
    try writeKitty(&output, .{
        .pixels = &pixels,
        .width = 1025,
        .height = 1,
        .format = .rgb8,
    }, .{ .columns = 10, .rows = 1, .image_id = 7 });
    const encoded = output.buffered();
    try std.testing.expect(std.mem.startsWith(u8, encoded, "\x1b_Ga=T,i=7,p=1,f=24,s=1025,v=1,c=10,r=1,z=1,C=1,m=1;"));
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\x1b\\\x1b_Gm=0;") != null);
}

test "iTerm2 output streams a valid PNG signature through multipart base64" {
    const pixels = [_]u8{ 0xff, 0, 0, 0xff };
    var output_bytes: [1024]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_bytes);
    try writeIterm2(&output, .{ .pixels = &pixels, .width = 1, .height = 1, .format = .rgba8 }, .{
        .columns = 1,
        .rows = 1,
        .image_id = 1,
    });
    try std.testing.expect(std.mem.indexOf(u8, output.buffered(), "\x1b]1337;FilePart=iVBORw0KGgo") != null);
    try std.testing.expect(std.mem.endsWith(u8, output.buffered(), "\x1b]1337;FileEnd\x1b\\"));
}

test "PNG CRC uses the standard reflected polynomial" {
    try std.testing.expectEqual(@as(u32, 0xcbf4_3926), ~crcUpdate(0xffff_ffff, "123456789"));
}

test "Adler checksum supports block and fragmented updates" {
    var whole: Adler = .{};
    whole.update("Wikipedia");
    try std.testing.expectEqual(@as(u32, 0x11e6_0398), whole.value());

    var fragmented: Adler = .{};
    fragmented.update("Wiki");
    fragmented.update("pedia");
    try std.testing.expectEqual(whole.value(), fragmented.value());
}

test "Sixel output validates pixels and composites RGBA" {
    const pixels = [_]u8{ 0xff, 0, 0, 0x80 };
    var output_bytes: [1024]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_bytes);
    try writeSixel(&output, .{ .pixels = &pixels, .width = 1, .height = 1, .format = .rgba8 }, .{});
    try std.testing.expectEqualStrings("\x1bP0;1;0q\"1;1;1;1#128;2;57;0;0#128@\x1b\\", output.buffered());
    try std.testing.expectError(
        error.InvalidPixelLength,
        writeSixel(&output, .{ .pixels = "", .width = 1, .height = 1, .format = .rgb8 }, .{}),
    );
}

test "Sixel compositing division is exact" {
    for (0..65_153) |value| {
        try std.testing.expectEqual(@as(u8, @intCast(value / 255)), divideBy255(@intCast(value)));
    }
}

test "Sixel output falls back for images wider than the band cache" {
    const width = 16 * 1024 + 1;
    const pixels: [width * 3]u8 = @splat(0);
    var output_bytes: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_bytes);
    try writeSixel(&output, .{ .pixels = &pixels, .width = width, .height = 1, .format = .rgb8 }, .{});
    try std.testing.expectEqualStrings(
        "\x1bP0;1;0q\"1;1;16385;1#0;2;0;0;0#0!16385@\x1b\\",
        output.buffered(),
    );
}
