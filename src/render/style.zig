const std = @import("std");

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const Color = union(enum(u8)) {
    default,
    indexed: u8,
    rgb: Rgb,
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
    attributes: Attributes = .{},

    pub fn eql(lhs: Style, rhs: Style) bool {
        return colorEql(lhs.foreground, rhs.foreground) and
            colorEql(lhs.background, rhs.background) and
            @as(u8, @bitCast(lhs.attributes)) == @as(u8, @bitCast(rhs.attributes));
    }

    fn hash(self: Style) u64 {
        var bytes: [9]u8 = @splat(0);
        encodeColor(self.foreground, bytes[0..4]);
        encodeColor(self.background, bytes[4..8]);
        bytes[8] = @bitCast(self.attributes);
        return std.hash.Wyhash.hash(0, &bytes);
    }
};

pub const Id = u16;

pub const Table = struct {
    const empty_slot: u32 = 0;
    const tombstone: u32 = std.math.maxInt(u32);
    const no_entry: u32 = std.math.maxInt(u32);

    const Entry = struct {
        style: Style = .{},
        hash: u64 = 0,
        refs: usize = 0,
        slot: u32 = 0,
        next_free: u32 = no_entry,
        active: bool = false,
    };

    allocator: std.mem.Allocator,
    entries: []Entry,
    slots: []u32,
    free_head: u32,
    revision: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: u16) !Table {
        if (capacity == 0) return error.InvalidCapacity;
        const entries = try allocator.alloc(Entry, capacity);
        errdefer allocator.free(entries);
        const slot_count = hashCapacity(capacity);
        const slots = try allocator.alloc(u32, slot_count);
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
            .allocator = allocator,
            .entries = entries,
            .slots = slots,
            .free_head = free_head,
        };
    }

    pub fn deinit(self: *Table) void {
        self.allocator.free(self.slots);
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn intern(self: *Table, style: Style) error{StyleCapacityExceeded}!Id {
        if (style.eql(.{})) return 0;
        const hash = style.hash();
        var first_tombstone: ?usize = null;
        var probe: usize = 0;
        while (probe < self.slots.len) : (probe += 1) {
            const slot_index = (@as(usize, @truncate(hash)) + probe) & (self.slots.len - 1);
            const slot = self.slots[slot_index];
            if (slot == empty_slot) return self.insert(style, hash, first_tombstone orelse slot_index);
            if (slot == tombstone) {
                if (first_tombstone == null) first_tombstone = slot_index;
                continue;
            }
            const entry = &self.entries[slot - 1];
            if (entry.hash == hash and entry.style.eql(style)) {
                entry.refs += 1;
                return @intCast(slot - 1);
            }
        }
        if (first_tombstone) |slot_index| return self.insert(style, hash, slot_index);
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
        std.debug.assert(entry.active and entry.refs >= count);
        entry.refs -= count;
    }

    pub fn get(self: *const Table, id: Id) Style {
        return self.entries[id].style;
    }

    pub inline fn currentRevision(self: *const Table) u64 {
        return self.revision;
    }

    fn insert(self: *Table, style: Style, hash: u64, slot_index: usize) error{StyleCapacityExceeded}!Id {
        const index = if (self.free_head != no_entry) index: {
            const free = self.free_head;
            self.free_head = self.entries[free].next_free;
            break :index free;
        } else self.evict() orelse return error.StyleCapacityExceeded;
        const entry = &self.entries[index];
        entry.* = .{
            .style = style,
            .hash = hash,
            .refs = 1,
            .slot = @intCast(slot_index),
            .active = true,
        };
        self.slots[slot_index] = index + 1;
        self.revision +%= 1;
        return @intCast(index);
    }

    fn evict(self: *Table) ?u32 {
        for (self.entries[1..], 1..) |*entry, index| {
            if (!entry.active or entry.refs != 0) continue;
            self.slots[entry.slot] = tombstone;
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
    }
}

fn hashCapacity(capacity: usize) usize {
    var result: usize = 2;
    while (result < capacity * 2) result *= 2;
    return result;
}

test "style entries are reused after their final reference" {
    var table = try Table.init(std.testing.allocator, 2);
    defer table.deinit();

    const red = Style{ .foreground = .{ .indexed = 1 } };
    const red_id = try table.intern(red);
    table.release(red_id);
    const blue_id = try table.intern(.{ .foreground = .{ .indexed = 4 } });
    try std.testing.expectEqual(red_id, blue_id);
    table.release(blue_id);
}
