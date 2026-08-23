const std = @import("std");
const tui = @import("tui");

test "OSC 8 hyperlink output is profile-gated with a discoverable fallback" {
    const hyperlink = tui.terminal.Hyperlink{
        .label = "tui.zig docs",
        .uri = "https://example.com/tui.zig",
    };
    var linked_buffer: [128]u8 = undefined;
    var linked = std.Io.Writer.fixed(&linked_buffer);
    try tui.terminal.writeHyperlink(&linked, .{ .hyperlinks = true }, hyperlink);
    try std.testing.expectEqualStrings(
        "\x1b]8;;https://example.com/tui.zig\x1b\\tui.zig docs\x1b]8;;\x1b\\",
        linked.buffered(),
    );

    var fallback_buffer: [128]u8 = undefined;
    var fallback = std.Io.Writer.fixed(&fallback_buffer);
    try tui.terminal.writeHyperlink(&fallback, .{}, hyperlink);
    try std.testing.expectEqualStrings("tui.zig docs <https://example.com/tui.zig>", fallback.buffered());
}

test "OSC 52 clipboard output requires endpoint and action opt-in" {
    var storage: [64]u8 = undefined;
    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    try std.testing.expectEqual(
        tui.terminal.ClipboardResult.emitted,
        try tui.terminal.writeClipboard(
            &output,
            .{ .clipboard_write = true },
            .{ .write_only = 8 },
            "copy\nme",
            &storage,
        ),
    );
    try std.testing.expectEqualStrings("\x1b]52;c;Y29weQptZQ==\x07", output.buffered());

    var disabled_buffer: [1]u8 = undefined;
    var disabled = std.Io.Writer.fixed(&disabled_buffer);
    try std.testing.expectEqual(
        tui.terminal.ClipboardResult.disabled,
        try tui.terminal.writeClipboard(&disabled, .{ .clipboard_write = true }, .deny, "copy\nme", &.{}),
    );
    try std.testing.expectEqual(@as(usize, 0), disabled.buffered().len);
}

test "terminal feedback uses explicit bell policy and a host notification backend" {
    var bell_buffer: [1]u8 = undefined;
    var bell = std.Io.Writer.fixed(&bell_buffer);
    try std.testing.expectEqual(tui.terminal.BellResult.emitted, try tui.terminal.writeBell(&bell, .terminal));

    const Backend = struct {
        calls: usize = 0,

        pub fn notify(self: *@This(), notification: tui.terminal.Notification) !void {
            try std.testing.expectEqualStrings("task complete", notification.body);
            self.calls += 1;
        }
    };
    var backend: Backend = .{};
    try std.testing.expectEqual(
        tui.terminal.NotificationDispatchResult.dispatched,
        try tui.terminal.dispatchNotification(
            tui.terminal.NotificationBackend.init(&backend),
            .{ .body = "task complete" },
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), backend.calls);
}

test "ANSI output replays to the desired terminal cells" {
    var renderer = try tui.render.Renderer.init(std.testing.allocator, .{ .width = 10, .height = 2 }, .{});
    defer renderer.deinit();

    var frame = renderer.frame();
    _ = try frame.putText(.{ .x = 0, .y = 0 }, "A", .{}, .narrow);
    _ = try frame.putText(.{ .x = 2, .y = 0 }, "\xE7\x95\x8C", .{}, .narrow);
    _ = try frame.putText(.{ .x = 5, .y = 0 }, "Z", .{}, .narrow);

    var first_buffer: [2048]u8 = undefined;
    var first_writer = std.Io.Writer.fixed(&first_buffer);
    _ = try renderer.present(&first_writer, .{});

    var terminal = VirtualTerminal.init(10, 2);
    try terminal.apply(first_writer.buffered());
    try std.testing.expectEqual(@as(u21, 'A'), terminal.at(0, 0));
    try std.testing.expectEqual(@as(u21, 0x754C), terminal.at(2, 0));
    try std.testing.expectEqual(VirtualTerminal.continuation, terminal.at(3, 0));
    try std.testing.expectEqual(@as(u21, 'Z'), terminal.at(5, 0));

    renderer.invalidate(.{ .x = 0, .y = 0, .width = 6, .height = 1 });
    frame = renderer.frame();
    _ = try frame.putText(.{ .x = 0, .y = 0 }, "B", .{}, .narrow);
    try frame.fill(.{ .x = 5, .y = 0, .width = 1, .height = 1 }, .{});

    var second_buffer: [2048]u8 = undefined;
    var second_writer = std.Io.Writer.fixed(&second_buffer);
    _ = try renderer.present(&second_writer, .{});
    try terminal.apply(second_writer.buffered());
    try std.testing.expectEqual(@as(u21, 'B'), terminal.at(0, 0));
    try std.testing.expectEqual(@as(u21, 0x754C), terminal.at(2, 0));
    try std.testing.expectEqual(@as(u21, ' '), terminal.at(5, 0));
}

