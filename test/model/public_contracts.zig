const std = @import("std");
const tui = @import("tui");

test "ASCII line layout matches the simple width model" {
    var storage: [32]u8 = @splat('x');
    const alignments = [_]tui.text.TextAlignment{ .left, .center, .right };
    const overflows = [_]tui.text.TextOverflow{ .clip, .ellipsis };

    for (0..storage.len + 1) |length| {
        const value = storage[0..length];
        try std.testing.expectEqual(length, try tui.text.measureLine(value, .narrow));
        for (0..17) |raw_available| {
            const available: u16 = @intCast(raw_available);
            for (alignments) |alignment| {
                for (overflows) |overflow| {
                    const actual = try tui.text.layoutLine(
                        value,
                        available,
                        .narrow,
                        .{ .alignment = alignment, .overflow = overflow },
                    );
                    const fits = length <= available;
                    const marker = !fits and overflow == .ellipsis and available != 0;
                    const prefix_len: usize = if (fits)
                        length
                    else if (marker)
                        available - 1
                    else
                        available;
                    const width: u16 = if (fits)
                        @intCast(length)
                    else if (marker)
                        available
                    else
                        @intCast(prefix_len);
                    const remaining = available - width;
                    const offset: u16 = switch (alignment) {
                        .left => 0,
                        .center => remaining / 2,
                        .right => remaining,
                    };

                    try std.testing.expectEqual(prefix_len, actual.prefix.len);
                    try std.testing.expectEqual(width, actual.width);
                    try std.testing.expectEqual(offset, actual.offset);
                    try std.testing.expectEqual(marker, actual.ellipsis);
                }
            }
        }
    }
}

test "random split and grid results satisfy independent constraints" {
    var random: u64 = 0x243F_6A88_85A3_08D3;
    var segments: [8]tui.layout.Segment = undefined;
    var output: [8]tui.render.Rect = undefined;

    for (0..5_000) |_| {
        const count = 1 + nextRandom(&random) % segments.len;
        const available: u16 = @intCast(nextRandom(&random) % 81);
        var minimum_total: usize = 0;
        var reachable_total: usize = 0;
        for (segments[0..count]) |*segment| {
            const minimum: u16 = @intCast(nextRandom(&random) % 11);
            const maximum = minimum + @as(u16, @intCast(nextRandom(&random) % 21));
            const weight: u16 = @intCast(nextRandom(&random) % 5);
            segment.* = .{ .min = minimum, .max = maximum, .weight = weight };
            minimum_total += minimum;
            reachable_total += if (weight == 0) minimum else maximum;
        }

        const axis: tui.layout.Axis = if (nextRandom(&random) & 1 == 0) .horizontal else .vertical;
        const area: tui.render.Rect = if (axis == .horizontal)
            .{ .x = 0, .y = 3, .width = available, .height = 7 }
        else
            .{ .x = 3, .y = 0, .width = 7, .height = available };
        if (minimum_total > available) {
            try std.testing.expectError(
                error.InsufficientSpace,
                tui.layout.split(area, axis, segments[0..count], output[0..count]),
            );
            continue;
        }

        const result = try tui.layout.split(area, axis, segments[0..count], output[0..count]);
        var cursor: u16 = 0;
        var total: usize = 0;
        for (result, segments[0..count]) |rect, segment| {
            const start = if (axis == .horizontal) rect.x else rect.y;
            const length = if (axis == .horizontal) rect.width else rect.height;
            try std.testing.expectEqual(cursor, start);
            try std.testing.expect(length >= segment.min and length <= segment.max);
            if (axis == .horizontal) {
                try std.testing.expectEqual(area.y, rect.y);
                try std.testing.expectEqual(area.height, rect.height);
            } else {
                try std.testing.expectEqual(area.x, rect.x);
                try std.testing.expectEqual(area.width, rect.width);
            }
            cursor += length;
            total += length;
        }
        try std.testing.expectEqual(@min(@as(usize, available), reachable_total), total);
    }

    const rows = [_]tui.layout.Segment{ tui.layout.Segment.fixed(2), tui.layout.Segment.flex(1, 1, 10) };
    const columns = [_]tui.layout.Segment{ tui.layout.Segment.flex(1, 1, 10), tui.layout.Segment.flex(2, 1, 10) };
    var row_rects: [2]tui.render.Rect = undefined;
    var column_rects: [2]tui.render.Rect = undefined;
    const area = tui.render.Rect{ .x = 4, .y = 5, .width = 13, .height = 9 };
    _ = try tui.layout.split(area, .vertical, &rows, &row_rects);
    _ = try tui.layout.split(area, .horizontal, &columns, &column_rects);
    var cells: [4]tui.render.Rect = undefined;
    const grid = try tui.layout.grid(area, &rows, &columns, &cells);
    for (grid, 0..) |cell, index| {
        const row = row_rects[index / columns.len];
        const column = column_rects[index % columns.len];
        try std.testing.expectEqual(
            tui.render.Rect{ .x = column.x, .y = row.y, .width = column.width, .height = row.height },
            cell,
        );
    }
}

