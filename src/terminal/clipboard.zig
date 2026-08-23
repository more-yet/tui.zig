const std = @import("std");
const capabilities = @import("capabilities.zig");

pub const Policy = union(enum) {
    deny,
    /// Enables writes up to this many input bytes.
    write_only: usize,
};

pub const Result = enum {
    disabled,
    emitted,
};

pub const ValidationError = error{
    EmptyText,
    TextTooLong,
    InvalidUtf8,
    OutputStorageTooSmall,
    OverlappingInput,
    SizeOverflow,
};

pub fn requiredOutputBytes(input_len: usize, max_input_bytes: usize) ValidationError!usize {
    if (input_len == 0) return error.EmptyText;
    if (input_len > max_input_bytes) return error.TextTooLong;
    const blocks = input_len / 3 + @intFromBool(input_len % 3 != 0);
    const encoded_len = std.math.mul(usize, blocks, 4) catch return error.SizeOverflow;
    return std.math.add(usize, encoded_len, 8) catch return error.SizeOverflow;
}

/// Emits a best-effort write-only OSC 52 request. It does not confirm clipboard delivery.
pub fn write(
    writer: *std.Io.Writer,
    terminal_capabilities: capabilities.Capabilities,
    policy: Policy,
    text: []const u8,
    output_storage: []u8,
) (ValidationError || std.Io.Writer.Error)!Result {
    if (!terminal_capabilities.clipboard_write) return .disabled;
    const max_input_bytes = switch (policy) {
        .deny => return .disabled,
        .write_only => |limit| limit,
    };
    const output_len = try requiredOutputBytes(text.len, max_input_bytes);
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    if (output_storage.len < output_len) return error.OutputStorageTooSmall;
    if (slicesOverlap(output_storage, text)) return error.OverlappingInput;

    @memcpy(output_storage[0..7], "\x1b]52;c;");
    const encoded = std.base64.standard.Encoder.encode(output_storage[7 .. output_len - 1], text);
    std.debug.assert(encoded.len == output_len - 8);
    output_storage[output_len - 1] = 0x07;
    errdefer writer.writeByte(0x07) catch {};
    try writer.writeAll(output_storage[0..output_len]);
    return .emitted;
}

/// Emits an explicit empty-selection OSC 52 request. Clipboard history may retain prior data.
pub fn clear(
    writer: *std.Io.Writer,
    terminal_capabilities: capabilities.Capabilities,
    policy: Policy,
) std.Io.Writer.Error!Result {
    if (!terminal_capabilities.clipboard_write) return .disabled;
    switch (policy) {
        .deny => return .disabled,
        .write_only => {},
    }
    try writer.writeAll("\x1b]52;c;\x07");
    return .emitted;
}

fn slicesOverlap(storage: []const u8, input: []const u8) bool {
    if (storage.len == 0 or input.len == 0) return false;
    const storage_start = @intFromPtr(storage.ptr);
    const input_start = @intFromPtr(input.ptr);
    const storage_end = std.math.add(usize, storage_start, storage.len) catch return true;
    const input_end = std.math.add(usize, input_start, input.len) catch return true;
    return input_start < storage_end and storage_start < input_end;
}

test "OSC 52 write is explicitly enabled, padded, and clear is separate" {
    var disabled_buffer: [32]u8 = undefined;
    var disabled = std.Io.Writer.fixed(&disabled_buffer);
    try std.testing.expectEqual(Result.disabled, try write(&disabled, .{}, .{ .write_only = 5 }, "hello", &.{}));
    try std.testing.expectEqual(Result.disabled, try write(&disabled, .{ .clipboard_write = true }, .deny, "hello", &.{}));
    try std.testing.expectEqual(Result.disabled, try write(&disabled, .{}, .{ .write_only = 0 }, "\xff", &.{}));
    try std.testing.expectEqual(Result.disabled, try write(&disabled, .{ .clipboard_write = true }, .deny, "", &.{}));
    try std.testing.expectEqual(@as(usize, 0), disabled.buffered().len);

    var storage: [64]u8 = undefined;
    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    try std.testing.expectEqual(
        Result.emitted,
        try write(&output, .{ .clipboard_write = true }, .{ .write_only = 5 }, "hello", &storage),
    );
    try std.testing.expectEqualStrings("\x1b]52;c;aGVsbG8=\x07", output.buffered());
    try std.testing.expectEqual(@as(usize, 16), try requiredOutputBytes(5, 5));
    try std.testing.expectEqual(@as(usize, 5_472), try requiredOutputBytes(4_097, 4_097));
    try std.testing.expectError(error.SizeOverflow, requiredOutputBytes(std.math.maxInt(usize), std.math.maxInt(usize)));

    var clear_buffer: [16]u8 = undefined;
    var clear_output = std.Io.Writer.fixed(&clear_buffer);
    try std.testing.expectEqual(Result.emitted, try clear(&clear_output, .{ .clipboard_write = true }, .{ .write_only = 0 }));
    try std.testing.expectEqualStrings("\x1b]52;c;\x07", clear_output.buffered());
}

test "OSC 52 validates the complete payload before output" {
    var output_buffer: [32]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var storage: [32]u8 = undefined;
    try std.testing.expectError(
        error.EmptyText,
        write(&output, .{ .clipboard_write = true }, .{ .write_only = 0 }, "", &storage),
    );
    try std.testing.expectError(
        error.InvalidUtf8,
        write(&output, .{ .clipboard_write = true }, .{ .write_only = 1 }, "\xff", &storage),
    );
    try std.testing.expectError(
        error.TextTooLong,
        write(&output, .{ .clipboard_write = true }, .{ .write_only = 5 }, "123456", &storage),
    );
    try std.testing.expectError(
        error.OutputStorageTooSmall,
        write(&output, .{ .clipboard_write = true }, .{ .write_only = 5 }, "hello", storage[0..15]),
    );
    @memcpy(storage[0..5], "hello");
    try std.testing.expectError(
        error.OverlappingInput,
        write(&output, .{ .clipboard_write = true }, .{ .write_only = 5 }, storage[0..5], &storage),
    );
    try std.testing.expectEqual(@as(usize, 0), output.buffered().len);
}

test "OSC 52 base64 handles every final block length" {
    const cases = [_]struct { text: []const u8, encoded: []const u8 }{
        .{ .text = "f", .encoded = "Zg==" },
        .{ .text = "fo", .encoded = "Zm8=" },
        .{ .text = "foo", .encoded = "Zm9v" },
        .{ .text = "foo\n", .encoded = "Zm9vCg==" },
        .{ .text = "\x1b", .encoded = "Gw==" },
    };
    for (cases) |case| {
        var storage: [32]u8 = undefined;
        var output_buffer: [32]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        _ = try write(&output, .{ .clipboard_write = true }, .{ .write_only = case.text.len }, case.text, &storage);
        try std.testing.expectEqualStrings("\x1b]52;c;", output.buffered()[0..7]);
        try std.testing.expectEqualStrings(case.encoded, output.buffered()[7 .. output.buffered().len - 1]);
        try std.testing.expectEqual(@as(u8, 0x07), output.buffered()[output.buffered().len - 1]);
    }
}

test "OSC 52 accepts payloads allowed by caller policy" {
    var text: [4_097]u8 = @splat('x');
    var storage: [5_472]u8 = undefined;
    var output_buffer: [5_472]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    try std.testing.expectEqual(
        Result.emitted,
        try write(&output, .{ .clipboard_write = true }, .{ .write_only = text.len }, &text, &storage),
    );
    try std.testing.expectEqual(try requiredOutputBytes(text.len, text.len), output.buffered().len);
}
