//! Multiline presentation and input handling for a caller-owned editor model.

const std = @import("std");
const editor = @import("../editor.zig");
const input = @import("../input.zig");
const render = @import("../render.zig");
const text = @import("../text.zig");
const theme = @import("../theme.zig");
const Update = @import("update.zig").Update;

pub const TextArea = struct {
    model: *editor.Model,
    role: theme.Role = .{},
    selection_role: theme.Role = .{
        .normal = .{ .attributes = .{ .reverse = true } },
    },
    enabled: bool = true,
    focused: bool = false,
    pending_failure: ?editor.EditError = null,

    pub fn handle(self: *TextArea, event: input.Event) Update {
        if (!self.enabled) {
            _ = self.model.handle(.paste_end);
            return .ignored;
        }
        const result = self.model.handle(event);
        if (result.failure) |failure| if (self.pending_failure == null) {
            self.pending_failure = failure;
        };
        return switch (result.status) {
            .ignored => .ignored,
            .handled => .handled,
            .redraw => .redraw,
        };
    }

    pub fn takeFailure(self: *TextArea) ?editor.EditError {
        const failure = self.pending_failure;
        self.pending_failure = null;
        return failure;
    }

    pub fn draw(self: *TextArea, surface: *render.Surface) !void {
        const size = surface.size();
        _ = self.model.setViewportSize(size.width, size.height);
        if (size.width == 0 or size.height == 0) return;

        const state = theme.State.from(self.enabled, self.focused);
        const base_style = self.role.resolve(state);
        const selected_style = self.selection_role.resolve(state);
        try surface.fill(render.Rect.fromSize(size), base_style);

        if (self.model.softWrapEnabled()) {
            try self.drawSoftRows(surface, base_style, selected_style);
            return;
        }

        const rows = self.model.visibleRows();
        const value = self.model.value();
        const first = self.model.lineRange(rows.start) orelse unreachable;
        const selection = self.model.selection();
        const cursor = self.model.cursorPosition();
        var line_start = first.start;
        var line_end = first.end;
        var row = rows.start;
        var y: u16 = 0;
        while (row < rows.end) : ({
            row += 1;
            y += 1;
        }) {
            const end_x = try self.drawLine(
                surface,
                y,
                line_start,
                line_end,
                selection,
                base_style,
                selected_style,
            );
            if (selection) |selected| {
                if (line_end < value.len and selected.start <= line_end and selected.end > line_end) {
                    if (end_x) |x| _ = try surface.putText(.{ .x = x, .y = y }, " ", selected_style, self.model.width_profile);
                }
            }
            if (self.enabled and self.focused and row == cursor.row) {
                try self.drawCaret(surface, y, line_start, line_end, cursor.column, selection, base_style, selected_style);
            }

            if (row + 1 < rows.end) {
                line_start = line_end + 1;
                const relative_end = std.mem.indexOfScalar(u8, value[line_start..], '\n') orelse value.len - line_start;
                line_end = line_start + relative_end;
            }
        }
    }

    fn drawSoftRows(
        self: *const TextArea,
        surface: *render.Surface,
        base_style: render.Style,
        selected_style: render.Style,
    ) !void {
        const selection = self.model.selection();
        const cursor = self.model.visualCursorPosition();
        const value = self.model.value();
        var rows = self.model.visualRows();
        const first_row = self.model.viewport.top_row;
        const end_row = first_row +| self.model.viewport.height;
        var row_index: usize = 0;
        while (row_index < first_row) : (row_index += 1) _ = rows.next().?;

        var y: u16 = 0;
        while (row_index < end_row) : ({
            row_index += 1;
            y += 1;
        }) {
            const row = rows.next() orelse break;
            const end_x = try self.drawLine(
                surface,
                y,
                row.start,
                row.end,
                selection,
                base_style,
                selected_style,
            );
            if (row.break_kind == .hard) {
                if (selection) |selected| {
                    if (row.end < value.len and selected.start <= row.end and selected.end > row.end) {
                        if (end_x) |x| _ = try surface.putText(.{ .x = x, .y = y }, " ", selected_style, self.model.width_profile);
                    }
                }
            }
            if (self.enabled and self.focused and row_index == cursor.row) {
                try self.drawCaret(
                    surface,
                    y,
                    row.start,
                    row.end,
                    cursor.column,
                    selection,
                    base_style,
                    selected_style,
                );
            }
        }
    }

    fn drawLine(
        self: *const TextArea,
        surface: *render.Surface,
        y: u16,
        line_start: usize,
        line_end: usize,
        selection: ?editor.Selection,
        base_style: render.Style,
        selected_style: render.Style,
    ) !?u16 {
        const line = self.model.value()[line_start..line_end];
        const left = self.model.viewport.left_column;
        var column: usize = line.len;
        var visible_start: ?usize = if (printableAscii(line) and left <= line.len) left else null;
        var x: usize = 0;
        if (visible_start == null) {
            var iterator = text.GraphemeIterator.init(line) catch unreachable;
            column = 0;
            while (iterator.next()) |cluster| {
                const width = cluster.displayWidthAssumeValid(self.model.width_profile) catch unreachable;
                if (width == 0) return error.ZeroWidthGrapheme;
                const next_column = column + width;
                if (visible_start == null and next_column > left) {
                    const cluster_start = @intFromPtr(cluster.bytes.ptr) - @intFromPtr(line.ptr);
                    if (column < left) {
                        visible_start = cluster_start + cluster.bytes.len;
                        x = next_column - left;
                    } else {
                        visible_start = cluster_start;
                        x = column - left;
                    }
                }
                column = next_column;
            }
            if (visible_start == null and left == column) visible_start = line.len;
        }
        const start = visible_start orelse return null;
        if (x < surface.size().width and start < line.len) {
            var byte = line_start + start;
            if (selection) |selected| {
                const selected_start = @min(@max(selected.start, byte), line_end);
                const selected_end = @min(@max(selected.end, byte), line_end);
                x += try drawSegment(surface, y, x, self.model.value()[byte..selected_start], base_style, self.model.width_profile);
                byte = selected_start;
                x += try drawSegment(surface, y, x, self.model.value()[byte..selected_end], selected_style, self.model.width_profile);
                byte = selected_end;
            }
            _ = try drawSegment(surface, y, x, self.model.value()[byte..line_end], base_style, self.model.width_profile);
        }
        if (column < left or column - left >= surface.size().width) return null;
        return @intCast(column - left);
    }

    fn drawCaret(
        self: *const TextArea,
        surface: *render.Surface,
        y: u16,
        line_start: usize,
        line_end: usize,
        cursor_column: usize,
        selection: ?editor.Selection,
        base_style: render.Style,
        selected_style: render.Style,
    ) !void {
        if (cursor_column < self.model.viewport.left_column) return;
        var x = cursor_column - self.model.viewport.left_column;
        var caret_offset = self.model.cursor;
        var caret_text: []const u8 = " ";
        if (x >= surface.size().width) {
            if (self.model.cursor == line_start) return;
            var clusters = text.GraphemeIterator.init(self.model.value()[line_start..self.model.cursor]) catch unreachable;
            var previous_start = line_start;
            var previous_width: usize = 0;
            var previous_text: []const u8 = "";
            while (clusters.next()) |cluster| {
                previous_start = @intFromPtr(cluster.bytes.ptr) - @intFromPtr(self.model.value().ptr);
                previous_width = cluster.displayWidthAssumeValid(self.model.width_profile) catch unreachable;
                previous_text = cluster.bytes;
            }
            x -|= previous_width;
            if (x >= surface.size().width) return;
            caret_offset = previous_start;
            if (previous_width <= surface.size().width - @as(u16, @intCast(x))) caret_text = previous_text;
        }

        var caret_style = if (selection) |selected|
            if (caret_offset >= selected.start and caret_offset < selected.end) selected_style else base_style
        else
            base_style;
        caret_style.attributes.reverse = !caret_style.attributes.reverse;

        if (self.model.cursor < line_end) {
            var iterator = text.GraphemeIterator.init(self.model.value()[self.model.cursor..line_end]) catch unreachable;
            if (iterator.next()) |cluster| {
                const width = cluster.displayWidthAssumeValid(self.model.width_profile) catch unreachable;
                if (width <= surface.size().width - @as(u16, @intCast(x))) caret_text = cluster.bytes;
            }
        }
        _ = try surface.putText(.{ .x = @intCast(x), .y = y }, caret_text, caret_style, self.model.width_profile);
    }
};

