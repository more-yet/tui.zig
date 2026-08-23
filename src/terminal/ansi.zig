const std = @import("std");
const cursor_module = @import("../render/cursor.zig");
const style_module = @import("../render/style.zig");
const capabilities_module = @import("capabilities.zig");

const spaces: [256]u8 = @splat(' ');

pub const Stats = struct {
    bytes: usize = 0,
};

pub const State = struct {
    cursor_known: bool = false,
    row: u16 = 0,
    column: u16 = 0,
    style_known: bool = false,
    style: style_module.Style = .{},
    color_depth: capabilities_module.ColorDepth = .ansi16,

    pub fn invalidate(self: *State) void {
        self.cursor_known = false;
        self.style_known = false;
    }
};

pub const CursorState = struct {
    cursor_visibility_known: bool = false,
    cursor_visible: bool = false,
    cursor_shape_known: bool = false,
    cursor_shape: cursor_module.Shape = .default,

    pub fn invalidate(self: *CursorState) void {
        self.cursor_visibility_known = false;
        self.cursor_shape_known = false;
    }
};

pub const Encoder = struct {
    writer: *std.Io.Writer,
    capabilities: capabilities_module.Capabilities,
    terminal_width: u16,
    state: *State,
    cursor_state: *CursorState,
    stats: *Stats,

    pub fn beginSynchronized(self: *Encoder) std.Io.Writer.Error!void {
        if (self.capabilities.synchronized_output) try self.emit("\x1b[?2026h");
    }

    pub fn endSynchronized(self: *Encoder) std.Io.Writer.Error!void {
        if (self.capabilities.synchronized_output) try self.emit("\x1b[?2026l");
    }

    pub fn clear(self: *Encoder) std.Io.Writer.Error!void {
        try self.emit("\x1b[0m\x1b[2J\x1b[H");
        self.state.* = .{
            .cursor_known = true,
            .style_known = true,
            .color_depth = self.capabilities.color_depth,
        };
    }

    pub inline fn moveTo(self: *Encoder, row: u16, column: u16) std.Io.Writer.Error!void {
        if (self.state.cursor_known and self.state.row == row and self.state.column == column) return;

        if (self.state.cursor_known and self.state.row == row) {
            if (column == 0) {
                try self.emit("\r");
                self.state.column = 0;
                return;
            }

            const delta = if (column > self.state.column) column - self.state.column else self.state.column - column;
            if (delta == 1) {
                try self.emit(if (column > self.state.column) "\x1b[C" else "\x1b[D");
                self.state.column = column;
                return;
            }
        }
        return self.moveToChanged(row, column);
    }

    noinline fn moveToChanged(self: *Encoder, row: u16, column: u16) std.Io.Writer.Error!void {
        if (self.state.cursor_known and self.state.row == row) {
            const absolute_cost = 4 + digits(row + 1) + digits(column + 1);
            const delta = if (column > self.state.column) column - self.state.column else self.state.column - column;
            const relative_cost = 3 + digits(delta);
            if (delta > 0 and relative_cost < absolute_cost) {
                var buffer: [24]u8 = undefined;
                const sequence = if (column > self.state.column)
                    std.fmt.bufPrint(&buffer, "\x1b[{d}C", .{delta}) catch unreachable
                else
                    std.fmt.bufPrint(&buffer, "\x1b[{d}D", .{delta}) catch unreachable;
                try self.emit(sequence);
                self.state.column = column;
                return;
            }
        }

        var buffer: [32]u8 = undefined;
        const sequence = std.fmt.bufPrint(&buffer, "\x1b[{d};{d}H", .{ row + 1, column + 1 }) catch unreachable;
        try self.emit(sequence);
        self.state.cursor_known = true;
        self.state.row = row;
        self.state.column = column;
    }

    pub inline fn setStyle(self: *Encoder, target: style_module.Style) std.Io.Writer.Error!void {
        if (self.state.style_known and self.state.color_depth == self.capabilities.color_depth and
            self.state.style.eql(target)) return;
        return self.setStyleChanged(target);
    }

    noinline fn setStyleChanged(self: *Encoder, target: style_module.Style) std.Io.Writer.Error!void {
        if (!self.state.style_known or self.state.color_depth != self.capabilities.color_depth) {
            try self.sgr(0);
            self.state.style = .{};
            self.state.style_known = true;
            self.state.color_depth = self.capabilities.color_depth;
        }

        const current = self.state.style;
        const old_attributes: u8 = @bitCast(current.attributes);
        const new_attributes: u8 = @bitCast(target.attributes);
        if (old_attributes != new_attributes) try self.setAttributes(current.attributes, target.attributes);
        if (!colorEql(current.foreground, target.foreground)) try self.setColor(target.foreground, true);
        if (!colorEql(current.background, target.background)) try self.setColor(target.background, false);

        self.state.style = target;
    }

    pub fn writeGlyph(self: *Encoder, bytes: []const u8, width: u2) std.Io.Writer.Error!void {
        try self.emit(bytes);
        self.advance(width);
    }

    pub fn writeAscii(self: *Encoder, bytes: []const u8) std.Io.Writer.Error!void {
        try self.emit(bytes);
        self.advance(@intCast(bytes.len));
    }

    pub fn writeSpaces(self: *Encoder, count: u16) std.Io.Writer.Error!void {
        var remaining = count;
        while (remaining > 0) {
            const chunk: u16 = @min(remaining, spaces.len);
            try self.emit(spaces[0..chunk]);
            remaining -= chunk;
        }
        self.advance(count);
    }

    fn advance(self: *Encoder, width: u16) void {
        if (!self.state.cursor_known) return;
        const next = @as(u32, self.state.column) + width;
        if (next >= self.terminal_width) {
            self.state.cursor_known = false;
        } else {
            self.state.column = @intCast(next);
        }
    }

    pub fn eraseLineRight(self: *Encoder) std.Io.Writer.Error!void {
        try self.emit("\x1b[K");
    }

    pub fn scrollUp(self: *Encoder, top: u16, bottom: u16) std.Io.Writer.Error!void {
        var buffer: [32]u8 = undefined;
        const sequence = std.fmt.bufPrint(
            &buffer,
            "\x1b[{d};{d}r\x1b[S\x1b[r",
            .{ top + 1, bottom },
        ) catch unreachable;
        try self.emit(sequence);
        self.state.cursor_known = false;
    }

    pub fn setCursor(self: *Encoder, target: cursor_module.Cursor, in_bounds: bool) std.Io.Writer.Error!bool {
        const visible = target.visible and in_bounds;
        const visibility_changed = !self.cursor_state.cursor_visibility_known or self.cursor_state.cursor_visible != visible;
        const shape_changed = !self.cursor_state.cursor_shape_known or self.cursor_state.cursor_shape != target.shape;
        const position_changed = in_bounds and (!self.state.cursor_known or
            self.state.row != target.position.y or self.state.column != target.position.x);
        if (!visibility_changed and !shape_changed and !position_changed) return false;

        if (visibility_changed and !visible) try self.setCursorVisible(false);
        if (shape_changed) {
            try self.emit(cursor_shape_sequences[@intFromEnum(target.shape)]);
            self.cursor_state.cursor_shape_known = true;
            self.cursor_state.cursor_shape = target.shape;
        }
        if (in_bounds) try self.moveTo(target.position.y, target.position.x);
        if (visibility_changed and visible) try self.setCursorVisible(true);
        return true;
    }

    fn setCursorVisible(self: *Encoder, visible: bool) std.Io.Writer.Error!void {
        try self.emit(if (visible) "\x1b[?25h" else "\x1b[?25l");
        self.cursor_state.cursor_visibility_known = true;
        self.cursor_state.cursor_visible = visible;
    }

    fn setAttributes(
        self: *Encoder,
        current: style_module.Attributes,
        target: style_module.Attributes,
    ) std.Io.Writer.Error!void {
        if ((current.bold and !target.bold) or (current.dim and !target.dim)) {
            try self.sgr(22);
            if (target.bold) try self.sgr(1);
            if (target.dim) try self.sgr(2);
        } else {
            if (!current.bold and target.bold) try self.sgr(1);
            if (!current.dim and target.dim) try self.sgr(2);
        }
        try self.toggleAttribute(current.italic, target.italic, 3, 23);
        try self.toggleAttribute(current.underline, target.underline, 4, 24);
        try self.toggleAttribute(current.blink, target.blink, 5, 25);
        try self.toggleAttribute(current.reverse, target.reverse, 7, 27);
        try self.toggleAttribute(current.hidden, target.hidden, 8, 28);
        try self.toggleAttribute(current.strike, target.strike, 9, 29);
    }

    fn toggleAttribute(self: *Encoder, current: bool, target: bool, on: u8, off: u8) std.Io.Writer.Error!void {
        if (current == target) return;
        try self.sgr(if (target) on else off);
    }

    fn setColor(self: *Encoder, color: style_module.Color, foreground: bool) std.Io.Writer.Error!void {
        switch (color) {
            .default => try self.sgr(if (foreground) 39 else 49),
            .indexed => |index| try self.indexedColor(index, foreground),
            .rgb => |rgb| switch (self.capabilities.color_depth) {
                .truecolor => {
                    var buffer: [32]u8 = undefined;
                    const sequence = if (foreground)
                        std.fmt.bufPrint(&buffer, "\x1b[38;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b }) catch unreachable
                    else
                        std.fmt.bufPrint(&buffer, "\x1b[48;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b }) catch unreachable;
                    try self.emit(sequence);
                },
                .indexed256 => try self.indexedColor(rgbToIndex(rgb), foreground),
                .ansi16 => try self.indexedColor(rgbToAnsi(rgb), foreground),
            },
        }
    }

    fn indexedColor(self: *Encoder, raw_index: u8, foreground: bool) std.Io.Writer.Error!void {
        const index = if (self.capabilities.color_depth == .ansi16) raw_index % 16 else raw_index;
        if (index < 8) {
            try self.sgr((if (foreground) @as(u16, 30) else 40) + index);
        } else if (index < 16) {
            try self.sgr((if (foreground) @as(u16, 90) else 100) + index - 8);
        } else {
            var buffer: [24]u8 = undefined;
            const sequence = if (foreground)
                std.fmt.bufPrint(&buffer, "\x1b[38;5;{d}m", .{index}) catch unreachable
            else
                std.fmt.bufPrint(&buffer, "\x1b[48;5;{d}m", .{index}) catch unreachable;
            try self.emit(sequence);
        }
    }

    fn sgr(self: *Encoder, code: u16) std.Io.Writer.Error!void {
        var buffer: [16]u8 = undefined;
        const sequence = std.fmt.bufPrint(&buffer, "\x1b[{d}m", .{code}) catch unreachable;
        try self.emit(sequence);
    }

    fn emit(self: *Encoder, bytes: []const u8) std.Io.Writer.Error!void {
        try self.writer.writeAll(bytes);
        self.stats.bytes += bytes.len;
    }
};

const cursor_shape_sequences = [_][]const u8{
    "\x1b[0 q",
    "\x1b[1 q",
    "\x1b[2 q",
    "\x1b[3 q",
    "\x1b[4 q",
    "\x1b[5 q",
    "\x1b[6 q",
};

fn colorEql(lhs: style_module.Color, rhs: style_module.Color) bool {
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
    return switch (lhs) {
        .default => true,
        .indexed => |value| value == rhs.indexed,
        .rgb => |value| value.r == rhs.rgb.r and value.g == rhs.rgb.g and value.b == rhs.rgb.b,
    };
}

fn rgbToIndex(rgb: style_module.Rgb) u8 {
    const r: u8 = @intCast((@as(u16, rgb.r) * 5 + 127) / 255);
    const g: u8 = @intCast((@as(u16, rgb.g) * 5 + 127) / 255);
    const b: u8 = @intCast((@as(u16, rgb.b) * 5 + 127) / 255);
    return 16 + 36 * r + 6 * g + b;
}

fn rgbToAnsi(rgb: style_module.Rgb) u8 {
    const bright = @max(rgb.r, @max(rgb.g, rgb.b)) >= 192;
    var index: u8 = 0;
    if (rgb.r >= 96) index |= 1;
    if (rgb.g >= 96) index |= 2;
    if (rgb.b >= 96) index |= 4;
    if (bright and index != 0) index += 8;
    return index;
}

fn digits(value: u16) usize {
    if (value < 10) return 1;
    if (value < 100) return 2;
    if (value < 1000) return 3;
    if (value < 10000) return 4;
    return 5;
}

test "RGB styles follow the configured color depth" {
    const cases = [_]struct {
        depth: capabilities_module.ColorDepth,
        expected: []const u8,
    }{
        .{ .depth = .truecolor, .expected = "\x1b[38;2;255;0;0m" },
        .{ .depth = .indexed256, .expected = "\x1b[38;5;196m" },
        .{ .depth = .ansi16, .expected = "\x1b[91m" },
    };

    for (cases) |case| {
        var output_buffer: [64]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        var state: State = .{};
        var cursor_state: CursorState = .{};
        var stats: Stats = .{};
        var encoder = Encoder{
            .writer = &output,
            .capabilities = .{ .color_depth = case.depth },
            .terminal_width = 80,
            .state = &state,
            .cursor_state = &cursor_state,
            .stats = &stats,
        };
        try encoder.setStyle(.{ .foreground = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } } });
        try std.testing.expect(std.mem.indexOf(u8, output.buffered(), case.expected) != null);
    }
}

