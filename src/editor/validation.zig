const std = @import("std");
const grapheme = @import("../text/grapheme.zig");

pub const Newlines = enum {
    reject,
    lf,
};

pub fn validateParts(comptime newlines: Newlines, parts: anytype) error{InvalidText}!void {
    var ascii = true;
    inline for (parts) |part| {
        for (part) |byte| {
            if (byte >= 0x80) {
                ascii = false;
            } else if (byte < 0x20 or byte == 0x7f) {
                if (newlines != .lf or byte != '\n') return error.InvalidText;
            }
        }
    }
    if (ascii) return;

    var validator = Validator(newlines){};
    inline for (parts) |part| try validator.add(part);
    try validator.finish();
}

fn Validator(comptime newlines: Newlines) type {
    return struct {
        bytes: [grapheme.max_cluster_bytes + 4]u8 = undefined,
        len: usize = 0,

        fn add(self: *@This(), segment: []const u8) error{InvalidText}!void {
            var index: usize = 0;
            while (index < segment.len) {
                const scalar_len = std.unicode.utf8ByteSequenceLength(segment[index]) catch return error.InvalidText;
                if (scalar_len > segment.len - index) return error.InvalidText;
                const scalar = segment[index .. index + scalar_len];
                _ = std.unicode.utf8Decode(scalar) catch return error.InvalidText;
                index += scalar_len;

                if (scalar_len == 1 and scalar[0] == '\n') {
                    if (newlines == .reject) return error.InvalidText;
                    try self.finish();
                    continue;
                }

                const previous_len = self.len;
                @memcpy(self.bytes[self.len..][0..scalar_len], scalar);
                self.len += scalar_len;
                var clusters = grapheme.Iterator.init(self.bytes[0..self.len]) catch return error.InvalidText;
                const first = clusters.next().?;
                if (first.bytes.len == self.len) {
                    if (self.len > grapheme.max_cluster_bytes) return error.InvalidText;
                    continue;
                }
                if (first.bytes.len != previous_len) return error.InvalidText;
                try validateCluster(first);
                std.mem.copyForwards(u8, self.bytes[0..scalar_len], scalar);
                self.len = scalar_len;
            }
        }

        fn finish(self: *@This()) error{InvalidText}!void {
            if (self.len == 0) return;
            try validateCluster(.{ .bytes = self.bytes[0..self.len] });
            self.len = 0;
        }
    };
}

fn validateCluster(cluster: grapheme.Cluster) error{InvalidText}!void {
    if (cluster.bytes.len > grapheme.max_cluster_bytes) return error.InvalidText;
    const width = cluster.displayWidthAssumeValid(.narrow) catch return error.InvalidText;
    if (width == 0) return error.InvalidText;
}
