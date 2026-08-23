const std = @import("std");
const tui = @import("tui");
const fixture = @import("fixture_options");

test "PTY process preserves literal argv and reports resize and exit" {
    var pointer_storage: [4]?[*:0]const u8 = undefined;
    var byte_storage: [512]u8 = undefined;
    var storage = tui.subprocess.SpawnStorage.init(&pointer_storage, &byte_storage);
    const arguments = [_][]const u8{ fixture.fixture_path, "literal; $(not-a-shell) space" };
    var process = try tui.subprocess.PtyProcess.spawnBeforeThreads(
        std.testing.io,
        .{ .argv = &arguments, .environ = std.testing.environ },
        &storage,
        .{ .size = .{ .width = 20, .height = 5 } },
    );
    defer cleanupProcess(&process);

    var output: [2048]u8 = undefined;
    var output_len: usize = 0;
    try readUntil(&process, &output, &output_len, "READY");
    try std.testing.expect(std.mem.indexOf(u8, output[0..output_len], "tty=true,true,true") != null);
    try std.testing.expect(std.mem.indexOf(u8, output[0..output_len], "size=20x5") != null);
    try std.testing.expect(std.mem.indexOf(u8, output[0..output_len], "literal; $(not-a-shell) space") != null);
    try drainToWouldBlock(&process, &output);
    try std.testing.expectEqual(@as(?tui.subprocess.WaitEvent, null), try process.poll());

    try process.setSize(.{ .width = 40, .height = 10 });
    try writeAll(&process, "x\n");
    try readUntil(&process, &output, &output_len, "size=40x10");
    const event = try process.wait();
    try std.testing.expect(event == .exit);
    try std.testing.expectEqual(@as(u8, 7), event.exit.exited);
    try readToEof(&process, &output);
}

test "PTY spawn reports validation and exec failures before returning a child" {
    var pointers: [2]?[*:0]const u8 = undefined;
    var bytes: [64]u8 = undefined;
    var storage = tui.subprocess.SpawnStorage.init(&pointers, &bytes);
    try std.testing.expectError(
        error.ExecutablePathRequired,
        tui.subprocess.PtyProcess.spawnBeforeThreads(
            std.testing.io,
            .{ .argv = &.{"not-a-path"}, .environ = std.testing.environ },
            &storage,
            .{ .size = .{ .width = 10, .height = 2 } },
        ),
    );
    try std.testing.expectError(
        error.FileNotFound,
        tui.subprocess.PtyProcess.spawnBeforeThreads(
            std.testing.io,
            .{ .argv = &.{"/definitely/missing/tui-zig-command"}, .environ = std.testing.environ },
            &storage,
            .{ .size = .{ .width = 10, .height = 2 } },
        ),
    );
}

test "PTY child closes unrelated inherited descriptors" {
    const unrelated_pipe = try std.Io.Threaded.pipe2(.{});
    const unrelated_read = std.Io.File{ .handle = unrelated_pipe[0], .flags = .{ .nonblocking = false } };
    const unrelated_write = std.Io.File{ .handle = unrelated_pipe[1], .flags = .{ .nonblocking = false } };
    defer unrelated_read.close(std.testing.io);
    defer unrelated_write.close(std.testing.io);

    var fd_buffer: [32]u8 = undefined;
    const fd = try std.fmt.bufPrint(&fd_buffer, "{d}", .{unrelated_pipe[0]});
    const arguments = [_][]const u8{ fixture.fixture_path, "check-fd", fd };
    var pointers: [4]?[*:0]const u8 = undefined;
    var bytes: [256]u8 = undefined;
    var storage = tui.subprocess.SpawnStorage.init(&pointers, &bytes);
    var process = try tui.subprocess.PtyProcess.spawnBeforeThreads(
        std.testing.io,
        .{ .argv = &arguments, .environ = std.testing.environ },
        &storage,
        .{ .size = .{ .width = 10, .height = 2 } },
    );
    defer cleanupProcess(&process);

    var output: [128]u8 = undefined;
    var output_len: usize = 0;
    try readUntil(&process, &output, &output_len, "FD_");
    const event = try process.wait();
    try std.testing.expect(event == .exit);
    try std.testing.expectEqual(@as(u8, 0), event.exit.exited);
    try std.testing.expect(std.mem.indexOf(u8, output[0..output_len], "FD_CLOSED") != null);
}

