//! Multiline presentation and input handling for a caller-owned editor model.

const std = @import("std");
const editor = @import("../editor.zig");
const input = @import("../input.zig");
const render = @import("../render.zig");
const theme = @import("../theme.zig");
const Update = @import("update.zig").Update;

pub const TextArea = struct {
    model: *editor.Model,
    role: theme.Role = .{},
    selection_role: theme.Role = .{
        .normal = .{ .attributes = .{ .reverse = true } },
    },
    /// Disabled widget operations cancel staged paste. If no operation observes
    /// a disable/re-enable transition, call `model.cancelPaste()` explicitly.
    enabled: bool = true,
    focused: bool = false,
    pending_failure: ?editor.EditError = null,

    pub fn handle(self: *TextArea, event: input.Event) Update {
        if (!self.enabled) {
            self.model.cancelPaste();
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

    pub fn layout(self: *TextArea, size: render.Size) bool {
        if (!self.enabled) self.model.cancelPaste();
        return self.model.setViewportSize(size.width, size.height);
    }

    pub fn draw(self: *const TextArea, surface: *render.Surface) !void {
        if (!self.enabled) self.model.cancelPaste();
        const size = surface.size();
        std.debug.assert(self.model.viewport.width == size.width);
        std.debug.assert(self.model.viewport.height == size.height);
        if (size.width == 0 or size.height == 0) return;

        const state = theme.State.from(self.enabled, self.focused);
        const base_style = self.role.resolve(state);
        const selected_style = self.selection_role.resolve(state);
        const selection = self.model.selection();
        const caret = if (self.enabled and self.focused)
            self.model.visibleCaretWindow(self.model.viewport.left_column, size.width)
        else
            null;
        const visible = self.model.visibleRows();
        var row_index = visible.start;

        var y: u16 = 0;
        while (row_index < visible.end) : ({
            row_index += 1;
            y += 1;
        }) {
            const window = self.model.visibleRowWindow(
                row_index,
                self.model.viewport.left_column,
                size.width,
            ) orelse break;
            try self.drawLine(
                surface,
                y,
                window,
                selection,
                base_style,
                selected_style,
            );
            if (caret) |visible_caret| if (row_index == visible_caret.row) {
                try self.drawCaret(
                    surface,
                    y,
                    visible_caret,
                    selection,
                    base_style,
                    selected_style,
                );
            };
        }
        if (y < surface.size().height) {
            try surface.fill(.{ .x = 0, .y = y, .width = surface.size().width, .height = surface.size().height - y }, base_style);
        }
    }

    fn drawLine(
        self: *const TextArea,
        surface: *render.Surface,
        y: u16,
        window: editor.RowWindow,
        selection: ?editor.Selection,
        base_style: render.Style,
        selected_style: render.Style,
    ) !void {
        const byte_start: usize = window.byte_start;
        const byte_end: usize = window.byte_end;
        const bytes = self.model.value()[byte_start..byte_end];
        const selected_bytes = if (selection) |selected|
            selected.start < byte_end and selected.end > byte_start
        else
            false;
        const selected_newline = if (selection) |selected|
            window.newline_column != null and selected.start <= byte_end and selected.end > byte_end
        else
            false;
        if (window.screen_column != 0) {
            try surface.fill(.{ .x = 0, .y = y, .width = window.screen_column, .height = 1 }, base_style);
        }
        const field_width = surface.size().width - window.screen_column;
        if (!selected_bytes and !selected_newline) {
            _ = try surface.putTextPadded(
                .{ .x = window.screen_column, .y = y },
                bytes,
                field_width,
                base_style,
                self.model.width_profile,
            );
            return;
        }

        const selected = selection orelse editor.Selection{ .start = byte_end, .end = byte_end };
        const selected_start = @min(@max(selected.start, byte_start), byte_end);
        const selected_end = @min(@max(selected.end, byte_start), byte_end);
        const spans = [_]render.StyledSpan{
            .{ .text = self.model.value()[byte_start..selected_start], .style = base_style },
            .{ .text = self.model.value()[selected_start..selected_end], .style = selected_style },
            .{ .text = self.model.value()[selected_end..byte_end], .style = base_style },
        };
        _ = try surface.putStyledLine(
            .{ .x = window.screen_column, .y = y },
            &spans,
            field_width,
            base_style,
            self.model.width_profile,
            .{},
        );
        if (selected_newline) {
            if (window.newline_column) |column| {
                _ = try surface.putText(.{ .x = column, .y = y }, " ", selected_style, self.model.width_profile);
            }
        }
    }

    fn drawCaret(
        self: *const TextArea,
        surface: *render.Surface,
        y: u16,
        caret: editor.CaretWindow,
        selection: ?editor.Selection,
        base_style: render.Style,
        selected_style: render.Style,
    ) !void {
        var caret_style = if (selection) |selected|
            if (caret.byte_offset >= selected.start and caret.byte_offset < selected.end) selected_style else base_style
        else
            base_style;
        caret_style.attributes.reverse = !caret_style.attributes.reverse;
        _ = try surface.putText(
            .{ .x = caret.screen_column, .y = y },
            caret.bytes,
            caret_style,
            self.model.width_profile,
        );
    }
};
