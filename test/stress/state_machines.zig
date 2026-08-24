const std = @import("std");
const tui = @import("tui");

test "parser handles a long deterministic byte stream in bounded chunks" {
    const Sink = struct {
        events: usize = 0,
        bytes: usize = 0,

        pub fn emit(self: *@This(), event: tui.input.Event) !void {
            self.events += 1;
            switch (event) {
                .text, .paste_chunk => |value| self.bytes += value.len,
                else => {},
            }
        }
    };

    var parser: tui.input.Parser = .{};
    var sink: Sink = .{};
    var random: u64 = 0xA409_3822_299F_31D0;
    var chunk: [31]u8 = undefined;
    for (0..20_000) |iteration| {
        const length = 1 + nextRandom(&random) % chunk.len;
        for (chunk[0..length]) |*byte| byte.* = @truncate(nextRandom(&random));
        try parser.feed(chunk[0..length], &sink);
        if (iteration % 97 == 0) try parser.abort(&sink);
        if (iteration % 251 == 0) try parser.flushEscape(&sink);
    }
    try parser.finish(&sink);
    try std.testing.expect(sink.events > 1_000);
    try std.testing.expect(sink.bytes != 0);
}

test "ASCII text input matches a plain editor model" {
    var storage: [64]u8 = undefined;
    var input = try tui.widget.TextInput.init(&storage, "");
    var expected: [64]u8 = undefined;
    var expected_len: usize = 0;
    var cursor: usize = 0;
    var random: u64 = 0x082E_FA98_EC4E_6C89;

    for (0..30_000) |_| {
        switch (nextRandom(&random) % 7) {
            0 => {
                const byte: u8 = @intCast('!' + nextRandom(&random) % ('~' - '!' + 1));
                _ = input.handle(.{ .text = &.{byte} });
                if (expected_len < expected.len) {
                    std.mem.copyBackwards(u8, expected[cursor + 1 .. expected_len + 1], expected[cursor..expected_len]);
                    expected[cursor] = byte;
                    cursor += 1;
                    expected_len += 1;
                }
            },
            1 => {
                _ = input.handle(.{ .key = .{ .code = .left } });
                cursor -|= 1;
            },
            2 => {
                _ = input.handle(.{ .key = .{ .code = .right } });
                cursor = @min(cursor + 1, expected_len);
            },
            3 => {
                _ = input.handle(.{ .key = .{ .code = .home } });
                cursor = 0;
            },
            4 => {
                _ = input.handle(.{ .key = .{ .code = .end } });
                cursor = expected_len;
            },
            5 => {
                _ = input.handle(.{ .key = .{ .code = .backspace } });
                if (cursor != 0) {
                    std.mem.copyForwards(u8, expected[cursor - 1 .. expected_len - 1], expected[cursor..expected_len]);
                    cursor -= 1;
                    expected_len -= 1;
                }
            },
            6 => {
                _ = input.handle(.{ .key = .{ .code = .delete } });
                if (cursor < expected_len) {
                    std.mem.copyForwards(u8, expected[cursor .. expected_len - 1], expected[cursor + 1 .. expected_len]);
                    expected_len -= 1;
                }
            },
            else => unreachable,
        }
        try std.testing.expectEqualSlices(u8, expected[0..expected_len], input.value());
    }
}

