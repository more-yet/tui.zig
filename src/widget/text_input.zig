//! Bounded single-line editing over caller-owned storage.

const std = @import("std");
const input = @import("../input.zig");
const render = @import("../render.zig");
const text = @import("../text.zig");
const theme = @import("../theme.zig");
const Update = @import("update.zig").Update;

pub const InitError = error{
    BufferTooSmall,
    InvalidUtf8,
    ControlCharacter,
    ZeroWidthGrapheme,
    GraphemeTooLong,
};

pub const EditError = error{
    CapacityExceeded,
    InvalidBoundary,
    InvalidText,
    OverlappingInput,
};

pub const Selection = struct {
    start: usize,
    end: usize,
};

pub const TextInput = struct {
    storage: []u8,
    len: usize,
    cursor: usize,
    previous_boundary: usize,
    next_boundary: usize,
    display_width: usize,
    cursor_column: usize,
    anchor: ?usize = null,
    view_start: usize = 0,
    view_column: usize = 0,
    placeholder: []const u8 = "",
    role: theme.Role = .{},
    selection_role: theme.Role = .{
        .normal = .{ .attributes = .{ .reverse = true } },
    },
    enabled: bool = true,
    focused: bool = false,
    width_profile: text.WidthProfile = .narrow,
    measured_profile: text.WidthProfile = .narrow,
    paste_tail: [4]u8 = undefined,
    paste_tail_len: u8 = 0,
    paste_expected: u8 = 0,
    paste_active: bool = false,
    paste_blocked: bool = false,
    pending_failure: ?EditError = null,

    /// Caller storage is the hard memory and adversarial-input work bound.
    pub fn init(storage: []u8, initial: []const u8) InitError!TextInput {
        if (initial.len > storage.len) return error.BufferTooSmall;
        const location = try validateAndLocate(initial, initial.len, .forward, .narrow);
        @memmove(storage[0..initial.len], initial);
        return .{
            .storage = storage,
            .len = initial.len,
            .cursor = location.cursor,
            .previous_boundary = location.previous,
            .next_boundary = location.next,
            .display_width = location.total_width,
            .cursor_column = location.cursor_width,
        };
    }

    pub inline fn value(self: *const TextInput) []const u8 {
        return self.storage[0..self.len];
    }

    pub fn selection(self: *const TextInput) ?Selection {
        const anchor = self.anchor orelse return null;
        if (anchor == self.cursor) return null;
        return .{
            .start = @min(anchor, self.cursor),
            .end = @max(anchor, self.cursor),
        };
    }

    pub fn selectedText(self: *const TextInput) ?[]const u8 {
        const selected = self.selection() orelse return null;
        return self.value()[selected.start..selected.end];
    }

    pub fn setCursor(self: *TextInput, cursor: usize) EditError!bool {
        return self.setSelection(cursor, cursor);
    }

    pub fn setSelection(self: *TextInput, anchor: usize, cursor: usize) EditError!bool {
        if (!isBoundary(self.value(), anchor) or !isBoundary(self.value(), cursor)) {
            return error.InvalidBoundary;
        }
        self.syncMetrics();
        const previous_cursor = self.cursor;
        const previous_anchor = self.anchor;
        const location = validateAndLocate(self.value(), cursor, .forward, self.width_profile) catch unreachable;
        self.cursor = cursor;
        self.previous_boundary = location.previous;
        self.next_boundary = location.next;
        self.cursor_column = location.cursor_width;
        self.anchor = if (anchor == cursor) null else anchor;
        self.view_start = 0;
        self.view_column = 0;
        return self.cursor != previous_cursor or self.anchor != previous_anchor;
    }

    pub fn selectAll(self: *TextInput) bool {
        self.syncMetrics();
        const previous_cursor = self.cursor;
        const previous_anchor = self.anchor;
        self.cursor = self.len;
        self.previous_boundary = previousBoundary(self.value(), self.cursor);
        self.next_boundary = self.len;
        self.cursor_column = self.display_width;
        self.anchor = if (self.len == 0) null else 0;
        self.view_start = 0;
        self.view_column = 0;
        return self.cursor != previous_cursor or self.anchor != previous_anchor;
    }

    pub fn replaceSelection(self: *TextInput, replacement: []const u8) EditError!bool {
        self.syncMetrics();
        return switch (self.replace(replacement)) {
            .inserted => true,
            .empty => false,
            .capacity => error.CapacityExceeded,
            .invalid => error.InvalidText,
            .overlapping => error.OverlappingInput,
        };
    }

    pub fn handle(self: *TextInput, event: input.Event) Update {
        if (!self.enabled) {
            self.resetPaste();
            return .ignored;
        }
        return switch (event) {
            .key => |key| self.handleKey(key),
            .text => |bytes| self.insertionUpdate(self.replace(bytes)),
            .paste_start => start: {
                self.resetPaste();
                self.paste_active = true;
                break :start .handled;
            },
            .paste_chunk => |chunk| self.handlePasteChunk(chunk),
            .paste_end => finish: {
                if (!self.paste_active) break :finish .ignored;
                if (self.paste_tail_len != 0) self.recordFailure(error.InvalidText);
                self.resetPaste();
                break :finish .handled;
            },
            .malformed => malformed: {
                if (!self.paste_active) break :malformed .ignored;
                self.recordFailure(error.InvalidText);
                self.resetPaste();
                break :malformed .handled;
            },
            else => .ignored,
        };
    }

    pub fn takeFailure(self: *TextInput) ?EditError {
        const failure = self.pending_failure;
        self.pending_failure = null;
        return failure;
    }

    pub fn draw(self: *TextInput, surface: *render.Surface) !void {
        const size = surface.size();
        if (size.width == 0 or size.height == 0) return;
        self.syncMetrics();
        const style = self.role.resolve(theme.State.from(self.enabled, self.focused));
        const selected_style = self.selection_role.resolve(theme.State.from(self.enabled, self.focused));
        const show_caret = self.enabled and self.focused;
        if (self.len == 0 and !show_caret) {
            self.view_start = 0;
            _ = try surface.putTextLine(
                .{ .x = 0, .y = 0 },
                self.placeholder,
                size.width,
                style,
                self.width_profile,
                .{ .overflow = .ellipsis },
            );
            return;
        }

        const caret_x = self.updateView(size.width, show_caret);
        if (self.selection()) |selected| {
            const selected_start = @min(@max(selected.start, self.view_start), self.len);
            const selected_end = @min(@max(selected.end, self.view_start), self.len);
            const spans = [_]render.StyledSpan{
                .{ .text = self.value()[self.view_start..selected_start], .style = style },
                .{ .text = self.value()[selected_start..selected_end], .style = selected_style },
                .{ .text = self.value()[selected_end..], .style = style },
            };
            _ = try surface.putStyledLine(
                .{ .x = 0, .y = 0 },
                &spans,
                size.width,
                style,
                self.width_profile,
                .{},
            );
        } else {
            _ = try surface.putTextLine(
                .{ .x = 0, .y = 0 },
                self.value()[self.view_start..],
                size.width,
                style,
                self.width_profile,
                .{},
            );
        }
        if (!show_caret) return;

        var caret_style = if (self.selection()) |selected|
            if (self.cursor >= selected.start and self.cursor < selected.end) selected_style else style
        else
            style;
        caret_style.attributes.reverse = !caret_style.attributes.reverse;
        const next = clusterAt(self.value(), self.cursor, self.width_profile);
        const draw_cluster = if (next) |cluster| cluster.width <= size.width - caret_x else false;
        const caret_text = if (next) |cluster|
            if (draw_cluster) self.value()[self.cursor..cluster.end] else " "
        else
            " ";
        _ = try surface.putText(.{ .x = caret_x, .y = 0 }, caret_text, caret_style, self.width_profile);
    }

    fn handleKey(self: *TextInput, key: input.Key) Update {
        if (key.action == .release) return .ignored;
        self.syncMetrics();
        switch (key.code) {
            .left => {
                if (hasTextModifiers(key.modifiers)) return .ignored;
                return if (self.moveLeft(key.modifiers.shift)) .redraw else .handled;
            },
            .right => {
                if (hasTextModifiers(key.modifiers)) return .ignored;
                return if (self.moveRight(key.modifiers.shift)) .redraw else .handled;
            },
            .home => {
                if (hasTextModifiers(key.modifiers)) return .ignored;
                return if (self.moveHome(key.modifiers.shift)) .redraw else .handled;
            },
            .end => {
                if (hasTextModifiers(key.modifiers)) return .ignored;
                return if (self.moveEnd(key.modifiers.shift)) .redraw else .handled;
            },
            .backspace => {
                if (hasTextModifiers(key.modifiers)) return .ignored;
                if (self.selection() != null) return self.insertionUpdate(self.replace(""));
                if (self.cursor == 0) return .handled;
                return if (self.erase(self.previous_boundary, self.cursor)) .redraw else .handled;
            },
            .delete => {
                if (hasTextModifiers(key.modifiers)) return .ignored;
                if (self.selection() != null) return self.insertionUpdate(self.replace(""));
                if (self.cursor == self.len) return .handled;
                return if (self.erase(self.cursor, self.next_boundary)) .redraw else .handled;
            },
            .codepoint => |codepoint| {
                if (hasTextModifiers(key.modifiers)) return .ignored;
                if (codepoint == '\r' or codepoint == '\n' or codepoint == '\t') return .ignored;
                var encoded: [4]u8 = undefined;
                const encoded_len = std.unicode.utf8Encode(codepoint, &encoded) catch {
                    self.recordFailure(error.InvalidText);
                    return .handled;
                };
                return self.insertionUpdate(self.replace(encoded[0..encoded_len]));
            },
            else => return .ignored,
        }
    }

    fn moveLeft(self: *TextInput, extend: bool) bool {
        if (!extend) {
            if (self.selection()) |selected| return self.moveTo(selected.start, false);
        }
        if (self.cursor == 0) {
            if (!extend and self.anchor != null) {
                self.anchor = null;
                return true;
            }
            return false;
        }
        if (extend) {
            if (self.anchor == null) self.anchor = self.cursor;
        } else {
            self.anchor = null;
        }
        self.next_boundary = self.cursor;
        const moved = clusterAt(self.value(), self.previous_boundary, self.width_profile).?;
        self.cursor_column -= moved.width;
        self.cursor = self.previous_boundary;
        self.previous_boundary = previousBoundary(self.value(), self.cursor);
        if (self.cursor < self.view_start) {
            self.view_start = self.cursor;
            self.view_column = self.cursor_column;
        }
        return true;
    }

    fn moveRight(self: *TextInput, extend: bool) bool {
        if (!extend) {
            if (self.selection()) |selected| return self.moveTo(selected.end, false);
        }
        if (self.cursor == self.len) {
            if (!extend and self.anchor != null) {
                self.anchor = null;
                return true;
            }
            return false;
        }
        if (extend) {
            if (self.anchor == null) self.anchor = self.cursor;
        } else {
            self.anchor = null;
        }
        const moved = clusterAt(self.value(), self.cursor, self.width_profile).?;
        self.previous_boundary = self.cursor;
        self.cursor = self.next_boundary;
        self.next_boundary = nextBoundary(self.value(), self.cursor);
        self.cursor_column += moved.width;
        return true;
    }

    fn moveHome(self: *TextInput, extend: bool) bool {
        return self.moveTo(0, extend);
    }

    fn moveEnd(self: *TextInput, extend: bool) bool {
        return self.moveTo(self.len, extend);
    }

    fn moveTo(self: *TextInput, target: usize, extend: bool) bool {
        const previous_cursor = self.cursor;
        const previous_anchor = self.anchor;
        if (extend) {
            if (self.anchor == null and target != self.cursor) self.anchor = self.cursor;
        } else {
            self.anchor = null;
        }
        if (target == self.cursor) return self.anchor != previous_anchor;

        const location = validateAndLocate(self.value(), target, .forward, self.width_profile) catch unreachable;
        self.cursor = target;
        self.previous_boundary = location.previous;
        self.next_boundary = location.next;
        self.cursor_column = location.cursor_width;
        if (target == 0 or target < self.view_start) {
            self.view_start = 0;
            self.view_column = 0;
        }
        return self.cursor != previous_cursor or self.anchor != previous_anchor;
    }

    fn replace(self: *TextInput, bytes: []const u8) InsertResult {
        const selected = self.selection() orelse return self.insert(bytes);
        if (slicesOverlap(self.storage, bytes)) return .overlapping;

        const removed_len = selected.end - selected.start;
        const retained_len = self.len - removed_len;
        if (bytes.len > self.storage.len - retained_len) return .capacity;

        const ascii_edit_safe = self.measured_profile == self.width_profile and
            asciiReplacementIsSafe(self.value(), selected.start, selected.end, bytes);
        if (!ascii_edit_safe) {
            validateTextParts(.{
                self.value()[0..selected.start],
                bytes,
                self.value()[selected.end..],
            }) catch return .invalid;
        }

        const old_len = self.len;
        const old_cursor = self.cursor;
        const old_cursor_column = self.cursor_column;
        const target = selected.start + bytes.len;
        const new_len = retained_len + bytes.len;
        if (bytes.len > removed_len) {
            std.mem.copyBackwards(
                u8,
                self.storage[target..new_len],
                self.storage[selected.end..old_len],
            );
        } else {
            std.mem.copyForwards(
                u8,
                self.storage[target..new_len],
                self.storage[selected.end..old_len],
            );
        }
        std.mem.copyForwards(u8, self.storage[selected.start..target], bytes);

        self.len = new_len;
        self.cursor = target;
        self.anchor = null;
        if (ascii_edit_safe) {
            const start_column = if (old_cursor == selected.start)
                old_cursor_column
            else
                old_cursor_column - removed_len;
            self.previous_boundary = if (target == 0) 0 else target - 1;
            self.next_boundary = if (target == new_len) new_len else target + 1;
            self.display_width = self.display_width - removed_len + bytes.len;
            self.cursor_column = start_column + bytes.len;
        } else {
            const location = validateAndLocate(self.value(), target, .forward, self.width_profile) catch unreachable;
            self.previous_boundary = location.previous;
            self.next_boundary = location.next;
            self.display_width = location.total_width;
            self.cursor_column = location.cursor_width;
        }
        self.measured_profile = self.width_profile;
        self.view_start = 0;
        self.view_column = 0;
        return .inserted;
    }

    fn insert(self: *TextInput, bytes: []const u8) InsertResult {
        if (bytes.len == 0) return .empty;
        if (slicesOverlap(self.storage, bytes)) return .overlapping;
        if (bytes.len > self.storage.len - self.len) return .capacity;

        const ascii_insertion_safe = self.measured_profile == self.width_profile and
            asciiInsertionIsSafe(self.value(), self.cursor, bytes);
        const old_len = self.len;
        const target = self.cursor + bytes.len;
        const new_len = old_len + bytes.len;
        std.mem.copyBackwards(
            u8,
            self.storage[target..new_len],
            self.storage[self.cursor..old_len],
        );
        std.mem.copyForwards(u8, self.storage[self.cursor..target], bytes);
        if (ascii_insertion_safe) {
            self.len = new_len;
            self.cursor = target;
            self.previous_boundary = target - 1;
            self.next_boundary = if (target == new_len) new_len else self.next_boundary + bytes.len;
            self.display_width += bytes.len;
            self.cursor_column += bytes.len;
            self.anchor = null;
            self.measured_profile = self.width_profile;
            self.view_start = 0;
            self.view_column = 0;
            return .inserted;
        }
        const location = validateAndLocate(
            self.storage[0..new_len],
            target,
            .forward,
            self.width_profile,
        ) catch {
            std.mem.copyForwards(
                u8,
                self.storage[self.cursor..old_len],
                self.storage[target..new_len],
            );
            return .invalid;
        };

        self.len = new_len;
        self.cursor = location.cursor;
        self.previous_boundary = location.previous;
        self.next_boundary = location.next;
        self.display_width = location.total_width;
        self.cursor_column = location.cursor_width;
        self.anchor = null;
        self.measured_profile = self.width_profile;
        self.view_start = 0;
        self.view_column = 0;
        return .inserted;
    }

    fn erase(self: *TextInput, start: usize, end: usize) bool {
        const removed_len = end - start;
        std.debug.assert(removed_len <= text.max_grapheme_bytes);
        var removed: [text.max_grapheme_bytes]u8 = undefined;
        @memcpy(removed[0..removed_len], self.storage[start..end]);

        const old_len = self.len;
        const new_len = old_len - removed_len;
        std.mem.copyForwards(u8, self.storage[start..new_len], self.storage[end..old_len]);
        const location = validateAndLocate(
            self.storage[0..new_len],
            start,
            .backward,
            self.width_profile,
        ) catch {
            std.mem.copyBackwards(u8, self.storage[end..old_len], self.storage[start..new_len]);
            @memcpy(self.storage[start..end], removed[0..removed_len]);
            return false;
        };

        self.len = new_len;
        self.cursor = location.cursor;
        self.previous_boundary = location.previous;
        self.next_boundary = location.next;
        self.display_width = location.total_width;
        self.cursor_column = location.cursor_width;
        self.anchor = null;
        self.measured_profile = self.width_profile;
        self.view_start = 0;
        self.view_column = 0;
        return true;
    }

    fn handlePasteChunk(self: *TextInput, chunk: []const u8) Update {
        if (!self.paste_active) return .ignored;
        if (self.paste_blocked) return .handled;
        var changed = false;
        if (slicesOverlap(self.storage, chunk)) {
            self.paste_blocked = true;
            self.recordFailure(error.OverlappingInput);
            return .handled;
        }

        var index: usize = 0;
        while (index < chunk.len and self.paste_tail_len != 0) : (index += 1) {
            changed = self.consumePasteByte(chunk[index]) or changed;
        }
        var run_start = index;
        while (index < chunk.len and !self.paste_blocked) {
            const byte = chunk[index];
            if (byte < 0x80) {
                if (byte < 0x20 or byte == 0x7f) {
                    self.insertPasteRun(chunk[run_start..index], &changed);
                    self.recordFailure(error.InvalidText);
                    index += 1;
                    run_start = index;
                } else {
                    index += 1;
                }
                continue;
            }

            const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch {
                self.insertPasteRun(chunk[run_start..index], &changed);
                self.recordFailure(error.InvalidText);
                index += 1;
                run_start = index;
                continue;
            };
            if (index + sequence_len > chunk.len) {
                self.insertPasteRun(chunk[run_start..index], &changed);
                while (index < chunk.len) : (index += 1) {
                    changed = self.consumePasteByte(chunk[index]) or changed;
                }
                run_start = index;
                break;
            }
            _ = std.unicode.utf8Decode(chunk[index .. index + sequence_len]) catch {
                self.insertPasteRun(chunk[run_start..index], &changed);
                self.recordFailure(error.InvalidText);
                index += 1;
                run_start = index;
                continue;
            };
            index += sequence_len;
        }
        self.insertPasteRun(chunk[run_start..index], &changed);
        return if (changed) .redraw else .handled;
    }

    fn insertPasteRun(self: *TextInput, bytes: []const u8, changed: *bool) void {
        if (bytes.len == 0 or self.paste_blocked) return;
        const selected_len = if (self.selection()) |selected| selected.end - selected.start else 0;
        const prefix_len = utf8PrefixAtMost(bytes, self.storage.len - self.len + selected_len);
        if (prefix_len != 0) switch (self.replace(bytes[0..prefix_len])) {
            .inserted => changed.* = true,
            .capacity => unreachable,
            .invalid => {
                self.insertPasteScalars(bytes, changed);
                return;
            },
            .empty, .overlapping => unreachable,
        };
        if (prefix_len != bytes.len) {
            self.paste_blocked = true;
            self.recordFailure(error.CapacityExceeded);
        }
    }

    fn insertPasteScalars(self: *TextInput, bytes: []const u8, changed: *bool) void {
        var index: usize = 0;
        while (index < bytes.len and !self.paste_blocked) {
            const sequence_len = std.unicode.utf8ByteSequenceLength(bytes[index]) catch unreachable;
            var scalar: [4]u8 = undefined;
            @memcpy(scalar[0..sequence_len], bytes[index .. index + sequence_len]);
            changed.* = self.applyPasteInsert(scalar[0..sequence_len]) or changed.*;
            index += sequence_len;
        }
    }

    fn consumePasteByte(self: *TextInput, byte: u8) bool {
        if (self.paste_blocked) return false;
        if (self.paste_tail_len == 0) {
            if (byte < 0x80) {
                if (byte < 0x20 or byte == 0x7F) {
                    self.recordFailure(error.InvalidText);
                    return false;
                }
                const scalar = [1]u8{byte};
                return self.applyPasteInsert(&scalar);
            }
            const expected = std.unicode.utf8ByteSequenceLength(byte) catch {
                self.recordFailure(error.InvalidText);
                return false;
            };
            if (expected == 1) {
                self.recordFailure(error.InvalidText);
                return false;
            }
            self.paste_tail[0] = byte;
            self.paste_tail_len = 1;
            self.paste_expected = expected;
            return false;
        }

        if (byte & 0xC0 != 0x80) {
            self.paste_tail_len = 0;
            self.paste_expected = 0;
            self.recordFailure(error.InvalidText);
            return self.consumePasteByte(byte);
        }
        self.paste_tail[self.paste_tail_len] = byte;
        self.paste_tail_len += 1;
        if (self.paste_tail_len != self.paste_expected) return false;

        var scalar: [4]u8 = undefined;
        const scalar_len = self.paste_tail_len;
        @memcpy(scalar[0..scalar_len], self.paste_tail[0..scalar_len]);
        self.paste_tail_len = 0;
        self.paste_expected = 0;
        _ = std.unicode.utf8Decode(scalar[0..scalar_len]) catch {
            self.recordFailure(error.InvalidText);
            return false;
        };
        return self.applyPasteInsert(scalar[0..scalar_len]);
    }

    fn applyPasteInsert(self: *TextInput, bytes: []const u8) bool {
        return switch (self.replace(bytes)) {
            .inserted => true,
            .capacity => blocked: {
                self.paste_blocked = true;
                self.recordFailure(error.CapacityExceeded);
                break :blocked false;
            },
            .invalid => invalid: {
                self.recordFailure(error.InvalidText);
                break :invalid false;
            },
            .overlapping => overlapping: {
                self.recordFailure(error.OverlappingInput);
                break :overlapping false;
            },
            .empty => false,
        };
    }

    fn insertionUpdate(self: *TextInput, result: InsertResult) Update {
        return switch (result) {
            .inserted => .redraw,
            .empty => .handled,
            .capacity => failed: {
                self.recordFailure(error.CapacityExceeded);
                break :failed .handled;
            },
            .invalid => failed: {
                self.recordFailure(error.InvalidText);
                break :failed .handled;
            },
            .overlapping => failed: {
                self.recordFailure(error.OverlappingInput);
                break :failed .handled;
            },
        };
    }

    fn recordFailure(self: *TextInput, failure: EditError) void {
        if (self.pending_failure == null) self.pending_failure = failure;
    }

    fn resetPaste(self: *TextInput) void {
        self.paste_tail_len = 0;
        self.paste_expected = 0;
        self.paste_active = false;
        self.paste_blocked = false;
    }

    fn updateView(self: *TextInput, width: u16, show_caret: bool) u16 {
        if (self.view_start > self.cursor) {
            self.view_start = self.cursor;
            self.view_column = self.cursor_column;
        }
        const next = clusterAt(self.value(), self.cursor, self.width_profile);
        const anchor_width: usize = if (!show_caret)
            0
        else if (next) |cluster|
            @min(@as(usize, cluster.width), width)
        else
            1;
        const prefix_limit = @as(usize, width) - anchor_width;
        var prefix_width = self.cursor_column - self.view_column;
        while (prefix_width > prefix_limit and self.view_start < self.cursor) {
            const first = clusterAt(self.value(), self.view_start, self.width_profile).?;
            prefix_width -= first.width;
            self.view_column += first.width;
            self.view_start = first.end;
        }
        while (self.view_start != 0) {
            const previous = previousBoundary(self.value(), self.view_start);
            const previous_width = clusterAt(self.value(), previous, self.width_profile).?.width;
            if (previous_width > prefix_limit - prefix_width) break;
            self.view_start = previous;
            self.view_column -= previous_width;
            prefix_width += previous_width;
        }
        return @intCast(prefix_width);
    }

    fn syncMetrics(self: *TextInput) void {
        if (self.measured_profile == self.width_profile) return;
        const location = validateAndLocate(
            self.value(),
            self.cursor,
            .forward,
            self.width_profile,
        ) catch unreachable;
        self.cursor = location.cursor;
        self.previous_boundary = location.previous;
        self.next_boundary = location.next;
        self.display_width = location.total_width;
        self.cursor_column = location.cursor_width;
        self.view_start = 0;
        self.view_column = 0;
        self.measured_profile = self.width_profile;
    }
};