fn drawSegment(
    surface: *render.Surface,
    y: u16,
    x: usize,
    value: []const u8,
    style: render.Style,
    width_profile: text.WidthProfile,
) !u16 {
    if (value.len == 0 or x >= surface.size().width) return 0;
    return surface.putText(.{ .x = @intCast(x), .y = y }, value, style, width_profile);
}

fn printableAscii(value: []const u8) bool {
    for (value) |byte| if (byte < 0x20 or byte > 0x7e) return false;
    return true;
}

test "text area owns rows and styles multiline selections" {
    var storage: [32]u8 = undefined;
    var model = try editor.Model.init(&storage, "zero\none\ntwo");
    _ = model.setViewportSize(5, 2);
    try std.testing.expect(try model.setSelection(1, 7));
    model.viewport.top_row = 0;
    var area = TextArea{
        .model = &model,
        .role = .{ .normal = .{ .foreground = .{ .indexed = 2 } } },
        .selection_role = .{ .normal = .{ .background = .{ .indexed = 4 } } },
    };
    var renderer = try render.Renderer.init(std.testing.allocator, .{ .width = 5, .height = 2 }, .{});
    defer renderer.deinit();

    var frame = renderer.frame();
    var surface = frame.surface(render.Rect.fromSize(renderer.size()));
    try area.draw(&surface);
    var glyph: [text.max_grapheme_bytes]u8 = undefined;
    try std.testing.expectEqual(
        render.Color{ .indexed = 4 },
        renderer.desiredCellView(.{ .x = 1, .y = 0 }, &glyph).?.style.background,
    );
    try std.testing.expectEqualStrings(" ", renderer.desiredCellView(.{ .x = 4, .y = 0 }, &glyph).?.glyph);
    try std.testing.expectEqual(
        render.Color{ .indexed = 4 },
        renderer.desiredCellView(.{ .x = 4, .y = 0 }, &glyph).?.style.background,
    );
    try std.testing.expectEqual(
        render.Color{ .indexed = 4 },
        renderer.desiredCellView(.{ .x = 0, .y = 1 }, &glyph).?.style.background,
    );

    try std.testing.expect(model.selectAll());
    try std.testing.expect(try model.replaceSelection("x"));
    frame = renderer.frame();
    surface = frame.surface(render.Rect.fromSize(renderer.size()));
    try area.draw(&surface);
    try std.testing.expectEqualStrings("x", renderer.desiredCellView(.{ .x = 0, .y = 0 }, &glyph).?.glyph);
    try std.testing.expectEqualStrings(" ", renderer.desiredCellView(.{ .x = 0, .y = 1 }, &glyph).?.glyph);
    try std.testing.expectEqual(
        render.Color{ .indexed = 2 },
        renderer.desiredCellView(.{ .x = 0, .y = 1 }, &glyph).?.style.foreground,
    );
}

