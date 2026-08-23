const std = @import("std");
const input = @import("../input/event.zig");
const grapheme = @import("../text/grapheme.zig");

pub const ColorDepth = enum {
    ansi16,
    indexed256,
    truecolor,
};

pub const TextSizing = enum {
    none,
    explicit_width,
    scaling,
};

pub const FeatureSupport = enum {
    unknown,
    unsupported,
    supported,
};

pub const Rgb16 = struct {
    red: u16,
    green: u16,
    blue: u16,
};

pub const PrimaryDeviceAttributes = struct {
    pub const max_parameters = 16;

    values: [max_parameters]u16 = @splat(0),
    len: u8 = 0,

    pub fn parameters(self: *const PrimaryDeviceAttributes) []const u16 {
        return self.values[0..self.len];
    }
};

pub const SecondaryDeviceAttributes = struct {
    terminal_type: u32,
    firmware_version: u32,
    rom_cartridge: u32,
};

/// Diagnostic replies describe the current terminal endpoint, which may be a multiplexer.
pub const Observations = struct {
    primary_device_attributes: ?PrimaryDeviceAttributes = null,
    secondary_device_attributes: ?SecondaryDeviceAttributes = null,
    default_foreground: ?Rgb16 = null,
    default_background: ?Rgb16 = null,
    kitty_keyboard: FeatureSupport = .unknown,
    synchronized_output: FeatureSupport = .unknown,
};

/// Trusted local configuration, such as application policy or terminfo results.
pub const Profile = struct {
    color_depth: ColorDepth = .ansi16,
    background_color_erase: bool = false,
    clipboard_write: bool = false,
    hyperlinks: bool = false,
    width_profile: grapheme.WidthProfile = .narrow,

    /// Converts caller-read terminfo fields without reading process environment state.
    pub fn fromTerminfo(max_colors: ?u32, direct_color: bool, background_color_erase: bool) Profile {
        return .{
            .color_depth = if (direct_color)
                .truecolor
            else if (max_colors != null and max_colors.? >= 256)
                .indexed256
            else
                .ansi16,
            .background_color_erase = background_color_erase,
        };
    }
};

pub const Capabilities = struct {
    color_depth: ColorDepth = .ansi16,
    synchronized_output: bool = false,
    background_color_erase: bool = false,
    clipboard_write: bool = false,
    hyperlinks: bool = false,
    kitty_keyboard: bool = false,
    text_sizing: TextSizing = .none,
    width_profile: grapheme.WidthProfile = .narrow,
};