const InsertResult = enum {
    inserted,
    capacity,
    invalid,
    overlapping,
    empty,
};

const SnapDirection = enum {
    forward,
    backward,
};

const ClusterInfo = struct {
    end: usize,
    width: u2,
};

const Location = struct {
    cursor: usize,
    previous: usize,
    next: usize,
    cursor_width: usize,
    total_width: usize,
};

fn validateAndLocate(
    value: []const u8,
    target: usize,
    direction: SnapDirection,
    width_profile: text.WidthProfile,
) InitError!Location {
    var ascii = true;
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7F) return error.ControlCharacter;
        if (byte > 0x7E) {
            ascii = false;
            break;
        }
    }
    if (ascii) return .{
        .cursor = target,
        .previous = if (target == 0) 0 else target - 1,
        .next = if (target == value.len) value.len else target + 1,
        .cursor_width = target,
        .total_width = value.len,
    };

    var clusters = text.GraphemeIterator.init(value) catch return error.InvalidUtf8;
    var previous: usize = 0;
    var before_previous: usize = 0;
    var total_width: usize = 0;
    var location: ?Location = if (target == 0) .{
        .cursor = 0,
        .previous = 0,
        .next = 0,
        .cursor_width = 0,
        .total_width = 0,
    } else null;
    while (clusters.next()) |cluster| {
        const cluster_width = try validateCluster(cluster, width_profile);
        const end_width = total_width + cluster_width;
        if (location == null and clusters.index >= target) {
            location = switch (direction) {
                .forward => .{
                    .cursor = clusters.index,
                    .previous = previous,
                    .next = clusters.index,
                    .cursor_width = end_width,
                    .total_width = 0,
                },
                .backward => if (clusters.index == target)
                    .{
                        .cursor = target,
                        .previous = previous,
                        .next = target,
                        .cursor_width = end_width,
                        .total_width = 0,
                    }
                else
                    .{
                        .cursor = previous,
                        .previous = before_previous,
                        .next = clusters.index,
                        .cursor_width = total_width,
                        .total_width = 0,
                    },
            };
        }
        if (location) |*located| {
            if (located.next == located.cursor and clusters.index > located.cursor) located.next = clusters.index;
        }
        before_previous = previous;
        previous = clusters.index;
        total_width = end_width;
    }
    if (location) |*located| {
        located.total_width = total_width;
        return located.*;
    }
    return .{
        .cursor = value.len,
        .previous = before_previous,
        .next = value.len,
        .cursor_width = total_width,
        .total_width = total_width,
    };
}