test "PTY termination addresses the child process group" {
    var pointers: [3]?[*:0]const u8 = undefined;
    var bytes: [256]u8 = undefined;
    var storage = tui.subprocess.SpawnStorage.init(&pointers, &bytes);
    const arguments = [_][]const u8{ fixture.fixture_path, "terminate" };
    var process = try tui.subprocess.PtyProcess.spawnBeforeThreads(
        std.testing.io,
        .{ .argv = &arguments, .environ = std.testing.environ },
        &storage,
        .{ .size = .{ .width = 20, .height = 5 } },
    );
    defer cleanupProcess(&process);
    var output: [512]u8 = undefined;
    var output_len: usize = 0;
    try readUntil(&process, &output, &output_len, "READY");
    try process.terminate();
    const event = try process.wait();
    try std.testing.expect(event == .exit);
    try std.testing.expectEqual(std.posix.SIG.TERM, event.exit.signaled);
}

test "PTY wait reports child stop and continuation" {
    var pointers: [3]?[*:0]const u8 = undefined;
    var bytes: [256]u8 = undefined;
    var storage = tui.subprocess.SpawnStorage.init(&pointers, &bytes);
    const arguments = [_][]const u8{ fixture.fixture_path, "stop" };
    var process = try tui.subprocess.PtyProcess.spawnBeforeThreads(
        std.testing.io,
        .{ .argv = &arguments, .environ = std.testing.environ },
        &storage,
        .{ .size = .{ .width = 20, .height = 5 } },
    );
    defer cleanupProcess(&process);

    var output: [512]u8 = undefined;
    var output_len: usize = 0;
    try readUntil(&process, &output, &output_len, "READY");
    const stopped = try process.wait();
    try std.testing.expect(stopped == .stopped);
    try std.testing.expectEqual(std.posix.SIG.STOP, stopped.stopped);
    try process.sendSignal(.CONT);
    try std.testing.expect((try process.wait()) == .continued);
    try readUntil(&process, &output, &output_len, "CONTINUED");
    try writeAll(&process, "x\n");
    const exited = try process.wait();
    try std.testing.expect(exited == .exit);
    try std.testing.expectEqual(@as(u8, 7), exited.exit.exited);
}

test "PTY wait records externally auto-reaped children" {
    const ignored = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var previous: std.posix.Sigaction = undefined;
    std.posix.sigaction(.CHLD, null, &previous);
    std.posix.sigaction(.CHLD, &ignored, null);
    defer std.posix.sigaction(.CHLD, &previous, null);

    var pointers: [3]?[*:0]const u8 = undefined;
    var bytes: [256]u8 = undefined;
    var storage = tui.subprocess.SpawnStorage.init(&pointers, &bytes);
    const arguments = [_][]const u8{ fixture.fixture_path, "exit-now" };
    var process = try tui.subprocess.PtyProcess.spawnBeforeThreads(
        std.testing.io,
        .{ .argv = &arguments, .environ = std.testing.environ },
        &storage,
        .{ .size = .{ .width = 20, .height = 5 } },
    );
    try std.testing.expectError(error.AlreadyReaped, process.wait());
    try std.testing.expect(process.isReaped());
    process.deinit();
}

test "PTY writes stop without blocking when the input queue fills" {
    var pointers: [3]?[*:0]const u8 = undefined;
    var bytes: [256]u8 = undefined;
    var storage = tui.subprocess.SpawnStorage.init(&pointers, &bytes);
    const arguments = [_][]const u8{ fixture.fixture_path, "bounded-write" };
    var process = try tui.subprocess.PtyProcess.spawnBeforeThreads(
        std.testing.io,
        .{ .argv = &arguments, .environ = std.testing.environ },
        &storage,
        .{ .size = .{ .width = 20, .height = 5 } },
    );
    defer cleanupProcess(&process);
    var output: [512]u8 = undefined;
    var output_len: usize = 0;
    try readUntil(&process, &output, &output_len, "READY");
    try drainToWouldBlock(&process, &output);

    var input: [64 * 1024]u8 = undefined;
    @memset(&input, 'x');
    var bounded = false;
    for (0..16) |_| switch (try process.write(&input)) {
        .written => |count| {
            if (count < input.len) {
                bounded = true;
                break;
            }
        },
        .would_block => {
            bounded = true;
            break;
        },
        .closed => return error.UnexpectedClosedPty,
    };
    try std.testing.expect(bounded);
}

