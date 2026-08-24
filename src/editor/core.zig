const std = @import("std");
const grapheme = @import("../text/grapheme.zig");

pub const Selection = struct {
    start: usize,
    end: usize,
};

pub const Splice = struct {
    target: usize,
    new_len: usize,
};

pub inline fn selection(anchor: ?usize, cursor: usize) ?Selection {
    const start = anchor orelse return null;
    if (start == cursor) return null;
    return .{ .start = @min(start, cursor), .end = @max(start, cursor) };
}

/// Replaces a prevalidated range. The caller must preflight overlap and capacity.
pub fn splice(
    storage: []u8,
    len: usize,
    start: usize,
    end: usize,
    replacement: []const u8,
) Splice {
    std.debug.assert(start <= end and end <= len);
    std.debug.assert(!slicesOverlap(storage, replacement));
    std.debug.assert(replacement.len <= storage.len - (len - (end - start)));

    const tail_len = len - end;
    const target = start + replacement.len;
    const new_len = len - (end - start) + replacement.len;
    if (target < end) {
        std.mem.copyForwards(u8, storage[target .. target + tail_len], storage[end..len]);
    } else if (target > end) {
        std.mem.copyBackwards(u8, storage[target .. target + tail_len], storage[end..len]);
    }
    @memcpy(storage[start..target], replacement);
    return .{ .target = target, .new_len = new_len };
}

pub fn previousBoundary(
    value: []const u8,
    cursor: usize,
    range_start: usize,
    range_end: usize,
) usize {
    std.debug.assert(range_start <= cursor and cursor <= range_end and range_end <= value.len);
    if (cursor == 0) return 0;
    if (cursor == range_start) return cursor - 1;
    if (value[cursor - 1] < 0x80 and (cursor == range_start + 1 or value[cursor - 2] < 0x80)) return cursor - 1;
    var previous = range_start;
    var iterator = grapheme.Iterator.init(value[range_start..range_end]) catch unreachable;
    while (iterator.next()) |cluster| {
        const cluster_end = @intFromPtr(cluster.bytes.ptr) - @intFromPtr(value.ptr) + cluster.bytes.len;
        if (cluster_end >= cursor) return previous;
        previous = cluster_end;
    }
    return previous;
}

pub fn nextBoundary(
    value: []const u8,
    cursor: usize,
    range_start: usize,
    range_end: usize,
) usize {
    std.debug.assert(range_start <= cursor and cursor <= range_end and range_end <= value.len);
    if (cursor == value.len) return value.len;
    if (cursor == range_end) return cursor + 1;
    if (value[cursor] < 0x80 and (cursor + 1 == range_end or value[cursor + 1] < 0x80)) return cursor + 1;
    var iterator = grapheme.Iterator.init(value[range_start..range_end]) catch unreachable;
    while (iterator.next()) |cluster| {
        const start = @intFromPtr(cluster.bytes.ptr) - @intFromPtr(value.ptr);
        if (start == cursor) return start + cluster.bytes.len;
    }
    unreachable;
}

pub fn isBoundary(value: []const u8, offset: usize, range_start: usize, range_end: usize) bool {
    if (offset > value.len or range_start > offset or offset > range_end or range_end > value.len) return false;
    if (offset == range_start or offset == range_end) return true;
    if (value[offset - 1] < 0x80 and value[offset] < 0x80) return true;
    var iterator = grapheme.Iterator.init(value[range_start..range_end]) catch unreachable;
    while (iterator.next()) |cluster| {
        const end = @intFromPtr(cluster.bytes.ptr) - @intFromPtr(value.ptr) + cluster.bytes.len;
        if (end == offset) return true;
        if (end > offset) return false;
    }
    return false;
}

pub fn slicesOverlap(storage: []const u8, source: []const u8) bool {
    if (storage.len == 0 or source.len == 0) return false;
    const storage_start = @intFromPtr(storage.ptr);
    const source_start = @intFromPtr(source.ptr);
    const storage_end = std.math.add(usize, storage_start, storage.len) catch return true;
    const source_end = std.math.add(usize, source_start, source.len) catch return true;
    return source_start < storage_end and storage_start < source_end;
}

pub fn utf8PrefixAtMost(value: []const u8, maximum: usize) usize {
    var end = @min(value.len, maximum);
    while (end != 0 and end < value.len and value[end] & 0xc0 == 0x80) end -= 1;
    return end;
}

test "shared edit primitives splice and preserve grapheme boundaries" {
    var storage: [16]u8 = undefined;
    @memcpy(storage[0..4], "a\xC3\xA9b");
    try std.testing.expectEqual(@as(usize, 1), previousBoundary(storage[0..4], 3, 0, 4));
    try std.testing.expectEqual(@as(usize, 3), nextBoundary(storage[0..4], 1, 0, 4));
    try std.testing.expect(isBoundary(storage[0..4], 3, 0, 4));
    const result = splice(&storage, 4, 1, 3, "xy");
    try std.testing.expectEqualStrings("axyb", storage[0..result.new_len]);
}
