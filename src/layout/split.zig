const std = @import("std");
const geometry = @import("../core/geometry.zig");

pub const Axis = enum {
    horizontal,
    vertical,
};

pub const Segment = struct {
    min: u16 = 0,
    max: u16 = std.math.maxInt(u16),
    weight: u16 = 1,

    pub fn fixed(length: u16) Segment {
        return .{ .min = length, .max = length, .weight = 0 };
    }

    pub fn flex(weight: u16, min: u16, max: u16) Segment {
        return .{ .min = min, .max = max, .weight = weight };
    }
};

pub const Error = error{
    InvalidSegment,
    OutputTooSmall,
    InsufficientSpace,
    CoordinateOverflow,
    SizeOverflow,
};

pub fn split(
    rect: geometry.Rect,
    axis: Axis,
    segments: []const Segment,
    output: []geometry.Rect,
) Error![]geometry.Rect {
    if (output.len < segments.len) return error.OutputTooSmall;
    switch (axis) {
        inline else => |selected| try solve(rect, selected, segments, output, 1),
    }
    for (output[0..segments.len]) |*result| switch (axis) {
        .horizontal => {
            result.y = rect.y;
            result.height = rect.height;
        },
        .vertical => {
            result.x = rect.x;
            result.width = rect.width;
        },
    };
    return output[0..segments.len];
}

pub inline fn grid(
    rect: geometry.Rect,
    rows: []const Segment,
    columns: []const Segment,
    output: []geometry.Rect,
) Error![]geometry.Rect {
    const cell_count = std.math.mul(usize, rows.len, columns.len) catch return error.SizeOverflow;
    if (output.len < cell_count) return error.OutputTooSmall;
    if (cell_count == 0) return output[0..0];

    try @call(.always_inline, solve, .{ rect, .horizontal, columns, output, 1 });
    try @call(.always_inline, solve, .{ rect, .vertical, rows, output, columns.len });
    for (0..rows.len) |row_index| {
        const row_y = output[row_index * columns.len].y;
        const row_height = output[row_index * columns.len].height;
        for (0..columns.len) |column_index| {
            const column_x = output[column_index].x;
            const column_width = output[column_index].width;
            output[row_index * columns.len + column_index] = .{
                .x = column_x,
                .y = row_y,
                .width = column_width,
                .height = row_height,
            };
        }
    }
    return output[0..cell_count];
}

fn solve(
    rect: geometry.Rect,
    comptime axis: Axis,
    segments: []const Segment,
    output: []geometry.Rect,
    stride: usize,
) Error!void {
    const available: u16 = switch (axis) {
        .horizontal => rect.width,
        .vertical => rect.height,
    };

    var minimum_total: u64 = 0;
    var total_weight: u64 = 0;
    for (segments, 0..) |segment, index| {
        if (segment.min > segment.max) return error.InvalidSegment;
        minimum_total += segment.min;
        if (segment.min < segment.max) total_weight += segment.weight;
        const result = &output[index * stride];
        if (axis == .horizontal) result.width = segment.min else result.height = segment.min;
    }
    if (minimum_total > available) return error.InsufficientSpace;

    var remaining: u64 = available - minimum_total;
    if (remaining != 0 and total_weight != 0) {
        const round_remaining = remaining;
        const narrow_weights = total_weight <= std.math.maxInt(u16);
        var cumulative_weight: u64 = 0;
        var distributed: u64 = 0;
        var cursor_x: u32 = rect.x;
        var cursor_y: u32 = rect.y;
        var capped = false;
        var coordinate_overflow = false;
        for (segments, 0..) |segment, index| {
            const result = &output[index * stride];
            var addition: u16 = 0;
            if (segment.min < segment.max and segment.weight != 0) {
                cumulative_weight += segment.weight;
                const target = if (narrow_weights)
                    @as(u64, @as(u32, @intCast(round_remaining)) * @as(u32, @intCast(cumulative_weight)) /
                        @as(u32, @intCast(total_weight)))
                else
                    round_remaining * cumulative_weight / total_weight;
                const share = target - distributed;
                distributed = target;
                if (share > segment.max - segment.min) {
                    capped = true;
                    break;
                }
                addition = @intCast(share);
            }
            if (axis == .horizontal) result.width = segment.min + addition else result.height = segment.min + addition;
            if (cursor_x > std.math.maxInt(u16) or cursor_y > std.math.maxInt(u16)) {
                coordinate_overflow = true;
            } else {
                result.x = @intCast(cursor_x);
                result.y = @intCast(cursor_y);
            }
            if (axis == .horizontal) cursor_x += result.width else cursor_y += result.height;
        }
        if (!capped) {
            if (coordinate_overflow) return error.CoordinateOverflow;
            return;
        }
        for (segments, 0..) |segment, index| {
            const result = &output[index * stride];
            if (axis == .horizontal) result.width = segment.min else result.height = segment.min;
        }
    }

    while (remaining > 0) {
        if (total_weight == 0) break;

        const round_remaining = remaining;
        var distributed: u64 = 0;
        var remainder: u64 = 0;
        for (segments, 0..) |segment, index| {
            const result = &output[index * stride];
            const length = if (axis == .horizontal) result.width else result.height;
            if (length == segment.max or segment.weight == 0) continue;
            const weighted = round_remaining * segment.weight + remainder;
            const share = weighted / total_weight;
            remainder = weighted % total_weight;
            const addition: u16 = @intCast(@min(share, @as(u64, segment.max - length)));
            if (axis == .horizontal) result.width += addition else result.height += addition;
            distributed += addition;
            if (distributed == round_remaining) break;
        }
        if (distributed == 0) break;
        remaining -= @min(remaining, distributed);
        if (remaining != 0) {
            total_weight = 0;
            for (segments, 0..) |segment, index| {
                const result = output[index * stride];
                const length = if (axis == .horizontal) result.width else result.height;
                if (length < segment.max) total_weight += segment.weight;
            }
        }
    }

    var cursor_x: u32 = rect.x;
    var cursor_y: u32 = rect.y;
    for (0..segments.len) |index| {
        const result = &output[index * stride];
        if (cursor_x > std.math.maxInt(u16) or cursor_y > std.math.maxInt(u16)) return error.CoordinateOverflow;
        result.x = @intCast(cursor_x);
        result.y = @intCast(cursor_y);
        if (axis == .horizontal) cursor_x += result.width else cursor_y += result.height;
    }
}