test "command registry matches a large sorted set and full chords" {
    var bindings: [80]tui.command.Binding = undefined;
    var strokes: [160]tui.command.Stroke = undefined;
    var registry = try tui.command.Registry.init(&bindings, &strokes);

    try std.testing.expectError(error.InvalidChord, registry.add(1, 1, &.{}));
    const too_long = [_]tui.command.Stroke{
        tui.command.Stroke.press(.{ .codepoint = 'a' }, .{}),
        tui.command.Stroke.press(.{ .codepoint = 'b' }, .{}),
        tui.command.Stroke.press(.{ .codepoint = 'c' }, .{}),
        tui.command.Stroke.press(.{ .codepoint = 'd' }, .{}),
        tui.command.Stroke.press(.{ .codepoint = 'e' }, .{}),
    };
    try std.testing.expectError(error.InvalidChord, registry.add(1, 1, &too_long));

    for (0..64) |index| {
        const codepoint: u21 = @intCast(0x100 + index);
        try registry.add(1, @intCast(index + 1), &.{tui.command.Stroke.press(.{ .codepoint = codepoint }, .{})});
    }
    const chord = [_]tui.command.Stroke{
        tui.command.Stroke.press(.{ .codepoint = 'w' }, .{ .control = true }),
        tui.command.Stroke.press(.{ .codepoint = 'x' }, .{ .control = true }),
        tui.command.Stroke.press(.{ .codepoint = 'y' }, .{ .control = true }),
        tui.command.Stroke.press(.{ .codepoint = 'z' }, .{ .control = true }),
    };
    try registry.add(1, 1000, &chord);

    var matcher: tui.command.Matcher = .{};
    for (0..64) |index| {
        const codepoint: u21 = @intCast(0x100 + index);
        const actual = matcher.feed(&registry, 1, .{
            .code = .{ .codepoint = codepoint },
            .modifiers = .{ .num_lock = true },
        });
        try std.testing.expectEqual(tui.command.Match{ .command = @intCast(index + 1) }, actual);
    }
    for (chord, 0..) |stroke, index| {
        const actual = matcher.feed(&registry, 1, .{
            .code = stroke.code,
            .modifiers = stroke.modifiers,
        });
        if (index + 1 == chord.len) {
            try std.testing.expectEqual(tui.command.Match{ .command = 1000 }, actual);
        } else {
            try std.testing.expectEqual(tui.command.Match.pending, actual);
        }
    }

    _ = matcher.feed(&registry, 1, .{ .code = chord[0].code, .modifiers = chord[0].modifiers });
    try std.testing.expect(matcher.cancel());
    try std.testing.expect(!matcher.pending());
}

test "focus registry reports errors and navigation wraps" {
    var nodes: [6]tui.focus.Node = undefined;
    var registry = try tui.focus.Registry.init(&nodes);
    try registry.add(.{ .id = 1, .rect = .{ .x = 0, .y = 0, .width = 2, .height = 1 } });
    try registry.add(.{ .id = 2, .rect = .{ .x = 5, .y = 0, .width = 2, .height = 1 } });
    try registry.add(.{ .id = 3, .rect = .{ .x = 0, .y = 4, .width = 2, .height = 1 } });
    try registry.add(.{ .id = 4, .rect = .{ .x = 5, .y = 4, .width = 0, .height = 1 } });

    var path: [2]tui.focus.Id = undefined;
    try std.testing.expectError(error.UnknownId, registry.path(99, &path));
    try std.testing.expectError(error.OutputTooSmall, registry.path(1, path[0..0]));
    try std.testing.expectEqual(@as(?tui.focus.Id, null), registry.hit(.{ .x = 20, .y = 20 }));

    var manager: tui.focus.Manager = .{};
    try std.testing.expectError(error.UnknownId, manager.set(&registry, 99));
    try std.testing.expect(try manager.set(&registry, 1));
    try std.testing.expect(!(try manager.set(&registry, 1)));
    try std.testing.expectEqual(@as(?tui.focus.Id, 3), manager.move(&registry, .previous));
    try std.testing.expectEqual(@as(?tui.focus.Id, 1), manager.move(&registry, .next));
    try std.testing.expectEqual(@as(?tui.focus.Id, 3), manager.move(&registry, .down));
    try std.testing.expectEqual(@as(?tui.focus.Id, null), manager.move(&registry, .left));
    try std.testing.expect(manager.clear());
    try std.testing.expect(!manager.clear());
}

