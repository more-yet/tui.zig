const std = @import("std");
const geometry = @import("../core/geometry.zig");

pub const Options = struct {
    alternate_screen: bool = true,
    hide_cursor: bool = true,
    bracketed_paste: bool = true,
    focus_events: bool = true,
    mouse: bool = false,
    kitty_keyboard: bool = false,
};

pub const Session = struct {
    input: std.Io.File,
    original: std.posix.termios,
    options: Options,
    terminal_modes_active: bool = true,
    raw_mode_active: bool = true,
    kitty_keyboard_enabled: bool,
    kitty_keyboard_active: bool,

    /// Termios rollback is guaranteed on output failure; visual-mode rollback is best effort on that writer.
    pub fn enter(
        input: std.Io.File,
        writer: *std.Io.Writer,
        options: Options,
    ) !Session {
        const original = try std.posix.tcgetattr(input.handle);
        const raw = makeRaw(original);
        try std.posix.tcsetattr(input.handle, .FLUSH, raw);

        var output_error: ?std.Io.Writer.Error = null;
        var kitty_keyboard_active = false;
        writeEnter(writer, options, options.kitty_keyboard, &kitty_keyboard_active) catch |err| {
            output_error = err;
        };
        if (output_error == null) writer.flush() catch |err| {
            output_error = err;
        };
        if (output_error) |err| {
            writeLeave(writer, options, &kitty_keyboard_active) catch {};
            writer.flush() catch {};
            std.posix.tcsetattr(input.handle, .FLUSH, original) catch |restore_error| return restore_error;
            return err;
        }
        return .{
            .input = input,
            .original = original,
            .options = options,
            .kitty_keyboard_enabled = options.kitty_keyboard,
            .kitty_keyboard_active = kitty_keyboard_active,
        };
    }

    pub fn leave(self: *Session, writer: *std.Io.Writer) !void {
        var output_error: ?std.Io.Writer.Error = null;
        if (self.terminal_modes_active) {
            writeLeave(writer, self.options, &self.kitty_keyboard_active) catch |err| {
                output_error = err;
            };
            writer.flush() catch |err| {
                if (output_error == null) output_error = err;
            };
            if (output_error == null) {
                self.terminal_modes_active = false;
                self.kitty_keyboard_active = false;
            }
        }

        if (self.raw_mode_active) {
            std.posix.tcsetattr(self.input.handle, .FLUSH, self.original) catch |err| return err;
            self.raw_mode_active = false;
        }
        if (output_error) |err| return err;
    }

    /// Reapplies the original-derived raw mode and configured terminal modes after resume.
    pub fn reenter(self: *Session, writer: *std.Io.Writer) !void {
        if (self.raw_mode_active and self.terminal_modes_active) return;
        const raw = makeRaw(self.original);
        try std.posix.tcsetattr(self.input.handle, .FLUSH, raw);
        self.raw_mode_active = true;

        const terminal_modes_were_active = self.terminal_modes_active;
        var output_error: ?std.Io.Writer.Error = null;
        const push_kitty_keyboard = self.kitty_keyboard_enabled and !self.kitty_keyboard_active;
        var kitty_keyboard_pushed = false;
        writeEnter(writer, self.options, push_kitty_keyboard, &kitty_keyboard_pushed) catch |err| {
            output_error = err;
        };
        if (output_error == null) writer.flush() catch |err| {
            output_error = err;
        };
        self.kitty_keyboard_active = self.kitty_keyboard_active or kitty_keyboard_pushed;
        if (output_error) |err| {
            if (!terminal_modes_were_active) {
                var cleanup_failed = false;
                writeLeave(writer, self.options, &self.kitty_keyboard_active) catch {
                    cleanup_failed = true;
                };
                writer.flush() catch {
                    cleanup_failed = true;
                };
                self.terminal_modes_active = cleanup_failed;
            }
            std.posix.tcsetattr(self.input.handle, .FLUSH, self.original) catch |restore_error| return restore_error;
            self.raw_mode_active = false;
            return err;
        }
        self.terminal_modes_active = true;
        self.kitty_keyboard_active = self.kitty_keyboard_enabled;
    }

    /// Changes Kitty keyboard reporting after capability negotiation.
    pub fn setKittyKeyboard(self: *Session, writer: *std.Io.Writer, enabled: bool) std.Io.Writer.Error!void {
        if (enabled == self.kitty_keyboard_enabled and
            (!self.terminal_modes_active or enabled == self.kitty_keyboard_active))
        {
            if (self.terminal_modes_active) try writer.flush();
            return;
        }
        if (!self.terminal_modes_active) {
            self.kitty_keyboard_enabled = enabled;
            return;
        }
        if (enabled) {
            try writer.writeAll("\x1b[>1u");
            self.kitty_keyboard_enabled = true;
            self.kitty_keyboard_active = true;
            try writer.flush();
        } else {
            try writer.writeAll("\x1b[<u");
            self.kitty_keyboard_enabled = false;
            self.kitty_keyboard_active = false;
            try writer.flush();
        }
    }

    /// Performs bounded best-effort restoration without allocation, logging, or Session mutation.
    /// This is a primitive for controlled emergency paths, not a guarantee after process corruption.
    pub fn emergencyRestore(self: *const Session, output_fd: std.posix.fd_t) void {
        _ = std.posix.system.tcsetattr(self.input.handle, .NOW, &self.original);
        var buffer: [128]u8 = undefined;
        const bytes = leaveSequence(self.options, self.kitty_keyboard_active, &buffer);
        _ = std.posix.system.write(output_fd, bytes.ptr, bytes.len);
    }

    pub fn restoreTermios(self: *Session) std.posix.TermiosSetError!void {
        if (!self.raw_mode_active) return;
        try std.posix.tcsetattr(self.input.handle, .FLUSH, self.original);
        self.raw_mode_active = false;
    }
};

