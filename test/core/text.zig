const std = @import("std");
const tui = @import("tui");

const testing = std.testing;

fn expectClusters(input: []const u8, expected: []const []const u8) !void {
    var iterator = try tui.text.GraphemeIterator.init(input);
    var index: usize = 0;
    while (iterator.next()) |cluster| : (index += 1) {
        try testing.expect(index < expected.len);
        try testing.expectEqualStrings(expected[index], cluster.bytes);
    }
    try testing.expectEqual(expected.len, index);
}

test "GB11 joins pictographs with Extend before but not after ZWJ" {
    const joined = "\u{1f469}\u{200d}\u{1f469}";
    try expectClusters(joined, &.{joined});
    const extended = "\u{1f469}\u{0308}\u{200d}\u{1f469}";
    try expectClusters(extended, &.{extended});
    try expectClusters("\u{1f469}\u{200d}\u{0308}\u{1f469}", &.{
        "\u{1f469}\u{200d}\u{0308}",
        "\u{1f469}",
    });
}

test "emoji selectors preserve zero-width clusters" {
    for ([_][]const u8{ "\u{fe0f}", "\u{301}\u{fe0f}", "\u{200d}\u{fe0f}" }) |bytes| {
        try testing.expectEqual(@as(u2, 0), try tui.text.graphemeWidth(bytes, .narrow));
        try testing.expectError(error.ZeroWidthGrapheme, tui.text.measureLine(bytes, .narrow));
    }
    try testing.expectEqual(@as(u2, 2), try tui.text.graphemeWidth("\u{2764}\u{fe0f}", .narrow));
}