test "ASCII multiline editor matches a selection-aware reference model" {
    const Reference = struct {
        storage: [128]u8 = undefined,
        len: usize = 0,
        cursor: usize = 0,
        anchor: ?usize = null,

        fn selection(self: *const @This()) ?tui.editor.Selection {
            const anchor = self.anchor orelse return null;
            if (anchor == self.cursor) return null;
            return .{ .start = @min(anchor, self.cursor), .end = @max(anchor, self.cursor) };
        }

        fn replace(self: *@This(), bytes: []const u8) void {
            const selected = self.selection() orelse tui.editor.Selection{ .start = self.cursor, .end = self.cursor };
            const retained = self.len - (selected.end - selected.start);
            if (bytes.len > self.storage.len - retained) return;
            const tail_len = self.len - selected.end;
            const target = selected.start + bytes.len;
            if (target < selected.end) {
                std.mem.copyForwards(
                    u8,
                    self.storage[target .. target + tail_len],
                    self.storage[selected.end..self.len],
                );
            } else if (target > selected.end) {
                std.mem.copyBackwards(
                    u8,
                    self.storage[target .. target + tail_len],
                    self.storage[selected.end..self.len],
                );
            }
            @memcpy(self.storage[selected.start..target], bytes);
            self.len = retained + bytes.len;
            self.cursor = target;
            self.anchor = null;
        }

        fn move(self: *@This(), target: usize, extend: bool) void {
            if (target == self.cursor and extend) return;
            if (extend) {
                if (self.anchor == null) self.anchor = self.cursor;
            } else {
                self.anchor = null;
            }
            self.cursor = target;
        }

        fn left(self: *@This(), extend: bool) void {
            if (!extend) if (self.selection()) |selected| {
                self.move(selected.start, false);
                return;
            };
            self.move(self.cursor -| 1, extend);
        }

        fn right(self: *@This(), extend: bool) void {
            if (!extend) if (self.selection()) |selected| {
                self.move(selected.end, false);
                return;
            };
            self.move(@min(self.cursor + 1, self.len), extend);
        }

        fn home(self: *@This()) void {
            var target: usize = 0;
            for (self.storage[0..self.cursor], 0..) |byte, index| if (byte == '\n') {
                target = index + 1;
            };
            self.move(target, false);
        }

        fn end(self: *@This()) void {
            const relative = std.mem.indexOfScalar(u8, self.storage[self.cursor..self.len], '\n');
            self.move(if (relative) |offset| self.cursor + offset else self.len, false);
        }

        fn backspace(self: *@This()) void {
            if (self.selection() != null) return self.replace("");
            if (self.cursor == 0) return;
            self.anchor = self.cursor - 1;
            self.replace("");
        }

        fn delete(self: *@This()) void {
            if (self.selection() != null) return self.replace("");
            if (self.cursor == self.len) return;
            self.anchor = self.cursor + 1;
            self.replace("");
        }
    };

    var storage: [128]u8 = undefined;
    var editor = try tui.editor.Model.init(&storage, "");
    var reference: Reference = .{};
    var random: u64 = 0x3BD3_9E10_CB0E_F593;
    const shift = tui.input.Modifiers{ .shift = true };
    for (0..30_000) |_| {
        switch (nextRandom(&random) % 10) {
            0 => {
                const byte: u8 = @intCast('a' + nextRandom(&random) % 26);
                _ = editor.handle(.{ .text = &.{byte} });
                reference.replace(&.{byte});
            },
            1 => {
                _ = editor.handle(.{ .key = .{ .code = .enter } });
                reference.replace("\n");
            },
            2 => {
                _ = editor.handle(.{ .key = .{ .code = .left } });
                reference.left(false);
            },
            3 => {
                _ = editor.handle(.{ .key = .{ .code = .right } });
                reference.right(false);
            },
            4 => {
                _ = editor.handle(.{ .key = .{ .code = .left, .modifiers = shift } });
                reference.left(true);
            },
            5 => {
                _ = editor.handle(.{ .key = .{ .code = .right, .modifiers = shift } });
                reference.right(true);
            },
            6 => {
                _ = editor.handle(.{ .key = .{ .code = .backspace } });
                reference.backspace();
            },
            7 => {
                _ = editor.handle(.{ .key = .{ .code = .delete } });
                reference.delete();
            },
            8 => {
                _ = editor.handle(.{ .key = .{ .code = .home } });
                reference.home();
            },
            9 => {
                _ = editor.handle(.{ .key = .{ .code = .end } });
                reference.end();
            },
            else => unreachable,
        }
        try std.testing.expectEqualSlices(u8, reference.storage[0..reference.len], editor.value());
        try std.testing.expectEqual(reference.cursor, editor.cursor);
        try std.testing.expect(std.meta.eql(reference.selection(), editor.selection()));
    }
}

test "bounded multiline history survives deterministic undo and redo sequences" {
    var storage: [64]u8 = undefined;
    var records: [512]tui.editor.HistoryRecord = undefined;
    var history_bytes: [1024]u8 = undefined;
    var history = tui.editor.History.init(&records, &history_bytes, .reject);
    var editor = try tui.editor.Model.init(&storage, "");
    editor.setHistory(&history);
    var random: u64 = 0xA24B_AED4_963E_E407;

    for (0..500) |_| {
        switch (nextRandom(&random) % 5) {
            0 => {
                const byte: u8 = @intCast('a' + nextRandom(&random) % 26);
                _ = editor.handle(.{ .text = &.{byte} });
            },
            1 => _ = editor.handle(.{ .key = .{ .code = .backspace } }),
            2 => _ = editor.handle(.{ .key = .{ .code = .delete } }),
            3 => _ = editor.handle(.{ .key = .{ .code = .left } }),
            4 => _ = editor.handle(.{ .key = .{ .code = .right } }),
            else => unreachable,
        }
        try std.testing.expect(editor.cursor <= editor.value().len);
        try std.testing.expect(std.unicode.utf8ValidateSlice(editor.value()));
    }

    var final: [64]u8 = undefined;
    const final_len = editor.value().len;
    @memcpy(final[0..final_len], editor.value());
    while (editor.canUndo()) {
        try std.testing.expect(try editor.undo());
        try std.testing.expect(editor.cursor <= editor.value().len);
    }
    while (editor.canRedo()) {
        try std.testing.expect(try editor.redo());
        try std.testing.expect(editor.cursor <= editor.value().len);
    }
    try std.testing.expectEqualSlices(u8, final[0..final_len], editor.value());
}