pub fn querySize(io: std.Io, file: std.Io.File) !geometry.Size {
    var winsize: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const result = try io.operate(.{ .device_io_control = .{
        .file = file,
        .code = std.posix.T.IOCGWINSZ,
        .arg = &winsize,
    } });
    if (result.device_io_control < 0 or winsize.col == 0 or winsize.row == 0) return error.TerminalSizeUnavailable;
    return .{ .width = winsize.col, .height = winsize.row };
}

fn makeRaw(original: std.posix.termios) std.posix.termios {
    var raw = original;
    raw.iflag.IGNBRK = false;
    raw.iflag.BRKINT = false;
    raw.iflag.PARMRK = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.INLCR = false;
    raw.iflag.IGNCR = false;
    raw.iflag.IXON = false;
    raw.oflag.OPOST = false;
    raw.cflag.CSIZE = .CS8;
    raw.cflag.PARENB = false;
    raw.lflag.ECHO = false;
    raw.lflag.ECHONL = false;
    raw.lflag.ICANON = false;
    raw.lflag.IEXTEN = false;
    raw.lflag.ISIG = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    return raw;
}

fn writeEnter(
    writer: *std.Io.Writer,
    options: Options,
    kitty_keyboard: bool,
    kitty_keyboard_active: *bool,
) std.Io.Writer.Error!void {
    if (options.alternate_screen) try writer.writeAll("\x1b[?1049h");
    if (options.bracketed_paste) try writer.writeAll("\x1b[?2004h");
    if (options.focus_events) try writer.writeAll("\x1b[?1004h");
    if (options.mouse) try writer.writeAll("\x1b[?1002h\x1b[?1006h");
    if (kitty_keyboard) {
        try writer.writeAll("\x1b[>1u");
        kitty_keyboard_active.* = true;
    }
    if (options.hide_cursor) try writer.writeAll("\x1b[?25l");
}

fn writeLeave(writer: *std.Io.Writer, options: Options, kitty_keyboard_active: *bool) std.Io.Writer.Error!void {
    try writer.writeAll("\x1b[?2026l\x1b[0m\x1b[0 q");
    if (options.hide_cursor) try writer.writeAll("\x1b[?25h");
    if (kitty_keyboard_active.*) {
        try writer.writeAll("\x1b[<u");
        kitty_keyboard_active.* = false;
    }
    if (options.mouse) try writer.writeAll("\x1b[?1006l\x1b[?1002l");
    if (options.focus_events) try writer.writeAll("\x1b[?1004l");
    if (options.bracketed_paste) try writer.writeAll("\x1b[?2004l");
    if (options.alternate_screen) try writer.writeAll("\x1b[?1049l");
}