pub const Negotiator = struct {
    capabilities: Capabilities = .{},
    observations: Observations = .{},
    text_probe_positions: [3]input.CursorPosition = undefined,
    text_probe_count: u2 = 0,
    text_probe_active: bool = false,
    primary_query_pending: bool = false,
    secondary_query_pending: bool = false,
    foreground_query_pending: bool = false,
    background_query_pending: bool = false,
    kitty_query_pending: bool = false,
    synchronized_query_pending: bool = false,

    pub fn init(profile: Profile) Negotiator {
        return .{ .capabilities = .{
            .color_depth = profile.color_depth,
            .background_color_erase = profile.background_color_erase,
            .clipboard_write = profile.clipboard_write,
            .hyperlinks = profile.hyperlinks,
            .width_profile = profile.width_profile,
        } };
    }

    pub fn writeQueries(self: *Negotiator, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        self.cancelQueries();
        self.capabilities.kitty_keyboard = false;
        self.capabilities.synchronized_output = false;
        self.capabilities.text_sizing = .none;
        self.observations = .{};
        self.primary_query_pending = true;
        self.secondary_query_pending = true;
        self.foreground_query_pending = true;
        self.background_query_pending = true;
        self.kitty_query_pending = true;
        self.synchronized_query_pending = true;
        self.text_probe_active = true;
        errdefer self.cancelQueries();

        // DA1 immediately after the Kitty query is the protocol-defined unsupported barrier.
        try writer.writeAll("\x1b[?u\x1b[c\x1b[>0c\x1b[?2026$p");
        try writer.writeAll("\x1b]10;?\x1b\\\x1b]11;?\x1b\\");
        // OSC 66 support is detected by measuring the cursor after width and scaling probes.
        try writer.writeAll("\r\x1b[6n\x1b]66;w=2; \x07\x1b[6n\x1b]66;s=2; \x07\x1b[6n");
        try writer.flush();
    }

    pub fn cancelQueries(self: *Negotiator) void {
        self.text_probe_count = 0;
        self.text_probe_active = false;
        self.primary_query_pending = false;
        self.secondary_query_pending = false;
        self.foreground_query_pending = false;
        self.background_query_pending = false;
        self.kitty_query_pending = false;
        self.synchronized_query_pending = false;
    }

    pub inline fn queriesPending(self: *const Negotiator) bool {
        return self.text_probe_active or
            self.primary_query_pending or
            self.secondary_query_pending or
            self.foreground_query_pending or
            self.background_query_pending or
            self.kitty_query_pending or
            self.synchronized_query_pending;
    }

    pub fn observe(self: *Negotiator, value: input.Event) void {
        const reply = switch (value) {
            .terminal_reply => |reply| reply,
            .cursor_position => |position| {
                self.observeTextProbe(position);
                return;
            },
            else => return,
        };
        switch (reply.kind) {
            .csi => self.observeCsi(reply),
            .osc => self.observeOsc(reply.raw),
        }
    }

    fn observeCsi(self: *Negotiator, reply: input.TerminalReply) void {
        if (reply.final == 'c') {
            if (parsePrimaryAttributes(reply.raw)) |attributes| {
                if (self.primary_query_pending) {
                    self.observations.primary_device_attributes = attributes;
                    self.primary_query_pending = false;
                }
                if (self.kitty_query_pending) {
                    self.observations.kitty_keyboard = .unsupported;
                    self.kitty_query_pending = false;
                }
                return;
            }
            if (self.secondary_query_pending) {
                if (parseSecondaryAttributes(reply.raw)) |attributes| {
                    self.observations.secondary_device_attributes = attributes;
                    self.secondary_query_pending = false;
                }
            }
            return;
        }
        if (self.kitty_query_pending and reply.final == 'u' and questionNumber(reply.raw) != null) {
            self.capabilities.kitty_keyboard = true;
            self.observations.kitty_keyboard = .supported;
            self.kitty_query_pending = false;
        }
        if (self.synchronized_query_pending and reply.final == 'y') {
            if (synchronizedReply(reply.raw)) |supported| {
                self.capabilities.synchronized_output = supported;
                self.observations.synchronized_output = if (supported) .supported else .unsupported;
                self.synchronized_query_pending = false;
            }
        }
    }

    fn observeOsc(self: *Negotiator, raw: []const u8) void {
        if (self.foreground_query_pending) {
            if (parseOscColor(raw, "10;rgb:")) |color| {
                self.observations.default_foreground = color;
                self.foreground_query_pending = false;
                return;
            }
        }
        if (self.background_query_pending) {
            if (parseOscColor(raw, "11;rgb:")) |color| {
                self.observations.default_background = color;
                self.background_query_pending = false;
            }
        }
    }

    fn observeTextProbe(self: *Negotiator, position: input.CursorPosition) void {
        if (!self.text_probe_active) return;
        self.text_probe_positions[self.text_probe_count] = position;
        self.text_probe_count += 1;
        if (self.text_probe_count != self.text_probe_positions.len) return;

        const width_supported = advancedBy(self.text_probe_positions[0], self.text_probe_positions[1], 2);
        const scaling_supported = advancedBy(self.text_probe_positions[1], self.text_probe_positions[2], 2);
        if (scaling_supported) {
            self.capabilities.text_sizing = .scaling;
        } else if (width_supported) {
            self.capabilities.text_sizing = .explicit_width;
        }
        self.text_probe_active = false;
    }
};

fn parsePrimaryAttributes(raw: []const u8) ?PrimaryDeviceAttributes {
    if (raw.len < 2 or raw[0] != '?') return null;
    var result: PrimaryDeviceAttributes = .{};
    var parameters = std.mem.splitScalar(u8, raw[1..], ';');
    while (parameters.next()) |parameter| {
        if (parameter.len == 0 or result.len == PrimaryDeviceAttributes.max_parameters) return null;
        result.values[result.len] = std.fmt.parseInt(u16, parameter, 10) catch return null;
        result.len += 1;
    }
    return if (result.len == 0) null else result;
}

