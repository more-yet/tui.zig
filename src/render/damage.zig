const std = @import("std");
const geometry = @import("../core/geometry.zig");

pub const Span = struct {
    start: u16,
    end: u16,
};

const Row = struct {
    start: u16 = 0,
    end: u16 = 0,
    dirty: bool = false,
};

pub const Map = struct {
    allocator: std.mem.Allocator,
    size: geometry.Size,
    tile_width: u8,
    tile_height: u8,
    tile_columns: u16,
    rows: []Row,
    tile_bits: []usize,
    dirty_row_count: usize = 0,
    first_dirty_row: u16 = std.math.maxInt(u16),
    last_dirty_row: u16 = 0,
    fully_dirty: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        size: geometry.Size,
        tile_width: u8,
        tile_height: u8,
    ) !Map {
        if (tile_width == 0 or tile_height == 0) return error.InvalidTileSize;
        const rows = try allocator.alloc(Row, size.height);
        errdefer allocator.free(rows);
        @memset(rows, .{});

        const tile_columns: u16 = @intCast((@as(u32, size.width) + tile_width - 1) / tile_width);
        const tile_rows: u16 = @intCast((@as(u32, size.height) + tile_height - 1) / tile_height);
        const tile_count = @as(usize, tile_columns) * tile_rows;
        const word_bits = @bitSizeOf(usize);
        const tile_bits = try allocator.alloc(usize, (tile_count + word_bits - 1) / word_bits);
        @memset(tile_bits, 0);

        return .{
            .allocator = allocator,
            .size = size,
            .tile_width = tile_width,
            .tile_height = tile_height,
            .tile_columns = tile_columns,
            .rows = rows,
            .tile_bits = tile_bits,
        };
    }

    pub fn deinit(self: *Map) void {
        self.allocator.free(self.tile_bits);
        self.allocator.free(self.rows);
        self.* = undefined;
    }

    pub fn canResize(self: *const Map, size: geometry.Size) bool {
        if (size.height > self.rows.len) return false;
        const tile_columns = (@as(usize, size.width) + self.tile_width - 1) / self.tile_width;
        const tile_rows = (@as(usize, size.height) + self.tile_height - 1) / self.tile_height;
        const tile_count = tile_columns * tile_rows;
        const word_bits = @bitSizeOf(usize);
        return (tile_count + word_bits - 1) / word_bits <= self.tile_bits.len;
    }

    pub fn resizeWithinCapacity(self: *Map, size: geometry.Size) void {
        std.debug.assert(self.canResize(size));
        self.size = size;
        self.tile_columns = @intCast((@as(u32, size.width) + self.tile_width - 1) / self.tile_width);
        self.reset();
        self.mark(geometry.Rect.fromSize(size));
    }

    pub fn mark(self: *Map, rect: geometry.Rect) void {
        if (self.fully_dirty) return;
        const clipped = rect.intersection(geometry.Rect.fromSize(self.size));
        if (clipped.isEmpty()) return;
        const end_x: u16 = @intCast(clipped.right());
        const end_y: u16 = @intCast(clipped.bottom());
        if (clipped.x == 0 and clipped.y == 0 and
            clipped.width == self.size.width and clipped.height == self.size.height)
        {
            if (self.dirty_row_count != 0) {
                @memset(self.rows[self.first_dirty_row..self.last_dirty_row], .{});
                @memset(self.tile_bits, 0);
            }
            self.dirty_row_count = self.size.height;
            self.first_dirty_row = 0;
            self.last_dirty_row = self.size.height;
            self.fully_dirty = true;
            return;
        }

        var y = clipped.y;
        while (y < end_y) : (y += 1) {
            const row_data = &self.rows[y];
            if (row_data.dirty) {
                row_data.start = @min(row_data.start, clipped.x);
                row_data.end = @max(row_data.end, end_x);
            } else {
                row_data.* = .{ .start = clipped.x, .end = end_x, .dirty = true };
                self.dirty_row_count += 1;
            }
        }
        self.first_dirty_row = @min(self.first_dirty_row, clipped.y);
        self.last_dirty_row = @max(self.last_dirty_row, end_y);

        const first_tile_x = clipped.x / self.tile_width;
        const last_tile_x = (end_x - 1) / self.tile_width;
        const first_tile_y = clipped.y / self.tile_height;
        const last_tile_y = (end_y - 1) / self.tile_height;
        var tile_y = first_tile_y;
        while (tile_y <= last_tile_y) : (tile_y += 1) {
            var tile_x = first_tile_x;
            while (tile_x <= last_tile_x) : (tile_x += 1) {
                const tile_index = @as(usize, tile_y) * self.tile_columns + tile_x;
                self.tile_bits[tile_index / @bitSizeOf(usize)] |= @as(usize, 1) << @intCast(tile_index % @bitSizeOf(usize));
            }
        }
    }

    pub fn markCell(self: *Map, x: u16, y: u16) void {
        if (self.fully_dirty) return;
        if (x >= self.size.width or y >= self.size.height) return;
        const end = x + 1;
        const row_data = &self.rows[y];
        if (row_data.dirty) {
            row_data.start = @min(row_data.start, x);
            row_data.end = @max(row_data.end, end);
        } else {
            row_data.* = .{ .start = x, .end = end, .dirty = true };
            self.dirty_row_count += 1;
        }
        self.first_dirty_row = @min(self.first_dirty_row, y);
        self.last_dirty_row = @max(self.last_dirty_row, y + 1);

        const tile_x = x / self.tile_width;
        const tile_y = y / self.tile_height;
        const tile_index = @as(usize, tile_y) * self.tile_columns + tile_x;
        self.tile_bits[tile_index / @bitSizeOf(usize)] |= @as(usize, 1) << @intCast(tile_index % @bitSizeOf(usize));
    }

    pub inline fn markSpan(self: *Map, y: u16, start: u16, end: u16) void {
        if (self.fully_dirty) return;
        std.debug.assert(y < self.size.height);
        std.debug.assert(start < end and end <= self.size.width);

        const row_data = &self.rows[y];
        if (row_data.dirty) {
            row_data.start = @min(row_data.start, start);
            row_data.end = @max(row_data.end, end);
        } else {
            row_data.* = .{ .start = start, .end = end, .dirty = true };
            self.dirty_row_count += 1;
            self.first_dirty_row = @min(self.first_dirty_row, y);
            self.last_dirty_row = @max(self.last_dirty_row, y + 1);
        }

        const first_tile_x = if (self.tile_width == 8) start >> 3 else start / self.tile_width;
        const last_tile_x = if (self.tile_width == 8) (end - 1) >> 3 else (end - 1) / self.tile_width;
        const tile_y = if (self.tile_height == 4) y >> 2 else y / self.tile_height;
        var tile_x = first_tile_x;
        while (tile_x <= last_tile_x) : (tile_x += 1) {
            const tile_index = @as(usize, tile_y) * self.tile_columns + tile_x;
            self.tile_bits[tile_index / @bitSizeOf(usize)] |= @as(usize, 1) << @intCast(tile_index % @bitSizeOf(usize));
        }
    }

    pub inline fn row(self: *const Map, y: u16) ?Span {
        if (self.fully_dirty) return .{ .start = 0, .end = self.size.width };
        const value = self.rows[y];
        if (!value.dirty) return null;
        return .{ .start = value.start, .end = value.end };
    }

    pub inline fn nextTileSpan(self: *const Map, y: u16, from: u16) ?Span {
        if (self.fully_dirty) {
            if (from >= self.size.width) return null;
            return .{ .start = from, .end = self.size.width };
        }
        const row_span = self.row(y) orelse return null;
        var cursor = @max(from, row_span.start);
        if (cursor >= row_span.end) return null;

        const tile_y = y / self.tile_height;
        var tile_x = cursor / self.tile_width;
        while (tile_x < self.tile_columns and !self.tileDirty(tile_x, tile_y)) : (tile_x += 1) {}
        if (tile_x == self.tile_columns) return null;

        const tile_start: u16 = @intCast(@as(u32, tile_x) * self.tile_width);
        if (tile_start >= row_span.end) return null;
        cursor = @max(cursor, tile_start);

        var end_tile = tile_x + 1;
        while (end_tile < self.tile_columns and self.tileDirty(end_tile, tile_y)) : (end_tile += 1) {}
        const tile_end: u16 = @intCast(@min(@as(u32, self.size.width), @as(u32, end_tile) * self.tile_width));
        return .{ .start = cursor, .end = @min(row_span.end, tile_end) };
    }

    pub fn dirtyRowCount(self: *const Map) usize {
        return self.dirty_row_count;
    }

    pub inline fn dirtyRows(self: *const Map) ?Span {
        if (self.dirty_row_count == 0) return null;
        return .{ .start = self.first_dirty_row, .end = self.last_dirty_row };
    }

    pub fn tileWords(self: *const Map) []const usize {
        return self.tile_bits;
    }

    pub fn reset(self: *Map) void {
        if (!self.fully_dirty and self.dirty_row_count != 0) {
            @memset(self.rows[self.first_dirty_row..self.last_dirty_row], .{});
            @memset(self.tile_bits, 0);
        }
        self.dirty_row_count = 0;
        self.first_dirty_row = std.math.maxInt(u16);
        self.last_dirty_row = 0;
        self.fully_dirty = false;
    }

    inline fn tileDirty(self: *const Map, x: u16, y: u16) bool {
        const tile_index = @as(usize, y) * self.tile_columns + x;
        return self.tile_bits[tile_index / @bitSizeOf(usize)] &
            (@as(usize, 1) << @intCast(tile_index % @bitSizeOf(usize))) != 0;
    }
};

