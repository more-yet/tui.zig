//! Each scenario owns a private PTY, job-control parent, demo, and oracle.
const std = @import("std");
const tui = @import("tui");
const Oracle = @import("oracle.zig");
const expect = std.testing.expect;
const graphics_checks = @import("graphics_checks.zig");
pub const std_options: std.Options = .{ .log_level = .warn };

extern "c" fn waitpid(pid: std.posix.pid_t, status: *c_int, flags: c_int) std.posix.pid_t;

const Scenario = enum { edit_resize, escape, interrupt, terminate, suspend_resume, oversize, silent, forced_cleanup, graphics_direct, graphics_file, graphics_temporary_file, graphics_shared_memory, graphics_oversize, graphics_reply_timeout, graphics_write_failure };
const initial_size: tui.render.Size = .{ .width = 60, .height = 16 };
const ready_text = "TUI_TEST_READY";

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4) return error.InvalidArguments;
    const scenario = std.meta.stringToEnum(Scenario, args[3]) orelse return error.InvalidScenario;
    const graphics_arg: ?[]const u8 = switch (scenario) {
        .graphics_direct => "--graphics=direct",
        .graphics_file, .graphics_oversize, .graphics_reply_timeout, .graphics_write_failure => "--graphics=file",
        .graphics_temporary_file => "--graphics=temporary-file",
        .graphics_shared_memory => "--graphics=shared-memory",
        else => null,
    };
    // If the job-control parent is force-killed, this process adopts and reaps
    // its known demo. The demo also uses PDEATHSIG to bound its lifetime.
    if (std.os.linux.prctl(@intFromEnum(std.os.linux.PR.SET_CHILD_SUBREAPER), 1, 0, 0, 0) != 0) return error.SubreaperFailed;

    // SIGCHLD wakes the loop; PtyProcess exclusively reaps the fixture.
    var mask = std.posix.sigemptyset();
    std.posix.sigaddset(&mask, .CHLD);
    var old_mask: std.posix.sigset_t = undefined;
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &mask, &old_mask);
    defer std.posix.sigprocmask(std.posix.SIG.SETMASK, &old_mask, null);
    const signal_fd = try std.posix.signalfd(-1, &mask, std.os.linux.SFD.NONBLOCK | std.os.linux.SFD.CLOEXEC);
    defer (std.Io.File{ .handle = signal_fd, .flags = .{ .nonblocking = true } }).close(init.io);

    var process = tui.subprocess.PtyProcess.init(init.io);
    defer cleanup(&process);
    var pointers: [5]?[*:0]const u8 = undefined;
    var bytes: [8192]u8 = undefined;
    var storage = tui.subprocess.SpawnStorage.init(&pointers, &bytes);
    const child_args = [_][]const u8{ args[1], args[2], graphics_arg orelse "", "--limit-file-size" };
    const child_arg_count: usize = if (scenario == .graphics_write_failure) 4 else if (graphics_arg != null) 3 else 2;
    try process.spawnBeforeThreads(.{
        .argv = child_args[0..child_arg_count],
        // Capabilities come from protocol replies in a reproducible environment.
        .environ = .empty,
    }, &storage, .{ .size = initial_size });

    var oracle: Oracle = undefined;
    try oracle.init(init.gpa, .{
        .io = init.io,
        .cols = initial_size.width,
        .rows = initial_size.height,
        .replies = scenario != .silent,
        .images = if (graphics_arg != null) .allWithTempDir("/tmp") else null,
    });
    defer oracle.deinit();
    var harness: Harness = .{
        .process = &process,
        .oracle = &oracle,
        .signal_fd = signal_fd,
        .suppress_local_reply = scenario == .graphics_reply_timeout,
    };
    defer harness.releaseDemo();
    runScenario(&harness, scenario) catch |err| {
        const screen = try oracle.terminal.plainString(init.gpa);
        defer init.gpa.free(screen);
        // Escape terminal control bytes before printing diagnostics.
        std.debug.print("FAIL PTY {s}, waiting for {s}: {s}\nscreen: \"{f}\"\n", .{
            @tagName(scenario), harness.phase, @errorName(err), std.zig.fmtString(screen),
        });
        return err;
    };
    // Check the descriptor release, not just a successful child exit.
    const master_fd = (try process.borrowedMaster()).handle;
    try process.deinit();
    try expect(process.state() == .empty);
    try expect(process.master == null);
    try expect(std.posix.errno(std.posix.system.fcntl(master_fd, std.posix.F.GETFD)) == .BADF);
}