test "text area clips a wide grapheme at the left viewport edge" {
    var storage: [16]u8 = undefined;
    var model = try editor.Model.init(&storage, "\xE7\x95\x8CA");
    try std.testing.expect(try model.setCursor(3));
    model.viewport.left_column = 1;
    var area = TextArea{ .model = &model };
    var renderer = try render.Renderer.init(std.testing.allocator, .{ .width = 2, .height = 1 }, .{});
    defer renderer.deinit();
    var frame = renderer.frame();
    var surface = frame.surface(render.Rect.fromSize(renderer.size()));
    try area.draw(&surface);

    var glyph: [text.max_grapheme_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(" ", renderer.desiredCellView(.{ .x = 0, .y = 0 }, &glyph).?.glyph);
    try std.testing.expectEqualStrings("A", renderer.desiredCellView(.{ .x = 1, .y = 0 }, &glyph).?.glyph);
}

test "text area renders grapheme-safe soft rows and selections" {
    var storage: [32]u8 = undefined;
    var model = try editor.Model.init(&storage, "ab\xE7\x95\x8Ccd\nxy");
    _ = model.setSoftWrap(true);
    try std.testing.expect(try model.setSelection(1, 9));
    var area = TextArea{
        .model = &model,
        .focused = true,
        .selection_role = .{ .normal = .{ .background = .{ .indexed = 4 } } },
    };
    var renderer = try render.Renderer.init(std.testing.allocator, .{ .width = 4, .height = 3 }, .{});
    defer renderer.deinit();
    var frame = renderer.frame();
    var surface = frame.surface(render.Rect.fromSize(renderer.size()));
    try area.draw(&surface);

    var glyph: [text.max_grapheme_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("a", renderer.desiredCellView(.{ .x = 0, .y = 0 }, &glyph).?.glyph);
    try std.testing.expectEqualStrings("\xE7\x95\x8C", renderer.desiredCellView(.{ .x = 2, .y = 0 }, &glyph).?.glyph);
    try std.testing.expectEqual(render.CellWidth.continuation, renderer.desiredCell(.{ .x = 3, .y = 0 }).?.width);
    try std.testing.expectEqualStrings("c", renderer.desiredCellView(.{ .x = 0, .y = 1 }, &glyph).?.glyph);
    try std.testing.expectEqualStrings("x", renderer.desiredCellView(.{ .x = 0, .y = 2 }, &glyph).?.glyph);
    try std.testing.expectEqual(
        render.Color{ .indexed = 4 },
        renderer.desiredCellView(.{ .x = 2, .y = 1 }, &glyph).?.style.background,
    );
    try std.testing.expectEqual(
        render.Color{ .indexed = 4 },
        renderer.desiredCellView(.{ .x = 0, .y = 2 }, &glyph).?.style.background,
    );
}

test "text area drawing and handling allocate nothing" {
    var storage: [64]u8 = undefined;
    var model = try editor.Model.init(&storage, "alpha\nbeta");
    var area = TextArea{ .model = &model, .focused = true };
    var allocator_state = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var renderer = try render.Renderer.init(allocator_state.allocator(), .{ .width = 4, .height = 2 }, .{});
    defer renderer.deinit();
    allocator_state.fail_index = allocator_state.alloc_index;
    allocator_state.resize_fail_index = allocator_state.resize_index;

    try std.testing.expectEqual(Update.redraw, area.handle(.{ .key = .{ .code = .left } }));
    var frame = renderer.frame();
    var surface = frame.surface(render.Rect.fromSize(renderer.size()));
    try area.draw(&surface);
    _ = model.setSoftWrap(true);
    try std.testing.expectEqual(Update.redraw, area.handle(.{ .key = .{ .code = .home } }));
    frame = renderer.frame();
    surface = frame.surface(render.Rect.fromSize(renderer.size()));
    try area.draw(&surface);
    try std.testing.expect(!allocator_state.has_induced_failure);
}
