const std = @import("std");
const app = @import("app.zig");
const input = @import("input.zig");
const render_module = @import("render.zig");
const terminal = @import("terminal.zig");
const text = @import("text.zig");
const widget = @import("widget.zig");

pub const ExpectedCell = struct {
    glyph: []const u8 = " ",
    style: render_module.Style = .{},
    width: render_module.CellWidth = .narrow,
};

pub const ExpectError = error{
    OutOfBounds,
    InvalidExpectedText,
    GlyphMismatch,
    StyleMismatch,
    WidthMismatch,
    TrailingContent,
};

pub const Headless = struct {
    renderer: render_module.Renderer,
    driver: app.Driver = .{},
    parser: input.Parser = .{},
    output_buffer: [4096]u8 = undefined,

    pub fn init(
        allocator: std.mem.Allocator,
        dimensions: render_module.Size,
        limits: render_module.Limits,
    ) !Headless {
        return .{ .renderer = try render_module.Renderer.init(allocator, dimensions, limits) };
    }

    /// Call `finishInput` first when parser EOF semantics are part of the test.
    pub fn deinit(self: *Headless) void {
        self.renderer.deinit();
        self.* = undefined;
    }

    pub inline fn dispatch(self: *Headless, application: anytype, event: input.Event) widget.Update {
        return self.driver.dispatch(application, event);
    }

    pub fn feed(self: *Headless, application: anytype, fragment: []const u8) !void {
        var sink = EventSink(@TypeOf(application)){ .headless = self, .application = application };
        try self.parser.feed(fragment, &sink);
    }

    pub fn flushEscape(self: *Headless, application: anytype) !void {
        var sink = EventSink(@TypeOf(application)){ .headless = self, .application = application };
        try self.parser.flushEscape(&sink);
    }

    pub fn finishInput(self: *Headless, application: anytype) !void {
        var sink = EventSink(@TypeOf(application)){ .headless = self, .application = application };
        try self.parser.finish(&sink);
    }

    pub fn abortInput(self: *Headless, application: anytype) !void {
        var sink = EventSink(@TypeOf(application)){ .headless = self, .application = application };
        try self.parser.abort(&sink);
    }

    pub inline fn resize(self: *Headless, new_size: render_module.Size) !bool {
        return self.driver.resize(&self.renderer, new_size);
    }

    pub fn render(
        self: *Headless,
        application: anytype,
        capabilities: terminal.Capabilities,
    ) !render_module.FrameStats {
        var output = std.Io.Writer.Discarding.init(&self.output_buffer);
        return self.driver.refresh(&self.renderer, application, &output.writer, capabilities);
    }

    pub inline fn size(self: *const Headless) render_module.Size {
        return self.renderer.size();
    }

    pub inline fn cell(
        self: *const Headless,
        point: render_module.Point,
        glyph_storage: *[text.max_grapheme_bytes]u8,
    ) ?render_module.CellView {
        return self.renderer.desiredCellView(point, glyph_storage);
    }

    pub fn expectCell(self: *const Headless, point: render_module.Point, expected: ExpectedCell) ExpectError!void {
        var glyph_storage: [text.max_grapheme_bytes]u8 = undefined;
        const actual = self.cell(point, &glyph_storage) orelse return error.OutOfBounds;
        if (!std.mem.eql(u8, expected.glyph, actual.glyph)) return error.GlyphMismatch;
        if (!expected.style.eql(actual.style)) return error.StyleMismatch;
        if (expected.width != actual.width) return error.WidthMismatch;
    }

    pub fn expectText(self: *const Headless, origin: render_module.Point, expected: []const u8) ExpectError!void {
        _ = try self.expectTextEnd(origin, expected);
    }

    pub fn expectRow(self: *const Headless, y: u16, expected: []const u8) ExpectError!void {
        if (y >= self.size().height) return error.OutOfBounds;
        var x = try self.expectTextEnd(.{ .x = 0, .y = y }, expected);
        while (x < self.size().width) : (x += 1) {
            var glyph_storage: [text.max_grapheme_bytes]u8 = undefined;
            const actual = self.cell(.{ .x = x, .y = y }, &glyph_storage).?;
            if (actual.width != .narrow or !std.mem.eql(u8, actual.glyph, " ")) {
                return error.TrailingContent;
            }
        }
    }

    fn expectTextEnd(self: *const Headless, origin: render_module.Point, expected: []const u8) ExpectError!u16 {
        if (origin.x >= self.size().width or origin.y >= self.size().height) return error.OutOfBounds;
        var expected_clusters = text.GraphemeIterator.init(expected) catch return error.InvalidExpectedText;
        var x = origin.x;
        while (expected_clusters.next()) |cluster| {
            const narrow_width = cluster.displayWidthAssumeValid(.narrow) catch return error.InvalidExpectedText;
            const wide_width = cluster.displayWidthAssumeValid(.wide_ambiguous) catch return error.InvalidExpectedText;
            if (narrow_width == 0 or x >= self.size().width) return error.OutOfBounds;

            var glyph_storage: [text.max_grapheme_bytes]u8 = undefined;
            const actual = self.cell(.{ .x = x, .y = origin.y }, &glyph_storage) orelse return error.OutOfBounds;
            if (!std.mem.eql(u8, cluster.bytes, actual.glyph)) return error.GlyphMismatch;
            const actual_width: u2 = switch (actual.width) {
                .continuation => return error.WidthMismatch,
                .narrow => 1,
                .wide => 2,
            };
            if (actual_width != narrow_width and actual_width != wide_width) return error.WidthMismatch;
            if (actual.width == .wide) {
                if (x + 1 >= self.size().width) return error.WidthMismatch;
                var continuation_storage: [text.max_grapheme_bytes]u8 = undefined;
                const continuation = self.cell(.{ .x = x + 1, .y = origin.y }, &continuation_storage).?;
                if (continuation.width != .continuation) return error.WidthMismatch;
            }
            x += actual_width;
        }
        return x;
    }
};

