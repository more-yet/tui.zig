const std = @import("std");
const memory = @import("../core/memory.zig");

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
    std.debug.assert(!memory.slicesOverlap(storage, replacement));
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