fn validateCluster(cluster: text.Grapheme, width_profile: text.WidthProfile) InitError!u2 {
    if (cluster.bytes.len > text.max_grapheme_bytes) return error.GraphemeTooLong;
    const width = cluster.displayWidthAssumeValid(width_profile) catch |err| switch (err) {
        error.InvalidUtf8 => return error.InvalidUtf8,
        error.ControlCharacter => return error.ControlCharacter,
    };
    if (width == 0) return error.ZeroWidthGrapheme;
    return width;
}

fn clusterAt(value: []const u8, start: usize, width_profile: text.WidthProfile) ?ClusterInfo {
    if (start == value.len) return null;
    var clusters = text.GraphemeIterator.init(value[start..]) catch unreachable;
    const cluster = clusters.next().?;
    return .{
        .end = start + cluster.bytes.len,
        .width = cluster.displayWidthAssumeValid(width_profile) catch unreachable,
    };
}

fn nextBoundary(value: []const u8, start: usize) usize {
    return if (clusterAt(value, start, .narrow)) |cluster| cluster.end else start;
}

fn previousBoundary(value: []const u8, end: usize) usize {
    if (end == 0) return 0;
    var clusters = text.GraphemeIterator.init(value) catch unreachable;
    var previous: usize = 0;
    while (clusters.next()) |_| {
        if (clusters.index >= end) return previous;
        previous = clusters.index;
    }
    return previous;
}