test "scroll output replays the desired rows" {
    var renderer = try tui.render.Renderer.init(std.testing.allocator, .{ .width = 6, .height = 4 }, .{});
    defer renderer.deinit();
    var frame = renderer.frame();
    _ = try frame.putTextPadded(.{ .x = 0, .y = 1 }, "a", 6, .{}, .narrow);
    _ = try frame.putTextPadded(.{ .x = 0, .y = 2 }, "b", 6, .{}, .narrow);
    _ = try frame.putTextPadded(.{ .x = 0, .y = 3 }, "c", 6, .{}, .narrow);
    var first_buffer: [2048]u8 = undefined;
    var first_writer = std.Io.Writer.fixed(&first_buffer);
    _ = try renderer.present(&first_writer, .{});

    var terminal = VirtualTerminal.init(6, 4);
    try terminal.apply(first_writer.buffered());
    try renderer.scrollUp(.{ .x = 0, .y = 1, .width = 6, .height = 3 });
    frame = renderer.frame();
    _ = try frame.putTextPadded(.{ .x = 0, .y = 3 }, "d", 6, .{}, .narrow);
    var second_buffer: [1024]u8 = undefined;
    var second_writer = std.Io.Writer.fixed(&second_buffer);
    _ = try renderer.present(&second_writer, .{});
    try terminal.apply(second_writer.buffered());

    try std.testing.expectEqual(@as(u21, 'b'), terminal.at(0, 1));
    try std.testing.expectEqual(@as(u21, 'c'), terminal.at(0, 2));
    try std.testing.expectEqual(@as(u21, 'd'), terminal.at(0, 3));
}

test "random styled frames replay to renderer state" {
    const width = 20;
    const height = 6;
    const styles = [_]tui.render.Style{
        .{},
        .{ .foreground = .{ .indexed = 2 }, .attributes = .{ .bold = true } },
        .{ .background = .{ .indexed = 4 }, .attributes = .{ .underline = true } },
        .{
            .foreground = .{ .rgb = .{ .r = 231, .g = 76, .b = 60 } },
            .background = .{ .rgb = .{ .r = 20, .g = 30, .b = 40 } },
            .attributes = .{ .italic = true, .reverse = true },
        },
        .{ .foreground = .{ .indexed = 12 }, .attributes = .{ .dim = true, .strike = true } },
    };
    const capabilities = tui.terminal.Capabilities{
        .color_depth = .truecolor,
        .synchronized_output = true,
    };
    var renderer = try tui.render.Renderer.init(
        std.testing.allocator,
        .{ .width = width, .height = height },
        .{ .style_capacity = styles.len + 1 },
    );
    defer renderer.deinit();
    var terminal = VirtualTerminal.init(width, height);
    var random: u64 = 0x3F84_D5B5_B547_0917;

    for (0..1_000) |_| {
        var frame = renderer.frame();
        const mutation_count = 1 + nextRandom(&random) % 8;
        for (0..mutation_count) |_| {
            const x: u16 = @intCast(nextRandom(&random) % width);
            const y: u16 = @intCast(nextRandom(&random) % height);
            const style = styles[nextRandom(&random) % styles.len];
            switch (nextRandom(&random) % 4) {
                0 => {
                    var text: [6]u8 = undefined;
                    const length = 1 + nextRandom(&random) % text.len;
                    for (text[0..length]) |*byte| byte.* = @intCast('!' + nextRandom(&random) % ('~' - '!' + 1));
                    _ = try frame.putText(.{ .x = x, .y = y }, text[0..length], style, .narrow);
                },
                1 => try frame.fillAscii(.{
                    .x = x,
                    .y = y,
                    .width = @intCast(1 + nextRandom(&random) % 8),
                    .height = @intCast(1 + nextRandom(&random) % 3),
                }, @intCast('!' + nextRandom(&random) % ('~' - '!' + 1)), style),
                2 => try frame.fill(.{
                    .x = x,
                    .y = y,
                    .width = @intCast(1 + nextRandom(&random) % 8),
                    .height = @intCast(1 + nextRandom(&random) % 3),
                }, style),
                3 => renderer.invalidate(.{
                    .x = x,
                    .y = y,
                    .width = @intCast(1 + nextRandom(&random) % 8),
                    .height = @intCast(1 + nextRandom(&random) % 3),
                }),
                else => unreachable,
            }
        }

        var output_buffer: [16 * 1024]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        _ = try renderer.present(&output, capabilities);
        try terminal.apply(output.buffered());
        try expectTerminalMatchesRenderer(&terminal, &renderer);
    }
}

