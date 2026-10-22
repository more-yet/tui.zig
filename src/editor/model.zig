const std = @import("std");
const grapheme = @import("../text/grapheme.zig");
const input = @import("../input/event.zig");
const memory = @import("../core/memory.zig");
const validation = @import("validation.zig");
const actions = @import("actions.zig");
const history_module = @import("history.zig");
const input_history = @import("input_history.zig");

pub const Selection = struct {
    start: usize,
    end: usize,
};
pub const Action = actions.Action;
pub const ActionMode = actions.Mode;
pub const defaultAction = actions.defaultAction;
pub const History = history_module.History;
pub const HistoryRecord = history_module.Record;
pub const HistoryError = history_module.Error;
pub const InputHistory = input_history.InputHistory;
pub const InputHistoryEntry = input_history.Entry;
pub const InputHistoryError = input_history.Error;

pub const Position = struct {
    row: usize,
    column: usize,
};

pub const RowRange = struct {
    start: usize,
    end: usize,
};

pub const VisualBreak = enum {
    soft,
    hard,
    end,
};

pub const VisualRow = struct {
    start: usize,
    end: usize,
    width: usize,
    break_kind: VisualBreak,
};

pub const RowWindow = struct {
    byte_start: u32,
    byte_end: u32,
    screen_column: u16,
    display_width: u16,
    newline_column: ?u16,
};

pub const CaretWindow = struct {
    bytes: []const u8,
    byte_offset: u32,
    screen_column: u16,
    row: u32,
};

pub const Boundary = struct {
    offset: u32,
    row: u32,
    column: u32,
};

/// Keep slices fixed, disjoint, and alive for the model lifetime.
pub const Storage = struct {
    text: []u8,
    boundaries: []Boundary,
    visual_rows: []VisualRow,
    paste: []u8,
};

/// Example: `var storage: tui.editor.FixedStorage(256) = .{};`
/// Use `Storage` with one `VisualRow` for compact non-wrapped single-line fields.
pub fn FixedStorage(comptime text_capacity: usize) type {
    return struct {
        text: [text_capacity]u8 = undefined,
        boundaries: [text_capacity + 1]Boundary = undefined,
        visual_rows: [text_capacity + 1]VisualRow = undefined,
        paste: [text_capacity]u8 = undefined,

        pub fn slices(self: *@This()) Storage {
            return .{
                .text = &self.text,
                .boundaries = &self.boundaries,
                .visual_rows = &self.visual_rows,
                .paste = &self.paste,
            };
        }
    };
}

pub const Viewport = struct {
    top_row: usize = 0,
    left_column: usize = 0,
    width: u16 = 0,
    height: u16 = 0,
};

pub const InitError = error{
    BufferTooSmall,
    IndexCapacityExceeded,
    InvalidText,
    OverlappingStorage,
};

pub const EditError = error{
    CapacityExceeded,
    InvalidText,
    InvalidBoundary,
    OverlappingInput,
    HistoryCapacityExceeded,
    PasteCapacityExceeded,
    OverlappingStorage,
};

fn storageSlicesOverlap(storage: Storage) bool {
    const slices = [_][]const u8{
        storage.text,
        std.mem.sliceAsBytes(storage.boundaries),
        std.mem.sliceAsBytes(storage.visual_rows),
        storage.paste,
    };
    for (slices, 0..) |lhs, lhs_index| {
        for (slices[lhs_index + 1 ..]) |rhs| {
            if (memory.slicesOverlap(lhs, rhs)) return true;
        }
    }
    return false;
}

pub const EventStatus = enum {
    ignored,
    handled,
    redraw,
};

pub const EventResult = struct {
    status: EventStatus,
    failure: ?EditError = null,
};

const CursorAffinity = enum {
    forward,
    backward,
};

const PasteState = union(enum) {
    idle,
    collecting: struct {
        len: usize,
        revision: u64,
        cursor_offset: usize,
        anchor: ?usize,
    },
    discarding,
};