test "renderer mutations match a plain ASCII grid without allocation" {
    const width = 32;
    const height = 12;
    var allocator_state = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var renderer = try tui.render.Renderer.init(
        allocator_state.allocator(),
        .{ .width = width, .height = height },
        .{},
    );
    defer renderer.deinit();
    allocator_state.fail_index = allocator_state.alloc_index;
    allocator_state.resize_fail_index = allocator_state.resize_index;

    var expected: [width * height]u8 = @splat(' ');
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.Writer.Discarding.init(&output_buffer);
    var random: u64 = 0x4528_21E6_38D0_1377;

    for (0..20_000) |iteration| {
        const x: u16 = @intCast(nextRandom(&random) % width);
        const y: u16 = @intCast(nextRandom(&random) % height);
        const operation = nextRandom(&random) % 5;
        var frame = renderer.frame();
        switch (operation) {
            0 => {
                var text: [8]u8 = undefined;
                const length = 1 + nextRandom(&random) % text.len;
                for (text[0..length]) |*byte| byte.* = @intCast('!' + nextRandom(&random) % ('~' - '!' + 1));
                _ = try frame.putText(.{ .x = x, .y = y }, text[0..length], .{}, .narrow);
                const count = @min(length, width - x);
                @memcpy(expected[@as(usize, y) * width + x ..][0..count], text[0..count]);
            },
            1 => {
                const rect_width: u16 = @intCast(1 + nextRandom(&random) % 12);
                const rect_height: u16 = @intCast(1 + nextRandom(&random) % 5);
                const glyph: u8 = @intCast('!' + nextRandom(&random) % ('~' - '!' + 1));
                const rect = tui.render.Rect{ .x = x, .y = y, .width = rect_width, .height = rect_height };
                try frame.fillAscii(rect, glyph, .{});
                fillModel(&expected, width, height, rect, glyph);
            },
            2 => {
                const rect = tui.render.Rect{
                    .x = x,
                    .y = y,
                    .width = @intCast(1 + nextRandom(&random) % 12),
                    .height = @intCast(1 + nextRandom(&random) % 5),
                };
                try frame.fill(rect, .{});
                fillModel(&expected, width, height, rect, ' ');
            },
            3 => renderer.invalidate(.{
                .x = x,
                .y = y,
                .width = @intCast(1 + nextRandom(&random) % 12),
                .height = @intCast(1 + nextRandom(&random) % 5),
            }),
            4 => _ = try renderer.present(&output.writer, .{}),
            else => unreachable,
        }

        if (iteration % 127 == 0) {
            _ = try renderer.present(&output.writer, .{});
            try expectGrid(&renderer, &expected, width, height);
        }
    }
    _ = try renderer.present(&output.writer, .{});
    try expectGrid(&renderer, &expected, width, height);
    try std.testing.expect(!allocator_state.has_induced_failure);
}

test "renderer reuses initial capacity across many resizes" {
    var allocator_state = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var renderer = try tui.render.Renderer.init(
        allocator_state.allocator(),
        .{ .width = 40, .height = 20 },
        .{},
    );
    defer renderer.deinit();
    allocator_state.fail_index = allocator_state.alloc_index;
    allocator_state.resize_fail_index = allocator_state.resize_index;

    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.Writer.Discarding.init(&output_buffer);
    var random: u64 = 0xBE54_66CF_34E9_0C6C;
    for (0..5_000) |_| {
        const size = tui.render.Size{
            .width = @intCast(1 + nextRandom(&random) % 40),
            .height = @intCast(1 + nextRandom(&random) % 20),
        };
        try renderer.resize(size);
        var frame = renderer.frame();
        _ = try frame.putText(.{ .x = 0, .y = 0 }, "ok", .{}, .narrow);
        _ = try renderer.present(&output.writer, .{});
        try std.testing.expectEqual(size, renderer.size());
        try std.testing.expectEqual(@as(u32, 'o'), renderer.desiredCell(.{ .x = 0, .y = 0 }).?.glyph);
    }
    try std.testing.expect(!allocator_state.has_induced_failure);
}

fn fillModel(
    cells: []u8,
    width: u16,
    height: u16,
    rect: tui.render.Rect,
    glyph: u8,
) void {
    const end_x: u16 = @intCast(@min(@as(u32, width), rect.right()));
    const end_y: u16 = @intCast(@min(@as(u32, height), rect.bottom()));
    var y = rect.y;
    while (y < end_y) : (y += 1) {
        @memset(cells[@as(usize, y) * width + rect.x .. @as(usize, y) * width + end_x], glyph);
    }
}

fn expectGrid(
    renderer: *const tui.render.Renderer,
    expected: []const u8,
    width: u16,
    height: u16,
) !void {
    var y: u16 = 0;
    while (y < height) : (y += 1) {
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            try std.testing.expectEqual(
                @as(u32, expected[@as(usize, y) * width + x]),
                renderer.desiredCell(.{ .x = x, .y = y }).?.glyph,
            );
        }
    }
}

fn nextRandom(state: *u64) usize {
    state.* = state.* *% 2_862_933_555_777_941_757 +% 3_037_000_493;
    return @truncate(state.* >> 16);
}
