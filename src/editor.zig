//! Bounded multiline editing over caller-owned contiguous storage.

const std = @import("std");
const grapheme = @import("text/grapheme.zig");
const input = @import("input/event.zig");

pub const Selection = struct {
    start: usize,
    end: usize,
};

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

pub const Viewport = struct {
    top_row: usize = 0,
    left_column: usize = 0,
    width: u16 = 0,
    height: u16 = 0,
};

pub const InitError = error{
    BufferTooSmall,
    InvalidText,
};

pub const EditError = error{
    CapacityExceeded,
    InvalidText,
    InvalidBoundary,
    OverlappingInput,
};

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

pub const Model = struct {
    storage: []u8,
    len: usize,
    cursor: usize,
    cursor_row: usize,
    cursor_column: usize,
    line_count: usize,
    anchor: ?usize = null,
    viewport: Viewport = .{},
    width_profile: grapheme.WidthProfile = .narrow,
    soft_wrap: bool = false,
    revision: u64 = 0,
    preferred_column: ?usize = null,
    cursor_affinity: CursorAffinity = .forward,
    paste_tail: [4]u8 = undefined,
    paste_tail_len: u8 = 0,
    paste_expected: u8 = 0,
    paste_active: bool = false,
    paste_blocked: bool = false,
    paste_pending_cr: bool = false,

    /// Caller storage is the hard memory and adversarial-input work bound.
    pub fn init(storage: []u8, initial: []const u8) InitError!Model {
        if (initial.len > storage.len) return error.BufferTooSmall;
        validateStoredText(initial) catch return error.InvalidText;
        const position = positionAt(initial, initial.len, .narrow);
        const line_count = countLines(initial);
        @memmove(storage[0..initial.len], initial);
        return .{
            .storage = storage,
            .len = initial.len,
            .cursor = initial.len,
            .cursor_row = position.row,
            .cursor_column = position.column,
            .line_count = line_count,
        };
    }

    pub fn value(self: *const Model) []const u8 {
        return self.storage[0..self.len];
    }

    pub fn lineCount(self: *const Model) usize {
        return self.line_count;
    }

    pub fn line(self: *const Model, row: usize) ?[]const u8 {
        const bounds = lineBoundsByRow(self.value(), row) orelse return null;
        return self.value()[bounds.start..bounds.end];
    }

    pub fn lineRange(self: *const Model, row: usize) ?Selection {
        const bounds = lineBoundsByRow(self.value(), row) orelse return null;
        return .{ .start = bounds.start, .end = bounds.end };
    }

    pub fn selection(self: *const Model) ?Selection {
        const anchor = self.anchor orelse return null;
        if (anchor == self.cursor) return null;
        return .{
            .start = @min(anchor, self.cursor),
            .end = @max(anchor, self.cursor),
        };
    }

    pub fn selectedText(self: *const Model) ?[]const u8 {
        const selected = self.selection() orelse return null;
        return self.value()[selected.start..selected.end];
    }

    pub fn cursorPosition(self: *const Model) Position {
        return .{ .row = self.cursor_row, .column = self.cursor_column };
    }

    pub fn visibleRows(self: *const Model) RowRange {
        const count = if (self.softWrapActive()) self.visualRowCount() else self.lineCount();
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
            if (self.soft_wrap) self.viewport.top_row = 0;
        }
        self.revealCursor();
        return !std.meta.eql(previous, self.viewport);
    }

    /// Wraps visual rows at display-width boundaries without changing stored lines.
    pub fn setSoftWrap(self: *Model, enabled: bool) bool {
        if (self.soft_wrap == enabled) return false;
        self.soft_wrap = enabled;
        self.cursor_affinity = .forward;
        self.preferred_column = null;
        self.viewport.top_row = 0;
        self.viewport.left_column = 0;
        self.revealCursor();
        return true;
    }

    pub fn softWrapEnabled(self: *const Model) bool {
        return self.soft_wrap;
    }

    /// Yields borrowed visual rows for the current viewport width.
    pub fn visualRows(self: *const Model) VisualRowIterator {
        return VisualRowIterator.init(
            self.value(),
            if (self.softWrapActive()) self.viewport.width else null,
            self.width_profile,
        );
    }

    pub fn visualCursorPosition(self: *const Model) Position {
        if (!self.softWrapActive()) return self.cursorPosition();
        const location = self.locateVisualCursor();
        return .{ .row = location.row, .column = location.column };
    }

    pub fn setWidthProfile(self: *Model, profile: grapheme.WidthProfile) bool {
        if (self.width_profile == profile) return false;
        self.width_profile = profile;
        const position = positionAt(self.value(), self.cursor, profile);
        self.cursor_row = position.row;
        self.cursor_column = position.column;
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
        if (!isBoundary(self.value(), anchor) or !isBoundary(self.value(), cursor)) {
            return error.InvalidBoundary;
        }
        const previous_cursor = self.cursor;
        const previous_anchor = self.anchor;
        const previous_affinity = self.cursor_affinity;
        self.cursor = cursor;
        self.anchor = if (anchor == cursor) null else anchor;
        const position = positionAt(self.value(), cursor, self.width_profile);
        self.cursor_row = position.row;
        self.cursor_column = position.column;
        self.cursor_affinity = .forward;
        self.preferred_column = null;
        self.revealCursor();
        return self.cursor != previous_cursor or self.anchor != previous_anchor or self.cursor_affinity != previous_affinity;
    }

    pub fn selectAll(self: *Model) bool {
        const previous_cursor = self.cursor;
        const previous_anchor = self.anchor;
        const previous_affinity = self.cursor_affinity;
        self.anchor = if (self.len == 0) null else 0;
        self.cursor = self.len;
        const position = positionAt(self.value(), self.cursor, self.width_profile);
        self.cursor_row = position.row;
        self.cursor_column = position.column;
        self.cursor_affinity = .forward;
        self.preferred_column = null;
        self.revealCursor();
        return self.cursor != previous_cursor or self.anchor != previous_anchor or self.cursor_affinity != previous_affinity;
    }

    pub fn replaceSelection(self: *Model, replacement: []const u8) EditError!bool {
        const selected = self.selection() orelse Selection{ .start = self.cursor, .end = self.cursor };
        return self.replaceRange(selected.start, selected.end, replacement);
    }

    pub fn handle(self: *Model, event: input.Event) EventResult {
        return switch (event) {
            .key => |key| self.handleKey(key),
            .text => |bytes| editResult(self.replaceSelection(bytes)),
            .paste_start => result: {
                self.resetPaste();
                self.paste_active = true;
                break :result .{ .status = .handled };
            },
            .paste_chunk => |bytes| self.handlePasteChunk(bytes),
            .paste_end => self.finishPaste(),
            .malformed => self.abortPaste(),
            else => .{ .status = .ignored },
        };
    }

    fn handleKey(self: *Model, key: input.Key) EventResult {
        if (key.action == .release) return .{ .status = .ignored };
        const extend = key.modifiers.shift;
        switch (key.code) {
            .left, .right, .up, .down, .home, .end, .page_up, .page_down => {
                if (hasUnsupportedModifiers(key.modifiers)) return .{ .status = .ignored };
                const changed = switch (key.code) {
                    .left => self.moveLeft(extend),
                    .right => self.moveRight(extend),
                    .up => self.moveVertical(-1, extend),
                    .down => self.moveVertical(1, extend),
                    .home => self.moveHome(extend),
                    .end => self.moveEnd(extend),
                    .page_up => self.moveVerticalRows(true, pageRows(self.viewport.height), extend),
                    .page_down => self.moveVerticalRows(false, pageRows(self.viewport.height), extend),
                    else => unreachable,
                };
                return .{ .status = if (changed) .redraw else .handled };
            },
            .backspace => {
                if (hasUnsupportedModifiers(key.modifiers)) return .{ .status = .ignored };
                if (self.selection() != null) return editResult(self.replaceSelection(""));
                const start = previousBoundary(self.value(), self.cursor);
                if (start == self.cursor) return .{ .status = .handled };
                return editResult(self.replaceRange(start, self.cursor, ""));
            },
            .delete => {
                if (hasUnsupportedModifiers(key.modifiers)) return .{ .status = .ignored };
                if (self.selection() != null) return editResult(self.replaceSelection(""));
                const end = nextBoundary(self.value(), self.cursor);
                if (end == self.cursor) return .{ .status = .handled };
                return editResult(self.replaceRange(self.cursor, end, ""));
            },
            .enter => {
                if (hasUnsupportedModifiers(key.modifiers)) return .{ .status = .ignored };
                return editResult(self.replaceSelection("\n"));
            },
            .codepoint => |codepoint| {
                if (hasUnsupportedModifiers(key.modifiers)) return .{ .status = .ignored };
                var encoded: [4]u8 = undefined;
                const encoded_len = std.unicode.utf8Encode(codepoint, &encoded) catch {
                    return .{ .status = .handled, .failure = error.InvalidText };
                };
                return editResult(self.replaceSelection(encoded[0..encoded_len]));
            },
            else => return .{ .status = .ignored },
        }
    }

    fn replaceRange(self: *Model, start: usize, end: usize, replacement: []const u8) EditError!bool {
        std.debug.assert(start <= end and end <= self.len);
        if (replacement.len != 0 and slicesOverlap(self.storage, replacement)) return error.OverlappingInput;
        const current = self.value();
        if (!asciiEditIsSafe(current, start, end, replacement)) {
            const left = lineRangeAtOffset(current, start);
            const right = lineRangeAtOffset(current, end);
            validateStoredTextParts(.{
                current[left.start..start],
                replacement,
                current[end..right.end],
            }) catch return error.InvalidText;
        }
        const retained_len = self.len - (end - start);
        if (replacement.len > self.storage.len - retained_len) return error.CapacityExceeded;
        if (start == end and replacement.len == 0) return false;

        const start_position = self.editStartPosition(start, end);
        const replacement_position = advancePosition(start_position, replacement, self.width_profile);
        const ascii_position_safe = isAsciiWithoutNewline(replacement) and
            (start == 0 or self.storage[start - 1] < 0x80);
        const removed_newlines = countNewlines(self.storage[start..end]);
        const added_newlines = countNewlines(replacement);
        const old_len = self.len;
        const tail_len = old_len - end;
        const target_tail = start + replacement.len;
        const new_len = retained_len + replacement.len;
        if (target_tail < end) {
            std.mem.copyForwards(u8, self.storage[target_tail .. target_tail + tail_len], self.storage[end..old_len]);
        } else if (target_tail > end) {
            std.mem.copyBackwards(u8, self.storage[target_tail .. target_tail + tail_len], self.storage[end..old_len]);
        }
        @memcpy(self.storage[start..target_tail], replacement);
        self.len = new_len;
        const target_cursor = snapBoundary(
            self.storage[0..new_len],
            target_tail,
            if (replacement.len == 0) .backward else .forward,
        );
        self.cursor = target_cursor;
        const cursor_position = if (target_cursor == target_tail and ascii_position_safe)
            replacement_position
        else if (target_cursor == target_tail and replacement.len == 0)
            start_position
        else
            positionAt(self.storage[0..new_len], target_cursor, self.width_profile);
        self.cursor_row = cursor_position.row;
        self.cursor_column = cursor_position.column;
        self.line_count = self.line_count - removed_newlines + added_newlines;
        self.anchor = null;
        self.cursor_affinity = .forward;
        self.preferred_column = null;
        self.revision +%= 1;
        self.revealCursor();
        return true;
    }

    fn editStartPosition(self: *const Model, start: usize, end: usize) Position {
        if (start == self.cursor) return self.cursorPosition();
        if (end == self.cursor and isAsciiWithoutNewline(self.value()[start..end])) {
            return .{ .row = self.cursor_row, .column = self.cursor_column - (end - start) };
        }
        return positionAt(self.value(), start, self.width_profile);
    }

    fn moveLeft(self: *Model, extend: bool) bool {
        if (!extend) {
            if (self.selection()) |selected| return self.moveTo(selected.start, false, false);
        }
        const target = previousBoundary(self.value(), self.cursor);
        if (target == self.cursor) return false;
        const position = if (self.value()[target] == '\n')
            positionAt(self.value(), target, self.width_profile)
        else
            Position{
                .row = self.cursor_row,
                .column = self.cursor_column - displayColumn(self.value()[target..self.cursor], self.width_profile),
            };
        return self.moveToKnown(target, position, extend, false, .forward);
    }

    fn moveRight(self: *Model, extend: bool) bool {
        if (!extend) {
            if (self.selection()) |selected| return self.moveTo(selected.end, false, false);
        }
        const target = nextBoundary(self.value(), self.cursor);
        if (target == self.cursor) return false;
        const position = if (self.value()[self.cursor] == '\n')
            Position{ .row = self.cursor_row + 1, .column = 0 }
        else
            Position{
                .row = self.cursor_row,
                .column = self.cursor_column + displayColumn(self.value()[self.cursor..target], self.width_profile),
            };
        return self.moveToKnown(target, position, extend, false, .forward);
    }

    fn moveHome(self: *Model, extend: bool) bool {
        if (self.softWrapActive()) {
            const visual = self.locateVisualCursor();
            return self.moveToKnown(
                visual.bounds.start,
                positionAt(self.value(), visual.bounds.start, self.width_profile),
                extend,
                false,
                .forward,
            );
        }
        const bounds = lineRangeAtOffset(self.value(), self.cursor);
        return self.moveToKnown(bounds.start, .{ .row = self.cursor_row, .column = 0 }, extend, false, .forward);
    }

    fn moveEnd(self: *Model, extend: bool) bool {
        if (self.softWrapActive()) {
            const visual = self.locateVisualCursor();
            return self.moveToKnown(
                visual.bounds.end,
                positionAt(self.value(), visual.bounds.end, self.width_profile),
                extend,
                false,
                if (visual.bounds.break_kind == .soft) .backward else .forward,
            );
        }
        const bounds = lineRangeAtOffset(self.value(), self.cursor);
        return self.moveToKnown(
            bounds.end,
            .{ .row = self.cursor_row, .column = displayColumn(self.value()[bounds.start..bounds.end], self.width_profile) },
            extend,
            false,
            .forward,
        );
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
            if (!extend and self.selection() != null) return self.moveTo(self.cursor, false, true);
            return false;
        }
        const desired = self.preferred_column orelse position.column;
        var bounds = lineRangeAtOffset(self.value(), self.cursor);
        var remaining = if (backward) position.row - target_row else target_row - position.row;
        while (remaining > 0) : (remaining -= 1) {
            if (backward) {
                const end = bounds.start - 1;
                const start = if (std.mem.lastIndexOfScalar(u8, self.value()[0..end], '\n')) |newline|
                    newline + 1
                else
                    0;
                bounds = .{ .start = start, .end = end };
            } else {
                const start = bounds.end + 1;
                const relative_end = std.mem.indexOfScalar(u8, self.value()[start..], '\n') orelse self.len - start;
                bounds = .{ .start = start, .end = start + relative_end };
            }
        }
        const target = offsetForColumn(
            self.value(),
            bounds.start,
            bounds.end,
            desired,
            self.width_profile,
        );
        const changed = self.moveToKnown(target.offset, .{ .row = target_row, .column = target.column }, extend, true, .forward);
        self.preferred_column = desired;
        return changed;
    }

    fn moveVisualRows(self: *Model, backward: bool, rows: usize, extend: bool) bool {
        const current = self.locateVisualCursor();
        const requested_row = if (backward) current.row -| rows else current.row +| rows;
        var iterator = self.visualRows();
        var target = iterator.next().?;
        var target_row: usize = 0;
        while (target_row < requested_row) {
            target = iterator.next() orelse break;
            target_row += 1;
        }
        if (target_row == current.row) {
            if (!extend and self.selection() != null) {
                return self.moveToKnown(self.cursor, self.cursorPosition(), false, true, self.cursor_affinity);
            }
            return false;
        }

        const desired = self.preferred_column orelse current.column;
        const target_cursor = offsetForColumn(
            self.value(),
            target.start,
            target.end,
            desired,
            self.width_profile,
        );
        const affinity: CursorAffinity = if (target_cursor.offset == target.end and target.break_kind == .soft)
            .backward
        else
            .forward;
        const changed = self.moveToKnown(
            target_cursor.offset,
            positionAt(self.value(), target_cursor.offset, self.width_profile),
            extend,
            true,
            affinity,
        );
        self.preferred_column = desired;
        return changed;
    }

    fn moveTo(self: *Model, target: usize, extend: bool, preserve_preferred: bool) bool {
        return self.moveToKnown(
            target,
            positionAt(self.value(), target, self.width_profile),
            extend,
            preserve_preferred,
            .forward,
        );
    }

    fn moveToKnown(
        self: *Model,
        target: usize,
        position: Position,
        extend: bool,
        preserve_preferred: bool,
        affinity: CursorAffinity,
    ) bool {
        if (target == self.cursor and affinity == self.cursor_affinity and (extend or self.anchor == null)) return false;
        const previous_cursor = self.cursor;
        const previous_anchor = self.anchor;
        const previous_affinity = self.cursor_affinity;
        if (extend) {
            if (self.anchor == null) self.anchor = self.cursor;
        } else {
            self.anchor = null;
        }
        self.cursor = target;
        self.cursor_row = position.row;
        self.cursor_column = position.column;
        self.cursor_affinity = affinity;
        if (!preserve_preferred) self.preferred_column = null;
        self.revealCursor();
        return self.cursor != previous_cursor or self.anchor != previous_anchor or self.cursor_affinity != previous_affinity;
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
            nextDisplayWidth(self.value(), self.cursor, self.width_profile),
        );
        const required_end = position.column +| anchor_width;
        const visible_end = self.viewport.left_column +| self.viewport.width;
        if (required_end > visible_end) self.viewport.left_column = required_end - self.viewport.width;
    }

    fn softWrapActive(self: *const Model) bool {
        return self.soft_wrap and self.viewport.width != 0;
    }

    fn visualRowCount(self: *const Model) usize {
        var count: usize = 0;
        var iterator = self.visualRows();
        while (iterator.next() != null) count += 1;
        return count;
    }

    fn locateVisualCursor(self: *const Model) VisualLocation {
        var iterator = self.visualRows();
        var row_index: usize = 0;
        while (iterator.next()) |row| : (row_index += 1) {
            if (self.cursor < row.end or
                self.cursor == row.end and (row.break_kind != .soft or self.cursor_affinity == .backward))
            {
                return .{
                    .row = row_index,
                    .column = if (self.cursor == row.end)
                        row.width
                    else
                        displayColumn(self.value()[row.start..self.cursor], self.width_profile),
                    .bounds = row,
                };
            }
        }
        unreachable;
    }

    fn handlePasteChunk(self: *Model, bytes: []const u8) EventResult {
        if (!self.paste_active) return .{ .status = .ignored };
        if (self.paste_blocked) return .{ .status = .handled };
        var changed = false;
        if (slicesOverlap(self.storage, bytes)) {
            return self.failPaste(false, error.OverlappingInput);
        }

        var index: usize = 0;
        if (self.paste_pending_cr and bytes.len > 0) {
            self.paste_pending_cr = false;
            if (bytes[0] != '\n') return self.failPaste(changed, error.InvalidText);
            if (self.insertPasteRun("\n", &changed)) |err| return self.failPaste(changed, err);
            index = 1;
        }

        if (self.paste_tail_len != 0) {
            while (index < bytes.len and self.paste_tail_len < self.paste_expected) : (index += 1) {
                const byte = bytes[index];
                if (byte & 0xc0 != 0x80) return self.failPaste(changed, error.InvalidText);
                self.paste_tail[self.paste_tail_len] = byte;
                self.paste_tail_len += 1;
            }
            if (self.paste_tail_len != self.paste_expected) {
                return .{ .status = if (changed) .redraw else .handled };
            }
            const scalar_len = self.paste_tail_len;
            self.paste_tail_len = 0;
            self.paste_expected = 0;
            validateScalarText(self.paste_tail[0..scalar_len]) catch return self.failPaste(changed, error.InvalidText);
            if (self.insertPasteRun(self.paste_tail[0..scalar_len], &changed)) |err| return self.failPaste(changed, err);
        }

        var run_start = index;
        while (index < bytes.len) {
            const byte = bytes[index];
            if (byte == '\r') {
                if (self.insertPasteRun(bytes[run_start..index], &changed)) |err| return self.failPaste(changed, err);
                if (index + 1 == bytes.len) {
                    self.paste_pending_cr = true;
                    index += 1;
                    run_start = index;
                    break;
                }
                if (bytes[index + 1] != '\n') return self.failPaste(changed, error.InvalidText);
                if (self.insertPasteRun("\n", &changed)) |err| return self.failPaste(changed, err);
                index += 2;
                run_start = index;
                continue;
            }
            if (byte < 0x80) {
                if (byte < 0x20 and byte != '\n' or byte == 0x7f) {
                    if (self.insertPasteRun(bytes[run_start..index], &changed)) |err| return self.failPaste(changed, err);
                    return self.failPaste(changed, error.InvalidText);
                }
                index += 1;
                continue;
            }

            const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch {
                if (self.insertPasteRun(bytes[run_start..index], &changed)) |err| return self.failPaste(changed, err);
                return self.failPaste(changed, error.InvalidText);
            };
            if (index + sequence_len > bytes.len) {
                if (self.insertPasteRun(bytes[run_start..index], &changed)) |err| return self.failPaste(changed, err);
                const tail = bytes[index..];
                @memcpy(self.paste_tail[0..tail.len], tail);
                self.paste_tail_len = @intCast(tail.len);
                self.paste_expected = sequence_len;
                index = bytes.len;
                run_start = index;
                break;
            }
            validateScalarText(bytes[index .. index + sequence_len]) catch {
                if (self.insertPasteRun(bytes[run_start..index], &changed)) |err| return self.failPaste(changed, err);
                return self.failPaste(changed, error.InvalidText);
            };
            index += sequence_len;
        }
        if (self.insertPasteRun(bytes[run_start..index], &changed)) |err| return self.failPaste(changed, err);
        return .{ .status = if (changed) .redraw else .handled };
    }

    fn insertPasteRun(self: *Model, bytes: []const u8, changed: *bool) ?EditError {
        if (bytes.len == 0) return null;
        const selected_len = if (self.selection()) |selected| selected.end - selected.start else 0;
        const available = self.storage.len - (self.len - selected_len);
        const prefix_len = utf8PrefixAtMost(bytes, available);
        if (prefix_len != 0) {
            changed.* = (self.replaceSelection(bytes[0..prefix_len]) catch |err| return err) or changed.*;
        }
        return if (prefix_len == bytes.len) null else error.CapacityExceeded;
    }

    fn failPaste(self: *Model, changed: bool, err: EditError) EventResult {
        self.paste_blocked = true;
        return .{ .status = if (changed) .redraw else .handled, .failure = err };
    }

    fn finishPaste(self: *Model) EventResult {
        if (!self.paste_active) return .{ .status = .ignored };
        const incomplete = !self.paste_blocked and (self.paste_tail_len != 0 or self.paste_pending_cr);
        self.resetPaste();
        return .{
            .status = .handled,
            .failure = if (incomplete) error.InvalidText else null,
        };
    }

    fn abortPaste(self: *Model) EventResult {
        if (!self.paste_active) return .{ .status = .ignored };
        self.resetPaste();
        return .{ .status = .handled, .failure = error.InvalidText };
    }

    fn resetPaste(self: *Model) void {
        self.paste_tail_len = 0;
        self.paste_expected = 0;
        self.paste_active = false;
        self.paste_blocked = false;
        self.paste_pending_cr = false;
    }
};