pub const Model = struct {
    storage: []u8,
    boundaries: []Boundary,
    boundary_count: usize,
    visual_row_storage: []VisualRow,
    visual_row_count: usize,
    paste_storage: []u8,
    len: usize,
    cursor_boundary: usize,
    line_count: usize,
    anchor: ?usize = null,
    viewport: Viewport = .{},
    width_profile: grapheme.WidthProfile = .narrow,
    soft_wrap: bool = false,
    multiline: bool = true,
    revision: u64 = 0,
    preferred_column: ?usize = null,
    cursor_affinity: CursorAffinity = .forward,
    paste_state: PasteState = .idle,
    history: ?*History = null,

    /// Example: `var model = try tui.editor.Model.init(storage.slices(), "hello");`
    pub fn init(storage: Storage, initial: []const u8) InitError!Model {
        return initMode(storage, initial, true);
    }

    /// Rejects newlines. Without wrapping, one visual-row slot is sufficient.
    pub fn initSingleLine(storage: Storage, initial: []const u8) InitError!Model {
        return initMode(storage, initial, false);
    }

    fn initMode(storage: Storage, initial: []const u8, multiline: bool) InitError!Model {
        if (storage.text.len > std.math.maxInt(u32)) return error.BufferTooSmall;
        if (initial.len > storage.text.len) return error.BufferTooSmall;
        if (storage.boundaries.len < initial.len + 1) return error.IndexCapacityExceeded;
        const required_rows = if (multiline) initial.len + 1 else 1;
        if (storage.visual_rows.len < required_rows) return error.IndexCapacityExceeded;
        if (storageSlicesOverlap(storage)) return error.OverlappingStorage;
        try validateText(initial, multiline);
        @memmove(storage.text[0..initial.len], initial);
        var result: Model = .{
            .storage = storage.text,
            .boundaries = storage.boundaries,
            .boundary_count = 0,
            .visual_row_storage = storage.visual_rows,
            .visual_row_count = 0,
            .paste_storage = storage.paste,
            .len = initial.len,
            .cursor_boundary = 0,
            .line_count = 1,
            .multiline = multiline,
        };
        result.rebuildBoundaries();
        result.cursor_boundary = result.boundary_count - 1;
        result.rebuildVisualRows();
        return result;
    }

    pub fn value(self: *const Model) []const u8 {
        return self.storage[0..self.len];
    }

    /// Ends all model borrows and erases full storage capacities. Separately owned
    /// history is not erased. Finish/cancel staged paste first; reinitialize to reuse.
    pub fn secureDeinit(self: *Model) error{PasteActive}!void {
        if (self.paste_state != .idle) return error.PasteActive;
        memory.secureZero(self.storage);
        memory.secureZero(std.mem.sliceAsBytes(self.boundaries));
        memory.secureZero(std.mem.sliceAsBytes(self.visual_row_storage));
        memory.secureZero(self.paste_storage);
        memory.secureZero(std.mem.asBytes(self));
    }

    fn rebuildBoundaries(self: *Model) void {
        var iterator = grapheme.Iterator{ .input = self.value() };
        var count: usize = 0;
        var row: u32 = 0;
        var column: u32 = 0;
        while (iterator.next()) |cluster| {
            const offset = @intFromPtr(cluster.bytes.ptr) - @intFromPtr(self.value().ptr);
            self.boundaries[count] = .{ .offset = @intCast(offset), .row = row, .column = column };
            count += 1;
            if (std.mem.eql(u8, cluster.bytes, "\n")) {
                row += 1;
                column = 0;
            } else {
                const width = cluster.displayWidthAssumeValid(self.width_profile) catch unreachable;
                column += width;
            }
        }
        self.boundaries[count] = .{ .offset = @intCast(self.len), .row = row, .column = column };
        self.boundary_count = count + 1;
        self.line_count = @as(usize, row) + 1;
    }

    fn rebuildVisualRows(self: *Model) void {
        if (!self.multiline and !self.soft_wrap) {
            self.visual_row_storage[0] = .{
                .start = 0,
                .end = self.len,
                .width = self.boundaries[self.boundary_count - 1].column,
                .break_kind = .end,
            };
            self.visual_row_count = 1;
            return;
        }
        var count: usize = 0;
        var row_start: usize = 0;
        var row_width: usize = 0;
        const wrap_width: ?usize = if (self.softWrapActive()) self.viewport.width else null;

        var boundary_index: usize = 0;
        while (boundary_index + 1 < self.boundary_count) : (boundary_index += 1) {
            const current = self.boundaries[boundary_index];
            const next = self.boundaries[boundary_index + 1];
            if (current.row != next.row) {
                self.visual_row_storage[count] = .{
                    .start = row_start,
                    .end = current.offset,
                    .width = row_width,
                    .break_kind = .hard,
                };
                count += 1;
                row_start = next.offset;
                row_width = 0;
                continue;
            }

            const cluster_width = next.column - current.column;
            if (wrap_width) |width| {
                if (row_width != 0 and row_width + cluster_width > width) {
                    self.visual_row_storage[count] = .{
                        .start = row_start,
                        .end = current.offset,
                        .width = row_width,
                        .break_kind = .soft,
                    };
                    count += 1;
                    row_start = current.offset;
                    row_width = 0;
                }
            }
            row_width += cluster_width;
        }

        self.visual_row_storage[count] = .{
            .start = row_start,
            .end = self.len,
            .width = row_width,
            .break_kind = .end,
        };
        count += 1;
        self.visual_row_count = count;
    }

    fn boundaryIndex(self: *const Model, offset: usize) ?usize {
        if (offset > std.math.maxInt(u32)) return null;
        const needle: u32 = @intCast(offset);
        var low: usize = 0;
        var high = self.boundary_count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const candidate = self.boundaries[middle].offset;
            if (candidate < needle) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        if (low == self.boundary_count or self.boundaries[low].offset != needle) return null;
        return low;
    }

    fn firstBoundaryForRow(self: *const Model, row: usize) ?usize {
        if (row > std.math.maxInt(u32)) return null;
        const needle: u32 = @intCast(row);
        var low: usize = 0;
        var high = self.boundary_count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.boundaries[middle].row < needle) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        if (low == self.boundary_count or self.boundaries[low].row != needle) return null;
        return low;
    }

    fn snapBoundaryIndex(self: *const Model, offset: usize, affinity: CursorAffinity) usize {
        const needle: u32 = @intCast(offset);
        var low: usize = 0;
        var high = self.boundary_count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.boundaries[middle].offset < needle) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        if (low < self.boundary_count and self.boundaries[low].offset == needle) return low;
        return switch (affinity) {
            .forward => @min(low, self.boundary_count - 1),
            .backward => low -| 1,
        };
    }

    fn boundaryForColumn(self: *const Model, start: usize, end: usize, target_column: usize) usize {
        const start_index = self.boundaryIndex(start) orelse unreachable;
        const end_index = self.boundaryIndex(end) orelse unreachable;
        const base_column = self.boundaries[start_index].column;
        const target = std.math.add(u32, base_column, @intCast(@min(target_column, std.math.maxInt(u32)))) catch
            std.math.maxInt(u32);
        var low = start_index;
        var high = end_index + 1;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.boundaries[middle].column <= target) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        return low - 1;
    }

    fn cursorGraphemeWidth(self: *const Model) usize {
        std.debug.assert(self.cursor_boundary < self.boundary_count);
        if (self.cursor_boundary + 1 == self.boundary_count or self.value()[self.cursorOffset()] == '\n') return 0;
        return self.boundaries[self.cursor_boundary + 1].column - self.boundaries[self.cursor_boundary].column;
    }

    pub fn lineCount(self: *const Model) usize {
        return self.line_count;
    }

    pub fn line(self: *const Model, row: usize) ?[]const u8 {
        const bounds = self.lineBounds(row) orelse return null;
        return self.value()[bounds.start..bounds.end];
    }

    pub fn lineRange(self: *const Model, row: usize) ?Selection {
        const bounds = self.lineBounds(row) orelse return null;
        return .{ .start = bounds.start, .end = bounds.end };
    }

    fn lineBounds(self: *const Model, row: usize) ?LineBounds {
        if (row >= self.line_count) return null;
        const start_index = self.firstBoundaryForRow(row) orelse return null;
        const start: usize = self.boundaries[start_index].offset;
        const next_index = self.firstBoundaryForRow(row + 1);
        const end: usize = if (next_index) |index| self.boundaries[index].offset - 1 else self.len;
        return .{ .row = row, .start = start, .end = end };
    }

    pub fn selection(self: *const Model) ?Selection {
        const anchor = self.anchor orelse return null;
        const cursor = self.cursorOffset();
        if (anchor == cursor) return null;
        return .{ .start = @min(anchor, cursor), .end = @max(anchor, cursor) };
    }

    pub fn selectedText(self: *const Model) ?[]const u8 {
        const selected = self.selection() orelse return null;
        return self.value()[selected.start..selected.end];
    }

    /// UTF-8 byte offset, not display column or grapheme index.
    pub fn cursorOffset(self: *const Model) usize {
        std.debug.assert(self.cursor_boundary < self.boundary_count);
        return self.boundaries[self.cursor_boundary].offset;
    }

    pub fn cursorPosition(self: *const Model) Position {
        std.debug.assert(self.cursor_boundary < self.boundary_count);
        const boundary = self.boundaries[self.cursor_boundary];
        return .{ .row = boundary.row, .column = boundary.column };
    }

    pub fn visibleRows(self: *const Model) RowRange {
        const count = self.visual_row_count;
        const start = @min(self.viewport.top_row, count - 1);
        return .{
            .start = start,
            .end = start + @min(count - start, self.viewport.height),
        };
    }

    pub fn setViewportSize(self: *Model, width: u16, height: u16) bool {
        const previous = self.viewport;
        self.viewport.width = width;
        self.viewport.height = height;
        if (previous.width != width) {
            self.preferred_column = null;
            if (self.soft_wrap) {
                self.viewport.top_row = 0;
                self.rebuildVisualRows();
            }
        }
        self.revealCursor();
        return !std.meta.eql(previous, self.viewport);
    }

    /// Example: `_ = try model.setSoftWrap(true);`
    /// Requires `value().len + 1` row slots when enabled; failure leaves state unchanged.
    pub fn setSoftWrap(self: *Model, enabled: bool) error{IndexCapacityExceeded}!bool {
        if (self.soft_wrap == enabled) return false;
        if (enabled and self.visual_row_storage.len < self.len + 1) return error.IndexCapacityExceeded;
        self.soft_wrap = enabled;
        self.cursor_affinity = .forward;
        self.preferred_column = null;
        self.viewport.top_row = 0;
        self.viewport.left_column = 0;
        self.rebuildVisualRows();
        self.revealCursor();
        return true;
    }

    pub fn softWrapEnabled(self: *const Model) bool {
        return self.soft_wrap;
    }

    /// Recreate after edits, wrap/width-profile changes, or viewport-width changes.
    pub fn visualRows(self: *const Model) VisualRowIterator {
        return .{ .rows = self.visual_row_storage[0..self.visual_row_count] };
    }

    pub fn visualRowsFrom(self: *const Model, start: usize) VisualRowIterator {
        const clamped = @min(start, self.visual_row_count);
        return .{ .rows = self.visual_row_storage[clamped..self.visual_row_count] };
    }

    /// Borrowed until edits or layout changes; partial edge graphemes are omitted.
    pub fn visibleRowWindow(
        self: *const Model,
        row_index: usize,
        left_column: usize,
        width: u16,
    ) ?RowWindow {
        if (row_index >= self.visual_row_count) return null;
        const row = self.visual_row_storage[row_index];
        if (left_column == 0 and row.width <= width) {
            return .{
                .byte_start = @intCast(row.start),
                .byte_end = @intCast(row.end),
                .screen_column = 0,
                .display_width = @intCast(row.width),
                .newline_column = if (row.break_kind == .hard and row.width < width) @intCast(row.width) else null,
            };
        }
        return self.clippedRowWindow(row, left_column, width);
    }

    fn clippedRowWindow(self: *const Model, row: VisualRow, left_column: usize, width: u16) RowWindow {
        const start_index = self.boundaryIndex(row.start) orelse unreachable;
        const end_index = self.boundaryIndex(row.end) orelse unreachable;
        const base_column: usize = self.boundaries[start_index].column;
        const left = std.math.add(usize, base_column, left_column) catch std.math.maxInt(usize);
        const right = std.math.add(usize, left, width) catch std.math.maxInt(usize);

        var visible_start = self.boundaryAtOrBeforeColumn(start_index, end_index, left);
        if (visible_start < end_index and self.boundaries[visible_start].column < left) visible_start += 1;
        var visible_end = self.boundaryAtOrBeforeColumn(visible_start, end_index, right);
        if (visible_end < visible_start) visible_end = visible_start;

        const byte_start = self.boundaries[visible_start].offset;
        const byte_end = self.boundaries[visible_end].offset;
        const start_column: usize = self.boundaries[visible_start].column;
        const end_column: usize = self.boundaries[visible_end].column;
        const newline_column = if (row.break_kind == .hard and row.width >= left_column and
            row.width - left_column < width)
            row.width - left_column
        else
            null;
        return .{
            .byte_start = byte_start,
            .byte_end = byte_end,
            .screen_column = @intCast(start_column -| left),
            .display_width = @intCast(end_column - start_column),
            .newline_column = if (newline_column) |column| @intCast(column) else null,
        };
    }

    pub fn visibleCaretWindow(
        self: *const Model,
        left_column: usize,
        width: u16,
    ) ?CaretWindow {
        if (width == 0) return null;
        const location = if (self.softWrapActive()) self.locateVisualCursor() else location: {
            const cursor = self.cursorPosition();
            break :location VisualLocation{
                .row = cursor.row,
                .column = cursor.column,
                .bounds = self.visual_row_storage[cursor.row],
            };
        };
        if (location.column < left_column) return null;
        const row = location.bounds;
        const cursor_offset = self.cursorOffset();
        var screen_column = location.column - left_column;
        var boundary_index = self.cursor_boundary;

        if (screen_column >= width) {
            if (cursor_offset == row.start or boundary_index == 0) return null;
            boundary_index -= 1;
            const previous = self.boundaries[boundary_index];
            if (previous.offset < row.start) return null;
            const previous_width = self.boundaries[boundary_index + 1].column - previous.column;
            screen_column -|= previous_width;
            if (screen_column >= width) return null;
        }

        const offset: usize = self.boundaries[boundary_index].offset;
        if (offset >= row.end or boundary_index + 1 >= self.boundary_count) {
            return .{
                .bytes = " ",
                .byte_offset = @intCast(cursor_offset),
                .screen_column = @intCast(screen_column),
                .row = @intCast(location.row),
            };
        }
        const end: usize = self.boundaries[boundary_index + 1].offset;
        const grapheme_width = self.boundaries[boundary_index + 1].column -
            self.boundaries[boundary_index].column;
        return .{
            .bytes = if (grapheme_width <= width - screen_column) self.value()[offset..end] else " ",
            .byte_offset = @intCast(offset),
            .screen_column = @intCast(screen_column),
            .row = @intCast(location.row),
        };
    }

    fn boundaryAtOrBeforeColumn(
        self: *const Model,
        start_index: usize,
        end_index: usize,
        target_column: usize,
    ) usize {
        const target: u32 = @intCast(@min(target_column, std.math.maxInt(u32)));
        var low = start_index;
        var high = end_index + 1;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.boundaries[middle].column <= target) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        return low - 1;
    }

    pub fn visualCursorPosition(self: *const Model) Position {
        if (!self.softWrapActive()) return self.cursorPosition();
        const location = self.locateVisualCursor();
        return .{ .row = location.row, .column = location.column };
    }

    pub fn setWidthProfile(self: *Model, profile: grapheme.WidthProfile) bool {
        if (self.width_profile == profile) return false;
        self.width_profile = profile;
        self.rebuildBoundaries();
        self.rebuildVisualRows();
        self.cursor_affinity = .forward;
        self.preferred_column = null;
        if (self.soft_wrap) self.viewport.top_row = 0;
        self.revealCursor();
        return true;
    }

    pub fn setCursor(self: *Model, cursor: usize) EditError!bool {
        return self.setSelection(cursor, cursor);
    }

    pub fn setSelection(self: *Model, anchor: usize, cursor: usize) EditError!bool {
        if (self.boundaryIndex(anchor) == null) return error.InvalidBoundary;
        const cursor_boundary = self.boundaryIndex(cursor) orelse return error.InvalidBoundary;
        const previous_cursor = self.cursorOffset();
        const previous_anchor = self.anchor;
        const previous_affinity = self.cursor_affinity;
        self.cursor_boundary = cursor_boundary;
        self.anchor = if (anchor == cursor) null else anchor;
        self.cursor_affinity = .forward;
        self.preferred_column = null;
        self.revealCursor();
        return self.cursorOffset() != previous_cursor or self.anchor != previous_anchor or self.cursor_affinity != previous_affinity;
    }

    pub fn selectAll(self: *Model) bool {
        const previous_cursor = self.cursorOffset();
        const previous_anchor = self.anchor;
        const previous_affinity = self.cursor_affinity;
        self.anchor = if (self.len == 0) null else 0;
        self.cursor_boundary = self.boundary_count - 1;
        self.cursor_affinity = .forward;
        self.preferred_column = null;
        self.revealCursor();
        return self.cursorOffset() != previous_cursor or self.anchor != previous_anchor or self.cursor_affinity != previous_affinity;
    }

    pub fn replaceSelection(self: *Model, replacement: []const u8) EditError!bool {
        const cursor = self.cursorOffset();
        const selected = self.selection() orelse Selection{ .start = cursor, .end = cursor };
        return self.replaceRange(selected.start, selected.end, replacement);
    }

    /// Clears and exclusively borrows history until detached. Keep its storage disjoint from the model.
    pub fn setHistory(self: *Model, history: ?*History) EditError!void {
        if (history) |history_ptr| {
            const retained = [_][]const u8{
                self.storage,
                std.mem.sliceAsBytes(self.boundaries),
                std.mem.sliceAsBytes(self.visual_row_storage),
                self.paste_storage,
            };
            for (retained) |slice| {
                if (history_ptr.storageOverlaps(slice)) return error.OverlappingStorage;
            }
        }
        self.cancelPaste();
        if (history) |history_ptr| history_ptr.clear();
        self.history = history;
    }

    /// Call if disabling and re-enabling a widget without letting it observe the disabled state.
    pub fn cancelPaste(self: *Model) void {
        self.paste_state = .idle;
    }

    pub fn canUndo(self: *const Model) bool {
        return if (self.history) |history_ptr| history_ptr.canUndo() else false;
    }

    pub fn canRedo(self: *const Model) bool {
        return if (self.history) |history_ptr| history_ptr.canRedo() else false;
    }

    pub fn undo(self: *Model) EditError!bool {
        const history = self.history orelse return false;
        const first = history.peekUndo() orelse return false;
        const transaction = first.transaction;
        while (history.peekUndo()) |edit| {
            if (edit.transaction != transaction) break;
            const end = std.math.add(usize, edit.start, edit.inserted.len) catch return error.InvalidBoundary;
            _ = try self.replaceRangeInternal(edit.start, end, edit.removed, false);
            _ = try self.setSelection(edit.before.anchor orelse edit.before.cursor, edit.before.cursor);
            history.commitUndo();
        }
        return true;
    }

    pub fn redo(self: *Model) EditError!bool {
        const history = self.history orelse return false;
        const first = history.peekRedo() orelse return false;
        const transaction = first.transaction;
        while (history.peekRedo()) |edit| {
            if (edit.transaction != transaction) break;
            const end = std.math.add(usize, edit.start, edit.removed.len) catch return error.InvalidBoundary;
            _ = try self.replaceRangeInternal(edit.start, end, edit.inserted, false);
            _ = try self.setSelection(edit.after.anchor orelse edit.after.cursor, edit.after.cursor);
            history.commitRedo();
        }
        return true;
    }

    pub fn handle(self: *Model, event: input.Event) EventResult {
        return switch (event) {
            .paste_start => result: {
                self.paste_state = .{ .collecting = .{
                    .len = 0,
                    .revision = self.revision,
                    .cursor_offset = self.cursorOffset(),
                    .anchor = self.anchor,
                } };
                break :result .{ .status = .handled };
            },
            .paste_chunk => |bytes| self.stagePasteChunk(bytes),
            .paste_end => self.commitStagedPaste(),
            .malformed => self.abortStagedPaste(),
            else => if (actions.defaultAction(event, if (self.multiline) .multiline else .single_line)) |action|
                self.applyAction(action)
            else
                .{ .status = .ignored },
        };
    }

    pub inline fn applyAction(self: *Model, action: Action) EventResult {
        const changed = switch (action) {
            .move_left => |extend| self.moveLeft(extend),
            .move_right => |extend| self.moveRight(extend),
            .move_up => |extend| self.moveVertical(-1, extend),
            .move_down => |extend| self.moveVertical(1, extend),
            .move_home => |extend| self.moveHome(extend),
            .move_end => |extend| self.moveEnd(extend),
            .page_up => |extend| self.moveVerticalRows(true, pageRows(self.viewport.height), extend),
            .page_down => |extend| self.moveVerticalRows(false, pageRows(self.viewport.height), extend),
            .move_word_left => |extend| self.moveToBoundary(
                self.snapBoundaryIndex(actions.previousWordStart(self.value(), self.cursorOffset()), .backward),
                extend,
                false,
                .forward,
            ),
            .move_word_right => |extend| self.moveToBoundary(
                self.snapBoundaryIndex(actions.nextWordEnd(self.value(), self.cursorOffset()), .forward),
                extend,
                false,
                .forward,
            ),
            .delete_backward => {
                if (self.selection() != null) return editResult(self.replaceSelection(""));
                if (self.cursor_boundary == 0) return .{ .status = .handled };
                return editResult(self.replaceRange(
                    self.boundaries[self.cursor_boundary - 1].offset,
                    self.cursorOffset(),
                    "",
                ));
            },
            .delete_forward => {
                if (self.selection() != null) return editResult(self.replaceSelection(""));
                if (self.cursor_boundary + 1 == self.boundary_count) return .{ .status = .handled };
                return editResult(self.replaceRange(
                    self.cursorOffset(),
                    self.boundaries[self.cursor_boundary + 1].offset,
                    "",
                ));
            },
            .delete_word_backward => {
                if (self.selection() != null) return editResult(self.replaceSelection(""));
                const cursor = self.cursorOffset();
                const start = self.boundaries[
                    self.snapBoundaryIndex(
                        actions.previousWordStart(self.value(), cursor),
                        .backward,
                    )
                ].offset;
                if (start == cursor) return .{ .status = .handled };
                return editResult(self.replaceRange(start, cursor, ""));
            },
            .delete_word_forward => {
                if (self.selection() != null) return editResult(self.replaceSelection(""));
                const cursor = self.cursorOffset();
                const end = self.boundaries[
                    self.snapBoundaryIndex(
                        actions.nextWordEnd(self.value(), cursor),
                        .forward,
                    )
                ].offset;
                if (end == cursor) return .{ .status = .handled };
                return editResult(self.replaceRange(cursor, end, ""));
            },
            .insert_codepoint => |codepoint| {
                var encoded: [4]u8 = undefined;
                const encoded_len = std.unicode.utf8Encode(codepoint, &encoded) catch {
                    return .{ .status = .handled, .failure = error.InvalidText };
                };
                return editResult(self.replaceSelection(encoded[0..encoded_len]));
            },
            .insert_text => |bytes| return editResult(self.replaceSelection(bytes)),
            .insert_newline => return editResult(self.replaceSelection("\n")),
            .select_all => self.selectAll(),
            .undo => return editResult(self.undo()),
            .redo => return editResult(self.redo()),
        };
        return .{ .status = if (changed) .redraw else .handled };
    }

    fn replaceRange(self: *Model, start: usize, end: usize, replacement: []const u8) EditError!bool {
        if (self.boundaryIndex(start) == null or self.boundaryIndex(end) == null) return error.InvalidBoundary;
        return self.replaceRangeInternal(start, end, replacement, true);
    }

    fn replaceRangeInternal(self: *Model, start: usize, end: usize, replacement: []const u8, record_history: bool) EditError!bool {
        if (start > end or end > self.len) return error.InvalidBoundary;
        if (memory.slicesOverlap(self.storage, replacement)) return error.OverlappingInput;
        const retained_len = self.len - (end - start);
        if (replacement.len > self.storage.len - retained_len) return error.CapacityExceeded;
        const new_len = retained_len + replacement.len;
        if (self.boundaries.len < new_len + 1) return error.CapacityExceeded;
        const required_rows = if (self.multiline or self.soft_wrap) new_len + 1 else 1;
        if (self.visual_row_storage.len < required_rows) return error.CapacityExceeded;
        const current = self.value();
        if (!asciiEditIsSafe(current, start, end, replacement, self.multiline)) {
            const left = lineRangeAtOffset(current, start);
            const right = lineRangeAtOffset(current, end);
            if (self.multiline) {
                try validation.validateParts(.lf, .{
                    current[left.start..start],
                    replacement,
                    current[end..right.end],
                });
            } else {
                try validation.validateParts(.reject, .{
                    current[left.start..start],
                    replacement,
                    current[end..right.end],
                });
            }
        }
        if (start == end and replacement.len == 0) return false;

        const history_index = if (record_history) history: {
            const history_ptr = self.history orelse break :history null;
            break :history try history_ptr.record(
                start,
                self.storage[start..end],
                replacement,
                .{ .cursor = self.cursorOffset(), .anchor = self.anchor },
            );
        } else null;

        const target_tail = start + replacement.len;
        @memmove(self.storage[target_tail..new_len], self.storage[end..self.len]);
        @memcpy(self.storage[start..target_tail], replacement);
        self.len = new_len;
        self.rebuildBoundaries();
        self.rebuildVisualRows();
        self.cursor_boundary = self.snapBoundaryIndex(target_tail, if (replacement.len == 0) .backward else .forward);
        self.anchor = null;
        self.cursor_affinity = .forward;
        self.preferred_column = null;
        self.revision +%= 1;
        self.revealCursor();
        if (history_index) |index| self.history.?.finish(index, .{ .cursor = self.cursorOffset(), .anchor = self.anchor });
        return true;
    }

    fn moveLeft(self: *Model, extend: bool) bool {
        if (!extend) {
            if (self.selection()) |selected| return self.moveTo(selected.start, false, false);
        }
        const target_index = self.cursor_boundary -| 1;
        return self.moveToBoundary(target_index, extend, false, .forward);
    }

    fn moveRight(self: *Model, extend: bool) bool {
        if (!extend) {
            if (self.selection()) |selected| return self.moveTo(selected.end, false, false);
        }
        const target_index = @min(self.cursor_boundary + 1, self.boundary_count - 1);
        return self.moveToBoundary(target_index, extend, false, .forward);
    }

    fn moveHome(self: *Model, extend: bool) bool {
        if (self.softWrapActive()) {
            const visual = self.locateVisualCursor();
            return self.moveToBoundary(
                self.boundaryIndex(visual.bounds.start) orelse unreachable,
                extend,
                false,
                .forward,
            );
        }
        const position = self.cursorPosition();
        const bounds = self.lineBounds(position.row) orelse unreachable;
        return self.moveToBoundary(self.boundaryIndex(bounds.start) orelse unreachable, extend, false, .forward);
    }

    fn moveEnd(self: *Model, extend: bool) bool {
        if (self.softWrapActive()) {
            const visual = self.locateVisualCursor();
            return self.moveToBoundary(
                self.boundaryIndex(visual.bounds.end) orelse unreachable,
                extend,
                false,
                if (visual.bounds.break_kind == .soft) .backward else .forward,
            );
        }
        const bounds = self.lineBounds(self.cursorPosition().row) orelse unreachable;
        return self.moveToBoundary(self.boundaryIndex(bounds.end) orelse unreachable, extend, false, .forward);
    }

    fn moveVertical(self: *Model, direction: i2, extend: bool) bool {
        return self.moveVerticalRows(direction < 0, 1, extend);
    }

    fn moveVerticalRows(self: *Model, backward: bool, rows: usize, extend: bool) bool {
        if (self.softWrapActive()) return self.moveVisualRows(backward, rows, extend);
        const position = self.cursorPosition();
        const target_row = if (backward)
            position.row -| rows
        else
            @min(position.row +| rows, self.lineCount() - 1);
        if (target_row == position.row) {
            if (!extend and self.selection() != null) return self.moveToBoundary(self.cursor_boundary, false, true, .forward);
            return false;
        }
        const desired = self.preferred_column orelse position.column;
        const bounds = self.lineBounds(target_row) orelse unreachable;
        const target = self.boundaryForColumn(bounds.start, bounds.end, desired);
        const changed = self.moveToBoundary(target, extend, true, .forward);
        self.preferred_column = desired;
        return changed;
    }

    fn moveVisualRows(self: *Model, backward: bool, rows: usize, extend: bool) bool {
        const current = self.locateVisualCursor();
        const requested_row = if (backward) current.row -| rows else current.row +| rows;
        const target_row = @min(requested_row, self.visual_row_count - 1);
        const target = self.visual_row_storage[target_row];
        if (target_row == current.row) {
            if (!extend and self.selection() != null) {
                return self.moveToBoundary(self.cursor_boundary, false, true, self.cursor_affinity);
            }
            return false;
        }

        const desired = self.preferred_column orelse current.column;
        const target_boundary = self.boundaryForColumn(target.start, target.end, desired);
        const affinity: CursorAffinity = if (self.boundaries[target_boundary].offset == target.end and target.break_kind == .soft)
            .backward
        else
            .forward;
        const changed = self.moveToBoundary(target_boundary, extend, true, affinity);
        self.preferred_column = desired;
        return changed;
    }

    fn moveTo(self: *Model, target: usize, extend: bool, preserve_preferred: bool) bool {
        return self.moveToBoundary(self.boundaryIndex(target) orelse unreachable, extend, preserve_preferred, .forward);
    }

    fn moveToBoundary(
        self: *Model,
        target_boundary: usize,
        extend: bool,
        preserve_preferred: bool,
        affinity: CursorAffinity,
    ) bool {
        std.debug.assert(target_boundary < self.boundary_count);
        if (target_boundary == self.cursor_boundary and affinity == self.cursor_affinity and (extend or self.anchor == null)) return false;
        const previous_cursor = self.cursorOffset();
        const previous_anchor = self.anchor;
        const previous_affinity = self.cursor_affinity;
        if (extend) {
            if (self.anchor == null) self.anchor = previous_cursor;
        } else {
            self.anchor = null;
        }
        self.cursor_boundary = target_boundary;
        self.cursor_affinity = affinity;
        if (!preserve_preferred) self.preferred_column = null;
        self.revealCursor();
        return self.cursorOffset() != previous_cursor or self.anchor != previous_anchor or self.cursor_affinity != previous_affinity;
    }

    fn revealCursor(self: *Model) void {
        const soft_wrap = self.softWrapActive();
        const position = if (soft_wrap) self.visualCursorPosition() else self.cursorPosition();
        if (self.viewport.height == 0) {
            self.viewport.top_row = position.row;
        } else if (position.row < self.viewport.top_row) {
            self.viewport.top_row = position.row;
        } else if (position.row - self.viewport.top_row >= self.viewport.height) {
            self.viewport.top_row = position.row - self.viewport.height + 1;
        }
        if (soft_wrap) {
            self.viewport.left_column = 0;
            return;
        }
        self.viewport.top_row = @min(self.viewport.top_row, self.line_count - 1);

        if (self.viewport.width == 0) {
            self.viewport.left_column = position.column;
            return;
        }
        if (position.column < self.viewport.left_column) {
            self.viewport.left_column = position.column;
            return;
        }
        const anchor_width = @min(
            @as(usize, self.viewport.width),
            self.cursorGraphemeWidth(),
        );
        const required_end = position.column +| anchor_width;
        const visible_end = self.viewport.left_column +| self.viewport.width;
        if (required_end > visible_end) self.viewport.left_column = required_end - self.viewport.width;
    }

    fn softWrapActive(self: *const Model) bool {
        return self.soft_wrap and self.viewport.width != 0;
    }

    fn locateVisualCursor(self: *const Model) VisualLocation {
        const cursor_offset = self.cursorOffset();
        var low: usize = 0;
        var high = self.visual_row_count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const row = self.visual_row_storage[middle];
            const after = cursor_offset > row.end or
                cursor_offset == row.end and row.break_kind == .soft and self.cursor_affinity != .backward;
            if (after) low = middle + 1 else high = middle;
        }
        const row = self.visual_row_storage[low];
        const start_boundary = self.boundaries[self.boundaryIndex(row.start) orelse unreachable];
        const cursor = self.cursorPosition();
        return .{
            .row = low,
            .column = if (cursor_offset == row.end) row.width else cursor.column - start_boundary.column,
            .bounds = row,
        };
    }

    fn stagePasteChunk(self: *Model, bytes: []const u8) EventResult {
        return switch (self.paste_state) {
            .idle => .{ .status = .ignored },
            .discarding => .{ .status = .handled },
            .collecting => |*paste| result: {
                if (memory.slicesOverlap(self.paste_storage, bytes)) {
                    break :result self.failStagedPaste(error.OverlappingInput);
                }
                if (bytes.len > self.paste_storage.len - paste.len) {
                    break :result self.failStagedPaste(error.PasteCapacityExceeded);
                }
                @memcpy(self.paste_storage[paste.len..][0..bytes.len], bytes);
                paste.len += bytes.len;
                break :result .{ .status = .handled };
            },
        };
    }

    fn failStagedPaste(self: *Model, err: EditError) EventResult {
        self.paste_state = .discarding;
        return .{ .status = .handled, .failure = err };
    }

    fn commitStagedPaste(self: *Model) EventResult {
        const paste = switch (self.paste_state) {
            .idle => return .{ .status = .ignored },
            .discarding => {
                self.paste_state = .idle;
                return .{ .status = .handled };
            },
            .collecting => |paste| paste,
        };
        if (self.revision != paste.revision or self.cursorOffset() != paste.cursor_offset or self.anchor != paste.anchor) {
            self.paste_state = .idle;
            return .{ .status = .handled, .failure = error.InvalidBoundary };
        }

        var read_index: usize = 0;
        var write_index: usize = 0;
        while (read_index < paste.len) {
            const byte = self.paste_storage[read_index];
            if (byte == '\r') {
                if (read_index + 1 == paste.len or self.paste_storage[read_index + 1] != '\n') {
                    self.paste_state = .idle;
                    return .{ .status = .handled, .failure = error.InvalidText };
                }
                self.paste_storage[write_index] = '\n';
                write_index += 1;
                read_index += 2;
                continue;
            }
            self.paste_storage[write_index] = byte;
            write_index += 1;
            read_index += 1;
        }
        validateText(self.paste_storage[0..write_index], self.multiline) catch {
            self.paste_state = .idle;
            return .{ .status = .handled, .failure = error.InvalidText };
        };
        const changed = self.replaceSelection(self.paste_storage[0..write_index]) catch |err| {
            self.paste_state = .idle;
            return .{ .status = .handled, .failure = err };
        };
        self.paste_state = .idle;
        return .{ .status = if (changed) .redraw else .handled };
    }

    fn abortStagedPaste(self: *Model) EventResult {
        return switch (self.paste_state) {
            .idle => .{ .status = .ignored },
            .collecting, .discarding => result: {
                self.paste_state = .idle;
                break :result .{ .status = .handled, .failure = error.InvalidText };
            },
        };
    }
};

