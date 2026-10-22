const render = @import("../render.zig");
const text = @import("../text.zig");
const theme = @import("../ui/theme.zig");

pub const Label = struct {
    text: []const u8,
    role: theme.Role = .{},
    state: theme.State = .normal,
    width_profile: text.WidthProfile = .narrow,
    options: text.LineOptions = .{},

    pub fn draw(self: *const Label, surface: *render.Surface) !void {
        _ = try surface.putTextLine(
            .{ .x = 0, .y = 0 },
            self.text,
            surface.size().width,
            self.role.resolve(self.state),
            self.width_profile,
            self.options,
        );
    }
};

pub const Paragraph = struct {
    text: []const u8,
    role: theme.Role = .{},
    state: theme.State = .normal,
    width_profile: text.WidthProfile = .narrow,
    alignment: text.TextAlignment = .left,
    first_row: usize = 0,

    /// Total wrapped rows at this width, independent of first_row. Borrows text.
    pub fn rowCount(self: *const Paragraph, width: u16) text.WrapError!usize {
        const lines = try text.WrapIterator.init(self.text, width, self.width_profile);
        return lines.countRemaining();
    }

    pub fn draw(self: *const Paragraph, surface: *render.Surface) !void {
        _ = try surface.putWrappedText(
            render.Rect.fromSize(surface.size()),
            self.text,
            self.role.resolve(self.state),
            self.width_profile,
            .{ .alignment = self.alignment, .first_row = self.first_row },
        );
    }
};

pub const Panel = struct {
    title: []const u8 = "",
    background: theme.Role = .{},
    border: theme.Role = .{},
    title_role: theme.Role = .{},
    state: theme.State = .normal,
    width_profile: text.WidthProfile = .narrow,
    title_options: text.LineOptions = .{ .overflow = .ellipsis },

    pub fn contentRect(size: render.Size) render.Rect {
        if (size.width < 2 or size.height < 2) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        return .{ .x = 1, .y = 1, .width = size.width - 2, .height = size.height - 2 };
    }

    pub fn draw(self: *const Panel, surface: *render.Surface) !void {
        const size = surface.size();
        if (size.width == 0 or size.height == 0) return;
        if (size.width < 2 or size.height < 2) {
            try surface.fill(render.Rect.fromSize(size), self.background.resolve(self.state));
            return;
        }

        const content = contentRect(size);
        try surface.fill(content, self.background.resolve(self.state));

        const border_style = self.border.resolve(self.state);
        const bottom = size.height - 1;
        const border_fills = [_]render.AsciiFill{
            .{ .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .glyph = '+' },
            .{ .rect = .{ .x = size.width - 1, .y = 0, .width = 1, .height = 1 }, .glyph = '+' },
            .{ .rect = .{ .x = 0, .y = bottom, .width = 1, .height = 1 }, .glyph = '+' },
            .{ .rect = .{ .x = size.width - 1, .y = bottom, .width = 1, .height = 1 }, .glyph = '+' },
            .{ .rect = .{ .x = 1, .y = bottom, .width = size.width - 2, .height = 1 }, .glyph = '-' },
            .{ .rect = .{ .x = 0, .y = 1, .width = 1, .height = size.height - 2 }, .glyph = '|' },
            .{ .rect = .{ .x = size.width - 1, .y = 1, .width = 1, .height = size.height - 2 }, .glyph = '|' },
            .{ .rect = .{ .x = 1, .y = 0, .width = size.width - 2, .height = 1 }, .glyph = '-' },
        };
        try surface.fillAsciiBatch(border_fills[0 .. border_fills.len - @intFromBool(self.title.len != 0)], border_style);

        if (self.title.len != 0) {
            _ = try surface.putTextLine(
                .{ .x = 1, .y = 0 },
                self.title,
                size.width - 2,
                self.title_role.resolve(self.state),
                self.width_profile,
                self.title_options,
            );
        }
    }
};

pub const Gauge = struct {
    value: u64,
    total: u64,
    filled: theme.Role = .{},
    empty: theme.Role = .{},
    state: theme.State = .normal,

    /// Filled cells for custom drawing, e.g. `gauge.filledWidth(surface.size().width)`.
    pub fn filledWidth(self: *const Gauge, width: u16) u16 {
        if (self.total == 0) return 0;
        return @intCast((@as(u128, @min(self.value, self.total)) * width) / self.total);
    }

    pub fn draw(self: *const Gauge, surface: *render.Surface) !void {
        const size = surface.size();
        if (size.width == 0 or size.height == 0) return;
        const filled_width = self.filledWidth(size.width);
        try surface.fillAscii(.{ .x = 0, .y = 0, .width = filled_width, .height = 1 }, '#', self.filled.resolve(self.state));
        try surface.fillAscii(.{ .x = filled_width, .y = 0, .width = size.width - filled_width, .height = 1 }, '-', self.empty.resolve(self.state));
    }
};