test "PTY output decodes into a safe scrollback viewport" {
    const Decoder = tui.scroll.LineDecoder(256);
    var slots: [8]Decoder.Ring.Slot = undefined;
    var ring = Decoder.Ring.init(&slots);
    var decoder: Decoder = .{};
    var decoded: tui.scroll.DecodeResult = .{};

    var pointers: [3]?[*:0]const u8 = undefined;
    var bytes: [256]u8 = undefined;
    var storage = tui.subprocess.SpawnStorage.init(&pointers, &bytes);
    const arguments = [_][]const u8{ fixture.fixture_path, "line-pipeline" };
    var process = try tui.subprocess.PtyProcess.spawnBeforeThreads(
        std.testing.io,
        .{ .argv = &arguments, .environ = std.testing.environ },
        &storage,
        .{ .size = .{ .width = 20, .height = 5 } },
    );
    defer cleanupProcess(&process);

    var fragment: [7]u8 = undefined;
    for (0..100) |_| {
        switch (try process.read(&fragment)) {
            .data => |chunk| {
                decoded.merge(decoder.feed(&ring, chunk));
                if (ring.count() != 0) break;
            },
            .would_block => try pollMaster(&process, std.posix.POLL.IN),
            .eof => return error.UnexpectedEof,
        }
    }
    try std.testing.expect(ring.count() != 0);
    try writeAll(&process, "x\n");
    const event = try process.wait();
    try std.testing.expect(event == .exit);
    try std.testing.expectEqual(@as(u8, 7), event.exit.exited);

    var saw_eof = false;
    read_loop: for (0..100) |_| {
        switch (try process.read(&fragment)) {
            .data => |chunk| decoded.merge(decoder.feed(&ring, chunk)),
            .would_block => try pollMaster(&process, std.posix.POLL.IN),
            .eof => {
                saw_eof = true;
                break :read_loop;
            },
        }
    }
    try std.testing.expect(saw_eof);
    decoded.merge(decoder.finish(&ring));
    try std.testing.expectEqual(@as(usize, 0), decoded.rejectedRows());

    var ready_row: ?usize = null;
    var input_row: ?usize = null;
    for (0..ring.count()) |index| {
        const row = ring.row(index);
        if (std.mem.startsWith(u8, row, "READY ")) ready_row = index;
        if (std.mem.startsWith(u8, row, "INPUT=x ")) input_row = index;
    }
    try std.testing.expect(ready_row != null);
    try std.testing.expect(input_row != null);

    var viewport: tui.scroll.Viewport = .{};
    var scrollback = tui.widget.Scrollback(Decoder.Ring){
        .provider = &ring,
        .viewport = &viewport,
        .bounds = .{ .x = 0, .y = 0, .width = 64, .height = 8 },
    };
    var renderer = try tui.render.Renderer.init(std.testing.allocator, .{ .width = 64, .height = 8 }, .{});
    defer renderer.deinit();
    var frame = renderer.frame();
    var surface = frame.surface(tui.render.Rect.fromSize(renderer.size()));
    try scrollback.draw(&surface);
    try std.testing.expectEqual(@as(u32, 'R'), renderer.desiredCell(.{ .x = 0, .y = @intCast(ready_row.?) }).?.glyph);
    try std.testing.expectEqual(@as(u32, 'I'), renderer.desiredCell(.{ .x = 0, .y = @intCast(input_row.?) }).?.glyph);
}

test "process console composes PTY runtime rendering and cleanup" {
    var pointers: [4]?[*:0]const u8 = undefined;
    var bytes: [512]u8 = undefined;
    var storage = tui.subprocess.SpawnStorage.init(&pointers, &bytes);
    const arguments = [_][]const u8{ fixture.console_path, fixture.fixture_path, "exit-now" };
    var process = try tui.subprocess.PtyProcess.spawnBeforeThreads(
        std.testing.io,
        .{ .argv = &arguments, .environ = std.testing.environ },
        &storage,
        .{ .size = .{ .width = 80, .height = 12 } },
    );
    defer cleanupProcess(&process);

    var output: [16 * 1024]u8 = undefined;
    var output_len: usize = 0;
    try readUntil(&process, &output, &output_len, "exited (0)");
    try writeAll(&process, "q");
    const event = try process.wait();
    try std.testing.expect(event == .exit);
    try std.testing.expectEqual(@as(u8, 0), event.exit.exited);
    try readToEof(&process, &output);
}