test "damage keeps exact row spans and coarse tile coverage" {
    var damage = try Map.init(std.testing.allocator, .{ .width = 20, .height = 8 }, 8, 4);
    defer damage.deinit();

    damage.mark(.{ .x = 7, .y = 3, .width = 3, .height = 2 });
    try std.testing.expectEqual(Span{ .start = 7, .end = 10 }, damage.row(3).?);
    try std.testing.expectEqual(Span{ .start = 7, .end = 10 }, damage.row(4).?);
    try std.testing.expectEqual(@as(usize, 2), damage.dirtyRowCount());
    var dirty_tiles: usize = 0;
    for (damage.tileWords()) |word| dirty_tiles += @popCount(word);
    try std.testing.expectEqual(@as(usize, 4), dirty_tiles);
}

test "disjoint dirty tiles remain separate scan spans" {
    var damage = try Map.init(std.testing.allocator, .{ .width = 40, .height = 4 }, 8, 4);
    defer damage.deinit();
    damage.markCell(1, 0);
    damage.markCell(33, 0);

    try std.testing.expectEqual(Span{ .start = 1, .end = 8 }, damage.nextTileSpan(0, 0).?);
    try std.testing.expectEqual(Span{ .start = 32, .end = 34 }, damage.nextTileSpan(0, 8).?);
    try std.testing.expect(damage.nextTileSpan(0, 34) == null);
}
