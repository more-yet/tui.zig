const std = @import("std");
const geometry = @import("../core/geometry.zig");
const memory = @import("../core/memory.zig");
const grapheme = @import("../text/grapheme.zig");
const line_layout = @import("../text/line.zig");
const text_wrap = @import("../text/wrap.zig");
const ansi = @import("../terminal/ansi.zig");
const capabilities_module = @import("../terminal/capabilities.zig");
const cell_module = @import("cell.zig");
const cursor_module = @import("cursor.zig");
const damage_module = @import("damage.zig");
const glyph_store = @import("glyph_store.zig");
const style_module = @import("style.zig");
const kitty_placeholder = @import("../graphics/placeholder.zig");

pub const Storage = struct {
    desired: []cell_module.Cell,
    presented: []cell_module.Cell,
    damage_rows: []damage_module.Row,
    damage_bits: []usize,
    glyph_entries: []glyph_store.Entry,
    glyph_slots: []u32,
    style_entries: []style_module.Entry,
    style_slots: []u32,
};

pub fn FixedStorage(
    comptime max_width: u16,
    comptime max_height: u16,
    comptime grapheme_capacity: u32,
    comptime style_capacity: u16,
) type {
    const max_size = geometry.Size{ .width = max_width, .height = max_height };
    const cell_count = @as(usize, max_width) * max_height;
    return struct {
        desired: [cell_count]cell_module.Cell = undefined,
        presented: [cell_count]cell_module.Cell = undefined,
        damage_rows: [max_height]damage_module.Row = undefined,
        damage_bits: [damage_module.requiredTileWords(max_size)]usize = undefined,
        glyph_entries: [grapheme_capacity]glyph_store.Entry = undefined,
        glyph_slots: [glyph_store.requiredSlots(grapheme_capacity)]u32 = undefined,
        style_entries: [style_capacity]style_module.Entry = undefined,
        style_slots: [style_module.requiredSlots(style_capacity)]u32 = undefined,

        pub fn slices(self: *@This()) Storage {
            return .{
                .desired = &self.desired,
                .presented = &self.presented,
                .damage_rows = &self.damage_rows,
                .damage_bits = &self.damage_bits,
                .glyph_entries = &self.glyph_entries,
                .glyph_slots = &self.glyph_slots,
                .style_entries = &self.style_entries,
                .style_slots = &self.style_slots,
            };
        }
    };
}

fn storageSlicesOverlap(storage: Storage) bool {
    const slices = [_][]const u8{
        std.mem.sliceAsBytes(storage.desired),
        std.mem.sliceAsBytes(storage.presented),
        std.mem.sliceAsBytes(storage.damage_rows),
        std.mem.sliceAsBytes(storage.damage_bits),
        std.mem.sliceAsBytes(storage.glyph_entries),
        std.mem.sliceAsBytes(storage.glyph_slots),
        std.mem.sliceAsBytes(storage.style_entries),
        std.mem.sliceAsBytes(storage.style_slots),
    };
    for (slices, 0..) |lhs, lhs_index| {
        for (slices[lhs_index + 1 ..]) |rhs| {
            if (memory.slicesOverlap(lhs, rhs)) return true;
        }
    }
    return false;
}

pub const FrameStats = struct {
    bytes: usize = 0,
    work_units: u64 = 0,
    // A u16-by-u16 terminal contains fewer than maxInt(u32) cells.
    cells_compared: u32 = 0,
    cells_changed: u32 = 0,
    /// Number of bounded, same-style terminal runs emitted.
    runs: u32 = 0,
    dirty_rows: u16 = 0,
    full_repaint: bool = false,
};

pub const Presentation = union(enum) {
    output: []const u8,
    yielded: FrameStats,
    /// A destructive clear was acknowledged. Replay application-owned
    /// graphics before requesting the next text presentation step.
    cleared: FrameStats,
    complete: FrameStats,
};

const PresentationPhase = enum {
    inactive,
    clear,
    clear_checkpoint,
    scan,
    cursor,
    cleanup,
};

const RunCommit = struct {
    index: usize,
    count: u16,
};

const PresentationCommit = union(enum) {
    none,
    clear,
    run: RunCommit,
    cursor,
};

const PendingCommand = struct {
    len: u16,
    accepted: u16 = 0,
    commit: PresentationCommit,
    terminal_state: ansi.State,
    cursor_state: ansi.CursorState,
};

pub const StyledSpan = struct {
    text: []const u8,
    style: style_module.Style = .{},
};

pub const CellView = struct {
    glyph: []const u8,
    style: style_module.Style,
    width: cell_module.Width,
};

pub const AsciiFill = struct {
    rect: geometry.Rect,
    glyph: u8,
};

const StyledPosition = text_wrap.SpanPosition;

const UniformFillProof = struct {
    rect: geometry.Rect,
    cell: cell_module.Cell = .{},
};

const AsciiFieldMode = enum {
    padded,
    line,
};