test "process console remains responsive under sustained child output" {
    var pointers: [4]?[*:0]const u8 = undefined;
    var bytes: [512]u8 = undefined;
    var storage = tui.subprocess.SpawnStorage.init(&pointers, &bytes);
    const arguments = [_][]const u8{ fixture.console_path, fixture.fixture_path, "flood" };
    var process = try tui.subprocess.PtyProcess.spawnBeforeThreads(
        std.testing.io,
        .{ .argv = &arguments, .environ = std.testing.environ },
        &storage,
        .{ .size = .{ .width = 80, .height = 12 } },
    );
    defer cleanupProcess(&process);

    var output: [32 * 1024]u8 = undefined;
    var output_len: usize = 0;
    try readUntil(&process, &output, &output_len, "flood output");
    try writeAll(&process, "q");

    var exit_event: ?tui.subprocess.WaitEvent = null;
    var drain: [4096]u8 = undefined;
    for (0..200) |_| {
        if (try process.poll()) |event| switch (event) {
            .exit => {
                exit_event = event;
                break;
            },
            .stopped => {},
            .continued => {},
        };
        switch (try process.read(&drain)) {
            .data => {},
            .would_block => try pollMaster(&process, std.posix.POLL.IN),
            .eof => {},
        }
        try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
    }
    const event = exit_event orelse return error.Timeout;
    try std.testing.expectEqual(@as(u8, 0), event.exit.exited);
    try readToEof(&process, &drain);
}

test "coding assistant reference streams a prompt and restores its terminal" {
    var pointers: [2]?[*:0]const u8 = undefined;
    var bytes: [256]u8 = undefined;
    var storage = tui.subprocess.SpawnStorage.init(&pointers, &bytes);
    const arguments = [_][]const u8{fixture.assistant_path};
    var process = try tui.subprocess.PtyProcess.spawnBeforeThreads(
        std.testing.io,
        .{ .argv = &arguments, .environ = std.testing.environ },
        &storage,
        .{ .size = .{ .width = 80, .height = 12 } },
    );
    defer cleanupProcess(&process);

    var output: [32 * 1024]u8 = undefined;
    var output_len: usize = 0;
    try readUntil(&process, &output, &output_len, "tui.zig assistant reference");
    try writeAll(&process, "hello\x13");
    try readUntil(&process, &output, &output_len, "streamed output uses bounded chunks");
    try writeAll(&process, "\x11");
    const event = try process.wait();
    try std.testing.expect(event == .exit);
    try std.testing.expectEqual(@as(u8, 0), event.exit.exited);
    try readToEof(&process, &output);
}

fn readUntil(
    process: *tui.subprocess.PtyProcess,
    output: []u8,
    output_len: *usize,
    needle: []const u8,
) !void {
    for (0..100) |_| {
        switch (try process.read(output[output_len.*..])) {
            .data => |bytes| {
                output_len.* += bytes.len;
                if (std.mem.indexOf(u8, output[0..output_len.*], needle) != null) return;
            },
            .would_block => {
                var poll_fds = [1]std.posix.pollfd{.{
                    .fd = (try process.borrowedMaster()).handle,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};
                _ = try std.posix.poll(&poll_fds, 100);
            },
            .eof => return error.UnexpectedEof,
        }
    }
    return error.Timeout;
}

fn writeAll(process: *tui.subprocess.PtyProcess, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        switch (try process.write(bytes[offset..])) {
            .written => |count| offset += count,
            .would_block => {
                var poll_fds = [1]std.posix.pollfd{.{
                    .fd = (try process.borrowedMaster()).handle,
                    .events = std.posix.POLL.OUT,
                    .revents = 0,
                }};
                _ = try std.posix.poll(&poll_fds, 100);
            },
            .closed => return error.Closed,
        }
    }
}

fn pollMaster(process: *tui.subprocess.PtyProcess, events: i16) !void {
    var poll_fds = [1]std.posix.pollfd{.{
        .fd = (try process.borrowedMaster()).handle,
        .events = events,
        .revents = 0,
    }};
    _ = try std.posix.poll(&poll_fds, 100);
}

fn drainToWouldBlock(process: *tui.subprocess.PtyProcess, buffer: []u8) !void {
    for (0..16) |_| switch (try process.read(buffer)) {
        .data => {},
        .would_block => return,
        .eof => return error.UnexpectedEof,
    };
    return error.ExpectedWouldBlock;
}

fn readToEof(process: *tui.subprocess.PtyProcess, buffer: []u8) !void {
    for (0..16) |_| switch (try process.read(buffer)) {
        .data => {},
        .would_block => continue,
        .eof => return,
    };
    return error.ExpectedEof;
}

fn cleanupProcess(process: *tui.subprocess.PtyProcess) void {
    if (!process.isReaped()) {
        process.forceKill() catch {};
        while (!process.isReaped()) _ = process.wait() catch break;
    }
    if (process.isReaped()) process.deinit() else process.closeMaster();
}
