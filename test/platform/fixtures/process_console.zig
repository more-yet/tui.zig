const std = @import("std");
const tui = @import("tui");

const Decoder = tui.scroll.LineDecoder(512);
const Ring = Decoder.Ring;
const child_timer_id: tui.runtime.TimerId = 1;
const max_process_reads_per_event = 16;
const max_process_bytes_per_event = 64 * 1024;

const ChildState = union(enum) {
    running,
    stopped: std.posix.SIG,
    exited: u8,
    signaled: std.posix.SIG,
};

const Control = enum {
    none,
    suspend_requested,
    continued,
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        var buffer: [256]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(init.io, &buffer);
        try stderr.interface.writeAll("usage: tui-process-console-fixture /absolute/path [args...]\n");
        try stderr.interface.flush();
        return;
    }
    const child_argv = args[1..];
    const pointer_count = std.math.add(usize, child_argv.len, 1) catch return error.ArgumentsTooLarge;
    var byte_count: usize = 0;
    for (child_argv) |argument| {
        const stored_len = std.math.add(usize, argument.len, 1) catch return error.ArgumentsTooLarge;
        byte_count = std.math.add(usize, byte_count, stored_len) catch return error.ArgumentsTooLarge;
    }
    const argument_pointers = try init.gpa.alloc(?[*:0]const u8, pointer_count);
    defer init.gpa.free(argument_pointers);
    const argument_bytes = try init.gpa.alloc(u8, byte_count);
    defer init.gpa.free(argument_bytes);
    var spawn_storage = tui.subprocess.SpawnStorage.init(argument_pointers, argument_bytes);

    const io = init.io;
    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();
    var size = tui.terminal.querySize(io, stdout) catch tui.render.Size{ .width = 80, .height = 24 };
    var process = try tui.subprocess.PtyProcess.spawnBeforeThreads(
        io,
        .{ .argv = child_argv, .environ = init.minimal.environ },
        &spawn_storage,
        .{ .size = size },
    );
    defer cleanupProcess(&process);

    var output_buffer: [4096]u8 = undefined;
    var file_writer = stdout.writer(io, &output_buffer);
    const output = &file_writer.interface;
    var session = try tui.terminal.Session.enter(stdin, output, .{ .mouse = true });
    defer session.leave(output) catch {};

    var renderer = try tui.render.Renderer.init(init.gpa, size, .{});
    defer renderer.deinit();
    const slots = try init.gpa.alloc(Ring.Slot, 2048);
    defer init.gpa.free(slots);
    var ring = Ring.init(slots);
    var decoder: Decoder = .{};
    var decoded: tui.scroll.DecodeResult = .{};
    var viewport: tui.scroll.Viewport = .{};
    var child_state: ChildState = .running;
    var child_eof = false;

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
    try scheduleChildPoll(&runtime);

    var pty_buffer: [4096]u8 = undefined;
    var poll_storage: [4]tui.runtime.PollSlot = undefined;
    var changed = true;
    var quit = false;
    var child_poll_due = false;
    while (!quit) {
        const regions = layout(size);
        if (changed) {
            try draw(
                &renderer,
                regions,
                &ring,
                &viewport,
                child_state,
                decoded,
            );
            _ = try renderer.present(output, .{});
            changed = false;
        }

        const source_storage = [1]tui.runtime.PollSource{.{
            .file = try process.borrowedMaster(),
            .interest = .{ .read = true },
        }};
        const sources: []const tui.runtime.PollSource = if (child_eof) &.{} else &source_storage;
        var control: Control = .none;
        var sink = ConsoleSink{
            .process = &process,
            .decoder = &decoder,
            .ring = &ring,
            .viewport = &viewport,
            .decoded = &decoded,
            .pty_buffer = &pty_buffer,
            .renderer = &renderer,
            .size = &size,
            .changed = &changed,
            .quit = &quit,
            .child_eof = &child_eof,
            .child_poll_due = &child_poll_due,
            .control = &control,
        };
        const required_poll_slots = try tui.runtime.requiredPollSlots(sources.len);
        try runtime.stepWithSources(sources, poll_storage[0..required_poll_slots], &sink);
        if (child_poll_due) {
            child_poll_due = false;
            if (!process.isReaped()) {
                if (try process.poll()) |event| {
                    child_state = childState(event);
                    changed = true;
                }
            }
            if (!process.isReaped()) try scheduleChildPoll(&runtime);
        }
        switch (control) {
            .none => {},
            .suspend_requested => {
                try session.leave(output);
                try signal_source.suspendProcess();
                try session.reenter(output);
                renderer.invalidateTerminal();
                changed = true;
            },
            .continued => {
                renderer.invalidateTerminal();
                changed = true;
            },
        }
    }

    try session.leave(output);
}