test "split satisfies fixed and weighted segments without allocation" {
    const segments = [_]Segment{
        Segment.fixed(2),
        Segment.flex(1, 1, 20),
        Segment.flex(2, 1, 20),
    };
    var output: [3]geometry.Rect = undefined;
    const result = try split(.{ .x = 4, .y = 2, .width = 14, .height = 3 }, .horizontal, &segments, &output);
    try std.testing.expectEqual(@as(u16, 2), result[0].width);
    try std.testing.expectEqual(@as(u16, 4), result[1].width);
    try std.testing.expectEqual(@as(u16, 8), result[2].width);
    try std.testing.expectEqual(@as(u16, 6), result[1].x);
    try std.testing.expectEqual(@as(u16, 10), result[2].x);
}

test "split reports impossible minimum constraints" {
    const segments = [_]Segment{ Segment.fixed(3), Segment.fixed(3) };
    var output: [2]geometry.Rect = undefined;
    try std.testing.expectError(
        error.InsufficientSpace,
        split(.{ .x = 0, .y = 0, .width = 5, .height = 1 }, .horizontal, &segments, &output),
    );
}

test "split redistributes capacity left by a capped segment" {
    const segments = [_]Segment{
        Segment.flex(1, 0, 2),
        Segment.flex(1, 0, 10),
    };
    var output: [2]geometry.Rect = undefined;
    const result = try split(.{ .x = 0, .y = 0, .width = 10, .height = 1 }, .horizontal, &segments, &output);
    try std.testing.expectEqual(@as(u16, 2), result[0].width);
    try std.testing.expectEqual(@as(u16, 8), result[1].width);
}

test "split permits a final segment ending one past the coordinate limit" {
    const segments = [_]Segment{Segment.fixed(std.math.maxInt(u16))};
    var output: [1]geometry.Rect = undefined;
    const result = try split(.{
        .x = 1,
        .y = 0,
        .width = std.math.maxInt(u16),
        .height = 1,
    }, .horizontal, &segments, &output);
    try std.testing.expectEqual(@as(u16, 1), result[0].x);
    try std.testing.expectEqual(std.math.maxInt(u16), result[0].width);
}

test "grid reuses split constraints in row-major order" {
    const rows = [_]Segment{ Segment.fixed(2), Segment.flex(1, 1, 10) };
    const columns = [_]Segment{ Segment.fixed(3), Segment.flex(1, 1, 10) };
    var output: [4]geometry.Rect = undefined;
    const cells = try grid(
        .{ .x = 4, .y = 2, .width = 10, .height = 6 },
        &rows,
        &columns,
        &output,
    );
    try std.testing.expectEqual(geometry.Rect{ .x = 4, .y = 2, .width = 3, .height = 2 }, cells[0]);
    try std.testing.expectEqual(geometry.Rect{ .x = 7, .y = 2, .width = 7, .height = 2 }, cells[1]);
    try std.testing.expectEqual(geometry.Rect{ .x = 4, .y = 4, .width = 3, .height = 4 }, cells[2]);
    try std.testing.expectEqual(geometry.Rect{ .x = 7, .y = 4, .width = 7, .height = 4 }, cells[3]);
}

test "grid checks output capacity before solving" {
    const rows = [_]Segment{ Segment.flex(1, 0, 10), Segment.flex(1, 0, 10) };
    const columns = [_]Segment{ Segment.flex(1, 0, 10), Segment.flex(1, 0, 10) };
    var output: [3]geometry.Rect = undefined;
    try std.testing.expectError(
        error.OutputTooSmall,
        grid(.{ .x = 0, .y = 0, .width = 8, .height = 8 }, &rows, &columns, &output),
    );
}

test "grid supports single-row and single-column output reuse" {
    const one = [_]Segment{Segment.flex(1, 0, 10)};
    const two = [_]Segment{ Segment.flex(1, 0, 10), Segment.flex(1, 0, 10) };
    var output: [2]geometry.Rect = undefined;

    const row = try grid(.{ .x = 2, .y = 3, .width = 8, .height = 4 }, &one, &two, &output);
    try std.testing.expectEqual(geometry.Rect{ .x = 2, .y = 3, .width = 4, .height = 4 }, row[0]);
    try std.testing.expectEqual(geometry.Rect{ .x = 6, .y = 3, .width = 4, .height = 4 }, row[1]);

    const column = try grid(.{ .x = 2, .y = 3, .width = 8, .height = 4 }, &two, &one, &output);
    try std.testing.expectEqual(geometry.Rect{ .x = 2, .y = 3, .width = 8, .height = 2 }, column[0]);
    try std.testing.expectEqual(geometry.Rect{ .x = 2, .y = 5, .width = 8, .height = 2 }, column[1]);
}
