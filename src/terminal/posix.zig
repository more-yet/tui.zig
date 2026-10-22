const std = @import("std");
const geometry = @import("../core/geometry.zig");

/// Native x86_64-linux-gnu libc ABI, including all 32 control characters.
pub const Termios = extern struct {
    iflag: std.os.linux.tc_iflag_t,
    oflag: std.os.linux.tc_oflag_t,
    cflag: std.os.linux.tc_cflag_t,
    lflag: std.os.linux.tc_lflag_t,
    line: u8,
    cc: [32]u8,
    ispeed: u32,
    ospeed: u32,
};

extern "c" fn tcgetattr(fd: c_int, value: *Termios) c_int;
extern "c" fn tcsetattr(fd: c_int, action: c_int, value: *const Termios) c_int;

const tcsanow: c_int = 0;

pub const KeyboardEnhancements = struct {
    disambiguate: bool = true,
    event_types: bool = false,
    alternate_keys: bool = false,
    all_keys: bool = false,
    associated_text: bool = false,

    fn validate(self: KeyboardEnhancements) error{InvalidKeyboardEnhancements}!void {
        if (self.associated_text and !self.all_keys) return error.InvalidKeyboardEnhancements;
    }

    fn flags(self: KeyboardEnhancements) u5 {
        return @as(u5, @intFromBool(self.disambiguate)) |
            (@as(u5, @intFromBool(self.event_types)) << 1) |
            (@as(u5, @intFromBool(self.alternate_keys)) << 2) |
            (@as(u5, @intFromBool(self.all_keys)) << 3) |
            (@as(u5, @intFromBool(self.associated_text)) << 4);
    }
};

pub const Options = struct {
    alternate_screen: bool = true,
    hide_cursor: bool = true,
    bracketed_paste: bool = true,
    focus_events: bool = true,
    mouse: bool = false,
    /// Null leaves the keyboard stack untouched. Releases for Enter/Tab/Backspace
    /// require event_types and all_keys; associated_text preserves generated text.
    kitty_keyboard: ?KeyboardEnhancements = null,
};

pub const EmergencyRestoreResult = struct {
    termios_errno: i32 = 0,
    output_errno: i32 = 0,
    requested_bytes: u16 = 0,
    written_bytes: u16 = 0,

    pub fn succeeded(self: EmergencyRestoreResult) bool {
        return self.termios_errno == 0 and self.output_errno == 0 and
            self.requested_bytes == self.written_bytes;
    }
};

const Transition = enum {
    idle,
    entering,
    active,
    kitty,
    leaving,
};

const Command = enum {
    none,
    alternate_enter,
    paste_enter,
    focus_enter,
    mouse_button_enter,
    mouse_sgr_enter,
    kitty_push,
    cursor_hide,
    reset,
    cursor_show,
    kitty_pop,
    mouse_sgr_leave,
    mouse_button_leave,
    focus_leave,
    paste_leave,
    alternate_leave,
};

