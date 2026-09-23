const std = @import("std");
const slot_index_module = @import("slot_index.zig");

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const Color = union(enum(u8)) {
    default,
    indexed: u8,
    rgb: Rgb,
    /// Exact protocol data. Unlike ordinary RGB, this is never quantized.
    protocol_rgb: Rgb,
};

pub const Attributes = packed struct(u8) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverse: bool = false,
    hidden: bool = false,
    strike: bool = false,
};

pub const Style = struct {
    foreground: Color = .default,
    background: Color = .default,
    underline_color: Color = .default,
    attributes: Attributes = .{},

    pub fn eql(lhs: Style, rhs: Style) bool {
        return colorEql(lhs.foreground, rhs.foreground) and
            colorEql(lhs.background, rhs.background) and
            colorEql(lhs.underline_color, rhs.underline_color) and
            @as(u8, @bitCast(lhs.attributes)) == @as(u8, @bitCast(rhs.attributes));
    }

    fn hash(self: Style) u64 {
        var bytes: [13]u8 = @splat(0);
        encodeColor(self.foreground, bytes[0..4]);
        encodeColor(self.background, bytes[4..8]);
        encodeColor(self.underline_color, bytes[8..12]);
        bytes[12] = @bitCast(self.attributes);
        return std.hash.Wyhash.hash(0, &bytes);
    }
};

pub const Id = u16;

pub const Entry = struct {
    style: Style = .{},
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

pub const Table = struct {
    const empty_slot: u32 = 0;
    const no_entry: u32 = std.math.maxInt(u32);

    entries: []Entry,
    slots: []u32,
    free_head: u32,

    pub fn init(entries: []Entry, slot_storage: []u32) !Table {
        if (entries.len == 0 or entries.len > std.math.maxInt(u16)) return error.InvalidCapacity;
        const slot_count = requiredSlots(entries.len);
        if (slot_storage.len < slot_count) return error.BufferTooSmall;
        const slots = slot_storage[0..slot_count];
        @memset(slots, empty_slot);
        @memset(entries, .{});

        entries[0] = .{ .style = .{}, .hash = (Style{}).hash(), .active = true };
        var free_head = no_entry;
        var index: usize = entries.len;
        while (index > 1) {
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

    pub fn intern(self: *Table, style: Style) error{StyleCapacityExceeded}!Id {
        if (style.eql(.{})) return 0;
        const hash = style.hash();
        var probe: usize = 0;
        while (probe < self.slots.len) : (probe += 1) {
            const candidate = (@as(usize, @truncate(hash)) +% probe) & (self.slots.len - 1);
            const slot = self.slots[candidate];
            if (slot == empty_slot) return self.insert(style, hash);
            const entry = &self.entries[slot - 1];
            if (entry.hash == hash and entry.style.eql(style)) {
                entry.refs += 1;
                return @intCast(slot - 1);
            }
        }
        return error.StyleCapacityExceeded;
    }

    pub fn retain(self: *Table, id: Id) void {
        if (id == 0) return;
        self.entries[id].refs += 1;
    }

    pub fn retainMany(self: *Table, id: Id, count: usize) void {
        if (id == 0) return;
        self.entries[id].refs += count;
    }

    pub fn release(self: *Table, id: Id) void {
        self.releaseMany(id, 1);
    }

    pub fn releaseMany(self: *Table, id: Id, count: usize) void {
        if (id == 0) return;
        const entry = &self.entries[id];
        std.debug.assert(entry.active);
        std.debug.assert(entry.refs >= count);
        entry.refs -= count;
    }

    pub fn get(self: *const Table, id: Id) Style {
        return self.entries[id].style;
    }

    fn insert(self: *Table, style: Style, hash: u64) error{StyleCapacityExceeded}!Id {
        const index = if (self.free_head != no_entry) index: {
            const free = self.free_head;
            self.free_head = self.entries[free].next_free;
            break :index free;
        } else self.evict() orelse return error.StyleCapacityExceeded;
        const destination = self.findEmptySlot(hash);
        const entry = &self.entries[index];
        entry.* = .{
            .style = style,
            .hash = hash,
            .refs = 1,
            .slot = @intCast(destination),
            .active = true,
        };
        self.slots[destination] = index + 1;
        return @intCast(index);
    }

    fn findEmptySlot(self: *const Table, hash: u64) usize {
        var probe: usize = 0;
        while (probe < self.slots.len) : (probe += 1) {
            const candidate = (@as(usize, @truncate(hash)) +% probe) & (self.slots.len - 1);
            if (self.slots[candidate] == empty_slot) return candidate;
        }
        unreachable;
    }

    fn evict(self: *Table) ?u32 {
        for (self.entries[1..], 1..) |*entry, index| {
            if (!entry.active or entry.refs != 0) continue;
            slot_index_module.remove(self.slots, self.entries, entry.slot);
            return @intCast(index);
        }
        return null;
    }
};

fn colorEql(lhs: Color, rhs: Color) bool {
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
    return switch (lhs) {
        .default => true,
        .indexed => |value| value == rhs.indexed,
        .rgb => |value| value.r == rhs.rgb.r and value.g == rhs.rgb.g and value.b == rhs.rgb.b,
        .protocol_rgb => |value| value.r == rhs.protocol_rgb.r and
            value.g == rhs.protocol_rgb.g and value.b == rhs.protocol_rgb.b,
    };
}

fn encodeColor(color: Color, output: []u8) void {
    output[0] = @intFromEnum(std.meta.activeTag(color));
    switch (color) {
        .default => {},
        .indexed => |value| output[1] = value,
        .rgb => |value| {
            output[1] = value.r;
            output[2] = value.g;
            output[3] = value.b;
        },
        .protocol_rgb => |value| {
            output[1] = value.r;
            output[2] = value.g;
            output[3] = value.b;
        },
    }
}