fn runScenario(h: *Harness, scenario: Scenario) !void {
    try h.waitText(ready_text);
    const ready = try h.oracle.terminal.plainString(h.oracle.allocator);
    defer h.oracle.allocator.free(ready);
    const pid_text = ready[(std.mem.indexOf(u8, ready, "pid=") orelse return error.MissingDemoPid) + 4 ..];
    const pid_end = std.mem.indexOfAny(u8, pid_text, "\r\n ") orelse pid_text.len;
    const pid = try std.fmt.parseInt(std.posix.pid_t, pid_text[0..pid_end], 10);
    if (pid <= 1) return error.InvalidDemoPid;
    const fd = std.os.linux.pidfd_open(pid, 0);
    if (std.os.linux.errno(fd) != .SUCCESS) return error.PidfdFailed;
    h.demo = .{ .pid = pid, .fd = @intCast(fd) };
    const master = try h.process.borrowedMaster();
    const original = try std.posix.tcgetattr(master.handle);
    try expect(original.lflag.ICANON and original.lflag.ECHO);
    try expect(std.meta.eql(initial_size, try tui.terminal.querySize(master)));

    if (scenario == .forced_cleanup) {
        // A stopped child cannot cooperate; exercise the real deadline cleanup.
        try h.process.sendSignal(.STOP);
        h.phase = "stopped fixture";
        const deadline = h.deadline(5000);
        while (!h.stopped) try h.turn(deadline);
        try h.process.killAndWait(h.deadline(5000));
        try h.reapDemo();
        try expect(h.process.isReaped());
        try std.testing.expectError(error.AlreadyReaped, h.process.poll());
        return;
    }

    try h.send("\n", h.deadline(5000));
    if (scenario == .graphics_write_failure) {
        try finishScenario(h, original, 1, "GraphicsFixtureWriteFailed");
        return;
    }
    try h.waitText("No steady-state allocation.");
    try h.waitActive(scenario != .silent);
    const raw = try std.posix.tcgetattr(master.handle);
    try expect(!raw.lflag.ICANON and !raw.lflag.ECHO and !raw.lflag.ISIG);
    try expect(!raw.oflag.OPOST);

    var expected_exit: u8 = 0;
    switch (scenario) {
        .edit_resize => {
            // Kitty Ctrl+A, then bracketed paste with multicodepoint graphemes.
            try h.sendFragmented("\x1b[97;5u\x1b[200~Ae\u{301}界\x1b[201~");
            try h.waitText("Ae\u{301}界");
            try h.expectRow(2, "  Ae\u{301}界");
            try h.sendFragmented("\x1b[D\x7f");
            try h.waitText("A界");
            try h.expectRow(2, "  A界");
            try h.sendFragmented("\x1b[CX");
            try h.waitText("A界X");
            try h.expectRow(2, "  A界X");

            // The trailing Y acknowledges input after the reports. Check the
            // whole row before switching focus, so stray text cannot be hidden.
            try h.sendFragmented("\x1b[O\x1b[I\x1b[<0;1;1M\x1b[<0;1;1mY");
            try h.waitText("A界XY");
            try h.expectRow(2, "  A界XY");

            // Tab moves focus; paste replaces the entire multiline editor.
            const line = "0123456789 abcdefghij klmnopqrst uvwxyz END";
            try h.sendFragmented("\t\x01\x1b[200~" ++ line ++ "\nsecond cafe\u{301}\x1b[201~");
            try h.waitText(line);
            try h.waitText("second cafe\u{301}");
            // Move to the first line's end so shrinking must pan to show END.
            try h.sendFragmented("\x1b[A\x1b[F");
            try h.resize(.{ .width = 32, .height = 10 });
            try h.waitText("END");
            try h.resize(.{ .width = 80, .height = 14 });
            // Growing preserves the editor's scroll offset. Home deliberately
            // reveals the prefix; the full line now requires a wider repaint.
            try h.sendFragmented("\x1b[H");
            try h.waitText(line);
            try h.waitText("second cafe\u{301}");
            try h.expectRow(5, "  " ++ line);
            try h.expectRow(6, "  second cafe\u{301}");
            try h.send("\x11", h.deadline(5000));
        },
        .escape => try h.send("\x1b", h.deadline(5000)),
        .interrupt => try h.process.sendSignal(.INT),
        .terminate => try h.process.sendSignal(.TERM),
        .suspend_resume => {
            try h.suspendResume(original);
            try h.waitText("No steady-state allocation.");
            try h.sendFragmented("\x01resumed");
            try h.waitText("resumed");
            try h.send("\x11", h.deadline(5000));
        },
        .oversize, .graphics_oversize => {
            if (scenario == .graphics_oversize) try h.waitGraphics();
            try h.process.setSize(.{ .width = 241, .height = 81 });
            expected_exit = 1;
        },
        .graphics_reply_timeout => {
            try h.waitText("Local image reply timed out");
            try expect(h.dropped_local_reply);
            try graphics_checks.expectEmpty(h.oracle);
            try h.sendFragmented("\x01still responsive");
            try h.waitText("still responsive");
            try h.send("\x11", h.deadline(5000));
        },
        .silent => {
            // Withhold all replies beyond the demo's 250ms query deadline.
            // Poll continues servicing output and child status; no sleeps.
            h.phase = "silent negotiation deadline";
            const deadline = h.deadline(400);
            while (h.remainingMillis(deadline) > 0) {
                if (h.exit != null) return error.EarlyExit;
                h.turn(deadline) catch |err| switch (err) {
                    error.Timeout => break,
                    else => return err,
                };
            }
            try expect(h.oracle.terminal.screens.active.kitty_keyboard.current().int() == 0);
            try h.sendFragmented("\x01plain input");
            try h.waitText("plain input");
            try h.send("\x11", h.deadline(5000));
        },
        .graphics_direct, .graphics_file, .graphics_temporary_file, .graphics_shared_memory => {
            try h.waitGraphics();
            try graphics_checks.expectShowcase(h.oracle);
            var path_bytes: [192:0]u8 = undefined;
            const path = if (scenario == .graphics_shared_memory)
                try std.fmt.bufPrintZ(&path_bytes, "/dev/shm/tui-zig-graphics-{d}", .{pid})
            else
                try std.fmt.bufPrintZ(&path_bytes, "/tmp/tui-zig-tty-graphics-protocol-{d}.rgba", .{pid});
            try expect(try fileExists(path) == (scenario == .graphics_file));

            try h.resize(.{ .width = 32, .height = 12 });
            try h.waitGraphics();
            try graphics_checks.expectShowcase(h.oracle);
            try h.resize(.{ .width = 32, .height = 11 });
            try h.waitText("Graphics need 20x12");
            try graphics_checks.expectEmpty(h.oracle);
            try h.resize(initial_size);
            try h.waitGraphics();
            try graphics_checks.expectShowcase(h.oracle);
            try h.suspendResume(original);
            try h.waitGraphics();
            try graphics_checks.expectShowcase(h.oracle);
            try h.send("\x11", h.deadline(5000));
        },
        .forced_cleanup, .graphics_write_failure => unreachable,
    }
    try finishScenario(h, original, expected_exit, ready_text);
}

