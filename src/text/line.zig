const std = @import("std");
const grapheme = @import("grapheme.zig");

pub const Alignment = enum {
    left,
    center,
    right,
};

pub const Overflow = enum {
    clip,
    ellipsis,
};

pub const Options = struct {
    alignment: Alignment = .left,
    overflow: Overflow = .clip,
};

pub const Layout = struct {
    prefix: []const u8,
    offset: u16,
    width: u16,
    ellipsis: bool,
};

pub const Error = grapheme.WidthError || error{ GraphemeTooLong, ZeroWidthGrapheme, WidthOverflow };

pub const ellipsis = "\xE2\x80\xA6";

pub inline fn ellipsisWidth(width_profile: grapheme.WidthProfile) u16 {
    return if (width_profile == .wide_ambiguous) 2 else 1;
}

pub fn measure(text: []const u8, width_profile: grapheme.WidthProfile) Error!usize {
    return (try analyze(text, width_profile, 0, 0)).total_width;
}

pub fn layout(
    text: []const u8,
    available: u16,
    width_profile: grapheme.WidthProfile,
    options: Options,
) Error!Layout {
    const marker_width = ellipsisWidth(width_profile);
    const prefix_limit = if (options.overflow == .ellipsis and marker_width <= available)
        available - marker_width
    else
        0;
    const analysis = try analyze(text, width_profile, available, prefix_limit);

    var result: Layout = if (analysis.total_width <= available)
        .{
            .prefix = text,
            .offset = 0,
            .width = @intCast(analysis.total_width),
            .ellipsis = false,
        }
    else switch (options.overflow) {
        .clip => .{
            .prefix = text[0..analysis.clipped_end],
            .offset = 0,
            .width = analysis.clipped_width,
            .ellipsis = false,
        },
        .ellipsis => if (marker_width <= available)
            .{
                .prefix = text[0..analysis.ellipsis_end],
                .offset = 0,
                .width = analysis.ellipsis_prefix_width + marker_width,
                .ellipsis = true,
            }
        else
            .{ .prefix = "", .offset = 0, .width = 0, .ellipsis = false },
    };

    const remaining = available - result.width;
    result.offset = switch (options.alignment) {
        .left => 0,
        .center => remaining / 2,
        .right => remaining,
    };
    return result;
}

const Analysis = struct {
    total_width: usize = 0,
    clipped_end: usize = 0,
    clipped_width: u16 = 0,
    ellipsis_end: usize = 0,
    ellipsis_prefix_width: u16 = 0,
};

fn analyze(
    text: []const u8,
    width_profile: grapheme.WidthProfile,
    clip_limit: u16,
    ellipsis_limit: u16,
) Error!Analysis {
    var ascii = true;
    for (text) |byte| {
        if (byte < 0x20 or byte == 0x7F) return error.ControlCharacter;
        if (byte > 0x7E) {
            ascii = false;
            break;
        }
    }
    if (ascii) {
        const clipped_width: u16 = @intCast(@min(text.len, clip_limit));
        const ellipsis_prefix_width: u16 = @intCast(@min(text.len, ellipsis_limit));
        return .{
            .total_width = text.len,
            .clipped_end = clipped_width,
            .clipped_width = clipped_width,
            .ellipsis_end = ellipsis_prefix_width,
            .ellipsis_prefix_width = ellipsis_prefix_width,
        };
    }

    var result: Analysis = .{};
    var iterator = try grapheme.Iterator.init(text);
    while (iterator.next()) |cluster| {
        if (cluster.bytes.len > grapheme.max_cluster_bytes) return error.GraphemeTooLong;
        const width = try cluster.displayWidthAssumeValid(width_profile);
        if (width == 0) return error.ZeroWidthGrapheme;
        result.total_width = std.math.add(usize, result.total_width, width) catch return error.WidthOverflow;
        const byte_end = @intFromPtr(cluster.bytes.ptr) - @intFromPtr(text.ptr) + cluster.bytes.len;
        if (result.total_width <= clip_limit) {
            result.clipped_end = byte_end;
            result.clipped_width = @intCast(result.total_width);
        }
        if (result.total_width <= ellipsis_limit) {
            result.ellipsis_end = byte_end;
            result.ellipsis_prefix_width = @intCast(result.total_width);
        }
    }
    return result;
}

test "line measurement and layout preserve grapheme boundaries" {
    try std.testing.expectEqual(@as(usize, 4), try measure("Ae\xCC\x81\xE7\x95\x8C", .narrow));

    const clipped = try layout("A\xE7\x95\x8CB", 2, .narrow, .{});
    try std.testing.expectEqualStrings("A", clipped.prefix);
    try std.testing.expectEqual(@as(u16, 1), clipped.width);
    try std.testing.expect(!clipped.ellipsis);

    const shortened = try layout("abcdef", 4, .narrow, .{ .overflow = .ellipsis });
    try std.testing.expectEqualStrings("abc", shortened.prefix);
    try std.testing.expectEqual(@as(u16, 4), shortened.width);
    try std.testing.expect(shortened.ellipsis);
}

test "line alignment uses the rendered width" {
    try std.testing.expectEqual(
        ellipsisWidth(.wide_ambiguous),
        @as(u16, try grapheme.width(ellipsis, .wide_ambiguous)),
    );
    const centered = try layout("ab", 7, .narrow, .{ .alignment = .center });
    try std.testing.expectEqual(@as(u16, 2), centered.offset);

    const right = try layout("ab", 7, .narrow, .{ .alignment = .right });
    try std.testing.expectEqual(@as(u16, 5), right.offset);

    const wide_marker = try layout("abcdef", 1, .wide_ambiguous, .{ .overflow = .ellipsis });
    try std.testing.expectEqualStrings("", wide_marker.prefix);
    try std.testing.expectEqual(@as(u16, 0), wide_marker.width);
    try std.testing.expect(!wide_marker.ellipsis);
}

test "line layout rejects unsafe or malformed text" {
    try std.testing.expectError(error.ControlCharacter, layout("safe\x1b[31m", 20, .narrow, .{}));
    try std.testing.expectError(error.ControlCharacter, layout("\xC3\xA9\x1b[31m", 20, .narrow, .{}));
    try std.testing.expectError(error.InvalidUtf8, layout("\xC0\x80", 20, .narrow, .{}));
    try std.testing.expectError(error.ZeroWidthGrapheme, layout("\xCC\x81", 20, .narrow, .{}));
}
