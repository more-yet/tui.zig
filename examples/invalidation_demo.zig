const std = @import("std");
const tui = @import("tui");

const capability_timer_id: tui.runtime.TimerId = 1;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();
    var output_buffer: [4096]u8 = undefined;
    var file_writer = stdout.writer(io, &output_buffer);
    const output = &file_writer.interface;

    var session = try tui.terminal.Session.enter(stdin, output, .{});
    defer session.leave(output) catch {};

    var size = tui.terminal.querySize(io, stdout) catch tui.render.Size{ .width = 80, .height = 24 };
    var renderer = try tui.render.Renderer.init(init.gpa, size, .{});
    defer renderer.deinit();

    var negotiator = tui.terminal.CapabilityNegotiator.init(.{ .color_depth = .truecolor });
    try negotiator.writeQueries(output);

    var counter: u64 = 0;
    var quit = false;
    var changed = true;
    var full_paint = true;
    var previous_stats: tui.render.FrameStats = .{};
    var regions: [3]tui.render.Rect = undefined;
    var read_buffer: [512]u8 = undefined;
    var timer_storage: [1]tui.runtime.TimerSlot = undefined;
    var signal_source = try tui.runtime.SignalSource.init(io, .{});
    defer signal_source.deinit();
    var runtime = try tui.runtime.Posix.init(io, stdin, &read_buffer, &timer_storage, .{
        .resize = .{
            .file = stdout,
            .initial_size = size,
            .poll_interval = .fromMilliseconds(50),
        },
        .signals = &signal_source,
    });
    defer runtime.deinit();
    var capability_deadline = runtime.now();
    capability_deadline.raw.nanoseconds += 250 * std.time.ns_per_ms;
    _ = try runtime.setTimer(capability_timer_id, capability_deadline);

    while (!quit) {
        if (changed) {
            layoutRegions(size, &regions);
            if (full_paint) {
                try paintAll(&renderer, regions, counter, previous_stats, negotiator.capabilities.width_profile);
            } else {
                try paintDynamic(&renderer, regions, counter, previous_stats, negotiator.capabilities.width_profile);
            }
            previous_stats = try renderer.present(output, negotiator.capabilities);
            full_paint = false;
            changed = false;
        }

        var control: Control = .none;
        var sink = DemoSink{
            .quit = &quit,
            .changed = &changed,
            .counter = &counter,
            .negotiator = &negotiator,
            .renderer = &renderer,
            .size = &size,
            .full_paint = &full_paint,
            .control = &control,
        };
        try runtime.step(&sink);
        try session.setKittyKeyboard(output, negotiator.capabilities.kitty_keyboard);
        if (!negotiator.queriesPending()) _ = runtime.cancelTimer(capability_timer_id);
        switch (control) {
            .none => {},
            .suspend_requested => {
                try session.leave(output);
                try signal_source.suspendProcess();
                try session.reenter(output);
                renderer.invalidateTerminal();
                full_paint = true;
                changed = true;
            },
            .continued => {
                renderer.invalidateTerminal();
                full_paint = true;
                changed = true;
            },
        }
    }

    try session.leave(output);
}

fn layoutRegions(size: tui.render.Size, regions: *[3]tui.render.Rect) void {
    const constraints = [_]tui.layout.Segment{
        tui.layout.Segment.fixed(1),
        tui.layout.Segment.flex(1, 1, std.math.maxInt(u16)),
        tui.layout.Segment.fixed(1),
    };
    _ = tui.layout.split(tui.render.Rect.fromSize(size), .vertical, &constraints, regions) catch {
        regions.* = .{
            tui.render.Rect.fromSize(size),
            .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        };
    };
}

fn paintAll(
    renderer: *tui.render.Renderer,
    regions: [3]tui.render.Rect,
    counter: u64,
    stats: tui.render.FrameStats,
    width_profile: tui.text.WidthProfile,
) !void {
    renderer.invalidate(tui.render.Rect.fromSize(renderer.size()));
    var frame = renderer.frame();
    try frame.fill(tui.render.Rect.fromSize(renderer.size()), .{ .background = .{ .rgb = .{ .r = 14, .g = 18, .b = 27 } } });
    try frame.fill(regions[0], .{
        .foreground = .{ .rgb = .{ .r = 17, .g = 24, .b = 39 } },
        .background = .{ .rgb = .{ .r = 125, .g = 211, .b = 252 } },
        .attributes = .{ .bold = true },
    });
    _ = try frame.putText(.{ .x = 1, .y = regions[0].y }, "tui.zig invalidation demo", .{
        .foreground = .{ .rgb = .{ .r = 17, .g = 24, .b = 39 } },
        .background = .{ .rgb = .{ .r = 125, .g = 211, .b = 252 } },
        .attributes = .{ .bold = true },
    }, width_profile);
    try paintDynamic(renderer, regions, counter, stats, width_profile);
}

