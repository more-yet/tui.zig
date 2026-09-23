const std = @import("std");
const memory = @import("../core/memory.zig");

pub const Entry = struct {
    offset: usize,
    len: usize,
};

pub const Error = error{
    CapacityExceeded,
    DraftCapacityExceeded,
    OverlappingInput,
    OverlappingStorage,
};

/// Bounded command history with separate caller-owned storage for the live draft.
pub const InputHistory = struct {
    entries: []Entry,
    bytes: []u8,
    draft: []u8,
    len: usize = 0,
    byte_len: usize = 0,
    navigation: ?usize = null,
    draft_len: usize = 0,

    /// Caller-owned entry, byte, and draft storage must remain fixed and
    /// pairwise disjoint for the history lifetime.
    pub fn init(entries: []Entry, bytes: []u8, draft: []u8) Error!InputHistory {
        const entry_bytes = std.mem.sliceAsBytes(entries);
        if (memory.slicesOverlap(entry_bytes, bytes) or
            memory.slicesOverlap(entry_bytes, draft) or
            memory.slicesOverlap(bytes, draft)) return error.OverlappingStorage;
        return .{ .entries = entries, .bytes = bytes, .draft = draft };
    }

    pub fn clear(self: *InputHistory) void {
        self.len = 0;
        self.byte_len = 0;
        self.resetNavigation();
    }

    pub fn count(self: *const InputHistory) usize {
        return self.len;
    }

    /// The returned slice remains borrowed until the next history mutation.
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
        if (memory.slicesOverlap(std.mem.sliceAsBytes(self.entries), value) or
            memory.slicesOverlap(self.bytes, value)) return error.OverlappingInput;
        if (self.len != 0 and std.mem.eql(u8, self.entry(self.len - 1).?, value)) {
            self.resetNavigation();
            return false;
        }
        if (self.entries.len == 0 or value.len > self.bytes.len) return error.CapacityExceeded;
        self.makeRoom(value.len);

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

    fn makeRoom(self: *InputHistory, required_bytes: usize) void {
        var remove_count: usize = 0;
        var removed_bytes: usize = 0;
        while (self.len - remove_count == self.entries.len or
            required_bytes > self.bytes.len - (self.byte_len - removed_bytes))
        {
            removed_bytes += self.entries[remove_count].len;
            remove_count += 1;
        }
        if (remove_count == 0) return;

        std.mem.copyForwards(u8, self.bytes[0 .. self.byte_len - removed_bytes], self.bytes[removed_bytes..self.byte_len]);
        std.mem.copyForwards(Entry, self.entries[0 .. self.len - remove_count], self.entries[remove_count..self.len]);
        self.len -= remove_count;
        self.byte_len -= removed_bytes;
        for (self.entries[0..self.len]) |*item| item.offset -= removed_bytes;
    }
};