fn parseSecondaryAttributes(raw: []const u8) ?SecondaryDeviceAttributes {
    if (raw.len < 2 or raw[0] != '>') return null;
    var values: [3]u32 = undefined;
    var count: usize = 0;
    var parameters = std.mem.splitScalar(u8, raw[1..], ';');
    while (parameters.next()) |parameter| {
        if (parameter.len == 0 or count == values.len) return null;
        values[count] = std.fmt.parseInt(u32, parameter, 10) catch return null;
        count += 1;
    }
    if (count != values.len) return null;
    return .{
        .terminal_type = values[0],
        .firmware_version = values[1],
        .rom_cartridge = values[2],
    };
}

fn parseOscColor(raw: []const u8, prefix: []const u8) ?Rgb16 {
    if (!std.mem.startsWith(u8, raw, prefix)) return null;
    var components = std.mem.splitScalar(u8, raw[prefix.len..], '/');
    const red = parseColorComponent(components.next() orelse return null) orelse return null;
    const green = parseColorComponent(components.next() orelse return null) orelse return null;
    const blue = parseColorComponent(components.next() orelse return null) orelse return null;
    if (components.next() != null) return null;
    return .{ .red = red, .green = green, .blue = blue };
}

fn parseColorComponent(component: []const u8) ?u16 {
    if (component.len == 0 or component.len > 4) return null;
    for (component) |byte| if (!std.ascii.isHex(byte)) return null;
    const value = std.fmt.parseInt(u32, component, 16) catch return null;
    const bits: u5 = @intCast(component.len * 4);
    const maximum = (@as(u32, 1) << bits) - 1;
    return @intCast((value * 65_535 + maximum / 2) / maximum);
}

fn questionNumber(raw: []const u8) ?u16 {
    if (raw.len < 2 or raw[0] != '?') return null;
    return std.fmt.parseInt(u16, raw[1..], 10) catch null;
}

fn synchronizedReply(raw: []const u8) ?bool {
    const prefix = "?2026;";
    if (!std.mem.startsWith(u8, raw, prefix) or raw.len <= prefix.len + 1 or raw[raw.len - 1] != '$') {
        return null;
    }
    const status = std.fmt.parseInt(u8, raw[prefix.len .. raw.len - 1], 10) catch return null;
    if (status > 4) return null;
    return status != 0;
}

fn advancedBy(from: input.CursorPosition, to: input.CursorPosition, cells: u16) bool {
    return from.row == to.row and @as(u32, from.column) + cells == to.column;
}

test "capability negotiation records bounded replies and trusted profile" {
    try std.testing.expectEqual(
        ColorDepth.indexed256,
        Profile.fromTerminfo(256, false, true).color_depth,
    );
    try std.testing.expectEqual(
        ColorDepth.truecolor,
        Profile.fromTerminfo(16, true, false).color_depth,
    );
    var negotiator = Negotiator.init(.{
        .color_depth = .truecolor,
        .background_color_erase = true,
        .clipboard_write = true,
        .hyperlinks = true,
    });
    var output_buffer: [160]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    try negotiator.writeQueries(&output);
    try std.testing.expect(std.mem.startsWith(u8, output.buffered(), "\x1b[?u\x1b[c"));
    try std.testing.expect(std.mem.indexOf(u8, output.buffered(), "\x1b]10;?\x1b\\") != null);

    negotiator.observe(.{ .terminal_reply = .{ .kind = .csi, .final = 'u', .raw = "?7" } });
    negotiator.observe(.{ .terminal_reply = .{ .kind = .csi, .final = 'c', .raw = "?62;4;6;22" } });
    negotiator.observe(.{ .terminal_reply = .{ .kind = .csi, .final = 'c', .raw = ">1;4000;0" } });
    negotiator.observe(.{ .terminal_reply = .{ .kind = .csi, .final = 'y', .raw = "?2026;1$" } });
    negotiator.observe(.{ .terminal_reply = .{ .kind = .osc, .final = '\\', .raw = "10;rgb:ffff/8000/0000" } });
    negotiator.observe(.{ .terminal_reply = .{ .kind = .osc, .final = '\\', .raw = "11;rgb:0000/1111/ffff" } });
    negotiator.observe(.{ .cursor_position = .{ .row = 0, .column = 0 } });
    negotiator.observe(.{ .cursor_position = .{ .row = 0, .column = 2 } });
    negotiator.observe(.{ .cursor_position = .{ .row = 0, .column = 4 } });

    try std.testing.expectEqual(ColorDepth.truecolor, negotiator.capabilities.color_depth);
    try std.testing.expect(negotiator.capabilities.background_color_erase);
    try std.testing.expect(negotiator.capabilities.clipboard_write);
    try std.testing.expect(negotiator.capabilities.hyperlinks);
    try std.testing.expect(negotiator.capabilities.kitty_keyboard);
    try std.testing.expect(negotiator.capabilities.synchronized_output);
    try std.testing.expectEqual(TextSizing.scaling, negotiator.capabilities.text_sizing);
    try std.testing.expectEqual(FeatureSupport.supported, negotiator.observations.kitty_keyboard);
    try std.testing.expectEqual(FeatureSupport.supported, negotiator.observations.synchronized_output);
    try std.testing.expectEqualSlices(
        u16,
        &.{ 62, 4, 6, 22 },
        negotiator.observations.primary_device_attributes.?.parameters(),
    );
    try std.testing.expectEqual(@as(u32, 4000), negotiator.observations.secondary_device_attributes.?.firmware_version);
    try std.testing.expectEqual(@as(u16, 0x8000), negotiator.observations.default_foreground.?.green);
    try std.testing.expectEqual(@as(u16, 0x1111), negotiator.observations.default_background.?.green);
    try std.testing.expect(!negotiator.queriesPending());
}

