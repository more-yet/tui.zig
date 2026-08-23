const std = @import("std");
const render = @import("../render.zig");
const text = @import("../text.zig");
const theme = @import("../theme.zig");

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

    pub fn draw(self: *const Paragraph, surface: *render.Surface) !void {
        _ = try surface.putWrappedText(
            render.Rect.fromSize(surface.size()),
            self.text,
            self.role.resolve(self.state),
            self.width_profile,
            self.alignment,
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

    pub fn draw(self: *const Gauge, surface: *render.Surface) !void {
        const size = surface.size();
        if (size.width == 0 or size.height == 0) return;
        const filled_width: u16 = if (self.total == 0)
            0
        else
            @intCast((@as(u128, @min(self.value, self.total)) * size.width) / self.total);
        try putRepeated(
            surface,
            .{ .x = 0, .y = 0 },
            &filled_cells,
            filled_width,
            self.filled.resolve(self.state),
        );
        try putRepeated(
            surface,
            .{ .x = filled_width, .y = 0 },
            &empty_cells,
            size.width - filled_width,
            self.empty.resolve(self.state),
        );
    }
};

const filled_cells: [64]u8 = @splat('#');
const empty_cells: [64]u8 = @splat('-');

fn putRepeated(
    surface: *render.Surface,
    origin: render.Point,
    pattern: []const u8,
    count: u16,
    style: render.Style,
) !void {
    var x = origin.x;
    var remaining = count;
    while (remaining != 0) {
        const chunk: u16 = @intCast(@min(@as(usize, remaining), pattern.len));
        _ = try surface.putText(.{ .x = x, .y = origin.y }, pattern[0..chunk], style, .narrow);
        x += chunk;
        remaining -= chunk;
    }
}

test "display widgets compose through clipped caller-owned surfaces" {
    var allocator_state = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var renderer = try render.Renderer.init(allocator_state.allocator(), .{ .width = 10, .height = 5 }, .{});
    defer renderer.deinit();
    allocator_state.fail_index = allocator_state.alloc_index;
    allocator_state.resize_fail_index = allocator_state.resize_index;

    var frame = renderer.frame();
    var root = frame.surface(render.Rect.fromSize(renderer.size()));
    const panel = Panel{ .title = "status" };
    try panel.draw(&root);

    var content = root.surface(Panel.contentRect(root.size()));
    const label = Label{ .text = "ready", .options = .{ .alignment = .center } };
    var label_surface = content.surface(.{ .x = 0, .y = 0, .width = content.size().width, .height = 1 });
    try label.draw(&label_surface);
    const gauge = Gauge{ .value = std.math.maxInt(u64), .total = std.math.maxInt(u64) };
    var gauge_surface = content.surface(.{ .x = 0, .y = 2, .width = content.size().width, .height = 1 });
    try gauge.draw(&gauge_surface);

    try std.testing.expectEqual(@as(u32, '+'), renderer.desiredCell(.{ .x = 0, .y = 0 }).?.glyph);
    try std.testing.expectEqual(@as(u32, 's'), renderer.desiredCell(.{ .x = 1, .y = 0 }).?.glyph);
    try std.testing.expectEqual(@as(u32, '|'), renderer.desiredCell(.{ .x = 9, .y = 2 }).?.glyph);
    try std.testing.expectEqual(@as(u32, '#'), renderer.desiredCell(.{ .x = 1, .y = 3 }).?.glyph);
    try std.testing.expectEqual(@as(u32, '#'), renderer.desiredCell(.{ .x = 8, .y = 3 }).?.glyph);
    try std.testing.expect(!allocator_state.has_induced_failure);
}

test "paragraph and zero-total gauge own their declared areas" {
    var renderer = try render.Renderer.init(std.testing.allocator, .{ .width = 6, .height = 3 }, .{});
    defer renderer.deinit();
    var frame = renderer.frame();
    var root = frame.surface(render.Rect.fromSize(renderer.size()));

    const paragraph = Paragraph{ .text = "one two three" };
    try paragraph.draw(&root);
    try std.testing.expectEqual(@as(u32, 'o'), renderer.desiredCell(.{ .x = 0, .y = 0 }).?.glyph);
    try std.testing.expectEqual(@as(u32, 't'), renderer.desiredCell(.{ .x = 0, .y = 1 }).?.glyph);

    const gauge = Gauge{ .value = 1, .total = 0 };
    var gauge_surface = root.surface(.{ .x = 0, .y = 2, .width = 6, .height = 1 });
    try gauge.draw(&gauge_surface);
    try std.testing.expectEqual(@as(u32, '-'), renderer.desiredCell(.{ .x = 0, .y = 2 }).?.glyph);
    try std.testing.expectEqual(
        render.Rect{ .x = 0, .y = 0, .width = 0, .height = 0 },
        Panel.contentRect(.{ .width = 1, .height = 1 }),
    );
}