test "cursor shapes map to fixed safe sequences" {
    const expected = [_][]const u8{
        "\x1b[0 q",
        "\x1b[1 q",
        "\x1b[2 q",
        "\x1b[3 q",
        "\x1b[4 q",
        "\x1b[5 q",
        "\x1b[6 q",
    };
    for (std.meta.tags(cursor_module.Shape), expected) |shape, sequence| {
        var output_buffer: [32]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        var state = State{
            .cursor_known = true,
            .row = 2,
            .column = 3,
        };
        var cursor_state = CursorState{ .cursor_visibility_known = true };
        var stats: Stats = .{};
        var encoder = Encoder{
            .writer = &output,
            .capabilities = .{},
            .terminal_width = 80,
            .state = &state,
            .cursor_state = &cursor_state,
            .stats = &stats,
        };
        const target = cursor_module.Cursor{
            .position = .{ .x = 3, .y = 2 },
            .visible = false,
            .shape = shape,
        };
        try std.testing.expect(try encoder.setCursor(target, true));
        try std.testing.expectEqualStrings(sequence, output.buffered());
        try std.testing.expect(!(try encoder.setCursor(target, true)));
    }
}

test "clear preserves cursor properties and invalidation forgets them" {
    var output_buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var state = State{
        .cursor_known = false,
    };
    var cursor_state = CursorState{
        .cursor_visibility_known = true,
        .cursor_visible = true,
        .cursor_shape_known = true,
        .cursor_shape = .steady_bar,
    };
    var stats: Stats = .{};
    var encoder = Encoder{
        .writer = &output,
        .capabilities = .{},
        .terminal_width = 80,
        .state = &state,
        .cursor_state = &cursor_state,
        .stats = &stats,
    };
    try encoder.clear();
    try std.testing.expect(cursor_state.cursor_visibility_known);
    try std.testing.expect(cursor_state.cursor_visible);
    try std.testing.expect(cursor_state.cursor_shape_known);
    try std.testing.expectEqual(cursor_module.Shape.steady_bar, cursor_state.cursor_shape);

    cursor_state.invalidate();
    try std.testing.expect(!cursor_state.cursor_visibility_known);
    try std.testing.expect(!cursor_state.cursor_shape_known);
}
