const std = @import("std");
const tui = @import("tui");
const testing = std.testing;

test "graphics sender preserves RFC 4648 padding for local names" {
    const vectors = .{
        .{ "f", "Zg==" },        .{ "fo", "Zm8=" },        .{ "foo", "Zm9v" },
        .{ "foob", "Zm9vYg==" }, .{ "fooba", "Zm9vYmE=" }, .{ "foobar", "Zm9vYmFy" },
    };
    inline for (vectors) |vector| {
        var sender = tui.graphics.Sender.init(.{});
        try sender.begin(.{ .transmit = .{ .transmission = .{ .format = .png, .medium = .file } } }, .{ .file = vector[0] }, .none);
        const output = (try sender.outputStep()).?;
        const separator = std.mem.indexOfScalar(u8, output, ';').?;
        try testing.expectEqualStrings(vector[1], output[separator + 1 .. output.len - 2]);
        try sender.consumeOutput(output.len);
        try testing.expect(try sender.outputStep() == null);
    }
}

test "graphics chunk bounds padding and acknowledged suffixes round trip" {
    const Sender = tui.graphics.Sender;
    var source: [Sender.max_source_chunk_bytes * 2 + 8]u8 = undefined;
    for (&source, 0..) |*byte, index| byte.* = @truncate(index);
    for ([_]usize{ 4, 8, 12, 3072, 3076, 3080, 6144, 6148 }) |length| {
        var sender = Sender.init(.{});
        try sender.begin(.{ .transmit = .{ .transmission = .{
            .width_pixels = @intCast(length / 4),
            .height_pixels = 1,
            .identifiers = .{ .image_id = 1 },
        } } }, .{ .direct = source[0..length] }, .none);
        var offset: usize = 0;
        while (try sender.outputStep()) |output| {
            try testing.expect(output.len <= Sender.output_capacity);
            try testing.expect(std.mem.startsWith(u8, output, "\x1b_G"));
            try testing.expect(std.mem.endsWith(u8, output, "\x1b\\"));
            const separator = std.mem.indexOfScalar(u8, output, ';').?;
            const encoded = output[separator + 1 .. output.len - 2];
            try testing.expect(encoded.len <= Sender.max_base64_chunk_bytes);
            const expected = @min(Sender.max_source_chunk_bytes, length - offset);
            const decoder = std.base64.standard.Decoder;
            try testing.expectEqual(expected, try decoder.calcSizeForSlice(encoded));
            var decoded: [Sender.max_source_chunk_bytes]u8 = undefined;
            try decoder.decode(decoded[0..expected], encoded);
            try testing.expectEqualSlices(u8, source[offset..][0..expected], decoded[0..expected]);
            const more = offset + expected < length;
            try testing.expectEqual(more, std.mem.indexOf(u8, output[0..separator], "m=1") != null);
            if (offset != 0 and !more) try testing.expect(std.mem.indexOf(u8, output[0..separator], "m=0") != null);
            var saved: [Sender.output_capacity]u8 = undefined;
            @memcpy(saved[0..output.len], output);
            try testing.expectError(error.InvalidByteCount, sender.consumeOutput(output.len + 1));
            try sender.consumeOutput(0);
            try testing.expectEqualSlices(u8, saved[0..output.len], (try sender.outputStep()).?);
            try sender.consumeOutput(1);
            try testing.expectEqualSlices(u8, saved[1..output.len], (try sender.outputStep()).?);
            try sender.consumeOutput(output.len - 1);
            offset += expected;
        }
        try testing.expectEqual(length, offset);
        try testing.expect(!sender.isActive());
    }
}