pub const VisualRowIterator = struct {
    rows: []const VisualRow,
    index: usize = 0,

    pub fn next(self: *VisualRowIterator) ?VisualRow {
        if (self.index == self.rows.len) return null;
        defer self.index += 1;
        return self.rows[self.index];
    }
};

const VisualLocation = struct {
    row: usize,
    column: usize,
    bounds: VisualRow,
};

const LineBounds = struct {
    row: usize,
    start: usize,
    end: usize,
};

fn lineRangeAtOffset(value: []const u8, offset: usize) Selection {
    std.debug.assert(offset <= value.len);
    const start = if (std.mem.lastIndexOfScalar(u8, value[0..offset], '\n')) |newline| newline + 1 else 0;
    const relative_end = std.mem.indexOfScalar(u8, value[offset..], '\n') orelse value.len - offset;
    return .{ .start = start, .end = offset + relative_end };
}

fn pageRows(visible_rows: u16) usize {
    return @max(@as(usize, 1), @as(usize, visible_rows) -| 1);
}

fn countNewlines(value: []const u8) usize {
    var count: usize = 0;
    for (value) |byte| count += @intFromBool(byte == '\n');
    return count;
}

fn asciiEditIsSafe(value: []const u8, start: usize, end: usize, replacement: []const u8, multiline: bool) bool {
    for (replacement) |byte| {
        if (!isStoredAscii(byte) or byte == '\n' and !multiline) return false;
    }
    return (start == 0 or isStoredAscii(value[start - 1])) and
        (end == value.len or isStoredAscii(value[end]));
}

fn isStoredAscii(byte: u8) bool {
    return byte == '\n' or byte >= 0x20 and byte <= 0x7e;
}

fn validateText(value: []const u8, multiline: bool) error{InvalidText}!void {
    if (multiline) return validation.validateParts(.lf, .{value});
    return validation.validateParts(.reject, .{value});
}

fn editResult(result: EditError!bool) EventResult {
    const changed = result catch |err| return .{ .status = .handled, .failure = err };
    return .{ .status = if (changed) .redraw else .handled };
}
