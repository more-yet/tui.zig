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

test "GB11 joins an extended pictograph immediately following ZWJ" {
    const input = "\u{1f469}\u{200d}\u{1f469}";
    const expected = [_][]const u8{input};
    try expectClusters(input, &expected);
}

test "GB11 permits Extend before ZWJ" {
    const input = "\u{1f469}\u{0308}\u{200d}\u{1f469}";
    const expected = [_][]const u8{input};
    try expectClusters(input, &expected);
}

test "GB11 does not skip Extend after ZWJ" {
    const input = "\u{1f469}\u{200d}\u{0308}\u{1f469}";
    const expected = [_][]const u8{
        "\u{1f469}\u{200d}\u{0308}",
        "\u{1f469}",
    };
    try expectClusters(input, &expected);
}