fn leaveSequence(options: Options, kitty_keyboard: bool, buffer: *[128]u8) []const u8 {
    var length: usize = 0;
    append(buffer, &length, "\x1b[?2026l\x1b[0m\x1b[0 q");
    if (options.hide_cursor) append(buffer, &length, "\x1b[?25h");
    if (kitty_keyboard) append(buffer, &length, "\x1b[<u");
    if (options.mouse) append(buffer, &length, "\x1b[?1006l\x1b[?1002l");
    if (options.focus_events) append(buffer, &length, "\x1b[?1004l");
    if (options.bracketed_paste) append(buffer, &length, "\x1b[?2004l");
    if (options.alternate_screen) append(buffer, &length, "\x1b[?1049l");
    return buffer[0..length];
}

fn append(buffer: []u8, length: *usize, bytes: []const u8) void {
    std.debug.assert(length.* + bytes.len <= buffer.len);
    @memcpy(buffer[length.*..][0..bytes.len], bytes);
    length.* += bytes.len;
}

test "raw mode transform disables line discipline without touching the source" {
    var original: std.posix.termios = undefined;
    original.iflag = .{};
    original.oflag = .{};
    original.cflag = .{};
    original.lflag = .{};
    original.cc = @splat(0);
    original.iflag.ICRNL = true;
    original.iflag.IGNBRK = true;
    original.iflag.PARMRK = true;
    original.iflag.INLCR = true;
    original.iflag.IGNCR = true;
    original.oflag.OPOST = true;
    original.lflag.ECHO = true;
    original.lflag.ECHONL = true;
    original.lflag.ICANON = true;
    original.lflag.ISIG = true;

    const raw = makeRaw(original);
    try std.testing.expect(original.lflag.ECHO);
    try std.testing.expect(!raw.iflag.ICRNL);
    try std.testing.expect(!raw.iflag.IGNBRK);
    try std.testing.expect(!raw.iflag.PARMRK);
    try std.testing.expect(!raw.iflag.INLCR);
    try std.testing.expect(!raw.iflag.IGNCR);
    try std.testing.expect(!raw.oflag.OPOST);
    try std.testing.expect(!raw.lflag.ECHO);
    try std.testing.expect(!raw.lflag.ECHONL);
    try std.testing.expect(!raw.lflag.ICANON);
    try std.testing.expect(!raw.lflag.ISIG);
}

test "terminal mode writes retain completed Kitty stack transitions" {
    var before_push_buffer: [1]u8 = undefined;
    var before_push = std.Io.Writer.fixed(&before_push_buffer);
    var pushed = false;
    try std.testing.expectError(
        error.WriteFailed,
        writeEnter(&before_push, .{ .alternate_screen = true, .kitty_keyboard = true }, true, &pushed),
    );
    try std.testing.expect(!pushed);

    var after_push_buffer: ["\x1b[>1u".len]u8 = undefined;
    var after_push = std.Io.Writer.fixed(&after_push_buffer);
    try std.testing.expectError(
        error.WriteFailed,
        writeEnter(&after_push, .{
            .alternate_screen = false,
            .hide_cursor = true,
            .bracketed_paste = false,
            .focus_events = false,
            .kitty_keyboard = true,
        }, true, &pushed),
    );
    try std.testing.expect(pushed);

    const leave_through_pop = "\x1b[?2026l\x1b[0m\x1b[0 q\x1b[<u";
    var after_pop_buffer: [leave_through_pop.len]u8 = undefined;
    var after_pop = std.Io.Writer.fixed(&after_pop_buffer);
    try std.testing.expectError(
        error.WriteFailed,
        writeLeave(&after_pop, .{
            .alternate_screen = true,
            .hide_cursor = false,
            .bracketed_paste = false,
            .focus_events = false,
        }, &pushed),
    );
    try std.testing.expect(!pushed);
}
