const std = @import("std");
const history = @import("history.zig");

pub const Entry = struct {
    offset: usize,
    len: usize,
};

pub const Error = error{
    CapacityExceeded,
    DraftCapacityExceeded,
    OverlappingInput,
};

/// Bounded command history with separate caller-owned storage for the live draft.
pub const InputHistory = struct {
    entries: []Entry,
    bytes: []u8,
    draft: []u8,
    policy: history.Policy,
    len: usize = 0,
    byte_len: usize = 0,
    navigation: ?usize = null,
    draft_len: usize = 0,

    pub fn init(entries: []Entry, bytes: []u8, draft: []u8, policy: history.Policy) InputHistory {
        return .{ .entries = entries, .bytes = bytes, .draft = draft, .policy = policy };
    }

    pub fn clear(self: *InputHistory) void {
        self.len = 0;
        self.byte_len = 0;
        self.resetNavigation();
    }

    pub fn count(self: *const InputHistory) usize {
        return self.len;
    }

    pub fn entry(self: *const InputHistory, index: usize) ?[]const u8 {
        if (index >= self.len) return null;
        const item = self.entries[index];
        return self.bytes[item.offset .. item.offset + item.len];
    }

    /// Appends a non-empty entry. Consecutive duplicates are deliberately ignored.
    pub fn push(self: *InputHistory, value: []const u8) Error!bool {
        if (value.len == 0) {
            self.resetNavigation();
            return false;
        }
        if (slicesOverlap(self.bytes, value)) return error.OverlappingInput;
        if (self.len != 0 and std.mem.eql(u8, self.entry(self.len - 1).?, value)) {
            self.resetNavigation();
            return false;
        }
        if (self.entries.len == 0 or value.len > self.bytes.len) return error.CapacityExceeded;
        if (self.policy == .reject and (self.len == self.entries.len or value.len > self.bytes.len - self.byte_len)) {
            return error.CapacityExceeded;
        }
        while (self.len == self.entries.len or value.len > self.bytes.len - self.byte_len) self.evictOldest();

        self.entries[self.len] = .{ .offset = self.byte_len, .len = value.len };
        @memcpy(self.bytes[self.byte_len .. self.byte_len + value.len], value);
        self.byte_len += value.len;
        self.len += 1;
        self.resetNavigation();
        return true;
    }

    /// Saves `current` as the draft on first use and returns the preceding entry.
    pub fn previous(self: *InputHistory, current: []const u8) Error!?[]const u8 {
        if (self.len == 0) return null;
        if (self.navigation == null) {
            if (current.len > self.draft.len) return error.DraftCapacityExceeded;
            @memmove(self.draft[0..current.len], current);
            self.draft_len = current.len;
            self.navigation = self.len - 1;
        } else if (self.navigation.? != 0) {
            self.navigation.? -= 1;
        }
        return self.entry(self.navigation.?);
    }

    /// Returns the following entry, then the saved draft after the newest entry.
    pub fn next(self: *InputHistory) ?[]const u8 {
        const index = self.navigation orelse return null;
        if (index + 1 < self.len) {
            self.navigation = index + 1;
            return self.entry(index + 1);
        }
        self.navigation = null;
        return self.draft[0..self.draft_len];
    }

    pub fn resetNavigation(self: *InputHistory) void {
        self.navigation = null;
        self.draft_len = 0;
    }

    fn evictOldest(self: *InputHistory) void {
        std.debug.assert(self.len != 0);
        const removed = self.entries[0].len;
        std.mem.copyForwards(u8, self.bytes[0 .. self.byte_len - removed], self.bytes[removed..self.byte_len]);
        std.mem.copyForwards(Entry, self.entries[0 .. self.len - 1], self.entries[1..self.len]);
        self.len -= 1;
        self.byte_len -= removed;
        for (self.entries[0..self.len]) |*item| item.offset -= removed;
    }
};

fn slicesOverlap(storage: []const u8, value: []const u8) bool {
    if (storage.len == 0 or value.len == 0) return false;
    const storage_start = @intFromPtr(storage.ptr);
    const storage_end = storage_start + storage.len;
    const value_start = @intFromPtr(value.ptr);
    const value_end = value_start + value.len;
    return storage_start < value_end and value_start < storage_end;
}

test "input history evicts entries and restores the live draft" {
    var entries: [3]Entry = undefined;
    var bytes: [12]u8 = undefined;
    var draft: [8]u8 = undefined;
    var value = InputHistory.init(&entries, &bytes, &draft, .evict_oldest);
    try std.testing.expect(try value.push("one"));
    try std.testing.expect(try value.push("two"));
    try std.testing.expect(try value.push("three"));
    try std.testing.expectEqualStrings("three", (try value.previous("draft")).?);
    try std.testing.expectEqualStrings("two", (try value.previous("ignored")).?);
    try std.testing.expectEqualStrings("three", value.next().?);
    try std.testing.expectEqualStrings("draft", value.next().?);
    try std.testing.expect(value.next() == null);
}

test "input history reject policy preserves existing entries" {
    var entries: [1]Entry = undefined;
    var bytes: [4]u8 = undefined;
    var draft: [4]u8 = undefined;
    var value = InputHistory.init(&entries, &bytes, &draft, .reject);
    try std.testing.expect(try value.push("one"));
    try std.testing.expectError(error.CapacityExceeded, value.push("two"));
    try std.testing.expectEqualStrings("one", value.entry(0).?);
}