const ConsoleSink = struct {
    process: *tui.subprocess.PtyProcess,
    decoder: *Decoder,
    ring: *Ring,
    viewport: *tui.scroll.Viewport,
    decoded: *tui.scroll.DecodeResult,
    pty_buffer: *[4096]u8,
    renderer: *tui.render.Renderer,
    size: *tui.render.Size,
    changed: *bool,
    quit: *bool,
    child_eof: *bool,
    child_poll_due: *bool,
    control: *Control,

    pub fn emit(self: *ConsoleSink, event: tui.runtime.Event) !void {
        switch (event) {
            .input => |value| self.handleInput(value),
            .resize => |new_size| {
                try self.renderer.resize(new_size);
                if (!self.process.isReaped()) try self.process.setSize(new_size);
                self.size.* = new_size;
                self.changed.* = true;
            },
            .eof => self.quit.* = true,
            .signal => |signal| switch (signal) {
                .interrupt, .terminate => self.quit.* = true,
                .suspend_requested => self.control.* = .suspend_requested,
                .continued => self.control.* = .continued,
            },
            .ready => |ready| if (ready.source_index == 0) try self.readProcessBatch(),
            .timer => |timer| {
                if (timer.id == child_timer_id) self.child_poll_due.* = true;
            },
            .wakeup => {},
        }
    }

    fn handleInput(self: *ConsoleSink, event: tui.input.Event) void {
        switch (event) {
            .key => |key| switch (key.code) {
                .escape => {
                    self.quit.* = true;
                    return;
                },
                .codepoint => |codepoint| if (codepoint == 'q') {
                    self.quit.* = true;
                    return;
                },
                else => {},
            },
            .text => |value| if (std.mem.eql(u8, value, "q")) {
                self.quit.* = true;
                return;
            },
            else => {},
        }

        const regions = layout(self.size.*);
        var scrollback = tui.widget.Scrollback(Ring){
            .provider = self.ring,
            .viewport = self.viewport,
            .bounds = regions[1],
            .focused = true,
        };
        if (scrollback.handle(event) == .redraw) self.changed.* = true;
    }

    fn readProcessBatch(self: *ConsoleSink) !void {
        var read_count: usize = 0;
        var byte_count: usize = 0;
        while (read_count < max_process_reads_per_event and byte_count < max_process_bytes_per_event) {
            switch (try self.process.read(self.pty_buffer)) {
                .data => |bytes| {
                    read_count += 1;
                    byte_count += bytes.len;
                    const result = self.decoder.feed(self.ring, bytes);
                    self.decoded.merge(result);
                    if (result.appended_rows != 0 or result.rejectedRows() != 0) {
                        _ = self.viewport.update(self.ring.count(), layout(self.size.*)[1].height, result.dropped_rows);
                        self.changed.* = true;
                    }
                },
                .would_block => break,
                .eof => {
                    const result = self.decoder.finish(self.ring);
                    self.decoded.merge(result);
                    if (result.appended_rows != 0 or result.rejectedRows() != 0) {
                        _ = self.viewport.update(self.ring.count(), layout(self.size.*)[1].height, result.dropped_rows);
                        self.changed.* = true;
                    }
                    self.child_eof.* = true;
                    self.child_poll_due.* = true;
                    break;
                },
            }
        }
    }
};

