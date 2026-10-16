const std = @import("std");
const tui = @import("tui");
const testing = std.testing;

test "slow and cancelled pastes stay framed while runtime controls remain live" {
    for ([_]bool{ false, true }) |cancel| {
        const io = testing.io;
        const fds = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
        const reader: std.Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = true } };
        const writer: std.Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = true } };
        defer reader.close(io);
        defer writer.close(io);
        var buffer: [256]u8 = undefined;
        var timers: [1]tui.runtime.TimerSlot = undefined;
        var runtime = try tui.runtime.Posix.init(io, reader, &buffer, &timers, .{});
        defer runtime.deinit();
        var storage: tui.editor.FixedStorage(32) = .{};
        var model = try tui.editor.Model.initSingleLine(storage.slices(), "");

        try writer.writeStreamingAll(io, "\x1b[200~zzz");
        const start = try runtime.step();
        try testing.expect(start.input == .paste_start);
        _ = model.handle(start.input);
        const chunk = try runtime.step();
        try testing.expectEqualStrings("zzz", chunk.input.paste_chunk);
        _ = model.handle(chunk.input);
        if (cancel) {
            try testing.expect(runtime.parser.cancelPending().outcome == .failure);
            _ = model.handle(.malformed);
        }
        try testing.expect(runtime.parser_deadline_ns == null);

        var deadline = runtime.now();
        deadline.raw.nanoseconds += 300 * std.time.ns_per_ms;
        _ = try runtime.setTimer(7, deadline);
        try runtime.notifier().wake();
        try testing.expect((try runtime.step()) == .wakeup);
        try testing.expectEqual(@as(u32, 7), (try runtime.step()).timer.id);
        try testing.expectEqual(.paste, runtime.inputState().pending);

        try writer.writeStreamingAll(io, "j\r\x1b[201~x");
        if (!cancel) {
            const tail = try runtime.step();
            try testing.expectEqualStrings("j\r", tail.input.paste_chunk);
            _ = model.handle(tail.input);
            const end = try runtime.step();
            try testing.expect(end.input == .paste_end);
            try testing.expectEqual(error.InvalidText, model.handle(end.input).failure.?);
        }
        const text = try runtime.step();
        try testing.expectEqualStrings("x", text.input.text);
        try testing.expectEqualStrings("", model.value());
        _ = model.handle(text.input);
        try testing.expectEqualStrings("x", model.value());
        try testing.expectEqual(.none, runtime.inputState().pending);

        var poll_storage: [3]tui.runtime.PollSlot = undefined;
        try writer.writeStreamingAll(io, "\x1b[");
        try testing.expect(try runtime.pollWithSources(&.{}, &poll_storage) == null);
        try testing.expect(runtime.parser_deadline_ns != null);
        runtime.parser_deadline_ns = 0;
        try testing.expect((try runtime.step()) == .input_failure);
        try writer.writeStreamingAll(io, "\x1b");
        try testing.expect(try runtime.pollWithSources(&.{}, &poll_storage) == null);
        runtime.parser_deadline_ns = 0;
        try testing.expect((try runtime.step()).input.key.code == .escape);
    }
}

test "input state distinguishes buffered bytes queued events incomplete framing and EOF" {
    const io = testing.io;
    const fds = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const reader: std.Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = true } };
    const writer: std.Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = true } };
    defer reader.close(io);
    var writer_open = true;
    defer if (writer_open) writer.close(io);
    var buffer: [32]u8 = undefined;
    var timers: [0]tui.runtime.TimerSlot = .{};
    var runtime = try tui.runtime.Posix.init(io, reader, &buffer, &timers, .{
        .input_timeouts = .{ .sequence = .fromMilliseconds(60_000) },
    });
    defer runtime.deinit();

    try writer.writeStreamingAll(io, "\x1b[200~ab\x1b[201~");
    try testing.expectEqual(tui.runtime.InputState{ .buffered_work = false, .pending = .none }, runtime.inputState());
    try testing.expect((try runtime.step()).input == .paste_start);
    try testing.expectEqual(tui.runtime.InputState{ .buffered_work = true, .pending = .paste }, runtime.inputState());
    try testing.expectEqualStrings("ab", (try runtime.step()).input.paste_chunk);
    try testing.expectEqual(tui.runtime.InputState{ .buffered_work = true, .pending = .none }, runtime.inputState());
    try testing.expect((try runtime.step()).input == .paste_end);

    var slots: [3]tui.runtime.PollSlot = undefined;
    try writer.writeStreamingAll(io, "\x1b[");
    try testing.expect(try runtime.pollWithSources(&.{}, &slots) == null);
    try testing.expectEqual(tui.runtime.InputState{ .buffered_work = false, .pending = .sequence }, runtime.inputState());
    writer.close(io);
    writer_open = false;
    try testing.expect(try runtime.pollWithSources(&.{}, &slots) == null);
    try testing.expect(runtime.inputState().buffered_work);
    try testing.expect((try runtime.step()) == .input_failure);
    try testing.expectEqual(tui.runtime.InputState{ .buffered_work = true, .pending = .none }, runtime.inputState());
    try testing.expect(try runtime.pollWithSources(&.{}, &slots) == null);
    try testing.expect(runtime.inputState().buffered_work);
    try testing.expect((try runtime.step()) == .eof);
    try testing.expectEqual(tui.runtime.InputState{ .buffered_work = false, .pending = .none }, runtime.inputState());
}
