//! Caller-owned z-order metadata; applications retain drawing, focus, and dispatch policy.

const std = @import("std");
const render = @import("render.zig");

pub const Id = u32;

pub const Entry = struct {
    id: Id,
    bounds: render.Rect,
    modal: bool = false,
};

pub const Hit = union(enum) {
    background,
    overlay: Id,
    modal_backdrop: Id,
};

pub const Stack = struct {
    storage: []Entry,
    len: u16 = 0,

    pub fn init(storage: []Entry) error{CapacityTooLarge}!Stack {
        if (storage.len > std.math.maxInt(u16)) return error.CapacityTooLarge;
        return .{ .storage = storage };
    }

    pub fn push(self: *Stack, entry: Entry) error{ DuplicateId, CapacityExceeded }!void {
        for (self.storage[0..self.len]) |existing| {
            if (existing.id == entry.id) return error.DuplicateId;
        }
        if (self.len == self.storage.len) return error.CapacityExceeded;
        self.storage[self.len] = entry;
        self.len += 1;
    }

    pub fn pop(self: *Stack) ?Entry {
        if (self.len == 0) return null;
        self.len -= 1;
        return self.storage[self.len];
    }

    pub inline fn count(self: *const Stack) usize {
        return self.len;
    }

    pub inline fn entries(self: *const Stack) []const Entry {
        return self.storage[0..self.len];
    }

    pub fn topModal(self: *const Stack) ?Id {
        var index = self.len;
        while (index != 0) {
            index -= 1;
            if (self.storage[index].modal) return self.storage[index].id;
        }
        return null;
    }

    pub fn hit(self: *const Stack, point: render.Point) Hit {
        var index = self.len;
        while (index != 0) {
            index -= 1;
            const entry = self.storage[index];
            if (entry.bounds.contains(point)) return .{ .overlay = entry.id };
            if (entry.modal) return .{ .modal_backdrop = entry.id };
        }
        return .background;
    }
};

test "overlay stack is LIFO and modal hits cannot leak to lower layers" {
    var storage: [4]Entry = undefined;
    var stack = try Stack.init(&storage);
    try stack.push(.{ .id = 1, .bounds = .{ .x = 0, .y = 0, .width = 8, .height = 8 } });
    try stack.push(.{ .id = 2, .bounds = .{ .x = 2, .y = 2, .width = 4, .height = 4 }, .modal = true });
    try stack.push(.{ .id = 3, .bounds = .{ .x = 3, .y = 3, .width = 1, .height = 1 } });

    try std.testing.expectEqual(Hit{ .overlay = 3 }, stack.hit(.{ .x = 3, .y = 3 }));
    try std.testing.expectEqual(Hit{ .overlay = 2 }, stack.hit(.{ .x = 2, .y = 2 }));
    try std.testing.expectEqual(Hit{ .modal_backdrop = 2 }, stack.hit(.{ .x = 0, .y = 0 }));
    try std.testing.expectEqual(@as(?Id, 2), stack.topModal());
    try stack.push(.{ .id = 4, .bounds = .{ .x = 5, .y = 5, .width = 1, .height = 1 }, .modal = true });
    try std.testing.expectEqual(Hit{ .modal_backdrop = 4 }, stack.hit(.{ .x = 2, .y = 2 }));
    try std.testing.expectEqual(Hit{ .overlay = 4 }, stack.hit(.{ .x = 5, .y = 5 }));
    try std.testing.expectEqual(@as(Id, 4), stack.pop().?.id);
    try std.testing.expectEqual(@as(Id, 3), stack.pop().?.id);
    try std.testing.expectEqual(@as(Id, 2), stack.pop().?.id);
    try std.testing.expectEqual(Hit{ .overlay = 1 }, stack.hit(.{ .x = 0, .y = 0 }));
}

test "overlay stack reports duplicate and capacity failures explicitly" {
    var storage: [1]Entry = undefined;
    var stack = try Stack.init(&storage);
    const entry = Entry{ .id = 7, .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 } };
    try stack.push(entry);
    try std.testing.expectError(error.DuplicateId, stack.push(entry));
    try std.testing.expectError(
        error.CapacityExceeded,
        stack.push(.{ .id = 8, .bounds = entry.bounds }),
    );
}
