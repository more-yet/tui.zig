const std = @import("std");
const tui = @import("tui");
pub const graphics_demo = @import("graphics_demo.zig");

const negotiation_timer_id: tui.runtime.TimerId = 1;
const cleanup_timer_id: tui.runtime.TimerId = 2;
const graphics_reply_timer_id: tui.runtime.TimerId = 3;
const negotiation_timeout_ns = 250 * std.time.ns_per_ms;
const cleanup_timeout_ns = 250 * std.time.ns_per_ms;
const presentation_work_budget = 256;

const Focus = enum { input, editor };
const CleanupTarget = enum { @"suspend", quit };

const Lifecycle = union(enum) {
    entering,
    running,
    draining: CleanupTarget,
    leaving: CleanupTarget,
    waiting_continue,

    fn acceptsApplicationInput(self: Lifecycle) bool {
        return switch (self) {
            .entering, .running => true,
            .draining, .leaving, .waiting_continue => false,
        };
    }

    fn isRunning(self: Lifecycle) bool {
        return switch (self) {
            .running => true,
            .entering, .draining, .leaving, .waiting_continue => false,
        };
    }

    fn cleanupActive(self: Lifecycle) bool {
        return switch (self) {
            .draining, .leaving => true,
            .entering, .running, .waiting_continue => false,
        };
    }

    /// Returns true only when the caller must arm a new cleanup deadline.
    fn requestCleanup(self: *Lifecycle, target: CleanupTarget) bool {
        switch (self.*) {
            .entering, .running, .waiting_continue => {
                self.* = .{ .draining = target };
                return true;
            },
            .draining => |current| {
                if (current == .@"suspend" and target == .quit) self.* = .{ .draining = .quit };
                return false;
            },
            .leaving => |current| {
                if (current == .@"suspend" and target == .quit) self.* = .{ .leaving = .quit };
                return false;
            },
        }
    }
};

const PendingOutput = union(enum) {
    none,
    session: []const u8,
    negotiation: []const u8,
    graphics: []const u8,
    renderer: []const u8,

    fn bytes(self: PendingOutput) []const u8 {
        return switch (self) {
            .none => &.{},
            .session => |data| data,
            .negotiation => |data| data,
            .graphics => |data| data,
            .renderer => |data| data,
        };
    }

    fn idle(self: PendingOutput) bool {
        return self == .none;
    }
};

