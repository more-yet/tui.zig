const std = @import("std");
const capabilities = @import("capabilities.zig");

pub const max_uri_bytes = 2048;
pub const max_label_bytes = 4096;

pub const Fallback = enum {
    label,
    label_and_uri,
};

pub const Hyperlink = struct {
    label: []const u8,
    uri: []const u8,
    fallback: Fallback = .label_and_uri,
};

pub const ValidationError = error{
    EmptyLabel,
    LabelTooLong,
    InvalidLabel,
    EmptyUri,
    UriTooLong,
    InvalidUri,
};

/// Writes one closed hyperlink span, or its explicit plain-text fallback.
pub fn write(
    writer: *std.Io.Writer,
    terminal_capabilities: capabilities.Capabilities,
    hyperlink: Hyperlink,
) (ValidationError || std.Io.Writer.Error)!void {
    try validateLabel(hyperlink.label);
    try validateUri(hyperlink.uri);
    if (!terminal_capabilities.hyperlinks) {
        try writer.writeAll(hyperlink.label);
        if (hyperlink.fallback == .label_and_uri) {
            try writer.writeAll(" <");
            try writer.writeAll(hyperlink.uri);
            try writer.writeByte('>');
        }
        return;
    }

    errdefer writer.writeAll("\x1b\\\x1b]8;;\x1b\\") catch {};
    try writer.writeAll("\x1b]8;;");
    try writer.writeAll(hyperlink.uri);
    try writer.writeAll("\x1b\\");
    try writer.writeAll(hyperlink.label);
    try writer.writeAll("\x1b]8;;\x1b\\");
}

fn validateLabel(label: []const u8) ValidationError!void {
    if (label.len == 0) return error.EmptyLabel;
    if (label.len > max_label_bytes) return error.LabelTooLong;
    var index: usize = 0;
    while (index < label.len) {
        const first = label[index];
        if (first < 0x80) {
            if (first < 0x20 or first == 0x7f) return error.InvalidLabel;
            index += 1;
            continue;
        }
        const sequence_len = std.unicode.utf8ByteSequenceLength(first) catch return error.InvalidLabel;
        if (index + sequence_len > label.len) return error.InvalidLabel;
        const codepoint = std.unicode.utf8Decode(label[index .. index + sequence_len]) catch return error.InvalidLabel;
        if (codepoint >= 0x80 and codepoint <= 0x9f) return error.InvalidLabel;
        index += sequence_len;
    }
}

fn validateUri(uri: []const u8) ValidationError!void {
    if (uri.len == 0) return error.EmptyUri;
    if (uri.len > max_uri_bytes) return error.UriTooLong;
    const scheme = "https://";
    if (!std.mem.startsWith(u8, uri, scheme)) return error.InvalidUri;
    const authority_start = scheme.len;
    var authority_end = authority_start;
    while (authority_end < uri.len and
        uri[authority_end] != '/' and
        uri[authority_end] != '?' and
        uri[authority_end] != '#') : (authority_end += 1)
    {}
    if (authority_end == authority_start) return error.InvalidUri;
    const authority = uri[authority_start..authority_end];
    if (std.mem.indexOfScalar(u8, authority, '@') != null or
        std.mem.indexOfScalar(u8, authority, '%') != null) return error.InvalidUri;
    if (!validAuthority(authority)) return error.InvalidUri;

    var index: usize = 0;
    while (index < uri.len) : (index += 1) {
        const byte = uri[index];
        if (byte == '%') {
            if (index + 2 >= uri.len or !std.ascii.isHex(uri[index + 1]) or !std.ascii.isHex(uri[index + 2])) {
                return error.InvalidUri;
            }
            index += 2;
            continue;
        }
        if (!isUriByte(byte)) return error.InvalidUri;
    }
}