fn isBoundary(value: []const u8, offset: usize) bool {
    if (offset > value.len) return false;
    if (offset == 0 or offset == value.len) return true;
    if (value[offset - 1] < 0x80 and value[offset] < 0x80) return true;
    var clusters = text.GraphemeIterator.init(value) catch unreachable;
    while (clusters.next()) |_| {
        if (clusters.index == offset) return true;
        if (clusters.index > offset) return false;
    }
    return false;
}

fn slicesOverlap(storage: []const u8, bytes: []const u8) bool {
    if (storage.len == 0 or bytes.len == 0) return false;
    const storage_start = @intFromPtr(storage.ptr);
    const bytes_start = @intFromPtr(bytes.ptr);
    const storage_end = std.math.add(usize, storage_start, storage.len) catch return true;
    const bytes_end = std.math.add(usize, bytes_start, bytes.len) catch return true;
    return storage_start < bytes_end and bytes_start < storage_end;
}

fn asciiInsertionIsSafe(value: []const u8, cursor: usize, bytes: []const u8) bool {
    for (bytes) |byte| if (byte < 0x20 or byte > 0x7e) return false;
    return (cursor == 0 or value[cursor - 1] < 0x80) and
        (cursor == value.len or value[cursor] < 0x80);
}

fn asciiReplacementIsSafe(value: []const u8, start: usize, end: usize, bytes: []const u8) bool {
    for (value[start..end]) |byte| if (byte < 0x20 or byte > 0x7e) return false;
    for (bytes) |byte| if (byte < 0x20 or byte > 0x7e) return false;
    return (start == 0 or value[start - 1] < 0x80) and
        (end == value.len or value[end] < 0x80);
}

