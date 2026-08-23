const std = @import("std");
const tui = @import("tui");

pub const Decoder = tui.scroll.LineDecoder(1024);
pub const Ring = Decoder.Ring;

const response =
    "assistant: received the prompt safely\r\n" ++
    "assistant: streamed output uses bounded chunks\r\n";
const response_timer_id: tui.runtime.TimerId = 1;

const Status = enum {
    ready,
    streaming,
    input_error,
    output_error,
};

const Control = enum {
    none,
    suspend_requested,
    continued,
};

pub const AssistantApp = struct {
    ring: *Ring,
    prompt: tui.widget.TextArea,
    decoder: Decoder = .{},
    viewport: tui.scroll.Viewport = .{},
    transcript_bounds: tui.render.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    visible_rows: u16 = 0,
    response_offset: usize = response.len,
    transcript_focused: bool = false,
    streaming: bool = false,
    quit: bool = false,
    status: Status = .ready,

    pub fn init(ring: *Ring, prompt: *tui.editor.Model) !AssistantApp {
        var self = AssistantApp{ .ring = ring, .prompt = .{ .model = prompt } };
        try self.appendLine("assistant: tui.zig coding-assistant reference");
        return self;
    }

    pub fn handle(self: *AssistantApp, event: tui.input.Event) tui.widget.Update {
        if (event == .key) {
            const key = event.key;
            if (key.action != .release and !key.modifiers.hasNonLock() and key.code == .escape) {
                self.quit = true;
                return .handled;
            }
            if (key.action != .release and !key.modifiers.hasNonLock() and key.code == .tab) {
                self.transcript_focused = !self.transcript_focused;
                return .redraw;
            }
            if (key.action != .release and key.modifiers.control) {
                switch (key.code) {
                    .codepoint => |codepoint| switch (codepoint) {
                        'q' => {
                            self.quit = true;
                            return .handled;
                        },
                        's' => return self.submit(),
                        else => {},
                    },
                    else => {},
                }
            }
        }

        if (event == .mouse and self.transcript_bounds.contains(.{ .x = event.mouse.x, .y = event.mouse.y })) {
            return self.handleTranscript(event);
        }
        if (self.transcript_focused) return self.handleTranscript(event);

        const update = self.prompt.handle(event);
        if (self.prompt.takeFailure() != null) {
            self.status = .input_error;
            return if (update == .redraw) .redraw else .handled;
        }
        return update;
    }

    pub fn streamStep(self: *AssistantApp) tui.widget.Update {
        if (!self.streaming) return .ignored;
        const end = @min(response.len, self.response_offset + 7);
        const result = self.decoder.feed(self.ring, response[self.response_offset..end]);
        self.response_offset = end;
        self.acceptDecoded(result);
        var changed = result.appended_rows != 0 or result.rejectedRows() != 0;
        if (end == response.len) {
            const finished = self.decoder.finish(self.ring);
            self.acceptDecoded(finished);
            changed = changed or finished.appended_rows != 0 or finished.rejectedRows() != 0;
            self.streaming = false;
            if (self.status != .output_error) self.status = .ready;
            changed = true;
        }
        return if (changed) .redraw else .handled;
    }

    pub fn draw(self: *AssistantApp, surface: *tui.render.Surface) !void {
        const regions = layout(surface.size());
        self.transcript_bounds = regions.transcript;
        self.visible_rows = regions.transcript.height;
        _ = self.viewport.update(self.ring.count(), self.visible_rows, 0);

        const background = tui.render.Style{
            .foreground = .{ .indexed = 7 },
            .background = .{ .indexed = 0 },
        };
        const chrome = tui.render.Style{
            .foreground = .{ .indexed = 0 },
            .background = .{ .indexed = 6 },
            .attributes = .{ .bold = true },
        };
        if (!regions.header.isEmpty()) {
            var header = surface.surface(regions.header);
            _ = try header.putTextLine(
                .{ .x = 0, .y = 0 },
                " tui.zig assistant reference",
                regions.header.width,
                chrome,
                .narrow,
                .{},
            );
        }

        var scrollback = tui.widget.Scrollback(Ring){
            .provider = self.ring,
            .viewport = &self.viewport,
            .bounds = regions.transcript,
            .role = .{ .normal = background, .focused = .{ .foreground = .{ .indexed = 15 } } },
            .focused = self.transcript_focused,
        };
        var transcript = surface.surface(regions.transcript);
        try scrollback.draw(&transcript);

        self.prompt.focused = !self.transcript_focused;
        self.prompt.role = .{
            .normal = .{ .foreground = .{ .indexed = 7 }, .background = .{ .indexed = 8 } },
            .focused = .{ .foreground = .{ .indexed = 15 }, .background = .{ .indexed = 8 } },
        };
        var prompt = surface.surface(regions.prompt);
        try self.prompt.draw(&prompt);

        if (!regions.footer.isEmpty()) {
            const focus = if (self.transcript_focused) "transcript" else "prompt";
            const state = switch (self.status) {
                .ready => "ready",
                .streaming => "streaming",
                .input_error => "input error",
                .output_error => "output error",
            };
            var status_buffer: [256]u8 = undefined;
            const status = try std.fmt.bufPrint(
                &status_buffer,
                " Tab: focus  Ctrl+S: submit  Ctrl+Q/Esc: quit  focus: {s}  status: {s}",
                .{ focus, state },
            );
            var footer = surface.surface(regions.footer);
            _ = try footer.putTextLine(.{ .x = 0, .y = 0 }, status, regions.footer.width, chrome, .narrow, .{});
        }
    }

    fn submit(self: *AssistantApp) tui.widget.Update {
        if (self.streaming) return .handled;
        const value = self.prompt.model.value();
        if (value.len == 0) return .handled;

        self.appendLine("you:") catch {
            self.status = .output_error;
            return .handled;
        };
        var start: usize = 0;
        while (true) {
            const relative_end = std.mem.indexOfScalar(u8, value[start..], '\n') orelse value.len - start;
            const end = start + relative_end;
            self.appendLine(value[start..end]) catch {
                self.status = .output_error;
                return .handled;
            };
            if (end == value.len) break;
            start = end + 1;
        }
        self.appendLine("") catch {
            self.status = .output_error;
            return .handled;
        };

        _ = self.prompt.model.selectAll();
        _ = self.prompt.model.replaceSelection("") catch {
            self.status = .input_error;
            return .handled;
        };
        self.decoder.reset();
        self.response_offset = 0;
        self.streaming = true;
        self.status = .streaming;
        return .redraw;
    }

    fn handleTranscript(self: *AssistantApp, event: tui.input.Event) tui.widget.Update {
        var scrollback = tui.widget.Scrollback(Ring){
            .provider = self.ring,
            .viewport = &self.viewport,
            .bounds = self.transcript_bounds,
            .focused = true,
        };
        return scrollback.handle(event);
    }

    fn appendLine(self: *AssistantApp, line: []const u8) tui.scroll.AppendError!void {
        const appended = try self.ring.append(line);
        _ = self.viewport.update(self.ring.count(), self.visible_rows, appended.dropped_rows);
    }

    fn acceptDecoded(self: *AssistantApp, result: tui.scroll.DecodeResult) void {
        _ = self.viewport.update(self.ring.count(), self.visible_rows, result.dropped_rows);
        if (result.rejectedRows() != 0) self.status = .output_error;
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();
    const size = tui.terminal.querySize(io, stdout) catch tui.render.Size{ .width = 80, .height = 24 };

    var output_buffer: [4096]u8 = undefined;
    var file_writer = stdout.writer(io, &output_buffer);
    const output = &file_writer.interface;
    var session = try tui.terminal.Session.enter(stdin, output, .{ .mouse = true, .focus_events = true });
    defer session.leave(output) catch {};

    var renderer = try tui.render.Renderer.init(init.gpa, size, .{});
    defer renderer.deinit();
    const slots = try init.gpa.alloc(Ring.Slot, 256);
    defer init.gpa.free(slots);
    var ring = Ring.init(slots);
    var prompt_storage: [1024]u8 = undefined;
    var prompt = try tui.editor.Model.init(&prompt_storage, "");
    var application = try AssistantApp.init(&ring, &prompt);

    var read_buffer: [512]u8 = undefined;
    var timers: [1]tui.runtime.TimerSlot = undefined;
    var signals = try tui.runtime.SignalSource.init(io, .{});
    defer signals.deinit();
    var runtime = try tui.runtime.Posix.init(io, stdin, &read_buffer, &timers, .{
        .resize = .{
            .file = stdout,
            .initial_size = size,
            .poll_interval = .fromMilliseconds(50),
        },
        .signals = &signals,
    });
    defer runtime.deinit();

    var changed = true;
    var timer_armed = false;
    while (!application.quit) {
        if (changed) {
            var frame = renderer.frame();
            var root = frame.surface(tui.render.Rect.fromSize(renderer.size()));
            try application.draw(&root);
            _ = try renderer.present(output, .{});
            changed = false;
        }

        var control: Control = .none;
        var sink = AssistantSink{
            .application = &application,
            .renderer = &renderer,
            .changed = &changed,
            .timer_armed = &timer_armed,
            .control = &control,
        };
        try runtime.step(&sink);
        if (application.streaming and !timer_armed) {
            var deadline = runtime.now();
            deadline.raw.nanoseconds += 30 * std.time.ns_per_ms;
            _ = try runtime.setTimer(response_timer_id, deadline);
            timer_armed = true;
        }
        switch (control) {
            .none => {},
            .suspend_requested => {
                try session.leave(output);
                try signals.suspendProcess();
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

const AssistantSink = struct {
    application: *AssistantApp,
    renderer: *tui.render.Renderer,
    changed: *bool,
    timer_armed: *bool,
    control: *Control,

    pub fn emit(self: *AssistantSink, event: tui.runtime.Event) !void {
        switch (event) {
            .input => |value| if (self.application.handle(value) == .redraw) {
                self.changed.* = true;
            },
            .resize => |new_size| {
                try self.renderer.resize(new_size);
                self.changed.* = true;
            },
            .timer => |timer| if (timer.id == response_timer_id) {
                self.timer_armed.* = false;
                if (self.application.streamStep() == .redraw) self.changed.* = true;
            },
            .signal => |signal| switch (signal) {
                .interrupt, .terminate => self.application.quit = true,
                .suspend_requested => self.control.* = .suspend_requested,
                .continued => self.control.* = .continued,
            },
            .eof => self.application.quit = true,
            .wakeup, .ready => {},
        }
    }
};

const Regions = struct {
    header: tui.render.Rect,
    transcript: tui.render.Rect,
    prompt: tui.render.Rect,
    footer: tui.render.Rect,
};

fn layout(size: tui.render.Size) Regions {
    const header_height: u16 = @intFromBool(size.height != 0);
    const footer_height: u16 = @intFromBool(size.height > 1);
    const content_height = size.height - header_height - footer_height;
    const prompt_height = @min(content_height, 3);
    const transcript_height = content_height - prompt_height;
    return .{
        .header = .{ .x = 0, .y = 0, .width = size.width, .height = header_height },
        .transcript = .{ .x = 0, .y = header_height, .width = size.width, .height = transcript_height },
        .prompt = .{
            .x = 0,
            .y = header_height + transcript_height,
            .width = size.width,
            .height = prompt_height,
        },
        .footer = .{
            .x = 0,
            .y = size.height - footer_height,
            .width = size.width,
            .height = footer_height,
        },
    };
}