fn paintDynamic(
    renderer: *tui.render.Renderer,
    regions: [3]tui.render.Rect,
    counter: u64,
    stats: tui.render.FrameStats,
    width_profile: tui.text.WidthProfile,
) !void {
    const counter_region = if (regions[1].isEmpty())
        regions[1]
    else
        tui.render.Rect{
            .x = regions[1].x,
            .y = regions[1].y + regions[1].height / 2,
            .width = regions[1].width,
            .height = 1,
        };
    renderer.invalidate(counter_region);
    renderer.invalidate(regions[2]);
    var frame = renderer.frame();
    try frame.fill(counter_region, .{ .background = .{ .rgb = .{ .r = 14, .g = 18, .b = 27 } } });
    try frame.fill(regions[2], .{
        .foreground = .{ .rgb = .{ .r = 203, .g = 213, .b = 225 } },
        .background = .{ .rgb = .{ .r = 30, .g = 41, .b = 59 } },
    });

    if (!counter_region.isEmpty()) {
        var counter_buffer: [96]u8 = undefined;
        const counter_text = std.fmt.bufPrint(&counter_buffer, "counter: {d}", .{counter}) catch unreachable;
        _ = try frame.putText(.{ .x = counter_region.x + 2, .y = counter_region.y }, counter_text, .{
            .foreground = .{ .rgb = .{ .r = 250, .g = 204, .b = 21 } },
            .background = .{ .rgb = .{ .r = 14, .g = 18, .b = 27 } },
            .attributes = .{ .bold = true },
        }, width_profile);
    }
    if (!regions[2].isEmpty()) {
        var status_buffer: [160]u8 = undefined;
        const status = std.fmt.bufPrint(
            &status_buffer,
            "space: increment  q/esc: quit  last frame: {d} cells, {d} bytes, {d} runs",
            .{ stats.cells_changed, stats.bytes, stats.runs },
        ) catch unreachable;
        _ = try frame.putText(.{ .x = regions[2].x + 1, .y = regions[2].y }, status, .{
            .foreground = .{ .rgb = .{ .r = 203, .g = 213, .b = 225 } },
            .background = .{ .rgb = .{ .r = 30, .g = 41, .b = 59 } },
        }, width_profile);
    }
}

const DemoSink = struct {
    quit: *bool,
    changed: *bool,
    counter: *u64,
    negotiator: *tui.terminal.CapabilityNegotiator,
    renderer: *tui.render.Renderer,
    size: *tui.render.Size,
    full_paint: *bool,
    control: *Control,

    pub fn emit(self: *DemoSink, event: tui.runtime.Event) !void {
        switch (event) {
            .input => |value| try self.handleInput(value),
            .resize => |size| {
                try self.renderer.resize(size);
                self.size.* = size;
                self.full_paint.* = true;
                self.changed.* = true;
            },
            .eof => self.quit.* = true,
            .signal => |signal| switch (signal) {
                .interrupt, .terminate => self.quit.* = true,
                .suspend_requested => self.control.* = .suspend_requested,
                .continued => self.control.* = .continued,
            },
            .timer => |timer| if (timer.id == capability_timer_id) self.negotiator.cancelQueries(),
            .wakeup, .ready => {},
        }
    }

    fn handleInput(self: *DemoSink, value: tui.input.Event) !void {
        self.negotiator.observe(value);
        switch (value) {
            .key => |key| switch (key.code) {
                .escape => self.quit.* = true,
                .codepoint => |codepoint| if (codepoint == 'q') {
                    self.quit.* = true;
                } else if (codepoint == ' ') {
                    self.counter.* += 1;
                    self.changed.* = true;
                },
                else => {},
            },
            .text => |text| {
                if (std.mem.eql(u8, text, "q")) {
                    self.quit.* = true;
                } else if (std.mem.eql(u8, text, " ")) {
                    self.counter.* += 1;
                    self.changed.* = true;
                }
            },
            else => {},
        }
    }
};

const Control = enum {
    none,
    suspend_requested,
    continued,
};