fn validateTextParts(parts: anytype) error{InvalidText}!void {
    var ascii = true;
    inline for (parts) |part| {
        for (part) |byte| {
            if (byte >= 0x80) {
                ascii = false;
            } else if (byte < 0x20 or byte == 0x7f) {
                return error.InvalidText;
            }
        }
    }
    if (ascii) return;

    var validator: TextValidator = .{};
    inline for (parts) |part| try validator.add(part);
    try validator.finish();
}

const TextValidator = struct {
    bytes: [text.max_grapheme_bytes + 4]u8 = undefined,
    len: usize = 0,

    fn add(self: *@This(), segment: []const u8) error{InvalidText}!void {
        var index: usize = 0;
        while (index < segment.len) {
            const scalar_len = std.unicode.utf8ByteSequenceLength(segment[index]) catch return error.InvalidText;
            if (scalar_len > segment.len - index) return error.InvalidText;
            const scalar = segment[index .. index + scalar_len];
            _ = std.unicode.utf8Decode(scalar) catch return error.InvalidText;
            index += scalar_len;

            const previous_len = self.len;
            @memcpy(self.bytes[self.len..][0..scalar_len], scalar);
            self.len += scalar_len;
            var clusters = text.GraphemeIterator.init(self.bytes[0..self.len]) catch return error.InvalidText;
            const first = clusters.next().?;
            if (first.bytes.len == self.len) {
                if (self.len > text.max_grapheme_bytes) return error.InvalidText;
                continue;
            }
            if (first.bytes.len != previous_len) return error.InvalidText;
            try validateTextCluster(first);
            std.mem.copyForwards(u8, self.bytes[0..scalar_len], scalar);
            self.len = scalar_len;
        }
    }

    fn finish(self: *@This()) error{InvalidText}!void {
        if (self.len == 0) return;
        try validateTextCluster(.{ .bytes = self.bytes[0..self.len] });
        self.len = 0;
    }
};

