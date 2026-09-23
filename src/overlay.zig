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
