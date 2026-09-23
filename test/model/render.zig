const std = @import("std");
const tui = @import("tui");

const testing = std.testing;
const wide_glyph = "\u{754c}";
const pinned_style = tui.render.Style{ .foreground = .{ .indexed = 1 } };
const unavailable_style = tui.render.Style{ .foreground = .{ .indexed = 2 } };

fn expectValidWideCells(renderer: *const tui.render.Renderer) !void {
    const size = renderer.size();
    var y: u16 = 0;
    while (y < size.height) : (y += 1) {
        var x: u16 = 0;
        while (x < size.width) : (x += 1) {
            const cell = renderer.desiredCell(.{ .x = x, .y = y }).?;
            switch (cell.width) {
                .narrow => {},
                .continuation => {
                    try testing.expect(x > 0);
                    const previous = renderer.desiredCell(.{ .x = x - 1, .y = y }).?;
                    try testing.expectEqual(tui.render.CellWidth.wide, previous.width);
                    try testing.expectEqual(previous.style, cell.style);
                },
                .wide => {
                    try testing.expect(x + 1 < size.width);
                    const next = renderer.desiredCell(.{ .x = x + 1, .y = y }).?;
                    try testing.expectEqual(tui.render.CellWidth.continuation, next.width);
                    try testing.expectEqual(cell.style, next.style);
                },
            }
        }
    }
}

fn pinOnlyStyleSlot(surface: *tui.render.Surface) !void {
    _ = try surface.putText(.{ .x = 5, .y = 0 }, "p", pinned_style, .narrow);
}

test "styled ASCII capacity failure at a field start preserves a wide glyph" {
    var storage: tui.render.FixedRendererStorage(6, 1, 1, 2) = .{};
    var renderer = try tui.render.Renderer.init(storage.slices(), .{ .width = 6, .height = 1 });
    defer renderer.deinit();
    var surface = renderer.surface(.{ .x = 0, .y = 0, .width = 6, .height = 1 });

    try testing.expectEqual(@as(u16, 2), try surface.putText(.{ .x = 0, .y = 0 }, wide_glyph, .{}, .narrow));
    try pinOnlyStyleSlot(&surface);
    const spans = [_]tui.render.StyledSpan{.{ .text = "x", .style = unavailable_style }};

    try testing.expectError(error.StyleCapacityExceeded, surface.putStyledLine(
        .{ .x = 1, .y = 0 },
        &spans,
        1,
        .{},
        .narrow,
        .{},
    ));
    try expectValidWideCells(&renderer);
    try testing.expectEqual(tui.render.CellWidth.wide, renderer.desiredCell(.{ .x = 0, .y = 0 }).?.width);
    try testing.expectEqual(tui.render.CellWidth.continuation, renderer.desiredCell(.{ .x = 1, .y = 0 }).?.width);

    _ = try surface.putText(.{ .x = 5, .y = 0 }, "p", .{}, .narrow);
    _ = try surface.putStyledLine(.{ .x = 1, .y = 0 }, &spans, 1, .{}, .narrow, .{});
    try expectValidWideCells(&renderer);
}

test "styled ASCII padding is structurally complete before a later style failure" {
    var storage: tui.render.FixedRendererStorage(6, 1, 1, 2) = .{};
    var renderer = try tui.render.Renderer.init(storage.slices(), .{ .width = 6, .height = 1 });
    defer renderer.deinit();
    var surface = renderer.surface(.{ .x = 0, .y = 0, .width = 6, .height = 1 });

    _ = try surface.putText(.{ .x = 0, .y = 0 }, wide_glyph, .{}, .narrow);
    try pinOnlyStyleSlot(&surface);
    const spans = [_]tui.render.StyledSpan{.{ .text = "x", .style = unavailable_style }};

    try testing.expectError(error.StyleCapacityExceeded, surface.putStyledLine(
        .{ .x = 0, .y = 0 },
        &spans,
        2,
        .{},
        .narrow,
        .{ .alignment = .right },
    ));
    try expectValidWideCells(&renderer);
    try testing.expectEqual(tui.render.CellWidth.narrow, renderer.desiredCell(.{ .x = 0, .y = 0 }).?.width);
    try testing.expectEqual(tui.render.CellWidth.narrow, renderer.desiredCell(.{ .x = 1, .y = 0 }).?.width);
}

test "styled ASCII base-style failure does not split a glyph at the field end" {
    var storage: tui.render.FixedRendererStorage(6, 1, 1, 2) = .{};
    var renderer = try tui.render.Renderer.init(storage.slices(), .{ .width = 6, .height = 1 });
    defer renderer.deinit();
    var surface = renderer.surface(.{ .x = 0, .y = 0, .width = 6, .height = 1 });

    _ = try surface.putText(.{ .x = 1, .y = 0 }, wide_glyph, .{}, .narrow);
    try pinOnlyStyleSlot(&surface);
    const no_spans = [_]tui.render.StyledSpan{};

    try testing.expectError(error.StyleCapacityExceeded, surface.putStyledLine(
        .{ .x = 0, .y = 0 },
        &no_spans,
        2,
        unavailable_style,
        .narrow,
        .{},
    ));
    try expectValidWideCells(&renderer);
    try testing.expectEqual(tui.render.CellWidth.wide, renderer.desiredCell(.{ .x = 1, .y = 0 }).?.width);
    try testing.expectEqual(tui.render.CellWidth.continuation, renderer.desiredCell(.{ .x = 2, .y = 0 }).?.width);
}

test "completed styled spans repair a wide glyph before a later span fails" {
    var storage: tui.render.FixedRendererStorage(6, 1, 1, 2) = .{};
    var renderer = try tui.render.Renderer.init(storage.slices(), .{ .width = 6, .height = 1 });
    defer renderer.deinit();
    var surface = renderer.surface(.{ .x = 0, .y = 0, .width = 6, .height = 1 });

    _ = try surface.putText(.{ .x = 0, .y = 0 }, wide_glyph, .{}, .narrow);
    try pinOnlyStyleSlot(&surface);
    const spans = [_]tui.render.StyledSpan{
        .{ .text = "a" },
        .{ .text = "b", .style = unavailable_style },
    };

    try testing.expectError(error.StyleCapacityExceeded, surface.putStyledLine(
        .{ .x = 0, .y = 0 },
        &spans,
        2,
        .{},
        .narrow,
        .{},
    ));
    try expectValidWideCells(&renderer);
    try testing.expectEqual(@as(u32, 'a'), renderer.desiredCell(.{ .x = 0, .y = 0 }).?.glyph);
    try testing.expectEqual(tui.render.CellWidth.narrow, renderer.desiredCell(.{ .x = 1, .y = 0 }).?.width);
}