test "overlay stack matches a separate modal reference model" {
    var random: u64 = 0x1319_8A2E_0370_7344;
    var storage: [16]tui.overlay.Entry = undefined;

    for (0..500) |_| {
        var stack = try tui.overlay.Stack.init(&storage);
        const count = nextRandom(&random) % (storage.len + 1);
        for (0..count) |index| {
            try stack.push(.{
                .id = @intCast(index + 1),
                .bounds = .{
                    .x = @intCast(nextRandom(&random) % 20),
                    .y = @intCast(nextRandom(&random) % 12),
                    .width = @intCast(nextRandom(&random) % 8),
                    .height = @intCast(nextRandom(&random) % 6),
                },
                .modal = nextRandom(&random) % 7 == 0,
            });
        }
        for (0..40) |_| {
            const point = tui.render.Point{
                .x = @intCast(nextRandom(&random) % 28),
                .y = @intCast(nextRandom(&random) % 18),
            };
            const expected = referenceOverlayHit(stack.entries(), point);
            try std.testing.expect(std.meta.eql(expected, stack.hit(point)));
        }
    }
}

test "scrollback viewport matches absolute-row anchoring under random updates" {
    const Ring = tui.scroll.LineRing(16);
    var slots: [7]Ring.Slot = undefined;
    var ring = Ring.init(&slots);
    var viewport: tui.scroll.Viewport = .{};
    var visible_rows: u16 = 3;
    var oldest_absolute: usize = 0;
    var next_absolute: usize = 0;
    var random: u64 = 0xA409_3822_299F_31D0;

    for (0..5_000) |_| {
        switch (nextRandom(&random) % 7) {
            0, 1, 2 => {
                const viewed_absolute = if (!viewport.follow and ring.count() != 0)
                    oldest_absolute + viewport.top
                else
                    null;
                var line_buffer: [16]u8 = undefined;
                const line = try std.fmt.bufPrint(&line_buffer, "{d}", .{next_absolute});
                const result = try ring.append(line);
                next_absolute += 1;
                oldest_absolute += result.dropped_rows;
                _ = viewport.update(ring.count(), visible_rows, result.dropped_rows);
                if (viewed_absolute) |absolute| {
                    const relative = if (absolute < oldest_absolute) 0 else absolute - oldest_absolute;
                    try std.testing.expectEqual(
                        @min(relative, modelMaxTop(ring.count(), visible_rows)),
                        viewport.top,
                    );
                }
            },
            3 => _ = viewport.scrollUp(nextRandom(&random) % 5, ring.count(), visible_rows),
            4 => _ = viewport.scrollDown(nextRandom(&random) % 5, ring.count(), visible_rows),
            5 => if (nextRandom(&random) & 1 == 0) {
                _ = viewport.home(ring.count(), visible_rows);
            } else {
                _ = viewport.end(ring.count(), visible_rows);
            },
            6 => {
                visible_rows = @intCast(nextRandom(&random) % 7);
                _ = viewport.update(ring.count(), visible_rows, 0);
            },
            else => unreachable,
        }

        try std.testing.expect(viewport.top <= modelMaxTop(ring.count(), visible_rows));
        const visible = viewport.visibleRange(ring.count(), visible_rows);
        try std.testing.expect(visible.start <= visible.end and visible.end <= ring.count());
        try std.testing.expect(visible.len() <= visible_rows);
        if (viewport.follow and visible_rows != 0) try std.testing.expectEqual(ring.count(), visible.end);
        for (0..ring.count()) |index| {
            try std.testing.expectEqual(
                oldest_absolute + index,
                try std.fmt.parseInt(usize, ring.row(index), 10),
            );
        }
    }
}

fn modelMaxTop(total_rows: usize, visible_rows: u16) usize {
    if (total_rows == 0) return 0;
    if (visible_rows == 0) return total_rows - 1;
    return total_rows -| visible_rows;
}

fn referenceOverlayHit(entries: []const tui.overlay.Entry, point: tui.render.Point) tui.overlay.Hit {
    var modal: ?usize = null;
    var index = entries.len;
    while (index != 0) {
        index -= 1;
        if (entries[index].modal) {
            modal = index;
            break;
        }
    }

    index = entries.len;
    while (index != 0) {
        index -= 1;
        if (modal) |modal_index| if (index < modal_index) break;
        if (entries[index].bounds.contains(point)) return .{ .overlay = entries[index].id };
    }
    return if (modal) |modal_index| .{ .modal_backdrop = entries[modal_index].id } else .background;
}

fn nextRandom(state: *u64) usize {
    state.* = state.* *% 6_364_136_223_846_793_005 +% 1_442_695_040_888_963_407;
    return @truncate(state.* >> 16);
}
