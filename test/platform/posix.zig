const std = @import("std");
const builtin = @import("builtin");
const tui = @import("tui");

extern fn openpty(
    master: *c_int,
    slave: *c_int,
    name: ?[*]u8,
    termios: ?*const std.posix.termios,
    winsize: ?*const std.posix.winsize,
) c_int;

test "POSIX session restores termios after enter failure and normal leave" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var master_fd: c_int = -1;
    var slave_fd: c_int = -1;
    if (openpty(&master_fd, &slave_fd, null, null, null) != 0) return error.OpenPtyFailed;
    const master = std.Io.File{ .handle = master_fd, .flags = .{ .nonblocking = false } };
    const slave = std.Io.File{ .handle = slave_fd, .flags = .{ .nonblocking = false } };
    defer master.close(std.testing.io);
    defer slave.close(std.testing.io);

    const original = try std.posix.tcgetattr(slave_fd);
    var tiny_buffer: [1]u8 = undefined;
    var tiny_writer = std.Io.Writer.fixed(&tiny_buffer);
    try std.testing.expectError(error.WriteFailed, tui.terminal.Session.enter(slave, &tiny_writer, .{}));
    try expectTermiosEqual(original, try std.posix.tcgetattr(slave_fd));

    var output_buffer: [512]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var session = try tui.terminal.Session.enter(slave, &output, .{});
    const raw = try std.posix.tcgetattr(slave_fd);
    try std.testing.expect(!raw.lflag.ECHO);
    try std.testing.expect(!raw.lflag.ICANON);
    try std.testing.expect(!raw.lflag.ISIG);

    var failed_leave_buffer: [1]u8 = undefined;
    var failed_leave = std.Io.Writer.fixed(&failed_leave_buffer);
    try std.testing.expectError(error.WriteFailed, session.leave(&failed_leave));
    try expectTermiosEqual(original, try std.posix.tcgetattr(slave_fd));

    var retry_buffer: [512]u8 = undefined;
    var retry = std.Io.Writer.fixed(&retry_buffer);
    try session.leave(&retry);
    try std.testing.expect(std.mem.indexOf(u8, retry.buffered(), "\x1b[?1049l") != null);
    const retry_len = retry.buffered().len;
    try session.leave(&retry);
    try std.testing.expectEqual(retry_len, retry.buffered().len);

    try std.testing.expect(std.mem.indexOf(u8, output.buffered(), "\x1b[?1049h") != null);

    var second_output_buffer: [512]u8 = undefined;
    var second_output = std.Io.Writer.fixed(&second_output_buffer);
    var second_session = try tui.terminal.Session.enter(slave, &second_output, .{});
    try second_session.restoreTermios();
    try expectTermiosEqual(original, try std.posix.tcgetattr(slave_fd));
    var failed_reenter_buffer: [1]u8 = undefined;
    var failed_reenter = std.Io.Writer.fixed(&failed_reenter_buffer);
    try std.testing.expectError(error.WriteFailed, second_session.reenter(&failed_reenter));
    try expectTermiosEqual(original, try std.posix.tcgetattr(slave_fd));
    var reenter_buffer: [512]u8 = undefined;
    var reenter = std.Io.Writer.fixed(&reenter_buffer);
    try second_session.reenter(&reenter);
    const reentered = try std.posix.tcgetattr(slave_fd);
    try std.testing.expect(!reentered.lflag.ECHO);
    try std.testing.expect(!reentered.lflag.ICANON);
    try std.testing.expect(std.mem.indexOf(u8, reenter.buffered(), "\x1b[?1049h") != null);
    var cleanup_buffer: [512]u8 = undefined;
    var cleanup = std.Io.Writer.fixed(&cleanup_buffer);
    try second_session.leave(&cleanup);
    try std.testing.expect(std.mem.indexOf(u8, cleanup.buffered(), "\x1b[?1049l") != null);
}

test "POSIX emergency restoration uses bounded raw terminal output" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var master_fd: c_int = -1;
    var slave_fd: c_int = -1;
    if (openpty(&master_fd, &slave_fd, null, null, null) != 0) return error.OpenPtyFailed;
    const master = std.Io.File{ .handle = master_fd, .flags = .{ .nonblocking = false } };
    const slave = std.Io.File{ .handle = slave_fd, .flags = .{ .nonblocking = false } };
    defer master.close(std.testing.io);
    defer slave.close(std.testing.io);
    const original = try std.posix.tcgetattr(slave_fd);

    var enter_buffer: [512]u8 = undefined;
    var enter = std.Io.Writer.fixed(&enter_buffer);
    var session = try tui.terminal.Session.enter(slave, &enter, .{});
    const output_pipe = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const output_read = std.Io.File{ .handle = output_pipe[0], .flags = .{ .nonblocking = true } };
    const output_write = std.Io.File{ .handle = output_pipe[1], .flags = .{ .nonblocking = true } };
    defer output_read.close(std.testing.io);
    defer output_write.close(std.testing.io);

    session.emergencyRestore(output_write.handle);
    try expectTermiosEqual(original, try std.posix.tcgetattr(slave_fd));
    var bytes: [256]u8 = undefined;
    const count = try std.posix.read(output_read.handle, &bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes[0..count], "\x1b[?1049l") != null);

    var leave_buffer: [512]u8 = undefined;
    var leave = std.Io.Writer.fixed(&leave_buffer);
    try session.leave(&leave);
}