fn validateTextCluster(cluster: text.Grapheme) error{InvalidText}!void {
    if (cluster.bytes.len > text.max_grapheme_bytes) return error.InvalidText;
    const width = cluster.displayWidthAssumeValid(.narrow) catch return error.InvalidText;
    if (width == 0) return error.InvalidText;
}

fn utf8PrefixAtMost(value: []const u8, maximum: usize) usize {
    var end = @min(value.len, maximum);
    while (end != 0 and end < value.len and value[end] & 0xc0 == 0x80) end -= 1;
    return end;
}

inline fn hasTextModifiers(modifiers: input.Modifiers) bool {
    return modifiers.alt or modifiers.control or modifiers.super or modifiers.hyper or modifiers.meta;
}

test "text input validates storage and edits by grapheme boundary" {
    var storage: [16]u8 = undefined;
    var field = try TextInput.init(&storage, "Ae\xCC\x81\xE7\x95\x8CB");
    try std.testing.expectEqual(@as(usize, 8), field.cursor);
    try std.testing.expectEqual(Update.redraw, field.handle(.{ .key = .{ .code = .left } }));
    try std.testing.expectEqual(@as(usize, 7), field.cursor);
    _ = field.handle(.{ .key = .{ .code = .left } });
    try std.testing.expectEqual(@as(usize, 4), field.cursor);
    try std.testing.expectEqual(Update.redraw, field.handle(.{ .key = .{ .code = .backspace } }));
    try std.testing.expectEqualStrings("A\xE7\x95\x8CB", field.value());
    try std.testing.expectEqual(@as(usize, 1), field.cursor);
    _ = field.handle(.{ .key = .{ .code = .delete } });
    try std.testing.expectEqualStrings("AB", field.value());
    _ = field.handle(.{ .key = .{ .code = .end } });
    try std.testing.expectEqual(Update.redraw, field.handle(.{ .text = "!" }));
    try std.testing.expectEqualStrings("AB!", field.value());

    var tiny_storage: [2]u8 = undefined;
    var full = try TextInput.init(&tiny_storage, "ab");
    try std.testing.expectEqual(Update.handled, full.handle(.{ .text = "c" }));
    try std.testing.expectEqual(error.CapacityExceeded, full.takeFailure().?);
    try std.testing.expect(full.takeFailure() == null);
    try std.testing.expectEqualStrings("ab", full.value());

    var suffix_storage: [8]u8 = undefined;
    var suffix = try TextInput.init(&suffix_storage, "xb\xCC\x81");
    _ = suffix.handle(.{ .key = .{ .code = .home } });
    _ = suffix.handle(.{ .key = .{ .code = .right } });
    try std.testing.expectEqual(Update.redraw, suffix.handle(.{ .text = "A" }));
    _ = suffix.handle(.{ .key = .{ .code = .right } });
    try std.testing.expectEqual(@as(usize, 5), suffix.cursor);

    var profile_storage: [8]u8 = undefined;
    var profile = try TextInput.init(&profile_storage, "\xC2\xB7x");
    profile.width_profile = .wide_ambiguous;
    try std.testing.expectEqual(Update.redraw, profile.handle(.{ .text = "A" }));
    try std.testing.expectEqual(@as(usize, 4), profile.cursor_column);
    try std.testing.expectEqual(@as(usize, 4), profile.display_width);
}

