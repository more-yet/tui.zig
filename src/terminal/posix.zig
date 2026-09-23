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
    original: std.posix.termios,
    options: Options,
    terminal_restore_needed: bool = false,
    termios_restore_needed: bool = false,
    kitty_keyboard_requested: bool,
    kitty_keyboard_active: bool = false,
    alternate_screen_active: bool = false,
    bracketed_paste_active: bool = false,
    focus_events_active: bool = false,
    mouse_button_active: bool = false,
    mouse_sgr_active: bool = false,
    cursor_hidden: bool = false,
    transition: Transition = .idle,
    transition_index: u8 = 0,
    kitty_target: bool = false,
    current_command: Command = .none,
    command_offset: u8 = 0,

    /// Captures terminal state without changing it. The descriptor and its flags
    /// remain borrowed and must stay valid for the session lifetime.
    pub fn init(input: std.Io.File, options: Options) !Session {
        const original = try getTermiosOnce(input.handle);
        return .{
            .input = input,
            .original = original,
            .options = options,
            .kitty_keyboard_requested = options.kitty_keyboard,
        };
    }

    /// Applies raw input mode once and schedules visual entry commands.
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

    /// Schedules visual restoration. A partially accepted command must be drained first.
    pub fn beginLeave(self: *Session) !void {
        if (self.transition == .leaving) return;
        if (!self.terminal_restore_needed) return;
        if (self.command_offset != 0) return error.PartialOutputPending;
        self.startTransition(.leaving);
    }

    /// Schedules a Kitty keyboard stack transition after capability negotiation.
    pub fn beginKittyKeyboard(self: *Session, enabled: bool) !void {
        if (!self.terminal_restore_needed) {
            self.kitty_keyboard_requested = enabled;
            return;
        }
        if (self.transition != .active) return error.TransitionActive;
        if (enabled == self.kitty_keyboard_active) {
            self.kitty_keyboard_requested = enabled;
            return;
        }
        if (self.command_offset != 0) return error.PartialOutputPending;
        self.kitty_keyboard_requested = enabled;
        self.kitty_target = enabled;
        self.startTransition(.kitty);
    }

    /// Returns one stable, unaccepted command suffix without performing I/O.
    pub fn outputStep(self: *Session) ?[]const u8 {
        while (true) {
            if (self.current_command != .none) {
                const bytes = commandBytes(self.current_command);
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

    /// Acknowledges exactly the bytes accepted by one output operation.
    pub fn consumeOutput(self: *Session, count: usize) !void {
        if (self.current_command == .none) return error.NoSessionOutput;
        const bytes = commandBytes(self.current_command);
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

    /// Restores termios independently of visual output progress.
    pub fn restoreTermios(self: *Session) !void {
        if (!self.termios_restore_needed) return;
        try setTermiosOnce(self.input.handle, self.original);
        self.termios_restore_needed = false;
    }

    /// Terminates a partial control string, restores termios, and attempts one
    /// bounded leave write. Preserves errno and the caller's Session state.
    pub fn emergencyRestore(self: *const Session, output_fd: std.posix.fd_t) EmergencyRestoreResult {
        const caller_errno = std.c._errno().*;
        defer std.c._errno().* = caller_errno;

        var report: EmergencyRestoreResult = .{};
        const termios_result = std.posix.system.tcsetattr(self.input.handle, .NOW, &self.original);
        const termios_errno = std.posix.errno(termios_result);
        if (termios_errno != .SUCCESS) report.termios_errno = @intFromEnum(termios_errno);

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
            report.output_errno = @intFromEnum(write_errno);
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
                .kitty => if (self.transition_index == 0)
                    (if (self.kitty_target) .kitty_push else .kitty_pop)
                else
                    return null,
                .entering => switch (self.transition_index) {
                    0 => if (self.options.alternate_screen and !self.alternate_screen_active) .alternate_enter else null,
                    1 => if (self.options.bracketed_paste and !self.bracketed_paste_active) .paste_enter else null,
                    2 => if (self.options.focus_events and !self.focus_events_active) .focus_enter else null,
                    3 => if (self.options.mouse and !self.mouse_button_active) .mouse_button_enter else null,
                    4 => if (self.options.mouse and !self.mouse_sgr_active) .mouse_sgr_enter else null,
                    5 => if (self.kitty_keyboard_requested and !self.kitty_keyboard_active) .kitty_push else null,
                    6 => if (self.options.hide_cursor and !self.cursor_hidden) .cursor_hide else null,
                    else => return null,
                },
                .leaving => switch (self.transition_index) {
                    0 => .reset,
                    1 => if (self.cursor_hidden) .cursor_show else null,
                    2 => if (self.kitty_keyboard_active) .kitty_pop else null,
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
            .kitty_push => self.kitty_keyboard_active = true,
            .kitty_pop => self.kitty_keyboard_active = false,
            .cursor_hide => self.cursor_hidden = true,
            .cursor_show => self.cursor_hidden = false,
        }
    }
};

pub fn querySize(file: std.Io.File) !geometry.Size {
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
    return .{ .width = winsize.col, .height = winsize.row };
}

fn getTermiosOnce(fd: std.posix.fd_t) !std.posix.termios {
    var result: std.posix.termios = undefined;
    switch (std.posix.errno(std.posix.system.tcgetattr(fd, &result))) {
        .SUCCESS => return result,
        .INTR => return error.Interrupted,
        .BADF => return error.InvalidDescriptor,
        .NOTTY => return error.NotATerminal,
        else => return error.Unexpected,
    }
}

fn setTermiosOnce(fd: std.posix.fd_t, value: std.posix.termios) !void {
    switch (std.posix.errno(std.posix.system.tcsetattr(fd, .NOW, &value))) {
        .SUCCESS => {},
        .INTR => return error.Interrupted,
        .BADF => return error.InvalidDescriptor,
        .NOTTY => return error.NotATerminal,
        .IO => return error.ProcessOrphaned,
        else => return error.Unexpected,
    }
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

fn commandBytes(command: Command) []const u8 {
    return switch (command) {
        .none => &.{},
        .alternate_enter => "\x1b[?1049h",
        .paste_enter => "\x1b[?2004h",
        .focus_enter => "\x1b[?1004h",
        .mouse_button_enter => "\x1b[?1002h",
        .mouse_sgr_enter => "\x1b[?1006h",
        .kitty_push => "\x1b[>1u",
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
    append(buffer, &length, commandBytes(.reset));
    if (session.cursor_hidden) append(buffer, &length, commandBytes(.cursor_show));
    if (session.kitty_keyboard_active) append(buffer, &length, commandBytes(.kitty_pop));
    if (session.mouse_sgr_active) append(buffer, &length, commandBytes(.mouse_sgr_leave));
    if (session.mouse_button_active) append(buffer, &length, commandBytes(.mouse_button_leave));
    if (session.focus_events_active) append(buffer, &length, commandBytes(.focus_leave));
    if (session.bracketed_paste_active) append(buffer, &length, commandBytes(.paste_leave));
    if (session.alternate_screen_active) append(buffer, &length, commandBytes(.alternate_leave));
    return buffer[0..length];
}

fn append(buffer: []u8, length: *usize, bytes: []const u8) void {
    std.debug.assert(length.* + bytes.len <= buffer.len);
    @memcpy(buffer[length.*..][0..bytes.len], bytes);
    length.* += bytes.len;
}