test "POSIX session writes enabled modes in safe order" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var master_fd: c_int = -1;
    var slave_fd: c_int = -1;
    if (openpty(&master_fd, &slave_fd, null, null, null) != 0) return error.OpenPtyFailed;
    const master = std.Io.File{ .handle = master_fd, .flags = .{ .nonblocking = false } };
    const slave = std.Io.File{ .handle = slave_fd, .flags = .{ .nonblocking = false } };
    defer master.close(std.testing.io);
    defer slave.close(std.testing.io);

    var enter_buffer: [512]u8 = undefined;
    var enter = std.Io.Writer.fixed(&enter_buffer);
    var session = try tui.terminal.Session.enter(slave, &enter, .{
        .alternate_screen = true,
        .hide_cursor = true,
        .bracketed_paste = true,
        .focus_events = true,
        .mouse = true,
        .kitty_keyboard = true,
    });
    try std.testing.expectEqualStrings(
        "\x1b[?1049h\x1b[?2004h\x1b[?1004h\x1b[?1000h\x1b[?1006h\x1b[>1u\x1b[?25l",
        enter.buffered(),
    );

    try session.restoreTermios();
    var restored_reenter_buffer: [512]u8 = undefined;
    var restored_reenter = std.Io.Writer.fixed(&restored_reenter_buffer);
    try session.reenter(&restored_reenter);
    try std.testing.expect(std.mem.indexOf(u8, restored_reenter.buffered(), "\x1b[?1049h") != null);
    try std.testing.expect(std.mem.indexOf(u8, restored_reenter.buffered(), "\x1b[>1u") == null);

    var leave_buffer: [512]u8 = undefined;
    var leave = std.Io.Writer.fixed(&leave_buffer);
    try session.leave(&leave);
    try std.testing.expectEqualStrings(
        "\x1b[?2026l\x1b[0m\x1b[0 q\x1b[?25h\x1b[<u\x1b[?1006l\x1b[?1000l\x1b[?1004l\x1b[?2004l\x1b[?1049l",
        leave.buffered(),
    );

    var plain_enter_buffer: [32]u8 = undefined;
    var plain_enter = std.Io.Writer.fixed(&plain_enter_buffer);
    var plain_session = try tui.terminal.Session.enter(slave, &plain_enter, .{
        .alternate_screen = false,
        .hide_cursor = false,
        .bracketed_paste = false,
        .focus_events = false,
        .mouse = false,
        .kitty_keyboard = false,
    });
    try std.testing.expectEqual(@as(usize, 0), plain_enter.buffered().len);
    var keyboard_buffer: [32]u8 = undefined;
    var keyboard = std.Io.Writer.fixed(&keyboard_buffer);
    try plain_session.setKittyKeyboard(&keyboard, true);
    try plain_session.setKittyKeyboard(&keyboard, true);
    try std.testing.expectEqualStrings("\x1b[>1u", keyboard.buffered());
    var plain_leave_buffer: [64]u8 = undefined;
    var plain_leave = std.Io.Writer.fixed(&plain_leave_buffer);
    try plain_session.leave(&plain_leave);
    try std.testing.expectEqualStrings("\x1b[?2026l\x1b[0m\x1b[0 q\x1b[<u", plain_leave.buffered());

    var plain_reenter_buffer: [32]u8 = undefined;
    var plain_reenter = std.Io.Writer.fixed(&plain_reenter_buffer);
    try plain_session.reenter(&plain_reenter);
    try std.testing.expectEqualStrings("\x1b[>1u", plain_reenter.buffered());
    try plain_session.reenter(&plain_reenter);
    try std.testing.expectEqualStrings("\x1b[>1u", plain_reenter.buffered());
    var keyboard_off_buffer: [32]u8 = undefined;
    var keyboard_off = std.Io.Writer.fixed(&keyboard_off_buffer);
    try plain_session.setKittyKeyboard(&keyboard_off, false);
    try std.testing.expectEqualStrings("\x1b[<u", keyboard_off.buffered());
    var plain_final_leave_buffer: [64]u8 = undefined;
    var plain_final_leave = std.Io.Writer.fixed(&plain_final_leave_buffer);
    try plain_session.leave(&plain_final_leave);
    try std.testing.expectEqualStrings("\x1b[?2026l\x1b[0m\x1b[0 q", plain_final_leave.buffered());
}

test "POSIX size query reads the PTY window and rejects zero dimensions" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var master_fd: c_int = -1;
    var slave_fd: c_int = -1;
    var winsize = std.posix.winsize{ .row = 37, .col = 121, .xpixel = 0, .ypixel = 0 };
    if (openpty(&master_fd, &slave_fd, null, null, &winsize) != 0) return error.OpenPtyFailed;
    const master = std.Io.File{ .handle = master_fd, .flags = .{ .nonblocking = false } };
    const slave = std.Io.File{ .handle = slave_fd, .flags = .{ .nonblocking = false } };
    defer master.close(std.testing.io);
    defer slave.close(std.testing.io);
    try std.testing.expectEqual(
        tui.render.Size{ .width = 121, .height = 37 },
        try tui.terminal.querySize(std.testing.io, slave),
    );

    winsize.row = 0;
    winsize.col = 0;
    _ = try std.testing.io.operate(.{ .device_io_control = .{
        .file = slave,
        .code = std.posix.T.IOCSWINSZ,
        .arg = &winsize,
    } });
    try std.testing.expectError(
        error.TerminalSizeUnavailable,
        tui.terminal.querySize(std.testing.io, slave),
    );
}

fn expectTermiosEqual(expected: std.posix.termios, actual: std.posix.termios) !void {
    try std.testing.expectEqualDeep(expected.iflag, actual.iflag);
    try std.testing.expectEqualDeep(expected.oflag, actual.oflag);
    try std.testing.expectEqualDeep(expected.cflag, actual.cflag);
    try std.testing.expectEqualDeep(expected.lflag, actual.lflag);
    try std.testing.expectEqualSlices(std.posix.cc_t, &expected.cc, &actual.cc);
}