test "text input selects and replaces complete graphemes" {
    var storage: [32]u8 = undefined;
    var field = try TextInput.init(&storage, "Ae\xCC\x81\xE7\x95\x8CB");
    const shift = input.Modifiers{ .shift = true };

    try std.testing.expectEqual(Update.redraw, field.handle(.{ .key = .{ .code = .left, .modifiers = shift } }));
    try std.testing.expectEqual(Selection{ .start = 7, .end = 8 }, field.selection().?);
    _ = field.handle(.{ .key = .{ .code = .left, .modifiers = shift } });
    try std.testing.expectEqualStrings("\xE7\x95\x8CB", field.selectedText().?);
    _ = field.handle(.{ .key = .{ .code = .left, .modifiers = shift } });
    try std.testing.expectEqual(Selection{ .start = 1, .end = 8 }, field.selection().?);

    _ = field.handle(.{ .key = .{ .code = .left } });
    try std.testing.expectEqual(@as(usize, 1), field.cursor);
    try std.testing.expect(field.selection() == null);
    try std.testing.expectError(error.InvalidBoundary, field.setSelection(2, 7));
    try std.testing.expectEqual(@as(usize, 1), field.cursor);

    try std.testing.expect(try field.setSelection(1, 7));
    try std.testing.expect(try field.replaceSelection("xy"));
    try std.testing.expectEqualStrings("AxyB", field.value());
    try std.testing.expectEqual(@as(usize, 3), field.cursor);
    try std.testing.expect(try field.setSelection(1, 3));
    try std.testing.expectError(error.InvalidText, field.replaceSelection("\n"));
    try std.testing.expectEqualStrings("AxyB", field.value());
    try std.testing.expectEqual(Selection{ .start = 1, .end = 3 }, field.selection().?);
    try std.testing.expectEqual(Update.redraw, field.handle(.{ .key = .{ .code = .backspace } }));
    try std.testing.expectEqualStrings("AB", field.value());
    _ = try field.setCursor(field.value().len);
    try std.testing.expectEqual(Update.redraw, field.handle(.{ .key = .{ .code = .home, .modifiers = shift } }));
    try std.testing.expectEqualStrings("AB", field.selectedText().?);
    try std.testing.expectEqual(Update.redraw, field.handle(.{ .key = .{ .code = .end } }));
    try std.testing.expect(field.selection() == null);

    var full_storage: [2]u8 = undefined;
    var full = try TextInput.init(&full_storage, "ab");
    try std.testing.expect(full.selectAll());
    try std.testing.expect(try full.replaceSelection("xy"));
    try std.testing.expectEqualStrings("xy", full.value());

    try std.testing.expect(full.selectAll());
    try std.testing.expectEqual(Update.handled, full.handle(.paste_start));
    try std.testing.expectEqual(Update.handled, full.handle(.{ .paste_chunk = "\xC3" }));
    try std.testing.expectEqualStrings("xy", full.value());
    try std.testing.expectEqual(Update.redraw, full.handle(.{ .paste_chunk = "\xA9" }));
    try std.testing.expectEqual(Update.handled, full.handle(.paste_end));
    try std.testing.expectEqualStrings("\xC3\xA9", full.value());
}

test "text input rejects invalid initial and merged values" {
    var storage: [64]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, TextInput.init(storage[0..1], "ab"));
    try std.testing.expectError(error.InvalidUtf8, TextInput.init(&storage, "\xC0\x80"));
    try std.testing.expectError(error.ControlCharacter, TextInput.init(&storage, "a\nb"));
    try std.testing.expectError(error.ZeroWidthGrapheme, TextInput.init(&storage, "\xCC\x81"));

    var oversized: [text.max_grapheme_bytes + 1]u8 = undefined;
    oversized[0] = 'a';
    var index: usize = 1;
    while (index < oversized.len) : (index += 2) {
        oversized[index] = 0xCC;
        oversized[index + 1] = 0x81;
    }
    try std.testing.expectError(error.GraphemeTooLong, TextInput.init(&storage, &oversized));

    var longest: [text.max_grapheme_bytes - 1]u8 = undefined;
    longest[0] = 'a';
    index = 1;
    while (index < longest.len) : (index += 2) {
        longest[index] = 0xCC;
        longest[index + 1] = 0x81;
    }
    var field = try TextInput.init(&storage, &longest);
    try std.testing.expectEqual(Update.handled, field.handle(.{ .text = "\xCC\x81" }));
    try std.testing.expectEqual(error.InvalidText, field.takeFailure().?);
    try std.testing.expectEqualSlices(u8, &longest, field.value());
    try std.testing.expectEqual(Update.handled, field.handle(.{ .key = .{ .code = .{ .codepoint = 0xD800 } } }));
    try std.testing.expectEqual(error.InvalidText, field.takeFailure().?);
}