test "terminal shadow reset restores an unchanged desired frame" {
    var allocator_state = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var renderer = try tui.render.Renderer.init(allocator_state.allocator(), .{ .width = 8, .height = 2 }, .{});
    defer renderer.deinit();
    var frame = renderer.frame();
    _ = try frame.putText(.{ .x = 1, .y = 0 }, "ready", .{
        .foreground = .{ .indexed = 2 },
        .attributes = .{ .bold = true },
    }, .narrow);

    var initial_buffer: [1024]u8 = undefined;
    var initial = std.Io.Writer.fixed(&initial_buffer);
    _ = try renderer.present(&initial, .{});
    var terminal = VirtualTerminal.init(8, 2);
    try terminal.apply(initial.buffered());
    try terminal.apply("\x1b[0m\x1b[2J\x1b[Hcorrupt");

    allocator_state.fail_index = allocator_state.alloc_index;
    allocator_state.resize_fail_index = allocator_state.resize_index;
    renderer.invalidateTerminal();
    var recovery_buffer: [1024]u8 = undefined;
    var recovery = std.Io.Writer.fixed(&recovery_buffer);
    const stats = try renderer.present(&recovery, .{});
    try std.testing.expect(stats.full_repaint);
    try std.testing.expect(std.mem.indexOf(u8, recovery.buffered(), "\x1b[2J") != null);
    try terminal.apply(recovery.buffered());
    try expectTerminalMatchesRenderer(&terminal, &renderer);
    try std.testing.expect(!allocator_state.has_induced_failure);

    var unchanged_buffer: [32]u8 = undefined;
    var unchanged = std.Io.Writer.fixed(&unchanged_buffer);
    try std.testing.expectEqual(@as(usize, 0), (try renderer.present(&unchanged, .{})).bytes);
}

