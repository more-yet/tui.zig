const std = @import("std");
const tui = @import("tui");
const unicode_test_data = @import("unicode_test_data");

const grapheme_break_tests = unicode_test_data.grapheme_break_test;
const line_break_tests = unicode_test_data.line_break_test;

test "Unicode 17 extended grapheme conformance" {
    var lines = std.mem.splitScalar(u8, grapheme_break_tests, '\n');
    var line_number: usize = 0;
    while (lines.next()) |raw_line| {
        line_number += 1;
        const comment = std.mem.indexOfScalar(u8, raw_line, '#') orelse raw_line.len;
        const line = std.mem.trim(u8, raw_line[0..comment], " \t\r");
        if (line.len == 0) continue;

        var encoded: [1024]u8 = undefined;
        var encoded_len: usize = 0;
        var expected: [128]usize = undefined;
        var expected_len: usize = 0;

        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        while (tokens.next()) |token| {
            if (std.mem.eql(u8, token, "\xC3\xB7")) {
                expected[expected_len] = encoded_len;
                expected_len += 1;
            } else if (!std.mem.eql(u8, token, "\xC3\x97")) {
                const codepoint = try std.fmt.parseInt(u21, token, 16);
                encoded_len += try std.unicode.utf8Encode(codepoint, encoded[encoded_len..]);
            }
        }

        var actual: [128]usize = undefined;
        var actual_len: usize = 1;
        actual[0] = 0;
        var iterator = try tui.text.GraphemeIterator.init(encoded[0..encoded_len]);
        while (iterator.next()) |cluster| {
            actual[actual_len] = actual[actual_len - 1] + cluster.bytes.len;
            actual_len += 1;
        }

        if (!std.mem.eql(usize, expected[0..expected_len], actual[0..actual_len])) {
            std.debug.print("grapheme conformance mismatch on data line {d}\n", .{line_number});
            try std.testing.expectEqualSlices(usize, expected[0..expected_len], actual[0..actual_len]);
        }
    }
}

test "Unicode 17 default line break conformance" {
    var lines = std.mem.splitScalar(u8, line_break_tests, '\n');
    var line_number: usize = 0;
    while (lines.next()) |raw_line| {
        line_number += 1;
        const comment = std.mem.indexOfScalar(u8, raw_line, '#') orelse raw_line.len;
        const line = std.mem.trim(u8, raw_line[0..comment], " \t\r");
        if (line.len == 0) continue;

        var encoded: [1024]u8 = undefined;
        var encoded_len: usize = 0;
        var expected_offsets: [256]usize = undefined;
        var expected_allowed: [256]bool = undefined;
        var expected_len: usize = 0;
        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        while (tokens.next()) |token| {
            if (std.mem.eql(u8, token, "\xC3\xB7") or std.mem.eql(u8, token, "\xC3\x97")) {
                expected_offsets[expected_len] = encoded_len;
                expected_allowed[expected_len] = std.mem.eql(u8, token, "\xC3\xB7");
                expected_len += 1;
            } else {
                const codepoint = try std.fmt.parseInt(u21, token, 16);
                encoded_len += try std.unicode.utf8Encode(codepoint, encoded[encoded_len..]);
            }
        }

        var iterator = try tui.text.LineBreakIterator.init(encoded[0..encoded_len]);
        var index: usize = 0;
        while (iterator.next()) |boundary| : (index += 1) {
            if (index >= expected_len or
                boundary.offset != expected_offsets[index] or
                (boundary.kind != .prohibited) != expected_allowed[index])
            {
                std.debug.print("line break conformance mismatch on data line {d}, boundary {d}\n", .{ line_number, index });
                try std.testing.expect(index < expected_len);
                try std.testing.expectEqual(expected_offsets[index], boundary.offset);
                try std.testing.expectEqual(expected_allowed[index], boundary.kind != .prohibited);
            }
        }
        try std.testing.expectEqual(expected_len, index);
    }
}