fn scheduleChildPoll(runtime: *tui.runtime.Posix) !void {
    var deadline = runtime.now();
    deadline.raw.nanoseconds += 50 * std.time.ns_per_ms;
    _ = try runtime.setTimer(child_timer_id, deadline);
}

fn childState(event: tui.subprocess.WaitEvent) ChildState {
    return switch (event) {
        .stopped => |signal| .{ .stopped = signal },
        .continued => .running,
        .exit => |exit| switch (exit) {
            .exited => |code| .{ .exited = code },
            .signaled => |signal| .{ .signaled = signal },
        },
    };
}

fn layout(size: tui.render.Size) [3]tui.render.Rect {
    const header_height: u16 = @intFromBool(size.height != 0);
    const footer_height: u16 = @intFromBool(size.height > 1);
    return .{
        .{ .x = 0, .y = 0, .width = size.width, .height = header_height },
        .{
            .x = 0,
            .y = header_height,
            .width = size.width,
            .height = size.height - header_height - footer_height,
        },
        .{ .x = 0, .y = size.height - footer_height, .width = size.width, .height = footer_height },
    };
}

fn draw(
    renderer: *tui.render.Renderer,
    regions: [3]tui.render.Rect,
    ring: *Ring,
    viewport: *tui.scroll.Viewport,
    child_state: ChildState,
    decoded: tui.scroll.DecodeResult,
) !void {
    const background = tui.render.Style{
        .foreground = .{ .indexed = 7 },
        .background = .{ .indexed = 0 },
    };
    const chrome = tui.render.Style{
        .foreground = .{ .indexed = 0 },
        .background = .{ .indexed = 6 },
        .attributes = .{ .bold = true },
    };
    var frame = renderer.frame();
    if (!regions[0].isEmpty()) {
        var header = frame.surface(regions[0]);
        _ = try header.putTextLine(
            .{ .x = 0, .y = 0 },
            " tui.zig process console",
            regions[0].width,
            chrome,
            .narrow,
            .{},
        );
    }
    var scrollback = tui.widget.Scrollback(Ring){
        .provider = ring,
        .viewport = viewport,
        .bounds = regions[1],
        .role = .{ .normal = background },
        .focused = true,
    };
    var body = frame.surface(regions[1]);
    try scrollback.draw(&body);

    if (!regions[2].isEmpty()) {
        var child_buffer: [48]u8 = undefined;
        const child = switch (child_state) {
            .running => "running",
            .stopped => |signal| try std.fmt.bufPrint(&child_buffer, "stopped ({d})", .{@intFromEnum(signal)}),
            .exited => |code| try std.fmt.bufPrint(&child_buffer, "exited ({d})", .{code}),
            .signaled => |signal| try std.fmt.bufPrint(&child_buffer, "signaled ({d})", .{@intFromEnum(signal)}),
        };
        var status_buffer: [256]u8 = undefined;
        const status = try std.fmt.bufPrint(
            &status_buffer,
            " up/down/page/home/end: browse  q/esc: quit  child: {s}  rows: {d}  rejected: {d}",
            .{ child, decoded.appended_rows, decoded.rejectedRows() },
        );
        var footer = frame.surface(regions[2]);
        _ = try footer.putTextLine(
            .{ .x = 0, .y = 0 },
            status,
            regions[2].width,
            chrome,
            .narrow,
            .{},
        );
    }
}

fn cleanupProcess(process: *tui.subprocess.PtyProcess) void {
    if (!process.isReaped()) {
        process.forceKill() catch {};
        while (!process.isReaped()) _ = process.wait() catch break;
    }
    if (process.isReaped()) process.deinit() else process.closeMaster();
}