test "hardware cursor updates without cell damage and survives recovery" {
    var allocator_state = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var renderer = try tui.render.Renderer.init(allocator_state.allocator(), .{ .width = 8, .height = 2 }, .{});
    defer renderer.deinit();
    var initial_buffer: [256]u8 = undefined;
    var initial = std.Io.Writer.fixed(&initial_buffer);
    _ = try renderer.present(&initial, .{});
    try std.testing.expect(std.mem.indexOf(u8, initial.buffered(), "\x1b[?25") == null);
    try std.testing.expect(std.mem.indexOf(u8, initial.buffered(), " q") == null);

    allocator_state.fail_index = allocator_state.alloc_index;
    allocator_state.resize_fail_index = allocator_state.resize_index;
    renderer.setCursor(.{
        .position = .{ .x = 3, .y = 1 },
        .shape = .steady_bar,
    });
    var cursor_buffer: [128]u8 = undefined;
    var cursor_output = std.Io.Writer.fixed(&cursor_buffer);
    const cursor_stats = try renderer.present(&cursor_output, .{});
    try std.testing.expectEqual(@as(u32, 0), cursor_stats.cells_compared);
    try std.testing.expectEqual(@as(u32, 0), cursor_stats.cells_changed);
    try std.testing.expect(std.mem.indexOf(u8, cursor_output.buffered(), "\x1b[6 q") != null);
    try std.testing.expect(std.mem.indexOf(u8, cursor_output.buffered(), "\x1b[?25h") != null);
    var terminal = VirtualTerminal.init(8, 2);
    try terminal.apply(initial.buffered());
    try terminal.apply(cursor_output.buffered());
    try std.testing.expect(terminal.cursor_visible);
    try std.testing.expectEqual(tui.render.CursorShape.steady_bar, terminal.cursor_shape);
    try std.testing.expectEqual(@as(u16, 3), terminal.column);
    try std.testing.expectEqual(@as(u16, 1), terminal.row);

    renderer.setCursor(.{
        .position = .{ .x = 3, .y = 1 },
        .shape = .steady_bar,
    });
    var unchanged_buffer: [16]u8 = undefined;
    var unchanged = std.Io.Writer.fixed(&unchanged_buffer);
    try std.testing.expectEqual(@as(usize, 0), (try renderer.present(&unchanged, .{})).bytes);

    renderer.invalidateTerminal();
    var recovery_buffer: [512]u8 = undefined;
    var recovery = std.Io.Writer.fixed(&recovery_buffer);
    const recovery_stats = try renderer.present(&recovery, .{});
    try std.testing.expect(recovery_stats.full_repaint);
    try std.testing.expect(std.mem.indexOf(u8, recovery.buffered(), "\x1b[6 q") != null);
    try std.testing.expect(std.mem.indexOf(u8, recovery.buffered(), "\x1b[?25h") != null);
    try std.testing.expect(!allocator_state.has_induced_failure);
}

test "out-of-bounds cursor hides until the renderer grows" {
    var renderer = try tui.render.Renderer.init(std.testing.allocator, .{ .width = 4, .height = 2 }, .{});
    defer renderer.deinit();
    renderer.setCursor(.{ .position = .{ .x = 7, .y = 1 }, .shape = .steady_underline });
    var hidden_buffer: [256]u8 = undefined;
    var hidden = std.Io.Writer.fixed(&hidden_buffer);
    _ = try renderer.present(&hidden, .{});
    try std.testing.expect(std.mem.indexOf(u8, hidden.buffered(), "\x1b[?25l") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden.buffered(), "\x1b[2;8H") == null);

    try renderer.resize(.{ .width = 8, .height = 2 });
    var visible_buffer: [512]u8 = undefined;
    var visible = std.Io.Writer.fixed(&visible_buffer);
    _ = try renderer.present(&visible, .{});
    try std.testing.expect(std.mem.indexOf(u8, visible.buffered(), "\x1b[2;8H") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible.buffered(), "\x1b[?25h") != null);
}

