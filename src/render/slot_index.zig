const std = @import("std");

pub fn requiredSlots(capacity: usize) usize {
    var result: usize = 2;
    while (result < capacity * 2) result *= 2;
    return result;
}

pub fn remove(slots: []u32, entries: anytype, removed_slot: usize) void {
    std.debug.assert(slots.len >= 2 and std.math.isPowerOfTwo(slots.len));
    std.debug.assert(slots[removed_slot] != 0);

    const mask = slots.len - 1;
    var hole = removed_slot;
    var scan = (hole + 1) & mask;
    var probes: usize = 0;
    while (probes < slots.len) : (probes += 1) {
        const id = slots[scan];
        if (id == 0) {
            slots[hole] = 0;
            return;
        }

        const entry = &entries[id - 1];
        const home = @as(usize, @truncate(entry.hash)) & mask;
        const scan_distance = (scan -% home) & mask;
        const hole_distance = (hole -% home) & mask;
        if (hole_distance < scan_distance) {
            slots[hole] = id;
            entry.slot = @intCast(hole);
            hole = scan;
        }
        scan = (scan + 1) & mask;
    }
    unreachable;
}