pub const Session = struct {
    input: std.Io.File,
    original: Termios,
    options: Options,
    terminal_restore_needed: bool = false,
    termios_restore_needed: bool = false,
    kitty_keyboard_active: ?KeyboardEnhancements = null,
    alternate_screen_active: bool = false,
    bracketed_paste_active: bool = false,
    focus_events_active: bool = false,
    mouse_button_active: bool = false,
    mouse_sgr_active: bool = false,
    cursor_hidden: bool = false,
    transition: Transition = .idle,
    transition_index: u8 = 0,
    keyboard_command: [16]u8 = undefined,
    current_command: Command = .none,
    command_offset: u8 = 0,

    /// Borrows the descriptor without changing terminal state. Keep it open until cleanup.
    pub fn init(input: std.Io.File, options: Options) !Session {
        if (options.kitty_keyboard) |keyboard| try keyboard.validate();
        const original = try getTermiosOnce(input.handle);
        return .{
            .input = input,
            .original = original,
            .options = options,
        };
    }

    /// Enters raw mode; drive `outputStep()` to finish visual entry.
    pub fn beginEnter(self: *Session) !void {
        if (self.termios_restore_needed or self.terminal_restore_needed or self.transition != .idle) {
            return error.SessionActive;
        }
        const raw = makeRaw(self.original);
        self.termios_restore_needed = true;
        try setTermiosOnce(self.input.handle, raw);
        self.terminal_restore_needed = true;
        self.startTransition(.entering);
    }

    /// Drain any partially written command before leaving; restore termios separately.
    pub fn beginLeave(self: *Session) !void {
        if (self.transition == .leaving) return;
        if (!self.terminal_restore_needed) return;
        if (self.command_offset != 0) return error.PartialOutputPending;
        self.startTransition(.leaving);
    }

    /// Replaces the session-owned keyboard stack frame after draining any output.
    pub fn beginKittyKeyboard(self: *Session, enhancements: ?KeyboardEnhancements) !void {
        if (enhancements) |keyboard| try keyboard.validate();
        if (!self.terminal_restore_needed) {
            self.options.kitty_keyboard = enhancements;
            return;
        }
        if (self.transition != .active) return error.TransitionActive;
        self.options.kitty_keyboard = enhancements;
        if (std.meta.eql(enhancements, self.kitty_keyboard_active)) return;
        self.startTransition(.kitty);
    }

    /// Write the suffix, then `try session.consumeOutput(written)`; null means complete.
    pub fn outputStep(self: *Session) ?[]const u8 {
        while (true) {
            if (self.current_command != .none) {
                const bytes = commandBytes(self.current_command, self.options.kitty_keyboard, &self.keyboard_command);
                return bytes[self.command_offset..];
            }
            self.current_command = self.selectNextCommand() orelse {
                switch (self.transition) {
                    .entering, .kitty => self.transition = .active,
                    .leaving => {
                        self.transition = .idle;
                        self.terminal_restore_needed = false;
                    },
                    .idle, .active => {},
                }
                return null;
            };
        }
    }

    /// Pass only the actual accepted byte count, including partial writes.
    pub fn consumeOutput(self: *Session, count: usize) !void {
        if (self.current_command == .none) return error.NoSessionOutput;
        const bytes = commandBytes(self.current_command, self.options.kitty_keyboard, &self.keyboard_command);
        const remaining = bytes.len - self.command_offset;
        if (count > remaining) return error.InvalidByteCount;
        if (count == 0) return;
        self.command_offset += @intCast(count);
        if (self.command_offset != bytes.len) return;
        self.commitCommand(self.current_command);
        self.current_command = .none;
        self.command_offset = 0;
        self.transition_index += 1;
    }

    /// Call even when visual leave output fails.
    pub fn restoreTermios(self: *Session) !void {
        if (!self.termios_restore_needed) return;
        try setTermiosOnce(self.input.handle, self.original);
        self.termios_restore_needed = false;
    }

    /// Last-resort restoration after output failure; one bounded write, no retries.
    pub fn emergencyRestore(self: *const Session, output_fd: std.posix.fd_t) EmergencyRestoreResult {
        const caller_errno = std.c._errno().*;
        defer std.c._errno().* = caller_errno;

        var report: EmergencyRestoreResult = .{};
        const termios_result = tcsetattr(self.input.handle, tcsanow, &self.original);
        const termios_errno = std.posix.errno(termios_result);
        if (termios_errno != .SUCCESS) report.termios_errno = @backingInt(termios_errno);

        var buffer: [130]u8 = undefined;
        @memcpy(buffer[0..2], "\x1b\\");
        const leave = leaveSequence(self, buffer[2..]);
        const bytes = buffer[0 .. 2 + leave.len];
        report.requested_bytes = @intCast(bytes.len);
        const write_result = std.posix.system.write(output_fd, bytes.ptr, bytes.len);
        const write_errno = std.posix.errno(write_result);
        if (write_errno == .SUCCESS) {
            report.written_bytes = @intCast(write_result);
        } else {
            report.output_errno = @backingInt(write_errno);
        }
        return report;
    }

    fn startTransition(self: *Session, transition: Transition) void {
        self.transition = transition;
        self.transition_index = 0;
        self.current_command = .none;
        self.command_offset = 0;
    }

    fn selectNextCommand(self: *Session) ?Command {
        while (true) {
            const command: ?Command = switch (self.transition) {
                .idle, .active => return null,
                .kitty => switch (self.transition_index) {
                    0 => if (self.kitty_keyboard_active != null) .kitty_pop else null,
                    1 => if (self.options.kitty_keyboard != null) .kitty_push else null,
                    else => return null,
                },
                .entering => switch (self.transition_index) {
                    0 => if (self.options.alternate_screen and !self.alternate_screen_active) .alternate_enter else null,
                    1 => if (self.options.bracketed_paste and !self.bracketed_paste_active) .paste_enter else null,
                    2 => if (self.options.focus_events and !self.focus_events_active) .focus_enter else null,
                    3 => if (self.options.mouse and !self.mouse_button_active) .mouse_button_enter else null,
                    4 => if (self.options.mouse and !self.mouse_sgr_active) .mouse_sgr_enter else null,
                    5 => if (self.options.kitty_keyboard != null) .kitty_push else null,
                    6 => if (self.options.hide_cursor and !self.cursor_hidden) .cursor_hide else null,
                    else => return null,
                },
                .leaving => switch (self.transition_index) {
                    0 => .reset,
                    1 => if (self.cursor_hidden) .cursor_show else null,
                    2 => if (self.kitty_keyboard_active != null) .kitty_pop else null,
                    3 => if (self.mouse_sgr_active) .mouse_sgr_leave else null,
                    4 => if (self.mouse_button_active) .mouse_button_leave else null,
                    5 => if (self.focus_events_active) .focus_leave else null,
                    6 => if (self.bracketed_paste_active) .paste_leave else null,
                    7 => if (self.alternate_screen_active) .alternate_leave else null,
                    else => return null,
                },
            };
            if (command) |value| return value;
            self.transition_index += 1;
        }
    }

    fn commitCommand(self: *Session, command: Command) void {
        switch (command) {
            .none, .reset => {},
            .alternate_enter => self.alternate_screen_active = true,
            .alternate_leave => self.alternate_screen_active = false,
            .paste_enter => self.bracketed_paste_active = true,
            .paste_leave => self.bracketed_paste_active = false,
            .focus_enter => self.focus_events_active = true,
            .focus_leave => self.focus_events_active = false,
            .mouse_button_enter => self.mouse_button_active = true,
            .mouse_button_leave => self.mouse_button_active = false,
            .mouse_sgr_enter => self.mouse_sgr_active = true,
            .mouse_sgr_leave => self.mouse_sgr_active = false,
            .kitty_push => self.kitty_keyboard_active = self.options.kitty_keyboard,
            .kitty_pop => self.kitty_keyboard_active = null,
            .cursor_hide => self.cursor_hidden = true,
            .cursor_show => self.cursor_hidden = false,
        }
    }
};