const VirtualTerminal = struct {
    const continuation: u21 = std.math.maxInt(u21);

    width: u16,
    height: u16,
    row: u16 = 0,
    column: u16 = 0,
    scroll_top: u16 = 0,
    scroll_bottom: u16,
    cells: [256]u21,
    styles: [256]tui.render.Style,
    current_style: tui.render.Style = .{},
    cursor_visible: bool = true,
    cursor_shape: tui.render.CursorShape = .default,

    fn init(width: u16, height: u16) VirtualTerminal {
        const result = VirtualTerminal{
            .width = width,
            .height = height,
            .scroll_bottom = height,
            .cells = @splat(' '),
            .styles = @splat(.{}),
        };
        std.debug.assert(@as(usize, width) * height <= result.cells.len);
        return result;
    }

    fn at(self: *const VirtualTerminal, x: u16, y: u16) u21 {
        return self.cells[@as(usize, y) * self.width + x];
    }

    fn styleAt(self: *const VirtualTerminal, x: u16, y: u16) tui.render.Style {
        return self.styles[@as(usize, y) * self.width + x];
    }

    fn apply(self: *VirtualTerminal, bytes: []const u8) !void {
        var index: usize = 0;
        while (index < bytes.len) {
            if (bytes[index] == 0x1B) {
                if (index + 1 >= bytes.len or bytes[index + 1] != '[') return error.UnsupportedEscape;
                index += 2;
                const parameter_start = index;
                while (index < bytes.len and !(bytes[index] >= 0x40 and bytes[index] <= 0x7E)) : (index += 1) {}
                if (index == bytes.len) return error.TruncatedEscape;
                const final = bytes[index];
                try self.csi(bytes[parameter_start..index], final);
                index += 1;
                continue;
            }
            if (bytes[index] == '\r') {
                self.column = 0;
                index += 1;
                continue;
            }

            const length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch return error.InvalidUtf8;
            const end = index + length;
            if (end > bytes.len) return error.InvalidUtf8;
            const codepoint = try std.unicode.utf8Decode(bytes[index..end]);
            const display_width = try tui.text.graphemeWidth(bytes[index..end], .narrow);
            if (self.row >= self.height or self.column >= self.width) return error.CursorOutOfBounds;
            const cell_index = @as(usize, self.row) * self.width + self.column;
            self.cells[cell_index] = codepoint;
            self.styles[cell_index] = self.current_style;
            if (display_width == 2) {
                if (self.column + 1 >= self.width) return error.CursorOutOfBounds;
                self.cells[cell_index + 1] = continuation;
                self.styles[cell_index + 1] = self.current_style;
            }
            self.column += display_width;
            index = end;
        }
    }

    fn csi(self: *VirtualTerminal, parameters: []const u8, final: u8) !void {
        switch (final) {
            'H' => {
                var fields = std.mem.splitScalar(u8, parameters, ';');
                const row = parseParameter(fields.next(), 1);
                const column = parseParameter(fields.next(), 1);
                if (row == 0 or column == 0 or row > self.height or column > self.width) return error.CursorOutOfBounds;
                self.row = row - 1;
                self.column = column - 1;
            },
            'C' => self.column += parseParameter(parameters, 1),
            'D' => self.column -= parseParameter(parameters, 1),
            'J' => if (std.mem.eql(u8, parameters, "2")) {
                @memset(self.cells[0 .. @as(usize, self.width) * self.height], ' ');
                @memset(self.styles[0 .. @as(usize, self.width) * self.height], self.current_style);
            },
            'K' => {
                var column = self.column;
                while (column < self.width) : (column += 1) {
                    const index = @as(usize, self.row) * self.width + column;
                    self.cells[index] = ' ';
                    self.styles[index] = self.current_style;
                }
            },
            'r' => {
                if (parameters.len == 0) {
                    self.scroll_top = 0;
                    self.scroll_bottom = self.height;
                } else {
                    var fields = std.mem.splitScalar(u8, parameters, ';');
                    const top = parseParameter(fields.next(), 1);
                    const bottom = parseParameter(fields.next(), self.height);
                    if (top == 0 or bottom <= top or bottom > self.height) return error.InvalidScrollRegion;
                    self.scroll_top = top - 1;
                    self.scroll_bottom = bottom;
                }
                self.row = 0;
                self.column = 0;
            },
            'S' => {
                const count = parseParameter(parameters, 1);
                for (0..count) |_| {
                    var row = self.scroll_top;
                    while (row + 1 < self.scroll_bottom) : (row += 1) {
                        const destination = @as(usize, row) * self.width;
                        const source = @as(usize, row + 1) * self.width;
                        std.mem.copyForwards(
                            u21,
                            self.cells[destination .. destination + self.width],
                            self.cells[source .. source + self.width],
                        );
                        std.mem.copyForwards(
                            tui.render.Style,
                            self.styles[destination .. destination + self.width],
                            self.styles[source .. source + self.width],
                        );
                    }
                    const last = @as(usize, self.scroll_bottom - 1) * self.width;
                    @memset(self.cells[last .. last + self.width], ' ');
                    @memset(self.styles[last .. last + self.width], self.current_style);
                }
            },
            'm' => try self.sgr(parameters),
            'h' => {
                if (std.mem.eql(u8, parameters, "?25")) self.cursor_visible = true;
            },
            'l' => {
                if (std.mem.eql(u8, parameters, "?25")) self.cursor_visible = false;
            },
            'q' => {
                const value = std.mem.trimEnd(u8, parameters, " ");
                const raw = std.fmt.parseInt(u3, value, 10) catch return error.UnsupportedCursorShape;
                if (raw > 6) return error.UnsupportedCursorShape;
                self.cursor_shape = @enumFromInt(raw);
            },
            else => return error.UnsupportedEscape,
        }
    }

    fn sgr(self: *VirtualTerminal, parameters: []const u8) !void {
        var values: [8]u16 = undefined;
        var count: usize = 0;
        var fields = std.mem.splitScalar(u8, parameters, ';');
        while (fields.next()) |field| {
            if (count == values.len) return error.UnsupportedSgr;
            values[count] = if (field.len == 0) 0 else std.fmt.parseInt(u16, field, 10) catch return error.UnsupportedSgr;
            count += 1;
        }
        if (count == 0) {
            values[0] = 0;
            count = 1;
        }

        var index: usize = 0;
        while (index < count) : (index += 1) {
            switch (values[index]) {
                0 => self.current_style = .{},
                1 => self.current_style.attributes.bold = true,
                2 => self.current_style.attributes.dim = true,
                3 => self.current_style.attributes.italic = true,
                4 => self.current_style.attributes.underline = true,
                5 => self.current_style.attributes.blink = true,
                7 => self.current_style.attributes.reverse = true,
                8 => self.current_style.attributes.hidden = true,
                9 => self.current_style.attributes.strike = true,
                22 => {
                    self.current_style.attributes.bold = false;
                    self.current_style.attributes.dim = false;
                },
                23 => self.current_style.attributes.italic = false,
                24 => self.current_style.attributes.underline = false,
                25 => self.current_style.attributes.blink = false,
                27 => self.current_style.attributes.reverse = false,
                28 => self.current_style.attributes.hidden = false,
                29 => self.current_style.attributes.strike = false,
                30...37 => self.current_style.foreground = .{ .indexed = @intCast(values[index] - 30) },
                39 => self.current_style.foreground = .default,
                40...47 => self.current_style.background = .{ .indexed = @intCast(values[index] - 40) },
                49 => self.current_style.background = .default,
                90...97 => self.current_style.foreground = .{ .indexed = @intCast(values[index] - 90 + 8) },
                100...107 => self.current_style.background = .{ .indexed = @intCast(values[index] - 100 + 8) },
                38, 48 => {
                    const foreground = values[index] == 38;
                    if (index + 2 < count and values[index + 1] == 5) {
                        const color = tui.render.Color{ .indexed = @intCast(values[index + 2]) };
                        if (foreground) self.current_style.foreground = color else self.current_style.background = color;
                        index += 2;
                    } else if (index + 4 < count and values[index + 1] == 2) {
                        const color = tui.render.Color{ .rgb = .{
                            .r = @intCast(values[index + 2]),
                            .g = @intCast(values[index + 3]),
                            .b = @intCast(values[index + 4]),
                        } };
                        if (foreground) self.current_style.foreground = color else self.current_style.background = color;
                        index += 4;
                    } else return error.UnsupportedSgr;
                },
                else => return error.UnsupportedSgr,
            }
        }
    }
};

fn expectTerminalMatchesRenderer(terminal: *const VirtualTerminal, renderer: *const tui.render.Renderer) !void {
    const size = renderer.size();
    var y: u16 = 0;
    while (y < size.height) : (y += 1) {
        var x: u16 = 0;
        while (x < size.width) : (x += 1) {
            var glyph_storage: [tui.text.max_grapheme_bytes]u8 = undefined;
            const cell = renderer.desiredCellView(.{ .x = x, .y = y }, &glyph_storage).?;
            try std.testing.expectEqual(
                if (cell.width == .continuation) VirtualTerminal.continuation else @as(u21, cell.glyph[0]),
                terminal.at(x, y),
            );
            try std.testing.expect(cell.style.eql(terminal.styleAt(x, y)));
        }
    }
}

fn nextRandom(state: *u64) usize {
    state.* = state.* *% 3_202_034_522_624_059_733 +% 1;
    return @truncate(state.* >> 16);
}

fn parseParameter(optional: ?[]const u8, default: u16) u16 {
    const value = optional orelse return default;
    if (value.len == 0) return default;
    return std.fmt.parseInt(u16, value, 10) catch default;
}
