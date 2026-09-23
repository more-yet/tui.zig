//! Single-line view over the shared editor engine.

const std = @import("std");
const editor = @import("../editor.zig");
const input = @import("../input.zig");
const render = @import("../render.zig");
const theme = @import("../theme.zig");
const TextArea = @import("text_area.zig").TextArea;
const Update = @import("update.zig").Update;

pub const TextInput = struct {
    pub const DisplayMode = enum {
        plain,
        masked,
    };

    model: *editor.Model,
    /// Masking changes presentation only; the caller-owned model still contains plaintext.
    display_mode: DisplayMode = .plain,
    role: theme.Role = .{},
    selection_role: theme.Role = .{ .normal = .{ .attributes = .{ .reverse = true } } },
    /// Disabled widget operations cancel staged paste. If no operation observes
    /// a disable/re-enable transition, call `model.cancelPaste()` explicitly.
    enabled: bool = true,
    focused: bool = false,
    pending_failure: ?editor.EditError = null,
    /// Implementation-managed masked viewport origin, measured in graphemes.
    masked_left_grapheme: usize = 0,

    pub fn init(model: *editor.Model) TextInput {
        std.debug.assert(!model.multiline);
        return .{ .model = model };
    }

    pub fn handle(self: *TextInput, event: input.Event) Update {
        if (!self.enabled) {
            self.model.cancelPaste();
            return .ignored;
        }
        if (event == .key and event.key.action != .release and event.key.code == .enter) return .handled;
        return self.mapResult(self.model.handle(event));
    }

    pub fn applyAction(self: *TextInput, action: editor.Action) Update {
        if (!self.enabled) {
            self.model.cancelPaste();
            return .ignored;
        }
        return self.mapResult(self.model.applyAction(action));
    }

    pub fn takeFailure(self: *TextInput) ?editor.EditError {
        const failure = self.pending_failure;
        self.pending_failure = null;
        return failure;
    }

    pub fn draw(self: *TextInput, surface: *render.Surface) !void {
        if (!self.enabled) self.model.cancelPaste();
        std.debug.assert(surface.size().height <= 1);
        std.debug.assert(!self.model.multiline);
        switch (self.display_mode) {
            .plain => {
                _ = self.model.setViewportSize(surface.size().width, surface.size().height);
                var area = TextArea{
                    .model = self.model,
                    .role = self.role,
                    .selection_role = self.selection_role,
                    .enabled = self.enabled,
                    .focused = self.focused,
                };
                try area.draw(surface);
            },
            .masked => try self.drawMasked(surface),
        }
    }

    /// Draws one fixed-width mask per indexed grapheme without reading plaintext bytes.
    fn drawMasked(self: *TextInput, surface: *render.Surface) !void {
        const size = surface.size();
        if (size.width == 0 or size.height == 0) return;

        const width: usize = size.width;
        const grapheme_count = self.model.boundary_count - 1;
        const cursor = self.model.cursor_boundary;
        var left = @min(self.masked_left_grapheme, grapheme_count -| width);
        if (cursor < left) left = cursor;
        if (cursor < grapheme_count) {
            if (cursor - left >= width) left = cursor - (width - 1);
        } else if (cursor - left > width) {
            left = cursor - width;
        }
        self.masked_left_grapheme = left;

        const state = theme.State.from(self.enabled, self.focused);
        const base_style = self.role.resolve(state);
        const selected_style = self.selection_role.resolve(state);
        const selected_range = self.model.selection();
        try surface.fill(.{ .x = 0, .y = 0, .width = size.width, .height = 1 }, base_style);

        const visible_count = @min(grapheme_count - left, width);
        for (0..visible_count) |relative| {
            const index = left + relative;
            const style = if (isSelectedBoundary(self.model, selected_range, index)) selected_style else base_style;
            try surface.fillAscii(.{
                .x = @intCast(relative),
                .y = 0,
                .width = 1,
                .height = 1,
            }, '*', style);
        }

        if (!self.enabled or !self.focused) return;
        const cursor_column = cursor - left;
        var caret_x: usize = undefined;
        var caret_glyph: u8 = ' ';
        var caret_style = base_style;
        if (cursor < grapheme_count) {
            if (cursor_column >= width) return;
            caret_x = cursor_column;
            caret_glyph = '*';
            if (isSelectedBoundary(self.model, selected_range, cursor)) caret_style = selected_style;
        } else if (cursor_column < width) {
            caret_x = cursor_column;
        } else {
            if (width == 0 or grapheme_count == 0) return;
            caret_x = width - 1;
            caret_glyph = '*';
            if (isSelectedBoundary(self.model, selected_range, grapheme_count - 1)) caret_style = selected_style;
        }
        caret_style.attributes.reverse = !caret_style.attributes.reverse;
        try surface.fillAscii(.{
            .x = @intCast(caret_x),
            .y = 0,
            .width = 1,
            .height = 1,
        }, caret_glyph, caret_style);
    }

    fn isSelectedBoundary(model: *const editor.Model, selected_range: ?editor.Selection, index: usize) bool {
        const selected = selected_range orelse return false;
        const offset = model.boundaries[index].offset;
        return offset >= selected.start and offset < selected.end;
    }

    fn mapResult(self: *TextInput, result: editor.EventResult) Update {
        if (result.failure) |failure| if (self.pending_failure == null) {
            self.pending_failure = failure;
        };
        return switch (result.status) {
            .ignored => .ignored,
            .handled => .handled,
            .redraw => .redraw,
        };
    }
};