pub const PixelSize = struct { width: u16, height: u16 };
pub const Geometry = struct {
    cells: geometry.Size,
    pixels: ?PixelSize,
};

pub fn queryGeometry(file: std.Io.File) !Geometry {
    var winsize: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const result = std.posix.system.ioctl(file.handle, @as(u32, std.posix.T.IOCGWINSZ), @intFromPtr(&winsize));
    switch (std.posix.errno(result)) {
        .SUCCESS => {},
        .INTR => return error.Interrupted,
        .BADF => return error.InvalidDescriptor,
        .NOTTY => return error.NotATerminal,
        else => return error.Unexpected,
    }
    if (winsize.col == 0 or winsize.row == 0) return error.TerminalSizeUnavailable;
    return .{
        .cells = .{ .width = winsize.col, .height = winsize.row },
        .pixels = if (winsize.xpixel == 0 or winsize.ypixel == 0) null else .{ .width = winsize.xpixel, .height = winsize.ypixel },
    };
}

fn getTermiosOnce(fd: std.posix.fd_t) !Termios {
    var result: Termios = undefined;
    switch (std.posix.errno(tcgetattr(fd, &result))) {
        .SUCCESS => return result,
        .INTR => return error.Interrupted,
        .BADF => return error.InvalidDescriptor,
        .NOTTY => return error.NotATerminal,
        else => return error.Unexpected,
    }
}

