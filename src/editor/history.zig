const std = @import("std");

pub const Policy = enum {
    reject,
    evict_oldest,
};

pub const State = struct {
    cursor: usize,
    anchor: ?usize,
};

pub const Record = struct {
    start: usize,
    removed_offset: usize,
    removed_len: usize,
    inserted_offset: usize,
    inserted_len: usize,
    before: State,
    after: State = .{ .cursor = 0, .anchor = null },
    transaction: u64,
};

pub const Edit = struct {
    start: usize,
    removed: []const u8,
    inserted: []const u8,
    before: State,
    after: State,
    transaction: u64,
};

pub const Error = error{HistoryCapacityExceeded};

pub const History = struct {
    records: []Record,
    bytes: []u8,
    policy: Policy,
    len: usize = 0,
    cursor: usize = 0,
    byte_len: usize = 0,
    next_transaction: u64 = 1,
    active_transaction: ?u64 = null,
    transaction_depth: usize = 0,

    pub fn init(records: []Record, bytes: []u8, policy: Policy) History {
        return .{ .records = records, .bytes = bytes, .policy = policy };
    }

    pub fn clear(self: *History) void {
        self.len = 0;
        self.cursor = 0;
        self.byte_len = 0;
        self.next_transaction = 1;
        self.active_transaction = null;
        self.transaction_depth = 0;
    }

    pub fn canUndo(self: *const History) bool {
        return self.cursor != 0;
    }

    pub fn canRedo(self: *const History) bool {
        return self.cursor != self.len;
    }

    pub fn beginTransaction(self: *History) void {
        if (self.transaction_depth == 0) self.active_transaction = self.takeTransaction();
        self.transaction_depth += 1;
    }

    pub fn endTransaction(self: *History) void {
        if (self.transaction_depth == 0) return;
        self.transaction_depth -= 1;
        if (self.transaction_depth == 0) self.active_transaction = null;
    }

    pub fn record(
        self: *History,
        start: usize,
        removed: []const u8,
        inserted: []const u8,
        before: State,
    ) Error!usize {
        const required_bytes = removed.len + inserted.len;
        if (self.records.len == 0 or required_bytes > self.bytes.len) return error.HistoryCapacityExceeded;

        const transaction = self.active_transaction orelse self.takeTransaction();
        if (self.policy == .reject) {
            const retained_bytes = self.appliedByteLen();
            if (self.cursor == self.records.len or required_bytes > self.bytes.len - retained_bytes) {
                return error.HistoryCapacityExceeded;
            }
        } else if (self.active_transaction != null) {
            var transaction_records: usize = 0;
            var transaction_bytes: usize = 0;
            var index = self.cursor;
            while (index != 0 and self.records[index - 1].transaction == transaction) {
                index -= 1;
                transaction_records += 1;
                transaction_bytes += self.recordByteLen(self.records[index]);
            }
            if (transaction_records == self.records.len or required_bytes > self.bytes.len - transaction_bytes) {
                return error.HistoryCapacityExceeded;
            }
        }

        self.truncateRedo();
        while (self.len == self.records.len or required_bytes > self.bytes.len - self.byte_len) {
            if (self.policy == .reject) return error.HistoryCapacityExceeded;
            if (self.len == 0 or self.records[0].transaction == transaction) return error.HistoryCapacityExceeded;
            self.evictOldestTransaction();
        }

        const index = self.len;
        const removed_offset = self.byte_len;
        @memcpy(self.bytes[removed_offset .. removed_offset + removed.len], removed);
        const inserted_offset = removed_offset + removed.len;
        @memcpy(self.bytes[inserted_offset .. inserted_offset + inserted.len], inserted);
        self.byte_len += required_bytes;
        self.records[index] = .{
            .start = start,
            .removed_offset = removed_offset,
            .removed_len = removed.len,
            .inserted_offset = inserted_offset,
            .inserted_len = inserted.len,
            .before = before,
            .transaction = transaction,
        };
        self.len += 1;
        self.cursor = self.len;
        return index;
    }

    pub fn finish(self: *History, index: usize, after: State) void {
        std.debug.assert(index < self.len);
        self.records[index].after = after;
    }

    pub fn peekUndo(self: *const History) ?Edit {
        if (!self.canUndo()) return null;
        return self.view(self.records[self.cursor - 1]);
    }

    pub fn commitUndo(self: *History) void {
        std.debug.assert(self.canUndo());
        self.cursor -= 1;
    }

    pub fn peekRedo(self: *const History) ?Edit {
        if (!self.canRedo()) return null;
        return self.view(self.records[self.cursor]);
    }

    pub fn commitRedo(self: *History) void {
        std.debug.assert(self.canRedo());
        self.cursor += 1;
    }

    fn view(self: *const History, item: Record) Edit {
        return .{
            .start = item.start,
            .removed = self.bytes[item.removed_offset .. item.removed_offset + item.removed_len],
            .inserted = self.bytes[item.inserted_offset .. item.inserted_offset + item.inserted_len],
            .before = item.before,
            .after = item.after,
            .transaction = item.transaction,
        };
    }

    fn takeTransaction(self: *History) u64 {
        const transaction = self.next_transaction;
        self.next_transaction +%= 1;
        return transaction;
    }

    fn truncateRedo(self: *History) void {
        self.len = self.cursor;
        self.byte_len = self.appliedByteLen();
    }

    fn appliedByteLen(self: *const History) usize {
        if (self.cursor == 0) return 0;
        const last = self.records[self.cursor - 1];
        return last.inserted_offset + last.inserted_len;
    }

    fn recordByteLen(_: *const History, item: Record) usize {
        return item.removed_len + item.inserted_len;
    }

    fn evictOldestTransaction(self: *History) void {
        std.debug.assert(self.len != 0 and self.cursor == self.len);
        const transaction = self.records[0].transaction;
        var remove_count: usize = 1;
        while (remove_count < self.len and self.records[remove_count].transaction == transaction) {
            remove_count += 1;
        }
        const first_retained_byte = if (remove_count == self.len)
            self.byte_len
        else
            self.records[remove_count].removed_offset;
        const removed_bytes = first_retained_byte;
        std.mem.copyForwards(u8, self.bytes[0 .. self.byte_len - removed_bytes], self.bytes[removed_bytes..self.byte_len]);
        std.mem.copyForwards(Record, self.records[0 .. self.len - remove_count], self.records[remove_count..self.len]);
        self.len -= remove_count;
        self.cursor = self.len;
        self.byte_len -= removed_bytes;
        for (self.records[0..self.len]) |*item| {
            item.removed_offset -= removed_bytes;
            item.inserted_offset -= removed_bytes;
        }
    }
};