fn EventSink(comptime Application: type) type {
    return struct {
        headless: *Headless,
        application: Application,

        pub fn emit(self: *@This(), event: input.Event) !void {
            _ = self.headless.dispatch(self.application, event);
        }
    };
}

test "headless rendering resolves graphemes styles widths and rows" {
    const Application = struct {
        layouts: u8 = 0,

        pub fn layout(self: *@This(), _: render_module.Size) void {
            self.layouts += 1;
        }

        pub fn draw(_: *@This(), surface: *render_module.Surface) !void {
            _ = try surface.putText(
                .{ .x = 0, .y = 0 },
                "e\xCC\x81\xE7\x95\x8C",
                .{ .foreground = .{ .indexed = 2 } },
                .narrow,
            );
        }
    };

    var headless = try Headless.init(std.testing.allocator, .{ .width = 5, .height = 2 }, .{});
    defer headless.deinit();
    var application: Application = .{};
    _ = try headless.render(&application, .{});
    try std.testing.expectEqual(@as(u8, 1), application.layouts);
    try headless.expectCell(.{ .x = 0, .y = 0 }, .{
        .glyph = "e\xCC\x81",
        .style = .{ .foreground = .{ .indexed = 2 } },
    });
    try headless.expectCell(.{ .x = 1, .y = 0 }, .{
        .glyph = "\xE7\x95\x8C",
        .style = .{ .foreground = .{ .indexed = 2 } },
        .width = .wide,
    });
    try headless.expectCell(.{ .x = 2, .y = 0 }, .{
        .style = .{ .foreground = .{ .indexed = 2 } },
        .width = .continuation,
    });
    try headless.expectText(.{ .x = 0, .y = 0 }, "e\xCC\x81\xE7\x95\x8C");
    try headless.expectRow(0, "e\xCC\x81\xE7\x95\x8C");

    try std.testing.expect(try headless.resize(.{ .width = 6, .height = 2 }));
    _ = try headless.render(&application, .{});
    try std.testing.expectEqual(@as(u8, 2), application.layouts);
}

test "headless input dispatches fragmented parser events synchronously" {
    const Application = struct {
        bytes: [16]u8 = undefined,
        len: usize = 0,
        escapes: u8 = 0,

        pub fn draw(_: *@This(), _: *render_module.Surface) void {}

        pub fn handle(self: *@This(), event: input.Event) widget.Update {
            switch (event) {
                .text, .paste_chunk => |bytes| {
                    @memcpy(self.bytes[self.len..][0..bytes.len], bytes);
                    self.len += bytes.len;
                    return .redraw;
                },
                .key => |key| if (key.code == .escape) {
                    self.escapes += 1;
                    return .handled;
                },
                else => {},
            }
            return .ignored;
        }
    };

    var headless = try Headless.init(std.testing.allocator, .{ .width = 2, .height = 1 }, .{});
    defer headless.deinit();
    var application: Application = .{};
    try headless.feed(&application, "a\x1b[200~e\xCC");
    try headless.feed(&application, "\x81\x1b[201~\x1b");
    try std.testing.expectEqual(@as(u8, 0), application.escapes);
    try headless.flushEscape(&application);
    try std.testing.expectEqual(@as(u8, 1), application.escapes);
    try std.testing.expectEqualStrings("ae\xCC\x81", application.bytes[0..application.len]);
}

test "headless helper performs no allocation after initialization" {
    const Application = struct {
        pub fn draw(_: *@This(), surface: *render_module.Surface) !void {
            _ = try surface.putText(.{ .x = 0, .y = 0 }, "ready", .{}, .narrow);
        }
    };

    var allocator_state = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var headless = try Headless.init(allocator_state.allocator(), .{ .width = 5, .height = 1 }, .{});
    defer headless.deinit();
    allocator_state.fail_index = allocator_state.alloc_index;
    allocator_state.resize_fail_index = allocator_state.resize_index;
    var application: Application = .{};
    _ = try headless.render(&application, .{});
    try headless.expectRow(0, "ready");
    try std.testing.expect(!allocator_state.has_induced_failure);
}