fn finishScenario(h: *Harness, original: std.posix.termios, expected_exit: u8, primary_text: []const u8) !void {
    h.phase = "exit and PTY EOF";
    const deadline = h.deadline(5000);
    while (h.exit == null or !h.process.eof) try h.turn(deadline);
    try expect(h.exit.? == .exited);
    try std.testing.expectEqual(expected_exit, h.exit.?.exited);
    try expect(h.process.isReaped());
    try std.testing.expectError(error.AlreadyReaped, h.process.poll());
    try h.expectRestored(original, primary_text);
    try graphics_checks.expectEmpty(h.oracle);
    const pid = h.demo.?.pid;
    try h.reapDemo();
    var local_path: [192:0]u8 = undefined;
    try expect(!try fileExists(try std.fmt.bufPrintZ(&local_path, "/tmp/tui-zig-tty-graphics-protocol-{d}.rgba", .{pid})));
    try expect(!try fileExists(try std.fmt.bufPrintZ(&local_path, "/dev/shm/tui-zig-graphics-{d}", .{pid})));
}

const Harness = struct {
    process: *tui.subprocess.PtyProcess,
    oracle: *Oracle,
    signal_fd: std.posix.fd_t,
    phase: []const u8 = "startup",
    exit: ?tui.subprocess.Exit = null,
    stopped: bool = false,
    output_bytes: usize = 0,
    demo: ?struct { pid: std.posix.pid_t, fd: std.posix.fd_t } = null,
    graphics_generation: u64 = 0,
    suppress_local_reply: bool = false,
    dropped_local_reply: bool = false,

    fn releaseDemo(self: *Harness) void {
        if (self.demo) |demo| {
            // A pidfd pins identity even after exit. Failure cleanup kills the
            // demo before its parent, then reaps it if it was adopted.
            switch (std.os.linux.errno(std.os.linux.pidfd_send_signal(demo.fd, .KILL, null, 0))) {
                .SUCCESS, .SRCH => {},
                else => std.debug.panic("failed to terminate owned demo", .{}),
            }
            if (self.process.state() == .running) self.process.killAndWait(self.deadline(5000)) catch |err| {
                std.debug.panic("fixture cleanup: {s}", .{@errorName(err)});
            };
            self.reapDemo() catch |err| std.debug.panic("demo cleanup: {s}", .{@errorName(err)});
        }
    }

    fn reapDemo(self: *Harness) !void {
        const until = self.deadline(5000);
        const demo = self.demo.?;
        var descriptors = [_]std.posix.pollfd{.{ .fd = demo.fd, .events = std.posix.POLL.IN, .revents = 0 }};
        while (descriptors[0].revents & std.posix.POLL.IN == 0) {
            if (self.remainingMillis(until) == 0) return error.DemoExitTimeout;
            try poll(&descriptors, self.remainingMillis(until));
        }
        var status: c_int = 0;
        const result = waitpid(demo.pid, &status, std.posix.W.NOHANG);
        if (result == demo.pid) {
            try expect(std.posix.W.IFEXITED(@bitCast(status)) or std.posix.W.IFSIGNALED(@bitCast(status)));
        } else if (result != -1 or std.posix.errno(result) != .CHILD) return error.DemoNotReaped;
        _ = std.os.linux.close(demo.fd);
        self.demo = null;
    }

    fn suspendResume(self: *Harness, original: std.posix.termios) !void {
        try self.process.sendSignal(.TSTP);
        try self.waitText("TUI_TEST_STOPPED");
        try self.expectRestored(original, ready_text);
        try graphics_checks.expectEmpty(self.oracle);
        try self.send("\n", self.deadline(5000));
        try self.waitActive(true);
    }

    fn waitGraphics(self: *Harness) !void {
        self.phase = "graphics replay";
        const until = self.deadline(5000);
        while (self.oracle.terminal.screens.active.kitty_images.generation == self.graphics_generation or
            !graphics_checks.showcaseReady(self.oracle))
        {
            if (self.exit != null) return error.EarlyExit;
            try self.turn(until);
        }
        self.graphics_generation = self.oracle.terminal.screens.active.kitty_images.generation;
    }

    fn deadline(self: *Harness, milliseconds: i64) std.Io.Clock.Timestamp {
        return .fromNow(self.process.io, .{ .raw = .fromMilliseconds(milliseconds), .clock = .awake });
    }

    fn remainingMillis(self: *Harness, until: std.Io.Clock.Timestamp) i32 {
        const remaining = until.raw.nanoseconds - std.Io.Clock.awake.now(self.process.io).nanoseconds;
        if (remaining <= 0) return 0;
        return @intCast(@min(std.math.maxInt(i32), @divTrunc(remaining + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
    }

    fn waitText(self: *Harness, text: []const u8) !void {
        self.phase = text;
        const until = self.deadline(5000);
        while (true) {
            const screen = try self.oracle.terminal.plainString(self.oracle.allocator);
            defer self.oracle.allocator.free(screen);
            if (std.mem.indexOf(u8, screen, text) != null and self.oracle.stream.ground() and
                !self.oracle.terminal.modes.get(.synchronized_output)) return;
            if (self.exit != null) return error.EarlyExit;
            try self.turn(until);
        }
    }

    fn waitActive(self: *Harness, keyboard: bool) !void {
        self.phase = "active terminal modes";
        const until = self.deadline(5000);
        while (true) {
            const t = &self.oracle.terminal;
            if (t.screens.active_key == .alternate and t.modes.get(.bracketed_paste) and
                t.modes.get(.focus_event) and t.modes.get(.mouse_event_button) and
                t.modes.get(.mouse_format_sgr) and
                (!keyboard or t.screens.active.kitty_keyboard.current().int() == 1)) return;
            if (self.exit != null) return error.EarlyExit;
            try self.turn(until);
        }
    }

    fn expectRow(self: *Harness, row_index: usize, expected: []const u8) !void {
        const screen = try self.oracle.terminal.plainString(self.oracle.allocator);
        defer self.oracle.allocator.free(screen);
        var lines = std.mem.splitScalar(u8, screen, '\n');
        for (0..row_index) |_| _ = lines.next() orelse return error.MissingRow;
        const line = lines.next() orelse return error.MissingRow;
        try std.testing.expectEqualStrings(expected, std.mem.trimEnd(u8, line, " "));
    }

    fn resize(self: *Harness, size: tui.render.Size) !void {
        try self.oracle.terminal.resize(self.oracle.allocator, .{ .cols = size.width, .rows = size.height });
        self.graphics_generation = self.oracle.terminal.screens.active.kitty_images.generation;
        try self.process.setSize(size);
    }

    fn expectRestored(self: *Harness, original: std.posix.termios, primary_text: []const u8) !void {
        const actual = try std.posix.tcgetattr((try self.process.borrowedMaster()).handle);
        // Compare defined fields, not ABI padding. glibc may leave padding unset.
        inline for (std.meta.fields(std.posix.termios)) |field| {
            try expect(std.meta.eql(@field(original, field.name), @field(actual, field.name)));
        }
        const t = &self.oracle.terminal;
        try expect(t.screens.active_key == .primary);
        try expect(t.modes.get(.cursor_visible));
        inline for (.{ .bracketed_paste, .focus_event, .mouse_event_button, .mouse_format_sgr, .synchronized_output }) |mode| {
            try expect(!t.modes.get(mode));
        }
        try expect(t.screens.active.kitty_keyboard.current().int() == 0);
        if (t.screens.all.get(.alternate)) |alternate| try expect(alternate.kitty_keyboard.current().int() == 0);
        try expect(self.oracle.stream.ground());
        const screen = try t.plainString(self.oracle.allocator);
        defer self.oracle.allocator.free(screen);
        try expect(std.mem.indexOf(u8, screen, primary_text) != null);
    }

    fn sendFragmented(self: *Harness, bytes: []const u8) !void {
        const until = self.deadline(5000);
        // Kernel reads may coalesce these writes. The in-memory tests separately
        // guarantee parser fragmentation at every output-byte boundary.
        for (bytes, 0..) |_, i| try self.send(bytes[i..][0..1], until);
    }

    fn send(self: *Harness, bytes: []const u8, until: std.Io.Clock.Timestamp) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            if (self.remainingMillis(until) == 0) return error.Timeout;
            const result = self.process.write(bytes[offset..]) catch |err| switch (err) {
                error.Interrupted => continue,
                else => return err,
            };
            switch (result) {
                .written => |n| {
                    if (n == 0) return error.NoWriteProgress;
                    offset += n;
                },
                .closed => return error.InputClosed,
                .would_block => {
                    var descriptors = [_]std.posix.pollfd{.{
                        .fd = (try self.process.borrowedMaster()).handle,
                        .events = std.posix.POLL.OUT,
                        .revents = 0,
                    }};
                    try poll(&descriptors, self.remainingMillis(until));
                },
            }
        }
    }

    fn turn(self: *Harness, until: std.Io.Clock.Timestamp) !void {
        if (self.remainingMillis(until) == 0) return error.Timeout;
        var progressed = false;
        if (!self.process.isReaped()) {
            if (try self.process.poll()) |event| {
                progressed = true;
                switch (event) {
                    .exit => |status| self.exit = status,
                    .stopped => self.stopped = true,
                    .continued => self.stopped = false,
                }
            }
        }
        var buffer: [4096]u8 = undefined;
        // Bound both work per turn and total child output, including bad loops.
        for (0..16) |_| {
            const result = self.process.read(&buffer) catch |err| switch (err) {
                error.Interrupted => break,
                else => return err,
            };
            switch (result) {
                .data => |data| {
                    progressed = true;
                    self.output_bytes += data.len;
                    if (self.output_bytes > 1024 * 1024) return error.OutputLimit;
                    try self.oracle.write(data);
                    const replies = self.oracle.takeReplies();
                    const local_ok = "\x1b_Gi=4001,p=1;OK\x1b\\";
                    const drop = if (self.suppress_local_reply) std.mem.indexOf(u8, replies, local_ok) else null;
                    if (drop) |offset| {
                        self.dropped_local_reply = true;
                        try self.send(replies[0..offset], until);
                        try self.send(replies[offset + local_ok.len ..], until);
                    } else try self.send(replies, until);
                },
                .eof, .would_block => break,
            }
        }
        if (progressed or self.exit != null and self.process.eof) return;
        var descriptors = [_]std.posix.pollfd{
            .{ .fd = if (self.process.eof) -1 else (try self.process.borrowedMaster()).handle, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = self.signal_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };
        try poll(&descriptors, self.remainingMillis(until));
        if (descriptors[1].revents & std.posix.POLL.IN != 0) {
            var records: [8]std.os.linux.signalfd_siginfo = undefined;
            const n = std.posix.system.read(self.signal_fd, std.mem.asBytes(&records), @sizeOf(@TypeOf(records)));
            switch (std.posix.errno(n)) {
                .SUCCESS => {},
                .INTR, .AGAIN => {},
                else => return error.SignalReadFailed,
            }
        }
    }
};

fn fileExists(path: [:0]const u8) !bool {
    const result = std.os.linux.open(path.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true }, 0);
    switch (std.os.linux.errno(result)) {
        .SUCCESS => {
            _ = std.os.linux.close(@intCast(result));
            return true;
        },
        .NOENT => return false,
        else => return error.FixtureFileCheckFailed,
    }
}

fn poll(descriptors: []std.posix.pollfd, timeout_ms: i32) !void {
    const n = std.posix.system.poll(descriptors.ptr, descriptors.len, timeout_ms);
    switch (std.posix.errno(n)) {
        .SUCCESS => {},
        .INTR => return,
        else => return error.PollFailed,
    }
    for (descriptors) |descriptor| if (descriptor.revents & std.posix.POLL.NVAL != 0) return error.InvalidDescriptor;
}

fn cleanup(process: *tui.subprocess.PtyProcess) void {
    if (process.state() == .running) {
        process.killAndWait(.fromNow(process.io, .{ .raw = .fromSeconds(5), .clock = .awake })) catch |err| {
            std.debug.panic("failed to reap private PTY child: {s}", .{@errorName(err)});
        };
    }
    process.deinit() catch |err| std.debug.panic("failed to release private PTY: {s}", .{@errorName(err)});
}