fn validAuthority(authority: []const u8) bool {
    if (authority.len == 0) return false;
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return false;
        if (close == 1) return false;
        for (authority[1..close]) |byte| {
            if (!std.ascii.isHex(byte) and byte != ':' and byte != '.') return false;
        }
        if (close + 1 == authority.len) return true;
        if (authority[close + 1] != ':') return false;
        return validPort(authority[close + 2 ..]);
    }
    const separator = std.mem.indexOfScalar(u8, authority, ':');
    const host = if (separator) |index| authority[0..index] else authority;
    if (host.len == 0 or host[0] == '.' or host[host.len - 1] == '.') return false;
    for (host) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '.') return false;
    }
    return if (separator) |index| validPort(authority[index + 1 ..]) else true;
}

fn validPort(port: []const u8) bool {
    if (port.len == 0) return false;
    for (port) |byte| if (!std.ascii.isDigit(byte)) return false;
    _ = std.fmt.parseInt(u16, port, 10) catch return false;
    return true;
}

fn isUriByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '-', '.', '_', '~', ':', '/', '?', '#', '[', ']', '@', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=' => true,
        else => false,
    };
}

test "hyperlink output is closed and has an explicit fallback" {
    const value = Hyperlink{ .label = "documentation", .uri = "https://example.com/docs" };
    var linked_buffer: [128]u8 = undefined;
    var linked = std.Io.Writer.fixed(&linked_buffer);
    try write(&linked, .{ .hyperlinks = true }, value);
    try std.testing.expectEqualStrings(
        "\x1b]8;;https://example.com/docs\x1b\\documentation\x1b]8;;\x1b\\",
        linked.buffered(),
    );

    var fallback_buffer: [128]u8 = undefined;
    var fallback = std.Io.Writer.fixed(&fallback_buffer);
    try write(&fallback, .{}, value);
    try std.testing.expectEqualStrings("documentation <https://example.com/docs>", fallback.buffered());

    var label_buffer: [32]u8 = undefined;
    var label = std.Io.Writer.fixed(&label_buffer);
    try write(&label, .{}, .{ .label = "documentation", .uri = value.uri, .fallback = .label });
    try std.testing.expectEqualStrings("documentation", label.buffered());
}

test "hyperlink validation rejects injection and deceptive authorities before output" {
    const cases = [_]struct { expected: ValidationError, value: Hyperlink }{
        .{ .expected = error.InvalidUri, .value = .{ .label = "x", .uri = "http://example.com" } },
        .{ .expected = error.InvalidUri, .value = .{ .label = "x", .uri = "https://trusted.example@evil.example" } },
        .{ .expected = error.InvalidUri, .value = .{ .label = "x", .uri = "https://:443/path" } },
        .{ .expected = error.InvalidUri, .value = .{ .label = "x", .uri = "https://example.com/%xy" } },
        .{ .expected = error.InvalidUri, .value = .{ .label = "x", .uri = "https://example.com/\x1b]8;;" } },
        .{ .expected = error.InvalidLabel, .value = .{ .label = "safe\nunsafe", .uri = "https://example.com" } },
        .{ .expected = error.InvalidLabel, .value = .{ .label = "\xc2\x9d", .uri = "https://example.com" } },
        .{ .expected = error.InvalidLabel, .value = .{ .label = "\xff", .uri = "https://example.com" } },
    };
    for (cases) |case| {
        var output_buffer: [128]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        try std.testing.expectError(case.expected, write(&output, .{ .hyperlinks = true }, case.value));
        try std.testing.expectEqual(@as(usize, 0), output.buffered().len);
    }

    var long_uri: [max_uri_bytes + 1]u8 = @splat('a');
    @memcpy(long_uri[0.."https://".len], "https://");
    var long_label: [max_label_bytes + 1]u8 = @splat('x');
    var output_buffer: [1]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    try std.testing.expectError(
        error.UriTooLong,
        write(&output, .{ .hyperlinks = true }, .{ .label = "x", .uri = &long_uri }),
    );
    try std.testing.expectError(
        error.LabelTooLong,
        write(&output, .{ .hyperlinks = true }, .{ .label = &long_label, .uri = "https://example.com" }),
    );
    try std.testing.expectEqual(@as(usize, 0), output.buffered().len);
}