test "text input consumes fragmented paste without retaining event slices" {
    var storage: [32]u8 = undefined;
    var field = try TextInput.init(&storage, "");
    const Sink = struct {
        field: *TextInput,

        pub fn emit(self: *@This(), event: input.Event) !void {
            _ = self.field.handle(event);
        }
    };
    var sink = Sink{ .field = &field };
    var parser: input.Parser = .{};
    const pasted = "\x1b[200~e\xCC\x81\r\n\xE7\x95\x8C\x1b[201~";
    for (pasted) |byte| try parser.feed(&.{byte}, &sink);
    try std.testing.expectEqualStrings("e\xCC\x81\xE7\x95\x8C", field.value());

    try parser.feed("\x1b[200~\xE7", &sink);
    try parser.finish(&sink);
    try std.testing.expectEqual(error.InvalidText, field.takeFailure().?);
    try std.testing.expectEqualStrings("e\xCC\x81\xE7\x95\x8C", field.value());
    try std.testing.expectEqual(Update.redraw, field.handle(.{ .text = "x" }));
    try std.testing.expectEqualStrings("e\xCC\x81\xE7\x95\x8Cx", field.value());
}

test "text input rejects overlapping paste input without mutation" {
    var storage: [16]u8 = undefined;
    var field = try TextInput.init(&storage, "abc");
    _ = field.handle(.paste_start);
    try std.testing.expectEqual(Update.handled, field.handle(.{ .paste_chunk = field.value() }));
    try std.testing.expectEqual(error.OverlappingInput, field.takeFailure().?);
    try std.testing.expectEqualStrings("abc", field.value());
}

test "text input draws a grapheme-safe viewport and visual caret without allocation" {
    var storage: [16]u8 = undefined;
    var field = try TextInput.init(&storage, "ab\xE7\x95\x8Cc");
    field.focused = true;
    var wide_storage: [4]u8 = undefined;
    var wide = try TextInput.init(&wide_storage, "\xE7\x95\x8C");
    wide.focused = true;
    _ = wide.handle(.{ .key = .{ .code = .home } });
    var empty_storage: [1]u8 = undefined;
    var empty = try TextInput.init(&empty_storage, "");
    empty.placeholder = "hint";
    var selected_storage: [4]u8 = undefined;
    var selected = try TextInput.init(&selected_storage, "abcd");
    _ = try selected.setSelection(1, 3);

    var allocator_state = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var renderer = try render.Renderer.init(allocator_state.allocator(), .{ .width = 4, .height = 4 }, .{});
    defer renderer.deinit();
    allocator_state.fail_index = allocator_state.alloc_index;
    allocator_state.resize_fail_index = allocator_state.resize_index;
    var frame = renderer.frame();
    var root = frame.surface(render.Rect.fromSize(renderer.size()));

    var first = root.surface(.{ .x = 0, .y = 0, .width = 3, .height = 1 });
    try field.draw(&first);
    try std.testing.expectEqual(@as(usize, 5), field.view_start);
    try std.testing.expectEqual(@as(u32, 'c'), renderer.desiredCell(.{ .x = 0, .y = 0 }).?.glyph);
    try std.testing.expect(renderer.desiredCell(.{ .x = 1, .y = 0 }).?.style != 0);

    _ = field.handle(.{ .key = .{ .code = .left } });
    try field.draw(&first);
    try std.testing.expectEqual(@as(usize, 2), field.view_start);
    try std.testing.expectEqual(@as(u32, 0x754C), renderer.desiredCell(.{ .x = 0, .y = 0 }).?.glyph);
    try std.testing.expectEqual(render.CellWidth.continuation, renderer.desiredCell(.{ .x = 1, .y = 0 }).?.width);
    try std.testing.expectEqual(@as(u32, 'c'), renderer.desiredCell(.{ .x = 2, .y = 0 }).?.glyph);

    var second = root.surface(.{ .x = 0, .y = 1, .width = 1, .height = 1 });
    try wide.draw(&second);
    try std.testing.expectEqual(@as(u32, ' '), renderer.desiredCell(.{ .x = 0, .y = 1 }).?.glyph);
    try std.testing.expect(renderer.desiredCell(.{ .x = 0, .y = 1 }).?.style != 0);

    var third = root.surface(.{ .x = 0, .y = 2, .width = 3, .height = 1 });
    try empty.draw(&third);
    try std.testing.expectEqual(@as(u32, 'h'), renderer.desiredCell(.{ .x = 0, .y = 2 }).?.glyph);

    var fourth = root.surface(.{ .x = 0, .y = 3, .width = 4, .height = 1 });
    try selected.draw(&fourth);
    try std.testing.expect(renderer.desiredCell(.{ .x = 0, .y = 3 }).?.style != renderer.desiredCell(.{ .x = 1, .y = 3 }).?.style);
    try std.testing.expectEqual(renderer.desiredCell(.{ .x = 1, .y = 3 }).?.style, renderer.desiredCell(.{ .x = 2, .y = 3 }).?.style);
    try std.testing.expectEqual(renderer.desiredCell(.{ .x = 0, .y = 3 }).?.style, renderer.desiredCell(.{ .x = 3, .y = 3 }).?.style);
    try std.testing.expect(!allocator_state.has_induced_failure);
}
