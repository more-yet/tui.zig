const std = @import("std");
const memory = @import("../core/memory.zig");

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

pub const Error = error{
    HistoryCapacityExceeded,
    OverlappingInput,
    OverlappingStorage,
};

pub const History = struct {
    records: []Record,
    bytes: []u8,
    len: usize = 0,
    cursor: usize = 0,
    byte_len: usize = 0,
    next_transaction: u64 = 1,
    active_transaction: ?u64 = null,
    transaction_depth: usize = 0,

    /// Caller-owned record and byte storage must remain fixed and disjoint for
    /// the history lifetime.
    pub fn init(records: []Record, bytes: []u8) Error!History {
        if (memory.slicesOverlap(std.mem.sliceAsBytes(records), bytes)) return error.OverlappingStorage;
        return .{ .records = records, .bytes = bytes };
    }

    pub fn storageOverlaps(self: *const History, storage: []const u8) bool {
        const record_bytes = std.mem.sliceAsBytes(self.records);
        return memory.slicesOverlap(record_bytes, self.bytes) or
            memory.slicesOverlap(record_bytes, storage) or
            memory.slicesOverlap(self.bytes, storage);
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
        std.debug.assert(self.transaction_depth != std.math.maxInt(usize));
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
        const record_bytes = std.mem.sliceAsBytes(self.records);
        if (memory.slicesOverlap(record_bytes, removed) or
            memory.slicesOverlap(record_bytes, inserted) or
            memory.slicesOverlap(self.bytes, removed) or
            memory.slicesOverlap(self.bytes, inserted)) return error.OverlappingInput;
        const required_bytes = std.math.add(usize, removed.len, inserted.len) catch return error.HistoryCapacityExceeded;
        if (self.records.len == 0 or required_bytes > self.bytes.len) return error.HistoryCapacityExceeded;

        const transaction = self.active_transaction orelse self.takeTransaction();
        if (self.active_transaction != null) {
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
        try self.makeRoom(required_bytes, transaction);

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

    /// Returned edit slices remain borrowed until the next history mutation.
    pub fn peekUndo(self: *const History) ?Edit {
        if (!self.canUndo()) return null;
        return self.view(self.records[self.cursor - 1]);
    }

    pub fn commitUndo(self: *History) void {
        std.debug.assert(self.canUndo());
        self.cursor -= 1;
    }

    /// Returned edit slices remain borrowed until the next history mutation.
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

    fn makeRoom(self: *History, required_bytes: usize, current_transaction: u64) Error!void {
        if (self.len < self.records.len and required_bytes <= self.bytes.len - self.byte_len) return;
        var remove_count: usize = 0;
        var removed_bytes: usize = 0;
        while (self.len - remove_count == self.records.len or
            required_bytes > self.bytes.len - (self.byte_len - removed_bytes))
        {
            if (remove_count == self.len or self.records[remove_count].transaction == current_transaction) {
                return error.HistoryCapacityExceeded;
            }
            const transaction = self.records[remove_count].transaction;
            while (remove_count < self.len and self.records[remove_count].transaction == transaction) {
                removed_bytes += self.recordByteLen(self.records[remove_count]);
                remove_count += 1;
            }
        }

        std.debug.assert(remove_count != 0);
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
