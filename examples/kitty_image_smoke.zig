const std = @import("std");
const tui = @import("tui");

const image_width = 96;
const image_height = 48;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();
    const size = try tui.terminal.querySize(io, stdout);
    if (size.width < 20 or size.height < 10) return error.TerminalTooSmall;

    var output_buffer: [4096]u8 = undefined;
    var file_writer = stdout.writer(io, &output_buffer);
    const output = &file_writer.interface;
    var session = try tui.terminal.Session.enter(stdin, output, .{
        .bracketed_paste = false,
        .focus_events = false,
    });
    defer session.leave(output) catch {};

    var image_may_exist = false;
    defer if (image_may_exist) {
        tui.terminal.clearKittyImages(output) catch {};
        output.flush() catch {};
    };

    var renderer = try tui.render.Renderer.init(init.gpa, size, .{ .image_capacity = 1 });
    defer renderer.deinit();
    var pixels: [image_width * image_height * 3]u8 = undefined;
    makeTestPattern(&pixels);

    const image_columns = @min(@as(u16, 40), size.width - 4);
    const image_rows = @min(@as(u16, 14), size.height - 7);
    const image_bounds = tui.render.Rect{
        .x = (size.width - image_columns) / 2,
        .y = 3,
        .width = image_columns,
        .height = image_rows,
    };
    const capabilities = tui.terminal.Capabilities{
        .color_depth = .truecolor,
        .synchronized_output = true,
        .image_protocol = .kitty,
    };

    var first_frame = renderer.frame();
    try paintBackground(&first_frame, size);
    _ = try first_frame.putText(.{ .x = 2, .y = 1 }, "Kitty graphics: presentation", .{
        .foreground = .{ .rgb = .{ .r = 226, .g = 232, .b = 240 } },
        .background = .{ .rgb = .{ .r = 15, .g = 23, .b = 42 } },
        .attributes = .{ .bold = true },
    }, .narrow);
    _ = try first_frame.putText(
        .{ .x = 2, .y = size.height - 2 },
        "White border + red/green/blue/yellow quadrants visible and centered? [y/n]",
        .{
            .foreground = .{ .rgb = .{ .r = 125, .g = 211, .b = 252 } },
            .background = .{ .rgb = .{ .r = 15, .g = 23, .b = 42 } },
        },
        .narrow,
    );
    try first_frame.putImage(image_bounds, .{
        .pixels = &pixels,
        .width = image_width,
        .height = image_height,
        .format = .rgb8,
    }, .{ .image_id = 0x5455_4901 });
    image_may_exist = true;
    const present_stats = try renderer.present(output, capabilities);

    var input_buffer: [64]u8 = undefined;
    var file_reader = stdin.readerStreaming(io, &input_buffer);
    const image_visible = try readAnswer(&file_reader.interface);

    var clear_frame = renderer.frame();
    try paintBackground(&clear_frame, size);
    _ = try clear_frame.putText(.{ .x = 2, .y = 2 }, "Kitty graphics: removal", .{
        .foreground = .{ .rgb = .{ .r = 226, .g = 232, .b = 240 } },
        .background = .{ .rgb = .{ .r = 15, .g = 23, .b = 42 } },
        .attributes = .{ .bold = true },
    }, .narrow);
    _ = try clear_frame.putText(.{ .x = 2, .y = 4 }, "The image should now be completely gone. Cleared? [y/n]", .{
        .foreground = .{ .rgb = .{ .r = 134, .g = 239, .b = 172 } },
        .background = .{ .rgb = .{ .r = 15, .g = 23, .b = 42 } },
    }, .narrow);
    const clear_stats = try renderer.present(output, capabilities);
    image_may_exist = false;
    const image_cleared = try readAnswer(&file_reader.interface);

    try session.leave(output);
    try output.print(
        "Kitty image smoke: {s} (present: {d} bytes, clear: {d} bytes, full repaint: {})\n",
        .{
            if (image_visible and image_cleared) "PASS" else "FAIL",
            present_stats.bytes,
            clear_stats.bytes,
            clear_stats.full_repaint,
        },
    );
    try output.flush();
    if (!image_visible or !image_cleared) std.process.exit(1);
}

fn paintBackground(frame: *tui.render.Frame, size: tui.render.Size) !void {
    try frame.fill(tui.render.Rect.fromSize(size), .{
        .background = .{ .rgb = .{ .r = 15, .g = 23, .b = 42 } },
    });
}

fn makeTestPattern(pixels: *[image_width * image_height * 3]u8) void {
    var y: usize = 0;
    while (y < image_height) : (y += 1) {
        var x: usize = 0;
        while (x < image_width) : (x += 1) {
            const border = x < 3 or y < 3 or x >= image_width - 3 or y >= image_height - 3;
            const color: [3]u8 = if (border)
                .{ 255, 255, 255 }
            else if (y < image_height / 2 and x < image_width / 2)
                .{ 239, 68, 68 }
            else if (y < image_height / 2)
                .{ 34, 197, 94 }
            else if (x < image_width / 2)
                .{ 59, 130, 246 }
            else
                .{ 250, 204, 21 };
            const offset = (y * image_width + x) * 3;
            pixels[offset..][0..3].* = color;
        }
    }
}

fn readAnswer(reader: *std.Io.Reader) !bool {
    while (true) switch (try reader.takeByte()) {
        'y', 'Y' => return true,
        'n', 'N', 3 => return false,
        else => {},
    };
}