pub const Renderer = struct {
    terminal_size: geometry.Size,
    desired: []cell_module.Cell,
    presented: []cell_module.Cell,
    damage: damage_module.Map,
    glyphs: glyph_store.Store,
    styles: style_module.Table,
    terminal_state: ansi.State = .{},
    terminal_cursor_state: ansi.CursorState = .{},
    shadow_valid: bool = false,
    frame_pending: bool = true,
    last_uniform_fill: ?UniformFillProof = null,
    desired_cursor: ?cursor_module.Cursor = null,
    presentation_phase: PresentationPhase = .inactive,
    presentation_capabilities: capabilities_module.Capabilities = .{},
    presentation_full_repaint: bool = false,
    presentation_y: u16 = 0,
    presentation_end_y: u16 = 0,
    presentation_x: u16 = 0,
    presentation_row_end: u16 = 0,
    presentation_row_started: bool = false,
    presentation_lookahead_count: u2 = 0,
    presentation_lookahead_changes: u2 = 0,
    presentation_damage_reset: damage_module.ResetProgress = .{},
    presentation_stats: FrameStats = .{},
    // One bounded command: synchronized wrappers, cursor state, positioning, SGR,
    // and a same-style run of complete graphemes fit within this fixed buffer.
    presentation_output: [512]u8 = undefined,
    pending_command: ?PendingCommand = null,

    pub fn init(
        storage: Storage,
        dimensions: geometry.Size,
    ) !Renderer {
        if (dimensions.width == 0 or dimensions.height == 0) return error.InvalidSize;
        const cell_count = try dimensions.cellCount();
        if (storage.desired.len < cell_count or storage.presented.len < cell_count) {
            return error.BufferTooSmall;
        }
        if (storageSlicesOverlap(storage)) return error.OverlappingStorage;

        const glyphs = try glyph_store.Store.init(storage.glyph_entries, storage.glyph_slots);
        const styles = try style_module.Table.init(storage.style_entries, storage.style_slots);
        var damage = try damage_module.Map.init(storage.damage_rows, storage.damage_bits, dimensions);

        @memset(storage.desired[0..cell_count], .{});
        @memset(storage.presented[0..cell_count], .{});
        damage.mark(geometry.Rect.fromSize(dimensions));

        return .{
            .terminal_size = dimensions,
            .desired = storage.desired,
            .presented = storage.presented,
            .damage = damage,
            .glyphs = glyphs,
            .styles = styles,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.* = undefined;
    }

    pub fn size(self: *const Renderer) geometry.Size {
        return self.terminal_size;
    }

    /// True after presentation begins until it completes or is aborted.
    pub fn isPresenting(self: *const Renderer) bool {
        return self.presentation_phase != .inactive;
    }

    /// True when presentation work remains for these terminal capabilities.
    pub fn needsPresentation(self: *const Renderer, capabilities: capabilities_module.Capabilities) bool {
        return self.isPresenting() or self.frame_pending or
            self.shadow_valid and self.terminal_state.color_depth != capabilities.color_depth;
    }

    pub fn resize(self: *Renderer, new_size: geometry.Size) !void {
        try self.requireInactive();
        if (new_size.width == 0 or new_size.height == 0) return error.InvalidSize;
        if (new_size.width == self.terminal_size.width and new_size.height == self.terminal_size.height) return;
        const new_cell_count = try new_size.cellCount();
        if (new_cell_count > self.desired.len or new_cell_count > self.presented.len) return error.SizeLimitExceeded;
        if (!self.damage.canResize(new_size)) return error.SizeLimitExceeded;
        const old_cell_count = self.terminal_size.cellCount() catch unreachable;
        self.last_uniform_fill = null;
        self.resetDenseGrid(self.desired, old_cell_count, new_cell_count);
        self.resetDenseGrid(self.presented, old_cell_count, new_cell_count);
        self.damage.resizeWithinCapacity(new_size);
        self.terminal_size = new_size;
        self.terminal_state = .{};
        self.terminal_cursor_state = .{};
        self.shadow_valid = false;
        self.frame_pending = true;
    }

    pub fn invalidate(self: *Renderer, rect: geometry.Rect) !void {
        try self.requireInactive();
        self.damage.mark(rect);
        self.frame_pending = true;
    }

    /// Discards the terminal shadow while retaining the desired frame.
    /// Use this after external output or terminal resume. The next presentation clears and repaints the terminal.
    pub fn invalidateTerminal(self: *Renderer) !void {
        try self.requireInactive();
        self.invalidateTerminalState();
    }

    fn invalidateTerminalState(self: *Renderer) void {
        self.shadow_valid = false;
        self.frame_pending = true;
        self.terminal_state.invalidate();
        self.terminal_cursor_state.invalidate();
    }

    /// Starts cursor management and schedules any changed position, visibility, or shape.
    /// An out-of-bounds position is retained but hidden until a later resize makes it visible.
    pub fn setCursor(self: *Renderer, cursor: cursor_module.Cursor) !void {
        try self.requireInactive();
        if (self.desired_cursor) |current| {
            if (current.eql(cursor)) return;
        }
        self.desired_cursor = cursor;
        self.frame_pending = true;
    }

    pub fn scrollUp(self: *Renderer, rect: geometry.Rect) !void {
        try self.requireInactive();
        if (rect.x != 0 or rect.width != self.terminal_size.width or rect.height < 2 or
            rect.bottom() > self.terminal_size.height)
        {
            return error.InvalidScrollRegion;
        }
        const top = rect.y;
        const bottom: u16 = @intCast(rect.bottom());
        var changed = false;
        var y = top;
        while (y + 1 < bottom) : (y += 1) {
            const target_offset = self.rowOffset(y);
            const source_offset = self.rowOffset(y + 1);
            var x: u16 = 0;
            while (x < self.terminal_size.width) : (x += 1) {
                changed = self.replaceDesiredCell(target_offset + x, self.desired[source_offset + x]) or changed;
            }
        }
        const final_offset = self.rowOffset(bottom - 1);
        var x: u16 = 0;
        while (x < self.terminal_size.width) : (x += 1) {
            changed = self.replaceDesiredCell(final_offset + x, .{}) or changed;
        }
        if (changed) self.damage.mark(rect);
    }

    /// Returns a clipped drawing view borrowing this renderer. Recreate surfaces
    /// after resize; drawing methods reject an active presentation.
    pub fn surface(self: *Renderer, rect: geometry.Rect) Surface {
        return Surface.init(
            self,
            rect.x,
            rect.y,
            .{ .width = rect.width, .height = rect.height },
            geometry.Rect.fromSize(self.terminal_size),
        );
    }

    pub fn desiredCell(self: *const Renderer, point: geometry.Point) ?cell_module.Cell {
        if (point.x >= self.terminal_size.width or point.y >= self.terminal_size.height) return null;
        return self.desired[self.index(point.x, point.y)];
    }

    pub fn desiredCellView(
        self: *const Renderer,
        point: geometry.Point,
        glyph_storage: *[grapheme.max_cluster_bytes]u8,
    ) ?CellView {
        const cell = self.desiredCell(point) orelse return null;
        var scalar: [4]u8 = undefined;
        const bytes = self.glyphs.bytes(cell.glyph, &scalar);
        @memcpy(glyph_storage[0..bytes.len], bytes);
        return .{
            .glyph = glyph_storage[0..bytes.len],
            .style = self.styles.get(cell.style),
            .width = cell.width,
        };
    }

    /// Generates bounded presentation work without performing I/O. The caller writes the
    /// returned bytes and acknowledges exactly the accepted prefix with `consumePresentation`.
    pub fn presentStep(self: *Renderer, work_budget: u32) !Presentation {
        if (work_budget < 2) return error.InvalidWorkBudget;
        if (self.pending_command) |pending| return .{
            .output = self.presentation_output[pending.accepted..pending.len],
        };
        if (self.presentation_phase == .inactive) return .{ .complete = .{} };

        var remaining = work_budget;
        while (true) switch (self.presentation_phase) {
            .inactive => unreachable,
            .clear => {
                try self.generateClearCommand();
                return .{ .output = self.presentation_output[0..self.pending_command.?.len] };
            },
            .clear_checkpoint => {
                self.presentation_phase = .scan;
                return .{ .cleared = self.presentation_stats };
            },
            .scan => {
                while (self.presentation_y < self.presentation_end_y) {
                    if (!self.presentation_row_started) {
                        if (remaining == 0) return .{ .yielded = self.presentation_stats };
                        remaining -= 1;
                        self.presentation_stats.work_units += 1;
                        const span = self.nextSpan(
                            self.presentation_y,
                            self.presentation_x,
                            self.presentation_full_repaint,
                        ) orelse {
                            self.presentation_y += 1;
                            self.presentation_x = 0;
                            continue;
                        };
                        self.presentation_x = span.start;
                        self.presentation_row_end = span.end;
                        if (self.presentation_x > 0 and
                            self.desired[self.rowOffset(self.presentation_y) + self.presentation_x].width == .continuation)
                        {
                            self.presentation_x -= 1;
                        }
                        if (self.presentation_row_end < self.terminal_size.width and
                            self.desired[self.rowOffset(self.presentation_y) + self.presentation_row_end - 1].width == .wide)
                        {
                            self.presentation_row_end += 1;
                        }
                        self.presentation_row_started = true;
                    }
                    if (self.presentation_x >= self.presentation_row_end) {
                        self.presentation_row_started = false;
                        continue;
                    }

                    const row_offset = self.rowOffset(self.presentation_y);
                    const index_value = row_offset + self.presentation_x;
                    const next = self.desired[index_value];
                    std.debug.assert(next.width != .continuation);
                    const commit_count: u16 = if (next.width == .wide) 2 else 1;
                    const output_changes: u16 = if (self.presentation_lookahead_count != 0) changes: {
                        std.debug.assert(self.presentation_lookahead_count == commit_count);
                        const changes = self.presentation_lookahead_changes;
                        self.presentation_lookahead_count = 0;
                        self.presentation_lookahead_changes = 0;
                        break :changes changes;
                    } else self.compareCells(index_value, commit_count, &remaining) orelse
                        return .{ .yielded = self.presentation_stats };
                    if (output_changes == 0) {
                        var offset: u16 = 0;
                        while (offset < commit_count) : (offset += 1) {
                            self.commitPresentedCell(
                                index_value + offset,
                                self.desired[index_value + offset],
                            );
                        }
                        self.presentation_x += commit_count;
                        continue;
                    }
                    try self.generateRunCommand(commit_count, output_changes, &remaining);
                    self.presentation_stats.runs += 1;
                    return .{ .output = self.presentation_output[0..self.pending_command.?.len] };
                }
                self.presentation_phase = .cursor;
            },
            .cursor => {
                if (try self.generateCursorCommand()) {
                    return .{ .output = self.presentation_output[0..self.pending_command.?.len] };
                }
                self.presentation_phase = .cleanup;
            },
            .cleanup => {
                const before = remaining;
                const complete = self.damage.resetStep(&self.presentation_damage_reset, &remaining);
                self.presentation_stats.work_units += before - remaining;
                if (!complete) return .{ .yielded = self.presentation_stats };
                return .{ .complete = self.finishPresentation() };
            },
        };
    }

    /// Acknowledges bytes accepted by the caller's nonblocking output operation.
    pub fn consumePresentation(self: *Renderer, count: usize) !void {
        if (self.pending_command == null) return error.NoPresentationOutput;
        const pending = &self.pending_command.?;
        const remaining: usize = pending.len - pending.accepted;
        if (count > remaining) return error.InvalidByteCount;
        if (count == 0) return;
        pending.accepted += @intCast(count);
        self.presentation_stats.bytes += count;
        if (pending.accepted != pending.len) return;
        const completed = pending.*;
        self.pending_command = null;
        self.terminal_state = completed.terminal_state;
        self.terminal_cursor_state = completed.cursor_state;
        switch (completed.commit) {
            .none => {},
            .clear => {
                self.presentation_phase = .clear_checkpoint;
            },
            .run => |commit| {
                var offset: u16 = 0;
                while (offset < commit.count) : (offset += 1) {
                    const index_value = commit.index + offset;
                    self.commitPresentedCell(index_value, self.desired[index_value]);
                }
                self.presentation_x += commit.count;
            },
            .cursor => self.presentation_phase = .cleanup,
        }
    }

    /// Aborts at a command boundary. A partially accepted command must be drained first.
    pub fn abortPresentation(self: *Renderer) !void {
        if (self.presentation_phase == .inactive) return;
        if (self.pending_command) |pending| if (pending.accepted != 0) return error.PartialOutputPending;
        self.presentation_phase = .inactive;
        self.pending_command = null;
        self.presentation_lookahead_count = 0;
        self.presentation_lookahead_changes = 0;
        self.shadow_valid = false;
        self.frame_pending = true;
        self.terminal_state.invalidate();
        self.terminal_cursor_state.invalidate();
    }

    /// Invalidates cached cursor and SGR state after caller-owned graphics
    /// output. This never clears the terminal or changes text damage.
    pub fn invalidateOutputState(self: *Renderer) !void {
        if (self.pending_command != null) return error.PresentationOutputPending;
        self.terminal_state.invalidate();
        self.terminal_cursor_state.invalidate();
        if (self.desired_cursor != null) self.frame_pending = true;
    }

    /// Starts one explicit presentation lifetime and captures terminal
    /// capabilities. If no work is pending the renderer remains idle.
    pub fn beginPresentation(self: *Renderer, capabilities: capabilities_module.Capabilities) !void {
        if (self.presentation_phase != .inactive) return error.PresentationActive;
        if (self.shadow_valid and self.terminal_state.color_depth != capabilities.color_depth) {
            self.invalidateTerminalState();
        }
        if (!self.frame_pending) return;
        self.presentation_capabilities = capabilities;
        self.presentation_full_repaint = !self.shadow_valid;
        self.presentation_row_started = false;
        self.presentation_lookahead_count = 0;
        self.presentation_lookahead_changes = 0;
        self.presentation_damage_reset = .{};
        self.presentation_stats = .{
            .dirty_rows = @intCast(if (self.presentation_full_repaint)
                self.terminal_size.height
            else
                self.damage.dirtyRowCount()),
            .full_repaint = self.presentation_full_repaint,
        };
        const rows = if (self.presentation_full_repaint)
            damage_module.Span{ .start = 0, .end = self.terminal_size.height }
        else
            self.damage.dirtyRows() orelse damage_module.Span{
                .start = self.terminal_size.height,
                .end = self.terminal_size.height,
            };
        self.presentation_y = rows.start;
        self.presentation_end_y = rows.end;
        self.presentation_x = 0;
        self.presentation_phase = if (self.presentation_full_repaint)
            .clear
        else
            .scan;
    }

    fn generateClearCommand(self: *Renderer) !void {
        var writer = std.Io.Writer.fixed(&self.presentation_output);
        var terminal_state = self.terminal_state;
        var cursor_state = self.terminal_cursor_state;
        var output_stats: ansi.Stats = .{};
        var encoder = ansi.Encoder{
            .writer = &writer,
            .capabilities = self.presentation_capabilities,
            .terminal_width = self.terminal_size.width,
            .state = &terminal_state,
            .cursor_state = &cursor_state,
            .stats = &output_stats,
        };
        encoder.beginSynchronized() catch return error.PresentationCommandTooLarge;
        if (self.desired_cursor != null) {
            _ = encoder.hideCursor() catch return error.PresentationCommandTooLarge;
        }
        encoder.clear() catch return error.PresentationCommandTooLarge;
        encoder.endSynchronized() catch return error.PresentationCommandTooLarge;
        self.stagePresentationOutput(writer.buffered().len, .clear, terminal_state, cursor_state);
    }

    fn generateRunCommand(
        self: *Renderer,
        first_count: u16,
        first_changes: u16,
        remaining: *u32,
    ) !void {
        const start_x = self.presentation_x;
        const start_index = self.rowOffset(self.presentation_y) + start_x;
        const first = self.desired[start_index];
        var writer = std.Io.Writer.fixed(&self.presentation_output);
        var terminal_state = self.terminal_state;
        var cursor_state = self.terminal_cursor_state;
        var output_stats: ansi.Stats = .{};
        var encoder = ansi.Encoder{
            .writer = &writer,
            .capabilities = self.presentation_capabilities,
            .terminal_width = self.terminal_size.width,
            .state = &terminal_state,
            .cursor_state = &cursor_state,
            .stats = &output_stats,
        };
        encoder.beginSynchronized() catch return error.PresentationCommandTooLarge;
        if (self.desired_cursor != null) {
            _ = encoder.hideCursor() catch return error.PresentationCommandTooLarge;
        }
        encoder.moveTo(self.presentation_y, start_x) catch return error.PresentationCommandTooLarge;
        encoder.setStyle(self.styles.get(first.style)) catch return error.PresentationCommandTooLarge;

        const synchronized_end_len: usize = if (self.presentation_capabilities.synchronized_output) 8 else 0;
        var run_cells: u16 = 0;
        var run_changes: u32 = 0;
        var x = start_x;
        while (x < self.presentation_row_end and run_cells < 64) {
            const index_value = self.rowOffset(self.presentation_y) + x;
            const cell = self.desired[index_value];
            if (cell.width == .continuation or cell.style != first.style) break;
            const cell_count: u16 = if (cell.width == .wide) 2 else 1;
            if (run_cells + cell_count > 64 or x + cell_count > self.presentation_row_end) break;

            const changes: u16 = if (run_cells == 0)
                first_changes
            else
                self.compareCells(index_value, cell_count, remaining) orelse break;
            if (changes == 0) {
                self.presentation_lookahead_count = @intCast(cell_count);
                break;
            }

            var scalar: [4]u8 = undefined;
            const bytes = self.glyphs.bytes(cell.glyph, &scalar);
            if (writer.buffered().len + bytes.len + synchronized_end_len > self.presentation_output.len) {
                self.presentation_lookahead_count = @intCast(cell_count);
                self.presentation_lookahead_changes = @intCast(changes);
                break;
            }
            encoder.writeGlyph(bytes, @intCast(cell_count)) catch return error.PresentationCommandTooLarge;
            run_cells += cell_count;
            run_changes += changes;
            x += cell_count;
        }
        std.debug.assert(run_cells >= first_count);
        encoder.endSynchronized() catch return error.PresentationCommandTooLarge;
        self.presentation_stats.cells_changed += run_changes;
        self.stagePresentationOutput(
            writer.buffered().len,
            .{ .run = .{
                .index = start_index,
                .count = run_cells,
            } },
            terminal_state,
            cursor_state,
        );
    }

    fn compareCells(self: *Renderer, index_value: usize, count: u16, remaining: *u32) ?u16 {
        if (remaining.* < count) return null;
        remaining.* -= count;
        self.presentation_stats.work_units += count;
        self.presentation_stats.cells_compared += count;
        var changes: u16 = 0;
        var offset: u16 = 0;
        while (offset < count) : (offset += 1) {
            const desired = self.desired[index_value + offset];
            const baseline: cell_module.Cell = if (self.presentation_full_repaint)
                .{}
            else
                self.presented[index_value + offset];
            if (!desired.eql(baseline)) changes += 1;
        }
        return changes;
    }

    fn generateCursorCommand(self: *Renderer) !bool {
        const cursor = self.desired_cursor orelse return false;
        var writer = std.Io.Writer.fixed(&self.presentation_output);
        var terminal_state = self.terminal_state;
        var cursor_state = self.terminal_cursor_state;
        var output_stats: ansi.Stats = .{};
        var encoder = ansi.Encoder{
            .writer = &writer,
            .capabilities = self.presentation_capabilities,
            .terminal_width = self.terminal_size.width,
            .state = &terminal_state,
            .cursor_state = &cursor_state,
            .stats = &output_stats,
        };
        const in_bounds = cursor.position.x < self.terminal_size.width and cursor.position.y < self.terminal_size.height;
        const emitted = encoder.setCursor(cursor, in_bounds) catch return error.PresentationCommandTooLarge;
        if (!emitted) return false;
        self.stagePresentationOutput(writer.buffered().len, .cursor, terminal_state, cursor_state);
        return true;
    }

    fn stagePresentationOutput(
        self: *Renderer,
        len: usize,
        commit: PresentationCommit,
        terminal_state: ansi.State,
        cursor_state: ansi.CursorState,
    ) void {
        std.debug.assert(len != 0 and len <= self.presentation_output.len);
        std.debug.assert(self.pending_command == null);
        self.pending_command = .{
            .len = @intCast(len),
            .commit = commit,
            .terminal_state = terminal_state,
            .cursor_state = cursor_state,
        };
    }

    fn commitPresentedCell(self: *Renderer, index_value: usize, next: cell_module.Cell) void {
        const previous = self.presented[index_value];
        if (next.eql(previous)) return;
        if (next.glyph != previous.glyph) self.commitGlyphReferences(next.glyph, previous.glyph, 1);
        if (next.style != previous.style) self.commitStyleReferences(next.style, previous.style, 1);
        self.presented[index_value] = next;
    }

    fn finishPresentation(self: *Renderer) FrameStats {
        const stats = self.presentation_stats;
        self.shadow_valid = true;
        self.frame_pending = false;
        self.presentation_phase = .inactive;
        return stats;
    }

    inline fn requireInactive(self: *const Renderer) !void {
        if (self.presentation_phase != .inactive) return error.PresentationActive;
    }

    inline fn nextSpan(self: *const Renderer, y: u16, from: u16, full_repaint: bool) ?damage_module.Span {
        if (full_repaint) {
            if (from >= self.terminal_size.width) return null;
            return .{ .start = from, .end = self.terminal_size.width };
        }
        return self.damage.nextTileSpan(y, from);
    }

    fn commitGlyphReferences(
        self: *Renderer,
        next: glyph_store.Glyph,
        previous: glyph_store.Glyph,
        count: usize,
    ) void {
        if (count == 0) return;
        if (glyph_store.isComplex(next)) self.glyphs.retainMany(next, count);
        if (glyph_store.isComplex(previous)) self.glyphs.releaseMany(previous, count);
    }

    fn commitStyleReferences(self: *Renderer, next: style_module.Id, previous: style_module.Id, count: usize) void {
        if (count == 0) return;
        if (next != 0) self.styles.retainMany(next, count);
        if (previous != 0) self.styles.releaseMany(previous, count);
    }

    fn setGlyph(
        self: *Renderer,
        x: u16,
        y: u16,
        glyph: glyph_store.Glyph,
        style_id: style_module.Id,
        width: cell_module.Width,
    ) void {
        std.debug.assert(width != .continuation);
        const head = cell_module.Cell{ .glyph = glyph, .style = style_id, .width = width };
        const head_index = self.index(x, y);
        if (self.desired[head_index].eql(head)) {
            if (width == .narrow or self.desired[self.index(x + 1, y)].eql(.{ .style = style_id, .width = .continuation })) return;
        }

        self.detachGlyphAt(x, y);
        if (width == .wide) self.detachGlyphAt(x + 1, y);
        self.assignDesired(x, y, head);
        if (width == .wide) {
            self.assignDesired(x + 1, y, .{ .style = style_id, .width = .continuation });
        }
    }

    fn setAscii(self: *Renderer, x: u16, y: u16, glyph: u8, style_id: style_module.Id) void {
        const index_value = self.index(x, y);
        if (self.desired[index_value].width == .narrow) {
            if (self.replaceDesiredCell(index_value, .{ .glyph = glyph, .style = style_id })) {
                self.damage.markCell(x, y);
            }
            return;
        }
        self.setGlyph(x, y, glyph, style_id, .narrow);
    }

    fn detachGlyphAt(self: *Renderer, x: u16, y: u16) void {
        if (x >= self.terminal_size.width) return;
        switch (self.desired[self.index(x, y)].width) {
            .continuation => {
                std.debug.assert(x > 0);
                self.assignDesired(x - 1, y, .{});
            },
            .wide => self.assignDesired(x + 1, y, .{}),
            .narrow => {},
        }
    }

    fn fillFullRows(self: *Renderer, start_y: u16, end_y: u16, style_id: style_module.Id) void {
        self.fillCellRect(.{
            .x = 0,
            .y = start_y,
            .width = self.terminal_size.width,
            .height = end_y - start_y,
        }, .{ .style = style_id });
    }

    fn fillCellRect(self: *Renderer, rect: geometry.Rect, target: cell_module.Cell) void {
        if (self.last_uniform_fill) |proof| {
            if (rectEql(proof.rect, rect)) {
                if (proof.cell.eql(target)) return;
                self.last_uniform_fill = null;
                self.frame_pending = true;
                const count = @as(usize, rect.width) * rect.height;
                if (target.glyph != proof.cell.glyph) {
                    self.commitGlyphReferences(target.glyph, proof.cell.glyph, count);
                }
                if (target.style != proof.cell.style) {
                    self.commitStyleReferences(target.style, proof.cell.style, count);
                }
                const end_y: u16 = @intCast(rect.bottom());
                if (rect.x == 0 and rect.width == self.terminal_size.width) {
                    const start = self.rowOffset(rect.y);
                    @memset(self.desired[start .. start + count], target);
                } else {
                    const end_x: u16 = @intCast(rect.right());
                    var y = rect.y;
                    while (y < end_y) : (y += 1) {
                        const row_offset = self.rowOffset(y);
                        @memset(self.desired[row_offset + rect.x .. row_offset + end_x], target);
                    }
                }
                self.damage.mark(rect);
                self.last_uniform_fill = .{ .rect = rect, .cell = target };
                return;
            }
        }
        const end_x: u16 = @intCast(rect.right());
        const end_y: u16 = @intCast(rect.bottom());
        var y = rect.y;
        while (y < end_y) : (y += 1) {
            if (rect.x > 0 and self.desired[self.index(rect.x, y)].width == .continuation) {
                self.assignDesired(rect.x - 1, y, .{});
            }
            if (end_x < self.terminal_size.width and self.desired[self.index(end_x, y)].width == .continuation) {
                self.assignDesired(end_x, y, .{});
            }

            const row_offset = self.rowOffset(y);
            if (self.replaceDesiredFill(row_offset + rect.x, rect.width, target)) |changed| {
                self.damage.markSpan(y, rect.x + changed.start, rect.x + changed.end);
            }
        }
        self.last_uniform_fill = .{ .rect = rect, .cell = target };
    }

    fn putAsciiPadded(
        self: *Renderer,
        origin: geometry.Point,
        text: []const u8,
        field_width: u16,
        style_id: style_module.Id,
    ) u16 {
        return self.putAsciiField(.padded, origin, text, field_width, 0, 0, style_id);
    }

    fn putAsciiLine(
        self: *Renderer,
        origin: geometry.Point,
        text: []const u8,
        field_width: u16,
        text_offset: u16,
        marker_width: u2,
        style_id: style_module.Id,
    ) void {
        _ = self.putAsciiField(.line, origin, text, field_width, text_offset, marker_width, style_id);
    }

    fn putAsciiStyledRange(
        self: *Renderer,
        comptime prefix_range: bool,
        origin: geometry.Point,
        spans: []const StyledSpan,
        range_start: StyledPosition,
        range_end: StyledPosition,
        field_width: u16,
        text_offset: u16,
        marker_width: u2,
        base_style: style_module.Style,
    ) !void {
        const count = @min(field_width, self.terminal_size.width - origin.x);
        if (count == 0) return;

        const row_offset = self.rowOffset(origin.y) + origin.x;
        const cells = self.desired[row_offset .. row_offset + count];
        var first_changed: u16 = std.math.maxInt(u16);
        var last_changed: u16 = 0;
        errdefer self.finishAsciiStyledLine(origin, first_changed, last_changed);
        const base_id = try self.styles.intern(base_style);
        defer self.styles.release(base_id);

        var offset: u16 = 0;
        replaceStyledFill(
            self,
            cells,
            0,
            text_offset,
            .{ .style = base_id },
            &first_changed,
            &last_changed,
        );
        offset = text_offset;
        if (!range_start.eql(range_end)) {
            if (prefix_range) {
                std.debug.assert(range_start.span == 0 and range_start.byte == 0);
                for (spans[0..range_end.span]) |span| {
                    try self.replaceAsciiSpanSlice(
                        cells,
                        &offset,
                        span,
                        span.text,
                        &first_changed,
                        &last_changed,
                    );
                }
                const span = spans[range_end.span];
                try self.replaceAsciiSpanSlice(
                    cells,
                    &offset,
                    span,
                    span.text[0..range_end.byte],
                    &first_changed,
                    &last_changed,
                );
            } else {
                var span_index = range_start.span;
                while (span_index < spans.len) : (span_index += 1) {
                    const span = spans[span_index];
                    const byte_start = if (span_index == range_start.span) range_start.byte else 0;
                    const byte_end = if (span_index == range_end.span) range_end.byte else span.text.len;
                    try self.replaceAsciiSpanSlice(
                        cells,
                        &offset,
                        span,
                        span.text[byte_start..byte_end],
                        &first_changed,
                        &last_changed,
                    );
                    if (span_index == range_end.span) break;
                }
            }
        }
        if (marker_width != 0) {
            replaceStyledFill(
                self,
                cells,
                offset,
                offset + 1,
                .{ .glyph = 0x2026, .style = base_id, .width = if (marker_width == 1) .narrow else .wide },
                &first_changed,
                &last_changed,
            );
            offset += 1;
            if (marker_width == 2) {
                replaceStyledFill(
                    self,
                    cells,
                    offset,
                    offset + 1,
                    .{ .style = base_id, .width = .continuation },
                    &first_changed,
                    &last_changed,
                );
                offset += 1;
            }
        }
        std.debug.assert(offset <= count);
        replaceStyledFill(
            self,
            cells,
            offset,
            count,
            .{ .style = base_id },
            &first_changed,
            &last_changed,
        );

        self.finishAsciiStyledLine(origin, first_changed, last_changed);
    }

    inline fn replaceAsciiSpanSlice(
        self: *Renderer,
        cells: []cell_module.Cell,
        offset: *u16,
        span: StyledSpan,
        text: []const u8,
        first_changed: *u16,
        last_changed: *u16,
    ) !void {
        const style_id = try self.styles.intern(span.style);
        defer self.styles.release(style_id);
        replaceStyledAscii(self, cells, offset.*, text, style_id, first_changed, last_changed);
        offset.* += @intCast(text.len);
    }

    fn finishAsciiStyledLine(
        self: *Renderer,
        origin: geometry.Point,
        first_changed: u16,
        last_changed: u16,
    ) void {
        if (first_changed == std.math.maxInt(u16)) return;
        self.damage.markSpan(origin.y, origin.x + first_changed, origin.x + last_changed);
    }

    fn putAsciiField(
        self: *Renderer,
        comptime mode: AsciiFieldMode,
        origin: geometry.Point,
        text: []const u8,
        field_width: u16,
        text_offset: u16,
        marker_width: u2,
        style_id: style_module.Id,
    ) u16 {
        const available = self.terminal_size.width - origin.x;
        const count = @min(field_width, available);
        const text_count: u16 = if (mode == .padded)
            @intCast(@min(text.len, count))
        else
            @intCast(text.len);
        if (count == 0) return 0;
        std.debug.assert(mode == .padded or text_offset + text_count + marker_width <= count);
        const end_x = origin.x + count;
        if (origin.x > 0 and self.desired[self.index(origin.x, origin.y)].width == .continuation) {
            self.assignDesired(origin.x - 1, origin.y, .{});
        }
        if (end_x < self.terminal_size.width and self.desired[self.index(end_x, origin.y)].width == .continuation) {
            self.assignDesired(end_x, origin.y, .{});
        }

        const row_offset = self.rowOffset(origin.y);
        var first_changed: ?u16 = null;
        var last_changed: u16 = 0;
        var offset: u16 = 0;
        if (mode == .line and text_offset != 0) {
            includeChanged(
                &first_changed,
                &last_changed,
                0,
                self.replaceDesiredFill(row_offset + origin.x, text_offset, .{ .style = style_id }),
            );
            offset = text_offset;
        }
        if (text_count != 0) {
            includeChanged(
                &first_changed,
                &last_changed,
                offset,
                self.replaceDesiredAscii(
                    row_offset + origin.x + offset,
                    text[0..text_count],
                    style_id,
                ),
            );
            offset += text_count;
        }
        if (mode == .line and marker_width != 0) {
            if (self.replaceDesiredCell(row_offset + origin.x + offset, .{
                .glyph = 0x2026,
                .style = style_id,
                .width = if (marker_width == 1) .narrow else .wide,
            })) {
                includeChanged(&first_changed, &last_changed, offset, .{ .start = 0, .end = 1 });
            }
            offset += 1;
            if (marker_width == 2) {
                if (self.replaceDesiredCell(row_offset + origin.x + offset, .{
                    .style = style_id,
                    .width = .continuation,
                })) {
                    includeChanged(&first_changed, &last_changed, offset, .{ .start = 0, .end = 1 });
                }
                offset += 1;
            }
        }
        if (offset < count) {
            includeChanged(
                &first_changed,
                &last_changed,
                offset,
                self.replaceDesiredFill(
                    row_offset + origin.x + offset,
                    count - offset,
                    .{ .style = style_id },
                ),
            );
        }
        if (first_changed) |first| {
            self.damage.markSpan(origin.y, origin.x + first, origin.x + last_changed);
        }
        return text_count;
    }

    fn resetDenseGrid(self: *Renderer, cells: []cell_module.Cell, old_count: usize, new_count: usize) void {
        for (cells[0..old_count]) |*cell| {
            if (glyph_store.isComplex(cell.glyph)) self.glyphs.release(cell.glyph);
            if (cell.style != 0) self.styles.release(cell.style);
            cell.* = .{};
        }
        if (new_count > old_count) @memset(cells[old_count..new_count], .{});
    }

    inline fn noteDesiredMutation(self: *Renderer) void {
        self.last_uniform_fill = null;
        self.frame_pending = true;
    }

    inline fn replaceDesiredCell(self: *Renderer, index_value: usize, next: cell_module.Cell) bool {
        const previous = self.desired[index_value];
        if (previous.eql(next)) return false;
        self.noteDesiredMutation();
        // Acquire before release so an intern slot cannot be reused in between.
        if (next.glyph != previous.glyph) {
            if (glyph_store.isComplex(next.glyph)) self.glyphs.retain(next.glyph);
            if (glyph_store.isComplex(previous.glyph)) self.glyphs.release(previous.glyph);
        }
        if (next.style != previous.style) {
            if (next.style != 0) self.styles.retain(next.style);
            if (previous.style != 0) self.styles.release(previous.style);
        }
        self.desired[index_value] = next;
        return true;
    }

    /// Replaces a repeated fill target in one pass. The caller's interned target
    /// style remains pinned until batched cell references are accounted for.
    fn replaceDesiredFill(
        self: *Renderer,
        index_value: usize,
        count: u16,
        next: cell_module.Cell,
    ) ?damage_module.Span {
        if (count == 0) return null;
        var first_changed: ?u16 = null;
        var last_changed: u16 = 0;
        var glyph_retains: usize = 0;
        var style_retains: usize = 0;
        var offset: u16 = 0;
        while (offset < count) : (offset += 1) {
            const previous = self.desired[index_value + offset];
            if (previous.eql(next)) continue;
            if (first_changed == null) {
                first_changed = offset;
                self.noteDesiredMutation();
            }
            last_changed = offset + 1;
            if (next.glyph != previous.glyph) {
                glyph_retains += @intFromBool(glyph_store.isComplex(next.glyph));
                if (glyph_store.isComplex(previous.glyph)) self.glyphs.release(previous.glyph);
            }
            if (next.style != previous.style) {
                style_retains += @intFromBool(next.style != 0);
                if (previous.style != 0) self.styles.release(previous.style);
            }
            self.desired[index_value + offset] = next;
        }
        const first = first_changed orelse return null;
        if (glyph_retains != 0) self.glyphs.retainMany(next.glyph, glyph_retains);
        if (style_retains != 0) self.styles.retainMany(next.style, style_retains);
        return .{ .start = first, .end = last_changed };
    }

    /// Replaces printable ASCII cells with one pinned target style in one pass.
    fn replaceDesiredAscii(
        self: *Renderer,
        index_value: usize,
        bytes: []const u8,
        style_id: style_module.Id,
    ) ?damage_module.Span {
        std.debug.assert(bytes.len <= std.math.maxInt(u16));
        var first_changed: ?u16 = null;
        var last_changed: u16 = 0;
        var style_retains: usize = 0;
        for (bytes, 0..) |byte, byte_index| {
            const offset: u16 = @intCast(byte_index);
            const next = cell_module.Cell{ .glyph = byte, .style = style_id };
            const previous = self.desired[index_value + offset];
            if (previous.eql(next)) continue;
            if (first_changed == null) {
                first_changed = offset;
                self.noteDesiredMutation();
            }
            last_changed = offset + 1;
            if (next.glyph != previous.glyph) {
                if (glyph_store.isComplex(previous.glyph)) self.glyphs.release(previous.glyph);
            }
            if (next.style != previous.style) {
                style_retains += @intFromBool(next.style != 0);
                if (previous.style != 0) self.styles.release(previous.style);
            }
            self.desired[index_value + offset] = next;
        }
        const first = first_changed orelse return null;
        if (style_retains != 0) self.styles.retainMany(style_id, style_retains);
        return .{ .start = first, .end = last_changed };
    }

    /// Clears the other half of any wide glyph cut by a replacement range.
    /// The caller must perform the non-fallible replacement immediately after
    /// this returns so a continuation is never exposed by a public return.
    fn prepareAsciiReplacement(self: *Renderer, index_value: usize, count: u16) void {
        if (count == 0) return;
        const row_width: usize = self.terminal_size.width;
        const x: u16 = @intCast(index_value % row_width);
        const y: u16 = @intCast(index_value / row_width);
        std.debug.assert(@as(usize, x) + count <= row_width);

        if (self.desired[index_value].width == .continuation) {
            std.debug.assert(x > 0);
            self.assignDesired(x - 1, y, .{});
        }

        const end_index = index_value + count;
        const row_end = self.rowOffset(y) + row_width;
        if (end_index < row_end and self.desired[end_index].width == .continuation) {
            self.assignDesired(x + count, y, .{});
        }
    }

    fn assignDesired(self: *Renderer, x: u16, y: u16, next: cell_module.Cell) void {
        const index_value = self.index(x, y);
        if (self.replaceDesiredCell(index_value, next)) self.damage.markCell(x, y);
    }

    fn index(self: *const Renderer, x: u16, y: u16) usize {
        return self.rowOffset(y) + x;
    }

    inline fn rowOffset(self: *const Renderer, y: u16) usize {
        return @as(usize, y) * self.terminal_size.width;
    }
};

inline fn putTextUntil(
    renderer: *Renderer,
    origin: geometry.Point,
    text: []const u8,
    style: style_module.Style,
    width_profile: grapheme.WidthProfile,
    end_x: u16,
) !u16 {
    std.debug.assert(end_x <= renderer.terminal_size.width);
    if (origin.x >= end_x or origin.y >= renderer.terminal_size.height) return 0;
    if (text.len == 1 and text[0] >= 0x20 and text[0] <= 0x7E and style.eql(.{})) {
        renderer.setAscii(origin.x, origin.y, text[0], 0);
        return 1;
    }
    if (printableAscii(text)) {
        const style_id = try renderer.styles.intern(style);
        defer renderer.styles.release(style_id);
        if (text.len >= 4) {
            return renderer.putAsciiPadded(
                origin,
                text,
                @intCast(@min(text.len, end_x - origin.x)),
                style_id,
            );
        }
        var x = origin.x;
        for (text) |byte| {
            if (x >= end_x) break;
            renderer.setAscii(x, origin.y, byte, style_id);
            x += 1;
        }
        return x - origin.x;
    }
    if (singleBrailleGlyph(text)) |glyph| {
        const style_id = try renderer.styles.intern(style);
        defer renderer.styles.release(style_id);
        renderer.setGlyph(origin.x, origin.y, glyph, style_id, .narrow);
        return 1;
    }

    return putUnicodeText(renderer, origin, text, style, width_profile, end_x);
}

fn putUnicodeText(
    renderer: *Renderer,
    origin: geometry.Point,
    text: []const u8,
    style: style_module.Style,
    width_profile: grapheme.WidthProfile,
    end_x: u16,
) !u16 {
    const style_id = try renderer.styles.intern(style);
    defer renderer.styles.release(style_id);

    var iterator = try grapheme.Iterator.init(text);
    var x = origin.x;
    while (iterator.next()) |cluster| {
        const cluster_width = try cluster.displayWidthAssumeValid(width_profile);
        if (cluster_width == 0) return error.ZeroWidthGrapheme;
        if (x >= end_x) break;

        if (cluster_width == 2 and x + 1 >= end_x) {
            renderer.setGlyph(x, origin.y, ' ', style_id, .narrow);
            x += 1;
            break;
        }

        const glyph = try renderer.glyphs.intern(cluster.bytes);
        defer renderer.glyphs.release(glyph);
        renderer.setGlyph(
            x,
            origin.y,
            glyph,
            style_id,
            if (cluster_width == 1) .narrow else .wide,
        );
        x += cluster_width;
    }
    return x - origin.x;
}

inline fn putTextPaddedUntil(
    renderer: *Renderer,
    origin: geometry.Point,
    text: []const u8,
    field_width: u16,
    style: style_module.Style,
    width_profile: grapheme.WidthProfile,
    end_x: u16,
) !u16 {
    std.debug.assert(end_x <= renderer.terminal_size.width);
    if (origin.x >= end_x or origin.y >= renderer.terminal_size.height) return 0;
    const available = @min(field_width, end_x - origin.x);
    if (printableAscii(text)) {
        const style_id = try renderer.styles.intern(style);
        defer renderer.styles.release(style_id);
        return renderer.putAsciiPadded(origin, text, available, style_id);
    }

    return putUnicodeTextPadded(renderer, origin, text, available, style, width_profile, end_x);
}

fn putUnicodeTextPadded(
    renderer: *Renderer,
    origin: geometry.Point,
    text: []const u8,
    field_width: u16,
    style: style_module.Style,
    width_profile: grapheme.WidthProfile,
    end_x: u16,
) !u16 {
    const available = @min(field_width, end_x - origin.x);
    var iterator = try grapheme.Iterator.init(text);
    var used: u16 = 0;
    var byte_end: usize = 0;
    var accepting = true;
    while (iterator.next()) |cluster| {
        if (cluster.bytes.len > grapheme.max_cluster_bytes) return error.GraphemeTooLong;
        const width = try cluster.displayWidthAssumeValid(width_profile);
        if (width == 0) return error.ZeroWidthGrapheme;
        if (!accepting) continue;
        if (width > available - used) {
            accepting = false;
            continue;
        }
        used += width;
        byte_end = @intFromPtr(cluster.bytes.ptr) - @intFromPtr(text.ptr) + cluster.bytes.len;
    }
    try fillRenderer(renderer, .{ .x = origin.x, .y = origin.y, .width = available, .height = 1 }, style);
    _ = try putTextUntil(renderer, origin, text[0..byte_end], style, width_profile, end_x);
    return used;
}

fn fillRenderer(renderer: *Renderer, rect: geometry.Rect, style: style_module.Style) !void {
    try renderer.requireInactive();
    const clipped = rect.intersection(geometry.Rect.fromSize(renderer.terminal_size));
    if (clipped.isEmpty()) return;
    const style_id = try renderer.styles.intern(style);
    defer renderer.styles.release(style_id);

    const end_x: u16 = @intCast(clipped.right());
    const end_y: u16 = @intCast(clipped.bottom());
    if (clipped.x == 0 and end_x == renderer.terminal_size.width) {
        renderer.fillFullRows(clipped.y, end_y, style_id);
        return;
    }
    renderer.fillCellRect(clipped, .{ .style = style_id });
}

fn fillAsciiRenderer(renderer: *Renderer, rect: geometry.Rect, glyph: u8, style: style_module.Style) !void {
    try renderer.requireInactive();
    if (glyph < 0x20 or glyph > 0x7E) return error.InvalidAsciiGlyph;
    const clipped = rect.intersection(geometry.Rect.fromSize(renderer.terminal_size));
    if (clipped.isEmpty()) return;
    const style_id = try renderer.styles.intern(style);
    defer renderer.styles.release(style_id);
    renderer.fillCellRect(clipped, .{ .glyph = glyph, .style = style_id });
}

pub const Surface = struct {
    renderer: *Renderer,
    origin: geometry.Point,
    extent: geometry.Size,
    clip: geometry.Rect,

    fn init(
        renderer: *Renderer,
        origin_x: u32,
        origin_y: u32,
        extent: geometry.Size,
        parent_clip: geometry.Rect,
    ) Surface {
        return .{
            .renderer = renderer,
            .origin = .{
                .x = @intCast(@min(origin_x, std.math.maxInt(u16))),
                .y = @intCast(@min(origin_y, std.math.maxInt(u16))),
            },
            .extent = extent,
            .clip = clipTranslated(origin_x, origin_y, extent, parent_clip),
        };
    }

    pub inline fn size(self: *const Surface) geometry.Size {
        return self.extent;
    }

    pub inline fn surface(self: *const Surface, rect: geometry.Rect) Surface {
        return Surface.init(
            self.renderer,
            @as(u32, self.origin.x) + rect.x,
            @as(u32, self.origin.y) + rect.y,
            .{ .width = rect.width, .height = rect.height },
            self.clip,
        );
    }

    pub fn putText(
        self: *Surface,
        origin: geometry.Point,
        text: []const u8,
        style: style_module.Style,
        width_profile: grapheme.WidthProfile,
    ) !u16 {
        try self.renderer.requireInactive();
        const placement = self.place(origin) orelse return 0;
        return putTextUntil(self.renderer, placement.point, text, style, width_profile, placement.end_x);
    }

    pub fn putBrailleMasks(self: *Surface, masks: []const u8, style: style_module.Style) !void {
        try self.renderer.requireInactive();
        const required = @as(usize, self.extent.width) * self.extent.height;
        if (masks.len < required) return error.BufferTooSmall;
        if (self.clip.isEmpty()) return;

        const start_x: u16 = @intCast(self.clip.x - self.origin.x);
        const start_y: u16 = @intCast(self.clip.y - self.origin.y);
        const end_x: u16 = @intCast(@min(self.clip.right(), @as(u32, self.origin.x) + self.extent.width) - self.origin.x);
        const end_y: u16 = @intCast(@min(self.clip.bottom(), @as(u32, self.origin.y) + self.extent.height) - self.origin.y);
        const style_id = try self.renderer.styles.intern(style);
        defer self.renderer.styles.release(style_id);

        var y = start_y;
        while (y < end_y) : (y += 1) {
            var x = start_x;
            while (x < end_x) : (x += 1) {
                const mask = masks[@as(usize, y) * self.extent.width + x];
                const glyph = @as(glyph_store.Glyph, 0x2800) + mask;
                self.renderer.setGlyph(self.origin.x + x, self.origin.y + y, glyph, style_id, .narrow);
            }
        }
    }

    /// Paints fully explicit Kitty Unicode placeholder cells for an existing
    /// virtual placement. Clipping advances source coordinates rather than
    /// changing which image fragment each visible cell identifies. As with
    /// other drawing operations, intern-capacity failure can leave a partial
    /// desired update; overwrite the region before retrying.
    pub fn putKittyImage(
        self: *Surface,
        rect: geometry.Rect,
        options: kitty_placeholder.Options,
    ) !void {
        try self.renderer.requireInactive();
        if (options.image_id == 0) return error.InvalidImageId;
        if (options.placement_id > 0x00ff_ffff) return error.InvalidPlacementId;
        const source_right = @as(u32, options.source_column) + rect.width;
        const source_bottom = @as(u32, options.source_row) + rect.height;
        if (source_right > kitty_placeholder.coordinate_count or
            source_bottom > kitty_placeholder.coordinate_count)
        {
            return error.PlaceholderCoordinateOverflow;
        }
        if (rect.width == 0 or rect.height == 0 or self.clip.isEmpty()) return;

        const absolute = geometry.Rect{
            .x = @intCast(@min(@as(u32, self.origin.x) + rect.x, std.math.maxInt(u16))),
            .y = @intCast(@min(@as(u32, self.origin.y) + rect.y, std.math.maxInt(u16))),
            .width = rect.width,
            .height = rect.height,
        };
        const visible = absolute.intersection(self.clip).intersection(geometry.Rect.fromSize(self.renderer.terminal_size));
        if (visible.isEmpty()) return;

        var style = options.style;
        style.foreground = kitty_placeholder.imageColor(options.image_id);
        style.underline_color = kitty_placeholder.placementColor(options.placement_id);
        const style_id = try self.renderer.styles.intern(style);
        defer self.renderer.styles.release(style_id);

        const x_skip: u16 = visible.x - absolute.x;
        const y_skip: u16 = visible.y - absolute.y;
        const end_x: u16 = @intCast(visible.right());
        const end_y: u16 = @intCast(visible.bottom());
        var y = visible.y;
        while (y < end_y) : (y += 1) {
            var x = visible.x;
            while (x < end_x) : (x += 1) {
                var encoded: [16]u8 = undefined;
                const glyph_bytes = try kitty_placeholder.encodeCell(
                    &encoded,
                    @intCast(@as(u16, options.source_row) + y_skip + (y - visible.y)),
                    @intCast(@as(u16, options.source_column) + x_skip + (x - visible.x)),
                    options.image_id,
                );
                const glyph = try self.renderer.glyphs.intern(glyph_bytes);
                defer self.renderer.glyphs.release(glyph);
                self.renderer.setGlyph(x, y, glyph, style_id, .narrow);
            }
        }
    }

    pub fn putTextPadded(
        self: *Surface,
        origin: geometry.Point,
        text: []const u8,
        field_width: u16,
        style: style_module.Style,
        width_profile: grapheme.WidthProfile,
    ) !u16 {
        try self.renderer.requireInactive();
        const placement = self.place(origin) orelse return 0;
        return putTextPaddedUntil(
            self.renderer,
            placement.point,
            text,
            field_width,
            style,
            width_profile,
            placement.end_x,
        );
    }

    pub fn putTextLine(
        self: *Surface,
        origin: geometry.Point,
        text: []const u8,
        field_width: u16,
        style: style_module.Style,
        width_profile: grapheme.WidthProfile,
        options: line_layout.Options,
    ) !u16 {
        try self.renderer.requireInactive();
        const placement = self.place(origin) orelse return 0;
        const available = @min(
            field_width,
            @min(self.extent.width - origin.x, placement.end_x - placement.point.x),
        );
        if (available == 0) return 0;
        const ascii_fits = text.len <= available and printableAscii(text);
        const line: line_layout.Layout = if (ascii_fits) line: {
            const width: u16 = @intCast(text.len);
            const remaining = available - width;
            break :line .{
                .prefix = text,
                .offset = switch (options.alignment) {
                    .left => 0,
                    .center => remaining / 2,
                    .right => remaining,
                },
                .width = width,
                .ellipsis = false,
            };
        } else try line_layout.layout(text, available, width_profile, options);
        if (ascii_fits or printableAscii(line.prefix)) {
            const style_id = try self.renderer.styles.intern(style);
            defer self.renderer.styles.release(style_id);
            self.renderer.putAsciiLine(
                placement.point,
                line.prefix,
                available,
                line.offset,
                if (line.ellipsis) @intCast(line_layout.ellipsisWidth(width_profile)) else 0,
                style_id,
            );
            return line.width;
        }

        try self.fill(.{ .x = origin.x, .y = origin.y, .width = available, .height = 1 }, style);

        const x = placement.point.x + line.offset;
        _ = try putTextUntil(
            self.renderer,
            .{ .x = x, .y = placement.point.y },
            line.prefix,
            style,
            width_profile,
            placement.end_x,
        );
        if (line.ellipsis) {
            const marker_width = line_layout.ellipsisWidth(width_profile);
            _ = try putTextUntil(
                self.renderer,
                .{ .x = x + line.width - marker_width, .y = placement.point.y },
                line_layout.ellipsis,
                style,
                width_profile,
                placement.end_x,
            );
        }
        return line.width;
    }

    pub fn putStyledLine(
        self: *Surface,
        origin: geometry.Point,
        spans: []const StyledSpan,
        field_width: u16,
        base_style: style_module.Style,
        width_profile: grapheme.WidthProfile,
        options: line_layout.Options,
    ) !u16 {
        try self.renderer.requireInactive();
        const placement = self.place(origin) orelse return 0;
        const available = @min(
            field_width,
            @min(self.extent.width - origin.x, placement.end_x - placement.point.x),
        );
        if (available == 0) return 0;

        var total_width: usize = 0;
        var all_ascii = true;
        for (spans) |span| {
            const span_ascii = printableAscii(span.text);
            total_width = std.math.add(
                usize,
                total_width,
                if (span_ascii) span.text.len else try line_layout.measure(span.text, width_profile),
            ) catch return error.WidthOverflow;
            all_ascii = all_ascii and span_ascii;
        }

        const truncated = total_width > available;
        const marker_width = line_layout.ellipsisWidth(width_profile);
        const append_ellipsis = truncated and options.overflow == .ellipsis and marker_width <= available;
        const content_limit = if (append_ellipsis) available - marker_width else available;
        var prefix_width: u16 = 0;
        var full_spans: usize = 0;
        var partial_span: ?usize = null;
        var partial_end: usize = 0;

        if (!truncated) {
            prefix_width = @intCast(total_width);
            full_spans = spans.len;
        } else {
            var remaining = content_limit;
            for (spans, 0..) |span, index| {
                const part_width: u16, const part_end: usize = if (all_ascii) part: {
                    const width: u16 = @intCast(@min(span.text.len, remaining));
                    break :part .{ width, width };
                } else part: {
                    const layout = try line_layout.layout(span.text, remaining, width_profile, .{});
                    break :part .{ layout.width, layout.prefix.len };
                };
                prefix_width += part_width;
                remaining -= part_width;
                if (part_end != span.text.len) {
                    partial_span = index;
                    partial_end = part_end;
                    break;
                }
                full_spans = index + 1;
                if (remaining == 0) break;
            }
        }

        const rendered_width = prefix_width + if (append_ellipsis) marker_width else 0;
        const offset = switch (options.alignment) {
            .left => 0,
            .center => (available - rendered_width) / 2,
            .right => available - rendered_width,
        };
        if (all_ascii) {
            const range_end: StyledPosition = if (partial_span) |span_index|
                .{ .span = span_index, .byte = partial_end }
            else if (full_spans != 0)
                .{ .span = full_spans - 1, .byte = spans[full_spans - 1].text.len }
            else
                .{};
            try self.renderer.putAsciiStyledRange(
                true,
                placement.point,
                spans,
                .{},
                range_end,
                available,
                offset,
                if (append_ellipsis) @intCast(marker_width) else 0,
                base_style,
            );
            return rendered_width;
        }
        try self.fill(.{ .x = origin.x, .y = origin.y, .width = available, .height = 1 }, base_style);

        var x = placement.point.x + offset;
        for (spans[0..full_spans]) |span| {
            x += try putTextUntil(
                self.renderer,
                .{ .x = x, .y = placement.point.y },
                span.text,
                span.style,
                width_profile,
                placement.end_x,
            );
        }
        if (partial_span) |index| {
            const span = spans[index];
            x += try putTextUntil(
                self.renderer,
                .{ .x = x, .y = placement.point.y },
                span.text[0..partial_end],
                span.style,
                width_profile,
                placement.end_x,
            );
        }
        if (append_ellipsis) {
            _ = try putTextUntil(
                self.renderer,
                .{ .x = x, .y = placement.point.y },
                line_layout.ellipsis,
                base_style,
                width_profile,
                placement.end_x,
            );
        }
        return rendered_width;
    }

    pub fn putWrappedText(
        self: *Surface,
        rect: geometry.Rect,
        text: []const u8,
        style: style_module.Style,
        width_profile: grapheme.WidthProfile,
        alignment: line_layout.Alignment,
    ) !u16 {
        try self.renderer.requireInactive();
        if (rect.width == 0 or rect.height == 0) return 0;
        var paragraph = self.surface(rect);
        if (paragraph.clip.isEmpty()) return 0;

        const visible_lines = @min(rect.height, paragraph.clip.height);
        var y: u16 = 0;
        var lines = try text_wrap.Iterator.init(text, rect.width, width_profile);
        const direct_ascii = lines.asciiOnly() and paragraph.clip.width == rect.width;
        const style_id = if (direct_ascii) try self.renderer.styles.intern(style) else 0;
        defer if (direct_ascii) self.renderer.styles.release(style_id);
        while (y < visible_lines) : (y += 1) {
            const line = try lines.next() orelse break;
            try paragraph.putMeasuredWrappedLine(
                y,
                line.bytes,
                line.width,
                rect.width,
                style,
                width_profile,
                alignment,
                direct_ascii,
                style_id,
            );
        }
        if (y < visible_lines) {
            try paragraph.fill(.{
                .x = 0,
                .y = y,
                .width = rect.width,
                .height = visible_lines - y,
            }, style);
        }
        return y;
    }

    pub fn putWrappedStyledText(
        self: *Surface,
        rect: geometry.Rect,
        spans: []const StyledSpan,
        base_style: style_module.Style,
        width_profile: grapheme.WidthProfile,
        alignment: line_layout.Alignment,
    ) !u16 {
        try self.renderer.requireInactive();
        if (rect.width == 0 or rect.height == 0) return 0;
        var paragraph = self.surface(rect);
        if (paragraph.clip.isEmpty()) return 0;

        var lines = try text_wrap.SpanIterator(StyledSpan).init(spans, rect.width, width_profile);
        const visible_lines = @min(rect.height, paragraph.clip.height);
        const direct_ascii = lines.asciiOnly() and paragraph.clip.width == rect.width;
        var y: u16 = 0;
        while (y < visible_lines) : (y += 1) {
            const line = try lines.next() orelse break;
            const offset = switch (alignment) {
                .left => 0,
                .center => (rect.width - line.width) / 2,
                .right => rect.width - line.width,
            };
            if (direct_ascii) {
                const placement = paragraph.place(.{ .x = 0, .y = y }).?;
                try self.renderer.putAsciiStyledRange(
                    false,
                    placement.point,
                    spans,
                    line.start,
                    line.end,
                    rect.width,
                    offset,
                    0,
                    base_style,
                );
            } else {
                try paragraph.fill(.{ .x = 0, .y = y, .width = rect.width, .height = 1 }, base_style);
                try paragraph.putStyledRange(
                    y,
                    offset,
                    spans,
                    line.start,
                    line.end,
                    width_profile,
                );
            }
        }
        if (y < visible_lines) {
            try paragraph.fill(.{
                .x = 0,
                .y = y,
                .width = rect.width,
                .height = visible_lines - y,
            }, base_style);
        }
        return y;
    }

    fn putStyledRange(
        self: *Surface,
        y: u16,
        x_offset: u16,
        spans: []const StyledSpan,
        start: StyledPosition,
        end: StyledPosition,
        width_profile: grapheme.WidthProfile,
    ) !void {
        if (start.eql(end)) return;
        const placement = self.place(.{ .x = x_offset, .y = y }) orelse return;
        var x = placement.point.x;
        var span_index = start.span;
        while (span_index < spans.len) : (span_index += 1) {
            const span = spans[span_index];
            const byte_start = if (span_index == start.span) start.byte else 0;
            const byte_end = if (span_index == end.span) end.byte else span.text.len;
            if (byte_start < byte_end) {
                x += try putTextUntil(
                    self.renderer,
                    .{ .x = x, .y = placement.point.y },
                    span.text[byte_start..byte_end],
                    span.style,
                    width_profile,
                    placement.end_x,
                );
            }
            if (span_index == end.span) break;
        }
    }

    inline fn putMeasuredWrappedLine(
        self: *Surface,
        y: u16,
        text: []const u8,
        text_width: u16,
        field_width: u16,
        style: style_module.Style,
        width_profile: grapheme.WidthProfile,
        alignment: line_layout.Alignment,
        direct_ascii: bool,
        style_id: style_module.Id,
    ) !void {
        if (direct_ascii) {
            const offset = switch (alignment) {
                .left => 0,
                .center => (field_width - text_width) / 2,
                .right => field_width - text_width,
            };
            const placement = self.place(.{ .x = 0, .y = y }).?;
            self.renderer.putAsciiLine(placement.point, text, field_width, offset, 0, style_id);
            return;
        }
        _ = try self.putTextLine(
            .{ .x = 0, .y = y },
            text,
            field_width,
            style,
            width_profile,
            .{ .alignment = alignment },
        );
    }

    pub fn fill(self: *Surface, rect: geometry.Rect, style: style_module.Style) !void {
        try self.renderer.requireInactive();
        const local = rect.intersection(geometry.Rect.fromSize(self.extent));
        if (local.isEmpty()) return;
        const clipped = clipTranslated(
            @as(u32, self.origin.x) + local.x,
            @as(u32, self.origin.y) + local.y,
            .{ .width = local.width, .height = local.height },
            self.clip,
        );
        if (clipped.isEmpty()) return;
        try fillRenderer(self.renderer, clipped, style);
    }

    pub fn fillAscii(self: *Surface, rect: geometry.Rect, glyph: u8, style: style_module.Style) !void {
        try self.renderer.requireInactive();
        if (glyph < 0x20 or glyph > 0x7E) return error.InvalidAsciiGlyph;
        const local = rect.intersection(geometry.Rect.fromSize(self.extent));
        if (local.isEmpty()) return;
        const clipped = clipTranslated(
            @as(u32, self.origin.x) + local.x,
            @as(u32, self.origin.y) + local.y,
            .{ .width = local.width, .height = local.height },
            self.clip,
        );
        if (clipped.isEmpty()) return;
        try fillAsciiRenderer(self.renderer, clipped, glyph, style);
    }

    pub fn fillAsciiBatch(self: *Surface, fills: []const AsciiFill, style: style_module.Style) !void {
        try self.renderer.requireInactive();
        for (fills) |entry| {
            if (entry.glyph < 0x20 or entry.glyph > 0x7E) return error.InvalidAsciiGlyph;
        }

        var style_id: ?style_module.Id = null;
        defer if (style_id) |id| self.renderer.styles.release(id);
        for (fills) |entry| {
            const local = entry.rect.intersection(geometry.Rect.fromSize(self.extent));
            if (local.isEmpty()) continue;
            const clipped = clipTranslated(
                @as(u32, self.origin.x) + local.x,
                @as(u32, self.origin.y) + local.y,
                .{ .width = local.width, .height = local.height },
                self.clip,
            );
            if (clipped.isEmpty()) continue;
            const id = style_id orelse id: {
                const interned = try self.renderer.styles.intern(style);
                style_id = interned;
                break :id interned;
            };
            self.renderer.fillCellRect(clipped, .{ .glyph = entry.glyph, .style = id });
        }
    }

    const Placement = struct {
        point: geometry.Point,
        end_x: u16,
    };

    inline fn place(self: *const Surface, point: geometry.Point) ?Placement {
        if (point.x >= self.extent.width or point.y >= self.extent.height or self.clip.isEmpty()) return null;
        const x = @as(u32, self.origin.x) + point.x;
        const y = @as(u32, self.origin.y) + point.y;
        if (x < self.clip.x or x >= self.clip.right() or y < self.clip.y or y >= self.clip.bottom()) return null;
        return .{
            .point = .{ .x = @intCast(x), .y = @intCast(y) },
            .end_x = @intCast(self.clip.right()),
        };
    }
};

fn clipTranslated(
    origin_x: u32,
    origin_y: u32,
    extent: geometry.Size,
    parent_clip: geometry.Rect,
) geometry.Rect {
    if (parent_clip.isEmpty()) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    const right = @min(origin_x + extent.width, parent_clip.right());
    const bottom = @min(origin_y + extent.height, parent_clip.bottom());
    const x = @max(origin_x, parent_clip.x);
    const y = @max(origin_y, parent_clip.y);
    if (x >= right or y >= bottom) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    return .{
        .x = @intCast(x),
        .y = @intCast(y),
        .width = @intCast(right - x),
        .height = @intCast(bottom - y),
    };
}

fn printableAscii(text: []const u8) bool {
    for (text) |byte| {
        if (byte < 0x20 or byte > 0x7E) return false;
    }
    return true;
}

inline fn singleBrailleGlyph(text: []const u8) ?glyph_store.Glyph {
    if (text.len != 3 or text[0] != 0xe2 or text[1] < 0xa0 or text[1] > 0xa3 or
        text[2] < 0x80 or text[2] > 0xbf) return null;
    return 0x2800 + (@as(glyph_store.Glyph, text[1] - 0xa0) << 6) + (text[2] - 0x80);
}

fn replaceStyledFill(
    renderer: *Renderer,
    cells: []cell_module.Cell,
    start: u16,
    end: u16,
    target: cell_module.Cell,
    first_changed: *u16,
    last_changed: *u16,
) void {
    if (start == end) return;
    const base = (@intFromPtr(cells.ptr) - @intFromPtr(renderer.desired.ptr)) / @sizeOf(cell_module.Cell);
    renderer.prepareAsciiReplacement(base + start, end - start);
    if (renderer.replaceDesiredFill(base + start, end - start, target)) |changed| {
        if (first_changed.* == std.math.maxInt(u16)) first_changed.* = start + changed.start;
        last_changed.* = @max(last_changed.*, start + changed.end);
    }
}

fn replaceStyledAscii(
    renderer: *Renderer,
    cells: []cell_module.Cell,
    start: u16,
    text: []const u8,
    style_id: style_module.Id,
    first_changed: *u16,
    last_changed: *u16,
) void {
    if (text.len == 0) return;
    const base = (@intFromPtr(cells.ptr) - @intFromPtr(renderer.desired.ptr)) / @sizeOf(cell_module.Cell);
    renderer.prepareAsciiReplacement(base + start, @intCast(text.len));
    if (renderer.replaceDesiredAscii(base + start, text, style_id)) |changed| {
        if (first_changed.* == std.math.maxInt(u16)) first_changed.* = start + changed.start;
        last_changed.* = @max(last_changed.*, start + changed.end);
    }
}

inline fn includeChanged(
    first_changed: *?u16,
    last_changed: *u16,
    offset: u16,
    changed: ?damage_module.Span,
) void {
    const span = changed orelse return;
    const start = offset + span.start;
    const end = offset + span.end;
    if (first_changed.* == null or start < first_changed.*.?) first_changed.* = start;
    last_changed.* = @max(last_changed.*, end);
}

fn rectEql(lhs: geometry.Rect, rhs: geometry.Rect) bool {
    return lhs.x == rhs.x and lhs.y == rhs.y and lhs.width == rhs.width and lhs.height == rhs.height;
}