pub const VisualRowIterator = struct {
    value: []const u8,
    wrap_width: ?u16,
    width_profile: grapheme.WidthProfile,
    index: usize = 0,
    need_final: bool = true,
    line_active: bool = false,
    line_end: usize = 0,
    line_has_break: bool = false,
    line_ascii: bool = true,

    fn init(value: []const u8, wrap_width: ?u16, width_profile: grapheme.WidthProfile) VisualRowIterator {
        return .{
            .value = value,
            .wrap_width = wrap_width,
            .width_profile = width_profile,
        };
    }

    pub fn next(self: *VisualRowIterator) ?VisualRow {
        if (!self.line_active) {
            if (self.index == self.value.len) {
                if (!self.need_final) return null;
                self.need_final = false;
                return .{
                    .start = self.index,
                    .end = self.index,
                    .width = 0,
                    .break_kind = .end,
                };
            }
            const relative_end = std.mem.indexOfScalar(u8, self.value[self.index..], '\n') orelse self.value.len - self.index;
            self.line_end = self.index + relative_end;
            self.line_has_break = self.line_end < self.value.len;
            self.line_ascii = isAsciiWithoutNewline(self.value[self.index..self.line_end]);
            self.line_active = true;
        }
        if (self.index == self.line_end) return self.finishLine(self.index, 0);

        const start = self.index;
        const wrap_width = self.wrap_width orelse {
            return self.finishLine(start, displayColumn(self.value[start..self.line_end], self.width_profile));
        };
        if (self.line_ascii) {
            const remaining = self.line_end - start;
            const consumed = @min(remaining, @as(usize, wrap_width));
            self.index = start + consumed;
            if (self.index < self.line_end) {
                return .{ .start = start, .end = self.index, .width = consumed, .break_kind = .soft };
            }
            return self.finishLine(start, consumed);
        }

        var iterator = grapheme.Iterator{ .input = self.value[start..self.line_end] };
        var end = start;
        var width: usize = 0;
        while (iterator.next()) |cluster| {
            const cluster_width = cluster.displayWidthAssumeValid(self.width_profile) catch unreachable;
            if (width != 0 and width + cluster_width > wrap_width) break;
            width += cluster_width;
            end = start + iterator.index;
            if (width >= wrap_width) break;
        }
        std.debug.assert(end > start);
        self.index = end;
        if (end < self.line_end) {
            return .{ .start = start, .end = end, .width = width, .break_kind = .soft };
        }
        return self.finishLine(start, width);
    }

    fn finishLine(self: *VisualRowIterator, start: usize, width: usize) VisualRow {
        const end = self.line_end;
        const break_kind: VisualBreak = if (self.line_has_break) .hard else .end;
        self.index = end + @intFromBool(self.line_has_break);
        self.need_final = self.line_has_break;
        self.line_active = false;
        return .{ .start = start, .end = end, .width = width, .break_kind = break_kind };
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

fn lineBoundsAtOffset(value: []const u8, offset: usize) LineBounds {
    std.debug.assert(offset <= value.len);
    var row: usize = 0;
    var start: usize = 0;
    for (value[0..offset], 0..) |byte, index| {
        if (byte == '\n') {
            row += 1;
            start = index + 1;
        }
    }
    const relative_end = std.mem.indexOfScalar(u8, value[start..], '\n') orelse value.len - start;
    return .{ .row = row, .start = start, .end = start + relative_end };
}

fn lineRangeAtOffset(value: []const u8, offset: usize) Selection {
    std.debug.assert(offset <= value.len);
    const start = if (std.mem.lastIndexOfScalar(u8, value[0..offset], '\n')) |newline| newline + 1 else 0;
    const relative_end = std.mem.indexOfScalar(u8, value[offset..], '\n') orelse value.len - offset;
    return .{ .start = start, .end = offset + relative_end };
}

fn lineBoundsByRow(value: []const u8, target_row: usize) ?LineBounds {
    var row: usize = 0;
    var start: usize = 0;
    for (value, 0..) |byte, index| {
        if (byte != '\n') continue;
        if (row == target_row) return .{ .row = row, .start = start, .end = index };
        row += 1;
        start = index + 1;
    }
    return if (row == target_row) .{ .row = row, .start = start, .end = value.len } else null;
}

fn previousBoundary(value: []const u8, cursor: usize) usize {
    if (cursor == 0) return 0;
    if (value[cursor - 1] < 0x80 and (cursor == 1 or value[cursor - 2] < 0x80)) return cursor - 1;
    const bounds = lineRangeAtOffset(value, cursor);
    if (cursor == bounds.start) return cursor - 1;
    var previous = bounds.start;
    var iterator = grapheme.Iterator.init(value[bounds.start..bounds.end]) catch unreachable;
    while (iterator.next()) |cluster| {
        const end = @intFromPtr(cluster.bytes.ptr) - @intFromPtr(value.ptr) + cluster.bytes.len;
        if (end >= cursor) return previous;
        previous = end;
    }
    return previous;
}

fn nextBoundary(value: []const u8, cursor: usize) usize {
    if (cursor == value.len) return value.len;
    if (value[cursor] == '\n') return cursor + 1;
    if (value[cursor] < 0x80 and (cursor + 1 == value.len or value[cursor + 1] < 0x80)) return cursor + 1;
    const bounds = lineRangeAtOffset(value, cursor);
    if (cursor == bounds.end) return cursor + 1;
    var iterator = grapheme.Iterator.init(value[bounds.start..bounds.end]) catch unreachable;
    while (iterator.next()) |cluster| {
        const start = @intFromPtr(cluster.bytes.ptr) - @intFromPtr(value.ptr);
        if (start == cursor) return start + cluster.bytes.len;
    }
    unreachable;
}

fn isBoundary(value: []const u8, offset: usize) bool {
    if (offset > value.len) return false;
    if (offset == 0 or offset == value.len) return true;
    const bounds = lineRangeAtOffset(value, offset);
    if (offset == bounds.start or offset == bounds.end) return true;
    var iterator = grapheme.Iterator.init(value[bounds.start..bounds.end]) catch unreachable;
    while (iterator.next()) |cluster| {
        const end = @intFromPtr(cluster.bytes.ptr) - @intFromPtr(value.ptr) + cluster.bytes.len;
        if (end == offset) return true;
        if (end > offset) return false;
    }
    return false;
}

const SnapDirection = enum { backward, forward };

fn snapBoundary(value: []const u8, offset: usize, direction: SnapDirection) usize {
    if (offset == 0 or offset == value.len) return offset;
    if (value[offset - 1] < 0x80 and value[offset] < 0x80) return offset;
    const bounds = lineRangeAtOffset(value, offset);
    if (offset == bounds.start or offset == bounds.end) return offset;
    var start = bounds.start;
    var iterator = grapheme.Iterator.init(value[bounds.start..bounds.end]) catch unreachable;
    while (iterator.next()) |cluster| {
        const end = @intFromPtr(cluster.bytes.ptr) - @intFromPtr(value.ptr) + cluster.bytes.len;
        if (end == offset) return offset;
        if (end > offset) return if (direction == .backward) start else end;
        start = end;
    }
    unreachable;
}

fn displayColumn(line_prefix: []const u8, profile: grapheme.WidthProfile) usize {
    if (isAsciiWithoutNewline(line_prefix)) return line_prefix.len;
    var column: usize = 0;
    var iterator = grapheme.Iterator.init(line_prefix) catch unreachable;
    while (iterator.next()) |cluster| column += cluster.displayWidthAssumeValid(profile) catch unreachable;
    return column;
}

const ColumnOffset = struct {
    offset: usize,
    column: usize,
};

fn offsetForColumn(
    value: []const u8,
    start: usize,
    end: usize,
    target_column: usize,
    profile: grapheme.WidthProfile,
) ColumnOffset {
    var offset = start;
    var column: usize = 0;
    var iterator = grapheme.Iterator.init(value[start..end]) catch unreachable;
    while (iterator.next()) |cluster| {
        const width = cluster.displayWidthAssumeValid(profile) catch unreachable;
        if (column + width > target_column) break;
        column += width;
        offset = @intFromPtr(cluster.bytes.ptr) - @intFromPtr(value.ptr) + cluster.bytes.len;
    }
    return .{ .offset = offset, .column = column };
}

fn nextDisplayWidth(value: []const u8, cursor: usize, profile: grapheme.WidthProfile) usize {
    if (cursor == value.len or value[cursor] == '\n') return 1;
    if (value[cursor] < 0x80 and (cursor + 1 == value.len or value[cursor + 1] < 0x80)) return 1;
    const bounds = lineRangeAtOffset(value, cursor);
    if (cursor == bounds.end) return 1;
    var iterator = grapheme.Iterator.init(value[bounds.start..bounds.end]) catch unreachable;
    while (iterator.next()) |cluster| {
        const start = @intFromPtr(cluster.bytes.ptr) - @intFromPtr(value.ptr);
        if (start == cursor) return cluster.displayWidthAssumeValid(profile) catch unreachable;
    }
    unreachable;
}

fn positionAt(value: []const u8, offset: usize, profile: grapheme.WidthProfile) Position {
    const bounds = lineBoundsAtOffset(value, offset);
    return .{
        .row = bounds.row,
        .column = displayColumn(value[bounds.start..offset], profile),
    };
}

fn advancePosition(start: Position, replacement: []const u8, profile: grapheme.WidthProfile) Position {
    const newline_count = countNewlines(replacement);
    if (newline_count == 0) {
        return .{ .row = start.row, .column = start.column + displayColumn(replacement, profile) };
    }
    const last_newline = std.mem.lastIndexOfScalar(u8, replacement, '\n').?;
    return .{
        .row = start.row + newline_count,
        .column = displayColumn(replacement[last_newline + 1 ..], profile),
    };
}

fn countLines(value: []const u8) usize {
    return 1 + countNewlines(value);
}

fn pageRows(visible_rows: u16) usize {
    return @max(@as(usize, 1), @as(usize, visible_rows) -| 1);
}

fn countNewlines(value: []const u8) usize {
    var count: usize = 0;
    for (value) |byte| count += @intFromBool(byte == '\n');
    return count;
}

fn isAsciiWithoutNewline(value: []const u8) bool {
    for (value) |byte| if (byte < 0x20 or byte > 0x7e) return false;
    return true;
}

fn asciiEditIsSafe(value: []const u8, start: usize, end: usize, replacement: []const u8) bool {
    for (replacement) |byte| if (!isStoredAscii(byte)) return false;
    return (start == 0 or isStoredAscii(value[start - 1])) and
        (end == value.len or isStoredAscii(value[end]));
}

fn isStoredAscii(byte: u8) bool {
    return byte == '\n' or byte >= 0x20 and byte <= 0x7e;
}

fn validateScalarText(value: []const u8) error{InvalidText}!void {
    var index: usize = 0;
    while (index < value.len) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(value[index]) catch return error.InvalidText;
        if (index + sequence_len > value.len) return error.InvalidText;
        const codepoint = std.unicode.utf8Decode(value[index .. index + sequence_len]) catch return error.InvalidText;
        if (codepoint != '\n') {
            _ = (grapheme.Cluster{ .bytes = value[index .. index + sequence_len] }).displayWidthAssumeValid(.narrow) catch {
                return error.InvalidText;
            };
        }
        index += sequence_len;
    }
}

fn validateStoredText(value: []const u8) error{InvalidText}!void {
    return validateStoredTextParts(.{value});
}

fn validateStoredTextParts(parts: anytype) error{InvalidText}!void {
    var ascii = true;
    inline for (parts) |part| {
        for (part) |byte| {
            if (byte >= 0x80) {
                ascii = false;
            } else if ((byte < 0x20 and byte != '\n') or byte == 0x7f) {
                return error.InvalidText;
            }
        }
    }
    if (ascii) return;

    var validator: StoredTextValidator = .{};
    inline for (parts) |part| try validator.add(part);
    try validator.finish();
}

const StoredTextValidator = struct {
    bytes: [grapheme.max_cluster_bytes + 4]u8 = undefined,
    len: usize = 0,

    fn add(self: *@This(), segment: []const u8) error{InvalidText}!void {
        var index: usize = 0;
        while (index < segment.len) {
            const scalar_len = std.unicode.utf8ByteSequenceLength(segment[index]) catch return error.InvalidText;
            if (scalar_len > segment.len - index) return error.InvalidText;
            const scalar = segment[index .. index + scalar_len];
            _ = std.unicode.utf8Decode(scalar) catch return error.InvalidText;
            index += scalar_len;

            if (scalar_len == 1 and scalar[0] == '\n') {
                try self.finish();
                continue;
            }

            const previous_len = self.len;
            @memcpy(self.bytes[self.len..][0..scalar_len], scalar);
            self.len += scalar_len;
            var clusters = grapheme.Iterator.init(self.bytes[0..self.len]) catch return error.InvalidText;
            const first = clusters.next().?;
            if (first.bytes.len == self.len) {
                if (self.len > grapheme.max_cluster_bytes) return error.InvalidText;
                continue;
            }
            if (first.bytes.len != previous_len) return error.InvalidText;
            try validateStoredCluster(first);
            std.mem.copyForwards(u8, self.bytes[0..scalar_len], scalar);
            self.len = scalar_len;
        }
    }

    fn finish(self: *@This()) error{InvalidText}!void {
        if (self.len == 0) return;
        try validateStoredCluster(.{ .bytes = self.bytes[0..self.len] });
        self.len = 0;
    }
};

fn validateStoredCluster(cluster: grapheme.Cluster) error{InvalidText}!void {
    if (cluster.bytes.len > grapheme.max_cluster_bytes) return error.InvalidText;
    const width = cluster.displayWidthAssumeValid(.narrow) catch return error.InvalidText;
    if (width == 0) return error.InvalidText;
}

fn utf8PrefixAtMost(value: []const u8, maximum: usize) usize {
    var end = @min(value.len, maximum);
    while (end != 0 and end < value.len and value[end] & 0xc0 == 0x80) end -= 1;
    return end;
}

fn hasUnsupportedModifiers(modifiers: input.Modifiers) bool {
    return modifiers.alt or modifiers.control or modifiers.super or modifiers.hyper or modifiers.meta;
}

fn editResult(result: EditError!bool) EventResult {
    const changed = result catch |err| return .{ .status = .handled, .failure = err };
    return .{ .status = if (changed) .redraw else .handled };
}

fn slicesOverlap(storage: []const u8, source: []const u8) bool {
    if (storage.len == 0 or source.len == 0) return false;
    const storage_start = @intFromPtr(storage.ptr);
    const source_start = @intFromPtr(source.ptr);
    const storage_end = std.math.add(usize, storage_start, storage.len) catch return true;
    const source_end = std.math.add(usize, source_start, source.len) catch return true;
    return source_start < storage_end and storage_start < source_end;
}

fn expectModelInvariants(editor: *const Model) !void {
    try validateStoredText(editor.value());
    try std.testing.expect(isBoundary(editor.value(), editor.cursor));
    if (editor.anchor) |anchor| try std.testing.expect(isBoundary(editor.value(), anchor));
    try std.testing.expectEqual(countLines(editor.value()), editor.line_count);
    try std.testing.expectEqual(
        positionAt(editor.value(), editor.cursor, editor.width_profile),
        editor.cursorPosition(),
    );
    const row_count = if (editor.softWrapActive()) editor.visualRowCount() else editor.line_count;
    try std.testing.expect(editor.viewport.top_row < row_count);
}

test "multiline editor edits selections on grapheme and newline boundaries" {
    var storage: [64]u8 = undefined;
    var editor = try Model.init(&storage, "a\xc3\xa9\n\xe7\x95\x8cb");
    try std.testing.expectEqual(@as(usize, 2), editor.lineCount());
    try std.testing.expectEqual(Position{ .row = 1, .column = 3 }, editor.cursorPosition());
    try std.testing.expectError(error.InvalidBoundary, editor.setCursor(2));
    try std.testing.expect(try editor.setSelection(1, 7));
    try std.testing.expectEqualStrings("\xc3\xa9\n\xe7\x95\x8c", editor.selectedText().?);
    try std.testing.expect(try editor.replaceSelection("X\nY"));
    try std.testing.expectEqualStrings("aX\nYb", editor.value());
    try std.testing.expectEqual(Position{ .row = 1, .column = 1 }, editor.cursorPosition());

    const before = editor.value().len;
    try std.testing.expectError(error.InvalidText, editor.replaceSelection("bad\rtext"));
    try std.testing.expectEqual(before, editor.value().len);
    try std.testing.expectError(error.OverlappingInput, editor.replaceSelection(editor.value()[0..1]));
    try expectModelInvariants(&editor);
}

test "multiline editor keeps desired column and reveals its cursor" {
    var storage: [128]u8 = undefined;
    var editor = try Model.init(&storage, "abcdef\nx\n123456\nlast");
    _ = editor.setViewportSize(3, 2);
    try std.testing.expect(try editor.setCursor(5));
    try std.testing.expectEqual(Position{ .row = 0, .column = 5 }, editor.cursorPosition());
    try std.testing.expect(editor.viewport.left_column > 0);

    try std.testing.expectEqual(EventStatus.redraw, editor.handle(.{ .key = .{ .code = .down } }).status);
    try std.testing.expectEqual(Position{ .row = 1, .column = 1 }, editor.cursorPosition());
    try std.testing.expectEqual(EventStatus.redraw, editor.handle(.{ .key = .{ .code = .down } }).status);
    try std.testing.expectEqual(Position{ .row = 2, .column = 5 }, editor.cursorPosition());
    try std.testing.expectEqual(@as(usize, 1), editor.viewport.top_row);
    try std.testing.expectEqual(RowRange{ .start = 1, .end = 3 }, editor.visibleRows());
    _ = editor.setViewportSize(3, 3);
    try std.testing.expectEqual(EventStatus.redraw, editor.handle(.{ .key = .{ .code = .page_up } }).status);
    try std.testing.expectEqual(Position{ .row = 0, .column = 5 }, editor.cursorPosition());
    try expectModelInvariants(&editor);
}

test "multiline editor soft wraps and navigates visual rows" {
    var storage: [32]u8 = undefined;
    var editor = try Model.init(&storage, "ab\xE7\x95\x8Ccd\nxy");
    _ = editor.setViewportSize(4, 3);
    try std.testing.expect(editor.setSoftWrap(true));

    var rows = editor.visualRows();
    try std.testing.expectEqual(VisualRow{ .start = 0, .end = 5, .width = 4, .break_kind = .soft }, rows.next().?);
    try std.testing.expectEqual(VisualRow{ .start = 5, .end = 7, .width = 2, .break_kind = .hard }, rows.next().?);
    try std.testing.expectEqual(VisualRow{ .start = 8, .end = 10, .width = 2, .break_kind = .end }, rows.next().?);
    try std.testing.expect(rows.next() == null);
    try std.testing.expectEqual(Position{ .row = 2, .column = 2 }, editor.visualCursorPosition());

    try std.testing.expect(try editor.setCursor(2));
    try std.testing.expectEqual(EventStatus.redraw, editor.handle(.{ .key = .{ .code = .down } }).status);
    try std.testing.expectEqual(@as(usize, 7), editor.cursor);
    try std.testing.expectEqual(Position{ .row = 1, .column = 2 }, editor.visualCursorPosition());
    try std.testing.expectEqual(EventStatus.redraw, editor.handle(.{ .key = .{ .code = .page_down } }).status);
    try std.testing.expectEqual(@as(usize, 10), editor.cursor);
    try std.testing.expectEqual(EventStatus.redraw, editor.handle(.{ .key = .{ .code = .home } }).status);
    try std.testing.expectEqual(@as(usize, 8), editor.cursor);
    try std.testing.expectEqual(EventStatus.redraw, editor.handle(.{ .key = .{ .code = .up } }).status);
    try std.testing.expectEqual(@as(usize, 5), editor.cursor);
    try std.testing.expectEqual(EventStatus.redraw, editor.handle(.{ .key = .{ .code = .end } }).status);
    try std.testing.expectEqual(@as(usize, 7), editor.cursor);
    try expectModelInvariants(&editor);

    var exact_storage: [5]u8 = undefined;
    var exact = try Model.init(&exact_storage, "abcdx");
    _ = exact.setViewportSize(4, 2);
    _ = exact.setSoftWrap(true);
    rows = exact.visualRows();
    try std.testing.expectEqual(VisualRow{ .start = 0, .end = 4, .width = 4, .break_kind = .soft }, rows.next().?);
    try std.testing.expectEqual(VisualRow{ .start = 4, .end = 5, .width = 1, .break_kind = .end }, rows.next().?);
    try std.testing.expect(rows.next() == null);
    try std.testing.expect(try exact.setCursor(4));
    try std.testing.expectEqual(Position{ .row = 1, .column = 0 }, exact.visualCursorPosition());
    try std.testing.expect(try exact.setCursor(0));
    try std.testing.expectEqual(EventStatus.redraw, exact.handle(.{ .key = .{ .code = .end, .modifiers = .{ .shift = true } } }).status);
    try std.testing.expectEqual(Selection{ .start = 0, .end = 4 }, exact.selection().?);
    try std.testing.expectEqual(Position{ .row = 0, .column = 4 }, exact.visualCursorPosition());
    try std.testing.expectEqual(EventStatus.redraw, exact.handle(.{ .key = .{ .code = .down } }).status);
    try std.testing.expectEqual(Position{ .row = 1, .column = 1 }, exact.visualCursorPosition());
    try std.testing.expectEqual(EventStatus.redraw, exact.handle(.{ .key = .{ .code = .up } }).status);
    try std.testing.expectEqual(Position{ .row = 0, .column = 4 }, exact.visualCursorPosition());
    try std.testing.expectEqual(EventStatus.redraw, exact.handle(.{ .key = .{ .code = .home } }).status);
    try std.testing.expectEqual(@as(usize, 0), exact.cursor);
    try std.testing.expectEqual(EventStatus.redraw, exact.handle(.{ .key = .{ .code = .end } }).status);
    try std.testing.expectEqual(Position{ .row = 0, .column = 4 }, exact.visualCursorPosition());

    var wide_storage: [4]u8 = undefined;
    var wide = try Model.init(&wide_storage, "\xE7\x95\x8CA");
    _ = wide.setViewportSize(1, 3);
    _ = wide.setSoftWrap(true);
    rows = wide.visualRows();
    try std.testing.expectEqual(VisualRow{ .start = 0, .end = 3, .width = 2, .break_kind = .soft }, rows.next().?);
    try std.testing.expectEqual(VisualRow{ .start = 3, .end = 4, .width = 1, .break_kind = .end }, rows.next().?);
    try std.testing.expect(rows.next() == null);

    var spaces_storage: [4]u8 = undefined;
    var spaces = try Model.init(&spaces_storage, "a  b");
    _ = spaces.setViewportSize(2, 2);
    _ = spaces.setSoftWrap(true);
    rows = spaces.visualRows();
    const first = rows.next().?;
    const second = rows.next().?;
    try std.testing.expectEqualStrings("a ", spaces.value()[first.start..first.end]);
    try std.testing.expectEqualStrings(" b", spaces.value()[second.start..second.end]);
}

test "multiline editor extends, collapses, deletes, and joins selections" {
    var storage: [64]u8 = undefined;
    var editor = try Model.init(&storage, "one\ntwo");
    const shift = input.Modifiers{ .shift = true };
    try std.testing.expectEqual(EventStatus.redraw, editor.handle(.{ .key = .{ .code = .left, .modifiers = shift } }).status);
    try std.testing.expectEqualStrings("o", editor.selectedText().?);
    try std.testing.expectEqual(EventStatus.redraw, editor.handle(.{ .key = .{ .code = .left } }).status);
    try std.testing.expect(editor.selection() == null);
    try std.testing.expectEqual(EventStatus.redraw, editor.handle(.{ .key = .{ .code = .home } }).status);
    try std.testing.expectEqual(EventStatus.redraw, editor.handle(.{ .key = .{ .code = .backspace } }).status);
    try std.testing.expectEqualStrings("onetwo", editor.value());
    try std.testing.expectEqual(EventStatus.redraw, editor.handle(.{ .key = .{ .code = .enter } }).status);
    try std.testing.expectEqualStrings("one\ntwo", editor.value());
    try std.testing.expect(editor.selectAll());
    try std.testing.expectEqual(EventStatus.redraw, editor.handle(.{ .text = "replacement" }).status);
    try std.testing.expectEqualStrings("replacement", editor.value());
    try expectModelInvariants(&editor);
}

test "multiline editor paste normalizes fragmented CRLF and reports failures" {
    var storage: [32]u8 = undefined;
    var editor = try Model.init(&storage, "");
    _ = editor.handle(.paste_start);
    try std.testing.expectEqual(EventStatus.redraw, editor.handle(.{ .paste_chunk = "a\r" }).status);
    try std.testing.expectEqual(EventStatus.redraw, editor.handle(.{ .paste_chunk = "\n\xc3" }).status);
    try std.testing.expectEqual(EventStatus.redraw, editor.handle(.{ .paste_chunk = "\xa9" }).status);
    try std.testing.expect(editor.handle(.paste_end).failure == null);
    try std.testing.expectEqualStrings("a\n\xc3\xa9", editor.value());

    _ = editor.handle(.paste_start);
    const overlapping = editor.handle(.{ .paste_chunk = editor.value() });
    try std.testing.expectEqual(error.OverlappingInput, overlapping.failure.?);
    try std.testing.expectEqualStrings("a\n\xc3\xa9", editor.value());
    _ = editor.handle(.paste_end);

    _ = editor.handle(.paste_start);
    _ = editor.handle(.{ .paste_chunk = "\r" });
    const invalid = editor.handle(.{ .paste_chunk = "x" });
    try std.testing.expectEqual(error.InvalidText, invalid.failure.?);
    _ = editor.handle(.paste_end);
    try std.testing.expectEqualStrings("a\n\xc3\xa9", editor.value());
    try expectModelInvariants(&editor);
}

test "multiline editor capacity errors do not partially mutate direct edits" {
    var storage: [4]u8 = undefined;
    var editor = try Model.init(&storage, "abcd");
    try std.testing.expectError(error.CapacityExceeded, editor.replaceSelection("x"));
    try std.testing.expectEqualStrings("abcd", editor.value());
    try std.testing.expect(try editor.setSelection(1, 3));
    try std.testing.expect(try editor.replaceSelection("XY"));
    try std.testing.expectEqualStrings("aXYd", editor.value());
    try expectModelInvariants(&editor);
}

test "multiline editor rejects non-displayable Unicode at ingress" {
    var storage: [16]u8 = undefined;
    try std.testing.expectError(error.InvalidText, Model.init(&storage, "\xE2\x80\x8B"));
    try std.testing.expectError(error.InvalidText, Model.init(&storage, "\xCC\x81"));

    var oversized: [grapheme.max_cluster_bytes + 1]u8 = undefined;
    oversized[0] = 'a';
    var oversized_index: usize = 1;
    while (oversized_index < oversized.len) : (oversized_index += 2) {
        oversized[oversized_index] = 0xCC;
        oversized[oversized_index + 1] = 0x81;
    }
    var oversized_storage: [oversized.len]u8 = undefined;
    try std.testing.expectError(error.InvalidText, Model.init(&oversized_storage, &oversized));

    var editor = try Model.init(&storage, "ok");
    _ = editor.handle(.paste_start);
    const result = editor.handle(.{ .paste_chunk = "a\xE2\x80\x8B" });
    try std.testing.expectEqual(error.InvalidText, result.failure.?);
    try std.testing.expectEqualStrings("oka", editor.value());
    try expectModelInvariants(&editor);

    var combining_storage: [8]u8 = undefined;
    var combining = try Model.init(&combining_storage, "a");
    try std.testing.expectEqual(EventStatus.redraw, combining.handle(.{ .text = "\xCC\x81" }).status);
    try std.testing.expectEqualStrings("a\xCC\x81", combining.value());
    try expectModelInvariants(&combining);
}

test "multiline editor rejects an overlong grapheme formed by deleting a newline" {
    const regional_indicator = "\xF0\x9F\x87\xA6";
    var initial: [4 + 1 + grapheme.max_cluster_bytes]u8 = undefined;
    @memcpy(initial[0..4], regional_indicator);
    initial[4] = '\n';
    @memcpy(initial[5..9], regional_indicator);
    var index: usize = 9;
    while (index < initial.len) : (index += 2) {
        initial[index] = 0xCC;
        initial[index + 1] = 0x81;
    }
    var storage: [initial.len]u8 = undefined;
    var editor = try Model.init(&storage, &initial);
    try std.testing.expect(try editor.setSelection(4, 5));
    const revision = editor.revision;
    try std.testing.expectError(error.InvalidText, editor.replaceSelection(""));
    try std.testing.expectEqualSlices(u8, &initial, editor.value());
    try std.testing.expectEqual(revision, editor.revision);
    try std.testing.expectEqual(Selection{ .start = 4, .end = 5 }, editor.selection().?);
    try expectModelInvariants(&editor);
}

test "multiline editor aborts malformed paste input" {
    var storage: [16]u8 = undefined;
    var editor = try Model.init(&storage, "");
    try std.testing.expectEqual(EventStatus.handled, editor.handle(.paste_start).status);
    try std.testing.expectEqual(EventStatus.redraw, editor.handle(.{ .paste_chunk = "a" }).status);
    const malformed = editor.handle(.malformed);
    try std.testing.expectEqual(EventStatus.handled, malformed.status);
    try std.testing.expectEqual(error.InvalidText, malformed.failure.?);
    try std.testing.expectEqual(EventStatus.ignored, editor.handle(.{ .paste_chunk = "b" }).status);
    try std.testing.expectEqualStrings("a", editor.value());
}

test "multiline editor moves and deletes by complete prepend graphemes" {
    var storage: [16]u8 = undefined;
    var editor = try Model.init(&storage, "\xD8\x80A");
    try std.testing.expectEqual(EventStatus.redraw, editor.handle(.{ .key = .{ .code = .left } }).status);
    try std.testing.expectEqual(@as(usize, 0), editor.cursor);
    try std.testing.expect(try editor.setCursor(editor.value().len));
    try std.testing.expectEqual(EventStatus.redraw, editor.handle(.{ .key = .{ .code = .backspace } }).status);
    try std.testing.expectEqualStrings("", editor.value());
    try expectModelInvariants(&editor);

    var insert_storage: [16]u8 = undefined;
    var inserted = try Model.init(&insert_storage, "\xD8\x80");
    try std.testing.expectEqual(EventStatus.redraw, inserted.handle(.{ .text = "A" }).status);
    try std.testing.expectEqualStrings("\xD8\x80A", inserted.value());
    try expectModelInvariants(&inserted);
}

test "multiline editor snaps edits that merge graphemes across a seam" {
    var storage: [32]u8 = undefined;
    var editor = try Model.init(&storage, "\xf0\x9f\x91\xa9\xf0\x9f\x91\xa9");
    try std.testing.expect(try editor.setCursor(4));
    try std.testing.expect(try editor.replaceSelection("\xe2\x80\x8d"));
    try std.testing.expectEqual(@as(usize, 11), editor.cursor);
    try std.testing.expectEqual(Position{ .row = 0, .column = 2 }, editor.cursorPosition());
    try expectModelInvariants(&editor);
}