test "history rejects or evicts complete transactions deterministically" {
    var records: [2]Record = undefined;
    var reject_bytes: [4]u8 = undefined;
    var rejected = History.init(&records, &reject_bytes, .reject);
    const first = try rejected.record(0, "", "ab", .{ .cursor = 0, .anchor = null });
    rejected.finish(first, .{ .cursor = 2, .anchor = null });
    try std.testing.expectError(
        error.HistoryCapacityExceeded,
        rejected.record(2, "", "cde", .{ .cursor = 2, .anchor = null }),
    );
    try std.testing.expectEqualStrings("ab", rejected.peekUndo().?.inserted);

    var evict_bytes: [6]u8 = undefined;
    var evicted = History.init(&records, &evict_bytes, .evict_oldest);
    const old = try evicted.record(0, "", "ab", .{ .cursor = 0, .anchor = null });
    evicted.finish(old, .{ .cursor = 2, .anchor = null });
    const recent = try evicted.record(2, "", "cd", .{ .cursor = 2, .anchor = null });
    evicted.finish(recent, .{ .cursor = 4, .anchor = null });
    const newest = try evicted.record(2, "cd", "x", .{ .cursor = 4, .anchor = null });
    evicted.finish(newest, .{ .cursor = 3, .anchor = null });
    try std.testing.expectEqualStrings("x", evicted.peekUndo().?.inserted);
    evicted.commitUndo();
    try std.testing.expectEqualStrings("cd", evicted.peekUndo().?.inserted);
}

test "history preserves transaction boundaries" {
    var records: [4]Record = undefined;
    var bytes: [8]u8 = undefined;
    var value = History.init(&records, &bytes, .evict_oldest);
    value.beginTransaction();
    const first = try value.record(0, "", "a", .{ .cursor = 0, .anchor = null });
    value.finish(first, .{ .cursor = 1, .anchor = null });
    const second = try value.record(1, "", "b", .{ .cursor = 1, .anchor = null });
    value.finish(second, .{ .cursor = 2, .anchor = null });
    value.endTransaction();
    try std.testing.expectEqual(value.peekUndo().?.transaction, value.records[0].transaction);
}