test "DA1 barrier marks only a pending Kitty query unsupported" {
    var negotiator: Negotiator = .{};
    negotiator.observe(.{ .terminal_reply = .{ .kind = .csi, .final = 'c', .raw = "?1;2" } });
    try std.testing.expectEqual(FeatureSupport.unknown, negotiator.observations.kitty_keyboard);

    var output_buffer: [160]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    try negotiator.writeQueries(&output);
    negotiator.observe(.{ .terminal_reply = .{ .kind = .csi, .final = 'c', .raw = "?1;2" } });
    negotiator.observe(.{ .terminal_reply = .{ .kind = .csi, .final = 'u', .raw = "?7" } });
    try std.testing.expectEqual(FeatureSupport.unsupported, negotiator.observations.kitty_keyboard);
    try std.testing.expect(!negotiator.capabilities.kitty_keyboard);
}

test "malformed, failed, and cancelled queries stay conservative" {
    var negotiator: Negotiator = .{};
    var output_buffer: [160]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    try negotiator.writeQueries(&output);
    negotiator.observe(.{ .terminal_reply = .{
        .kind = .csi,
        .final = 'c',
        .raw = "?1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;16;17",
    } });
    negotiator.observe(.{ .terminal_reply = .{ .kind = .csi, .final = 'c', .raw = ">1;2" } });
    negotiator.observe(.{ .terminal_reply = .{ .kind = .csi, .final = 'y', .raw = "?2026;9$" } });
    negotiator.observe(.{ .terminal_reply = .{ .kind = .osc, .final = '\\', .raw = "10;rgb:ffff/zzzz/0000" } });
    try std.testing.expect(negotiator.queriesPending());
    negotiator.cancelQueries();
    try std.testing.expect(!negotiator.queriesPending());
    try std.testing.expectEqual(FeatureSupport.unknown, negotiator.observations.synchronized_output);
    try std.testing.expect(negotiator.observations.default_foreground == null);
    try std.testing.expect(negotiator.observations.primary_device_attributes == null);
    negotiator.observe(.{ .terminal_reply = .{ .kind = .csi, .final = 'u', .raw = "?7" } });
    negotiator.observe(.{ .terminal_reply = .{ .kind = .osc, .final = '\\', .raw = "10;rgb:ffff/ffff/ffff" } });
    try std.testing.expect(!negotiator.capabilities.kitty_keyboard);
    try std.testing.expect(negotiator.observations.default_foreground == null);

    var tiny_buffer: [1]u8 = undefined;
    var tiny = std.Io.Writer.fixed(&tiny_buffer);
    try std.testing.expectError(error.WriteFailed, negotiator.writeQueries(&tiny));
    try std.testing.expect(!negotiator.queriesPending());
    try std.testing.expect(!negotiator.capabilities.kitty_keyboard);
    try std.testing.expect(!negotiator.capabilities.synchronized_output);
}
