const std = @import("std");
const grapheme = @import("../text/grapheme.zig");
const slot_index_module = @import("slot_index.zig");

pub const Glyph = u32;
pub const complex_tag: Glyph = 0x8000_0000;
const max_cluster_bytes = grapheme.max_cluster_bytes;

pub const Entry = struct {
    bytes: [max_cluster_bytes]u8 = @splat(0),
    len: u8 = 0,
    hash: u64 = 0,
    refs: usize = 0,
    slot: u32 = 0,
    next_free: u32 = std.math.maxInt(u32),
    active: bool = false,
};

pub fn requiredSlots(capacity: usize) usize {
    var result: usize = 2;
    while (result < capacity * 2) result *= 2;
    return result;
}

pub const Store = struct {
    const empty_slot: u32 = 0;
    const no_entry: u32 = std.math.maxInt(u32);

    entries: []Entry,
    slots: []u32,
    free_head: u32,

    pub fn init(entries: []Entry, slot_storage: []u32) !Store {
        if (entries.len == 0 or entries.len >= complex_tag) return error.InvalidCapacity;
        const slot_count = requiredSlots(entries.len);
        if (slot_storage.len < slot_count) return error.BufferTooSmall;
        const slots = slot_storage[0..slot_count];
        @memset(entries, .{});
        @memset(slots, empty_slot);

        var free_head = no_entry;
        var index: usize = entries.len;
        while (index > 0) {
            index -= 1;
            entries[index].next_free = free_head;
            free_head = @intCast(index);
        }
        return .{
            .entries = entries,
            .slots = slots,
            .free_head = free_head,
        };
    }

    pub fn intern(self: *Store, cluster: []const u8) error{ GraphemeTooLong, GraphemeCapacityExceeded }!Glyph {
        if (singleScalar(cluster)) |codepoint| return codepoint;
        if (cluster.len > max_cluster_bytes) return error.GraphemeTooLong;

        const hash = std.hash.Wyhash.hash(0, cluster);
        var probe: usize = 0;
        while (probe < self.slots.len) : (probe += 1) {
            const slot_index = (@as(usize, @truncate(hash)) +% probe) & (self.slots.len - 1);
            const slot = self.slots[slot_index];
            if (slot == empty_slot) return self.insert(cluster, hash, slot_index);
            const entry = &self.entries[slot - 1];
            if (entry.hash == hash and std.mem.eql(u8, entry.bytes[0..entry.len], cluster)) {
                entry.refs += 1;
                return complex_tag | (slot - 1);
            }
        }
        return error.GraphemeCapacityExceeded;
    }

    pub fn retain(self: *Store, glyph: Glyph) void {
        self.retainMany(glyph, 1);
    }

    pub fn retainMany(self: *Store, glyph: Glyph, count: usize) void {
        if (!isComplex(glyph)) return;
        self.entries[indexOf(glyph)].refs += count;
    }

    pub fn release(self: *Store, glyph: Glyph) void {
        self.releaseMany(glyph, 1);
    }

    pub fn releaseMany(self: *Store, glyph: Glyph, count: usize) void {
        if (!isComplex(glyph)) return;
        const index = indexOf(glyph);
        const entry = &self.entries[index];
        std.debug.assert(entry.active);
        std.debug.assert(entry.refs >= count);
        entry.refs -= count;
        if (entry.refs != 0) return;
        slot_index_module.remove(self.slots, self.entries, entry.slot);
        entry.active = false;
        entry.next_free = self.free_head;
        self.free_head = @intCast(index);
    }

    pub inline fn bytes(self: *const Store, glyph: Glyph, scalar_buffer: *[4]u8) []const u8 {
        if (isComplex(glyph)) {
            const entry = &self.entries[indexOf(glyph)];
            return entry.bytes[0..entry.len];
        }
        if (glyph <= 0x7F) {
            scalar_buffer[0] = @intCast(glyph);
            return scalar_buffer[0..1];
        }
        const len = std.unicode.utf8Encode(@intCast(glyph), scalar_buffer) catch unreachable;
        return scalar_buffer[0..len];
    }

    fn insert(
        self: *Store,
        cluster: []const u8,
        hash: u64,
        slot_index: usize,
    ) error{GraphemeCapacityExceeded}!Glyph {
        if (self.free_head == no_entry) return error.GraphemeCapacityExceeded;
        const index = self.free_head;
        const entry = &self.entries[index];
        self.free_head = entry.next_free;
        entry.* = .{
            .len = @intCast(cluster.len),
            .hash = hash,
            .refs = 1,
            .slot = @intCast(slot_index),
            .active = true,
        };
        @memcpy(entry.bytes[0..cluster.len], cluster);
        self.slots[slot_index] = index + 1;
        return complex_tag | index;
    }
};

pub fn isComplex(glyph: Glyph) bool {
    return glyph & complex_tag != 0;
}

fn indexOf(glyph: Glyph) usize {
    return glyph & ~complex_tag;
}

fn singleScalar(bytes: []const u8) ?u21 {
    if (bytes.len == 0) return null;
    const length = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return null;
    if (length != bytes.len) return null;
    return std.unicode.utf8Decode(bytes) catch null;
}