fn setTermiosOnce(fd: std.posix.fd_t, value: Termios) !void {
    switch (std.posix.errno(tcsetattr(fd, tcsanow, &value))) {
        .SUCCESS => {},
        .INTR => return error.Interrupted,
        .BADF => return error.InvalidDescriptor,
        .NOTTY => return error.NotATerminal,
        .IO => return error.ProcessOrphaned,
        else => return error.Unexpected,
    }
}

fn makeRaw(original: Termios) Termios {
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
    raw.cc[@backingInt(std.posix.V.MIN)] = 1;
    raw.cc[@backingInt(std.posix.V.TIME)] = 0;
    return raw;
}

fn commandBytes(command: Command, keyboard: ?KeyboardEnhancements, buffer: *[16]u8) []const u8 {
    return switch (command) {
        .none => &.{},
        .alternate_enter => "\x1b[?1049h",
        .paste_enter => "\x1b[?2004h",
        .focus_enter => "\x1b[?1004h",
        .mouse_button_enter => "\x1b[?1002h",
        .mouse_sgr_enter => "\x1b[?1006h",
        .kitty_push => std.fmt.bufPrint(buffer, "\x1b[>{d}u", .{keyboard.?.flags()}) catch unreachable,
        .cursor_hide => "\x1b[?25l",
        .reset => "\x1b[?2026l\x1b[0m\x1b[0 q",
        .cursor_show => "\x1b[?25h",
        .kitty_pop => "\x1b[<u",
        .mouse_sgr_leave => "\x1b[?1006l",
        .mouse_button_leave => "\x1b[?1002l",
        .focus_leave => "\x1b[?1004l",
        .paste_leave => "\x1b[?2004l",
        .alternate_leave => "\x1b[?1049l",
    };
}

fn leaveSequence(session: *const Session, buffer: []u8) []const u8 {
    if (!session.terminal_restore_needed) return buffer[0..0];
    var length: usize = 0;
    var keyboard_buffer: [16]u8 = undefined;
    append(buffer, &length, commandBytes(.reset, null, &keyboard_buffer));
    if (session.cursor_hidden) append(buffer, &length, commandBytes(.cursor_show, null, &keyboard_buffer));
    if (session.kitty_keyboard_active != null) append(buffer, &length, commandBytes(.kitty_pop, null, &keyboard_buffer));
    if (session.mouse_sgr_active) append(buffer, &length, commandBytes(.mouse_sgr_leave, null, &keyboard_buffer));
    if (session.mouse_button_active) append(buffer, &length, commandBytes(.mouse_button_leave, null, &keyboard_buffer));
    if (session.focus_events_active) append(buffer, &length, commandBytes(.focus_leave, null, &keyboard_buffer));
    if (session.bracketed_paste_active) append(buffer, &length, commandBytes(.paste_leave, null, &keyboard_buffer));
    if (session.alternate_screen_active) append(buffer, &length, commandBytes(.alternate_leave, null, &keyboard_buffer));
    return buffer[0..length];
}

fn append(buffer: []u8, length: *usize, bytes: []const u8) void {
    std.debug.assert(length.* + bytes.len <= buffer.len);
    @memcpy(buffer[length.*..][0..bytes.len], bytes);
    length.* += bytes.len;
}