pub const DemoApp = struct {
    input: tui.widget.TextInput,
    editor: tui.widget.TextArea,
    focus: Focus = .input,
    graphics_requested: bool = false,
    graphics_available: bool = false,
    graphics_error: [80]u8 = undefined,
    graphics_error_len: u8 = 0,
    quit: bool = false,

    pub fn init(input_model: *tui.editor.Model, editor_model: *tui.editor.Model) DemoApp {
        return .{
            .input = tui.widget.TextInput.init(input_model),
            .editor = .{ .model = editor_model },
        };
    }

    pub fn layout(self: *DemoApp, size: tui.render.Size) !void {
        const rect = self.editorRect(size);
        _ = self.editor.layout(.{ .width = rect.width, .height = rect.height });
    }

    fn editorRect(self: *const DemoApp, size: tui.render.Size) tui.render.Rect {
        const bottom = if (self.graphics_available)
            if (graphics_demo.Layout.forSize(size)) |layout_| layout_.heading_y else size.height
        else
            size.height;
        return .{ .x = 2, .y = 5, .width = size.width -| 2, .height = bottom -| 5 };
    }

    pub fn handle(self: *DemoApp, event: tui.input.Event) tui.widget.Update {
        if (event == .key and event.key.action != .release) {
            const key = event.key;
            if (key.modifiers.control and key.code == .codepoint and key.code.codepoint == 'q' or
                !key.modifiers.hasNonLock() and key.code == .escape)
            {
                self.quit = true;
                return .handled;
            }
            if (!key.modifiers.hasNonLock() and key.code == .tab or
                key.modifiers.alt and (key.code == .left or key.code == .right))
            {
                self.focus = if (self.focus == .input) .editor else .input;
                return .redraw;
            }
        }

        self.input.focused = self.focus == .input;
        self.editor.focused = self.focus == .editor;
        return switch (self.focus) {
            .input => self.input.handle(event),
            .editor => self.editor.handle(event),
        };
    }

    pub fn draw(self: *DemoApp, surface: *tui.render.Surface) !void {
        const size = surface.size();
        const normal = tui.render.Style{ .foreground = .{ .indexed = 7 } };
        const accent = tui.render.Style{ .foreground = .{ .indexed = 6 }, .attributes = .{ .bold = true } };
        try surface.fill(tui.render.Rect.fromSize(size), normal);
        if (size.width == 0 or size.height == 0) return;

        _ = try surface.putText(.{ .x = 0, .y = 0 }, "tui.zig  OVERVIEW", accent, .narrow);
        if (size.height < 2) return;
        if (self.graphics_error_len != 0) {
            const prefix_width = try surface.putText(.{ .x = 0, .y = 1 }, "Graphics error: ", normal, .narrow);
            _ = try surface.putText(
                .{ .x = prefix_width, .y = 1 },
                self.graphics_error[0..self.graphics_error_len],
                normal,
                .narrow,
            );
        } else {
            _ = try surface.putText(
                .{ .x = 0, .y = 1 },
                if (self.graphics_requested and !self.graphics_available)
                    "Graphics unavailable · Tab switches focus · Ctrl+Q exits"
                else if (self.graphics_available and graphics_demo.Layout.forSize(size) == null)
                    "Graphics need 20x12 · Tab switches focus · Ctrl+Q exits"
                else
                    "Tab switches focus · Ctrl+Q exits",
                normal,
                .narrow,
            );
        }
        if (size.height < 3 or size.width < 3) return;

        var input_surface = surface.surface(.{ .x = 2, .y = 2, .width = size.width - 2, .height = 1 });
        self.input.focused = self.focus == .input;
        try self.input.draw(&input_surface);
        if (size.height < 5) return;

        _ = try surface.putText(.{ .x = 0, .y = 4 }, "Editor", accent, .narrow);
        var editor_surface = surface.surface(self.editorRect(size));
        self.editor.focused = self.focus == .editor;
        _ = self.editor.layout(editor_surface.size());
        try self.editor.draw(&editor_surface);

        if (self.graphics_available) {
            if (graphics_demo.Layout.forSize(size)) |layout_| {
                _ = try surface.putText(.{ .x = 0, .y = layout_.heading_y }, "Graphics", accent, .narrow);
                try surface.putKittyImage(layout_.placeholderRect(), .{ .image_id = 4_001, .placement_id = 10 });
            }
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const graphics_medium = try parseGraphicsMedium(args);
    var graphics_fixture: ?graphics_demo.Fixture = if (graphics_medium) |medium|
        try graphics_demo.Fixture.init(medium)
    else
        null;
    defer if (graphics_fixture) |*fixture| fixture.deinit();
    const io = init.io;
    const tty = try openControllingTerminal();
    defer tty.close(io);
    const size = try tui.terminal.querySize(tty);
    if (size.width > 240 or size.height > 80) return error.TerminalTooLarge;
    var session = try tui.terminal.Session.init(tty, .{ .mouse = true, .focus_events = true });

    runInteractive(
        io,
        tty,
        size,
        &session,
        if (graphics_fixture) |*fixture| fixture else null,
    ) catch |err| {
        _ = session.emergencyRestore(tty.handle);
        return err;
    };
}

fn runInteractive(
    io: std.Io,
    tty: std.Io.File,
    initial_size: tui.render.Size,
    session: *tui.terminal.Session,
    graphics_fixture: ?*const graphics_demo.Fixture,
) !void {
    var renderer_storage: tui.render.FixedRendererStorage(240, 80, 512, 64) = .{};
    var renderer = try tui.render.Renderer.init(renderer_storage.slices(), initial_size);
    defer renderer.deinit();
    var input_storage: tui.editor.FixedStorage(256) = .{};
    var input_model = try tui.editor.Model.initSingleLine(input_storage.slices(), "Ada");
    var editor_storage: tui.editor.FixedStorage(2048) = .{};
    var editor_model = try tui.editor.Model.init(
        editor_storage.slices(),
        "Caller-owned indexed UTF-8.\nUnicode navigation: café · 世界 · 👋\nNo steady-state allocation.",
    );
    var application = DemoApp.init(&input_model, &editor_model);
    application.graphics_requested = graphics_fixture != null;
    var showcase_storage: graphics_demo.Showcase = undefined;
    const showcase: ?*graphics_demo.Showcase = if (graphics_fixture) |fixture| value: {
        showcase_storage = graphics_demo.Showcase.init(fixture);
        break :value &showcase_storage;
    } else null;
    var driver: tui.app.Driver = .{};

    var read_buffer: [512]u8 = undefined;
    var timers: [3]tui.runtime.TimerSlot = undefined;
    var signals = try tui.runtime.SignalSource.init(io, .{});
    defer signals.deinit() catch |err| std.log.err("signal cleanup failed: {s}", .{@errorName(err)});
    var runtime = try tui.runtime.Posix.init(io, tty, &read_buffer, &timers, .{
        .resize = .{ .file = tty, .initial_size = initial_size },
        .signals = &signals,
    });
    defer runtime.deinit();

    var negotiator = tui.terminal.CapabilityNegotiator.init(.{});
    var kitty_update_pending = false;
    var graphics_start_pending = false;
    var pending_resize: ?tui.render.Size = null;
    var recovery_requested = false;
    var quit_error: ?error{TerminalTooLarge} = null;
    var lifecycle: Lifecycle = .entering;
    var output: PendingOutput = .none;
    try session.beginKittyKeyboard(false);
    try session.beginEnter();

    while (true) {
        const pending_output = output.bytes();
        const source = [_]tui.runtime.PollSource{.{
            .file = tty,
            .interest = .{ .write = pending_output.len != 0 },
        }};
        var poll_storage: [4]tui.runtime.PollSlot = undefined;
        const negotiated = negotiator.capabilities();
        const graphics_waiting = if (showcase) |graphics| graphics.waitingForReply() else false;
        const graphics_work = if (showcase) |graphics| graphics.hasWork() else false;
        const cpu_work_pending = output.idle() and switch (lifecycle) {
            .running => !graphics_waiting and (driver.pending() != .ignored or
                renderer.needsPresentation(negotiated) or kitty_update_pending or
                graphics_start_pending or graphics_work or pending_resize != null or
                recovery_requested or application.quit),
            .entering, .draining, .leaving => true,
            .waiting_continue => false,
        };
        const event = if (cpu_work_pending)
            try runtime.pollWithSources(&source, &poll_storage)
        else
            try runtime.stepWithSources(&source, &poll_storage);

        if (event) |value| switch (value) {
            .input => |input_event| {
                const previous = negotiator.capabilities();
                if (showcase) |graphics| {
                    graphics.observe(input_event);
                    if (!graphics.needsReply()) _ = runtime.cancelTimer(graphics_reply_timer_id);
                }
                _ = negotiator.observe(input_event);
                if (!std.meta.eql(previous, negotiator.capabilities())) {
                    const current = negotiator.capabilities();
                    application.graphics_available = current.kitty_graphics;
                    if (!previous.kitty_graphics and current.kitty_graphics) {
                        graphics_start_pending = true;
                    }
                    kitty_update_pending = true;
                    driver.schedule(.redraw);
                }
                if (!negotiator.queriesPending()) _ = runtime.cancelTimer(negotiation_timer_id);
                if (lifecycle.acceptsApplicationInput()) _ = driver.dispatch(&application, input_event);
            },
            .input_failure => if (lifecycle.acceptsApplicationInput()) {
                _ = driver.dispatch(&application, .malformed);
            },
            .resize => |new_size| pending_resize = new_size,
            .timer => |timer| {
                if (timer.id == negotiation_timer_id) {
                    negotiator.cancelQueries();
                } else if (timer.id == cleanup_timer_id and lifecycle.cleanupActive()) {
                    return error.CleanupTimeout;
                } else if (timer.id == graphics_reply_timer_id) {
                    if (showcase) |graphics| if (graphics.needsReply()) graphics.failLocalUpload("Local image reply timed out");
                }
            },
            .signal => |signal| switch (signal) {
                .interrupt, .terminate => if (lifecycle.requestCleanup(.quit)) {
                    try beginCleanup(&runtime, session, showcase);
                },
                .suspend_requested => if (lifecycle.acceptsApplicationInput()) {
                    if (lifecycle.requestCleanup(.@"suspend")) try beginCleanup(&runtime, session, showcase);
                },
                .continued => switch (lifecycle) {
                    .waiting_continue => {
                        try session.beginKittyKeyboard(false);
                        try session.beginEnter();
                        lifecycle = .entering;
                        driver.schedule(.redraw);
                        try renderer.invalidateTerminal();
                    },
                    .entering, .running => recovery_requested = true,
                    .draining, .leaving => {},
                },
            },
            .eof => if (lifecycle.requestCleanup(.quit)) {
                try beginCleanup(&runtime, session, showcase);
            },
            .wakeup, .ready => {},
        };

        if (showcase) |graphics| {
            const message = graphics.errorMessage();
            const visible = message[0..@min(message.len, application.graphics_error.len)];
            if (!std.mem.eql(u8, visible, application.graphics_error[0..application.graphics_error_len])) {
                @memcpy(application.graphics_error[0..visible.len], visible);
                application.graphics_error_len = @intCast(visible.len);
                driver.schedule(.redraw);
            }
        }

        if (lifecycle.acceptsApplicationInput() and application.quit) {
            if (lifecycle.requestCleanup(.quit)) try beginCleanup(&runtime, session, showcase);
        }

        if (lifecycle.acceptsApplicationInput()) {
            if (pending_resize) |new_size| {
                if (output.idle() and (showcase == null or !showcase.?.hasWork())) {
                    if (new_size.width > 240 or new_size.height > 80) {
                        // Capacity rejection is an orderly exit: images and
                        // terminal modes still need their normal cleanup.
                        quit_error = error.TerminalTooLarge;
                        if (lifecycle.requestCleanup(.quit)) try beginCleanup(&runtime, session, showcase);
                    } else {
                        if (renderer.isPresenting()) try renderer.abortPresentation();
                        _ = try driver.resize(&renderer, new_size);
                    }
                    pending_resize = null;
                }
            }
        }

        // As with resize, finish the graphics burst before recovery can clear
        // the screen or restart it with a new anchor.
        if (lifecycle.isRunning() and recovery_requested and output.idle() and
            (showcase == null or !showcase.?.hasWork()))
        {
            if (renderer.isPresenting()) {
                try renderer.abortPresentation();
            }
            try renderer.invalidateTerminal();
            application.graphics_available = false;
            graphics_start_pending = false;
            output = .{ .negotiation = if (showcase != null)
                try negotiator.beginGraphicsQueries(graphics_demo.probe_image_id)
            else
                negotiator.beginQueries() };
            driver.schedule(.redraw);
            recovery_requested = false;
        }

        if (output.idle()) switch (lifecycle) {
            .draining => |target| {
                graphics_start_pending = false;
                if (showcase) |graphics| {
                    if (graphics.hasWork()) {
                        if (try graphics.outputStep()) |bytes| {
                            output = .{ .graphics = bytes };
                        } else {
                            _ = graphics.takeOutputInvalidation();
                        }
                        continue;
                    }
                }
                negotiator.cancelQueries();
                _ = runtime.cancelTimer(negotiation_timer_id);
                if (renderer.isPresenting()) {
                    try renderer.abortPresentation();
                }
                try session.beginLeave();
                lifecycle = .{ .leaving = target };
            },
            else => {},
        };

        if (output.idle()) switch (lifecycle) {
            .leaving => |target| {
                if (session.outputStep()) |bytes| {
                    output = .{ .session = bytes };
                } else {
                    _ = runtime.cancelTimer(cleanup_timer_id);
                    if (target == .quit) {
                        if (quit_error) |err| return err;
                        return;
                    }
                    try signals.suspendProcess();
                    lifecycle = .waiting_continue;
                }
            },
            else => {},
        };

        if (output.idle() and lifecycle == .entering) {
            if (session.outputStep()) |bytes| {
                output = .{ .session = bytes };
            } else {
                lifecycle = .running;
                application.graphics_available = false;
                graphics_start_pending = false;
                output = .{ .negotiation = if (showcase != null)
                    try negotiator.beginGraphicsQueries(graphics_demo.probe_image_id)
                else
                    negotiator.beginQueries() };
                driver.schedule(.redraw);
            }
        }

        if (lifecycle.isRunning() and output.idle() and !renderer.isPresenting()) {
            // Acknowledging the final byte does not finish a Session transition:
            // outputStep must reach null before another capability update starts.
            if (session.outputStep()) |bytes| {
                output = .{ .session = bytes };
            } else if (kitty_update_pending) {
                try session.beginKittyKeyboard(negotiator.capabilities().kitty_keyboard);
                kitty_update_pending = false;
                if (session.outputStep()) |bytes| output = .{ .session = bytes };
            }
        }

        if (lifecycle.isRunning() and output.idle() and
            driver.pending() != .ignored and !renderer.isPresenting())
        {
            try driver.prepare(&renderer, &application);
        }

        if (lifecycle.isRunning() and output.idle()) {
            if (showcase) |graphics| {
                if (graphics_start_pending and !renderer.isPresenting() and
                    !renderer.needsPresentation(negotiator.capabilities()))
                {
                    try restartGraphics(graphics, renderer.size(), &runtime);
                    graphics_start_pending = false;
                }
                if (!graphics_start_pending) {
                    if (try graphics.outputStep()) |bytes| {
                        output = .{ .graphics = bytes };
                    } else if (graphics.takeOutputInvalidation()) {
                        try renderer.invalidateOutputState();
                    }
                }
            }
        }

        if (lifecycle.isRunning() and output.idle() and
            (showcase == null or !showcase.?.hasWork()) and
            (renderer.isPresenting() or
                (driver.pending() == .ignored and renderer.needsPresentation(negotiator.capabilities()))))
        {
            if (!renderer.isPresenting()) try renderer.beginPresentation(negotiator.capabilities());
            switch (try renderer.presentStep(presentation_work_budget)) {
                .output => |bytes| output = .{ .renderer = bytes },
                .yielded => {},
                .cleared => if (showcase) |graphics| {
                    if (negotiator.capabilities().kitty_graphics) {
                        try restartGraphics(graphics, renderer.size(), &runtime);
                        graphics_start_pending = false;
                    }
                },
                .complete => {},
            }
        }

        if (!output.idle()) {
            const bytes = output.bytes();
            std.debug.assert(bytes.len != 0);
            const accepted = writeOnce(tty.handle, bytes) catch |err| switch (err) {
                error.WouldBlock, error.Interrupted => continue,
                else => return err,
            };
            if (accepted == 0) return error.NoWriteProgress;
            const completed = std.meta.activeTag(output);
            switch (output) {
                .none => unreachable,
                .session => try session.consumeOutput(accepted),
                .graphics => if (showcase) |graphics| try graphics.consumeOutput(accepted) else unreachable,
                .renderer => try renderer.consumePresentation(accepted),
                .negotiation => {},
            }
            const remaining = bytes[accepted..];
            if (remaining.len == 0) {
                output = .none;
                if (completed == .negotiation) {
                    var deadline = runtime.now();
                    deadline.raw.nanoseconds = try std.math.add(
                        i96,
                        deadline.raw.nanoseconds,
                        negotiation_timeout_ns,
                    );
                    _ = try runtime.setTimer(negotiation_timer_id, deadline);
                }
            } else {
                output = switch (completed) {
                    .none => unreachable,
                    .session => .{ .session = remaining },
                    .negotiation => .{ .negotiation = remaining },
                    .graphics => .{ .graphics = remaining },
                    .renderer => .{ .renderer = remaining },
                };
            }
        }
    }
}

fn beginCleanup(
    runtime: *tui.runtime.Posix,
    session: *tui.terminal.Session,
    showcase: ?*graphics_demo.Showcase,
) !void {
    if (showcase) |graphics| graphics.requestCleanup();
    _ = runtime.cancelTimer(graphics_reply_timer_id);
    try session.restoreTermios();
    var deadline = runtime.now();
    deadline.raw.nanoseconds = try std.math.add(i96, deadline.raw.nanoseconds, cleanup_timeout_ns);
    _ = try runtime.setTimer(cleanup_timer_id, deadline);
}

fn restartGraphics(graphics: *graphics_demo.Showcase, size: tui.render.Size, runtime: *tui.runtime.Posix) !void {
    try graphics.restart(size);
    if (graphics.needsReply()) {
        var deadline = runtime.now();
        deadline.raw.nanoseconds = try std.math.add(i96, deadline.raw.nanoseconds, negotiation_timeout_ns);
        _ = try runtime.setTimer(graphics_reply_timer_id, deadline);
    }
}

fn parseGraphicsMedium(args: []const []const u8) !?graphics_demo.Medium {
    if (args.len == 1) return null;
    if (args.len != 2) return error.InvalidArguments;
    const prefix = "--graphics=";
    if (!std.mem.startsWith(u8, args[1], prefix)) return error.InvalidArguments;
    const value = args[1][prefix.len..];
    if (std.mem.eql(u8, value, "direct")) return .direct;
    if (std.mem.eql(u8, value, "file")) return .file;
    if (std.mem.eql(u8, value, "temporary-file")) return .temporary_file;
    if (std.mem.eql(u8, value, "shared-memory")) return .shared_memory;
    return error.InvalidArguments;
}

fn openControllingTerminal() !std.Io.File {
    const result = std.os.linux.open(
        "/dev/tty",
        .{ .ACCMODE = .RDWR, .NONBLOCK = true, .CLOEXEC = true },
        0,
    );
    return switch (std.os.linux.errno(result)) {
        .SUCCESS => .{ .handle = @intCast(result), .flags = .{ .nonblocking = true } },
        .INTR => error.Interrupted,
        .ACCES, .NOENT, .NXIO, .NOTTY => error.ControllingTerminalUnavailable,
        .MFILE, .NFILE, .NOMEM => error.SystemResources,
        else => error.Unexpected,
    };
}

fn writeOnce(fd: std.posix.fd_t, bytes: []const u8) !usize {
    const result = std.posix.system.write(fd, bytes.ptr, bytes.len);
    return switch (std.posix.errno(result)) {
        .SUCCESS => @intCast(result),
        .INTR => error.Interrupted,
        .AGAIN => error.WouldBlock,
        .BADF => error.InvalidDescriptor,
        .IO => error.InputOutput,
        .PIPE => error.BrokenPipe,
        .NOBUFS, .NOMEM => error.SystemResources,
        else => error.Unexpected,
    };
}
