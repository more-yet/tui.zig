const std = @import("std");
const input = @import("../input/event.zig");
const grapheme = @import("../text/grapheme.zig");
const kitty = @import("../graphics/kitty.zig");

pub const ColorDepth = enum {
    ansi16,
    indexed256,
    truecolor,
};

pub const FeatureSupport = enum {
    unknown,
    unsupported,
    supported,
};

/// Caller-supplied terminal policy. Negotiation never changes these values.
pub const Profile = struct {
    color_depth: ColorDepth = .ansi16,
    background_color_erase: bool = false,
    width_profile: grapheme.WidthProfile = .narrow,
};

pub const Capabilities = struct {
    color_depth: ColorDepth = .ansi16,
    synchronized_output: bool = false,
    background_color_erase: bool = false,
    kitty_keyboard: bool = false,
    kitty_graphics: bool = false,
    width_profile: grapheme.WidthProfile = .narrow,
};

pub const Observations = struct {
    kitty_keyboard: FeatureSupport = .unknown,
    kitty_graphics: FeatureSupport = .unknown,
    kitty_graphics_error: bool = false,
    synchronized_output: FeatureSupport = .unknown,
};

const FeatureState = enum {
    unknown,
    pending,
    unsupported,
    supported,
    failed,
};

const query_bytes = "\x1b[?u\x1b[c\x1b[?2026$p";

pub const ProbeFailure = struct {
    /// Both slices borrow the terminal-reply event and are valid only as long
    /// as that event's storage remains valid.
    code: []const u8,
    message: []const u8,
};

/// One bounded negotiation epoch for retained behavioral extensions.
pub const Negotiator = struct {
    profile: Profile = .{},
    kitty_keyboard: FeatureState = .unknown,
    kitty_graphics: FeatureState = .unknown,
    synchronized_output: FeatureState = .unknown,
    graphics_probe_id: u32 = 0,
    query_storage: [128]u8 = undefined,

    pub fn init(profile: Profile) Negotiator {
        return .{ .profile = profile };
    }

    pub fn capabilities(self: *const Negotiator) Capabilities {
        return .{
            .color_depth = self.profile.color_depth,
            .synchronized_output = self.synchronized_output == .supported,
            .background_color_erase = self.profile.background_color_erase,
            .kitty_keyboard = self.kitty_keyboard == .supported,
            .kitty_graphics = self.kitty_graphics == .supported,
            .width_profile = self.profile.width_profile,
        };
    }

    pub fn observations(self: *const Negotiator) Observations {
        return .{
            .kitty_keyboard = observed(self.kitty_keyboard),
            .kitty_graphics = observed(self.kitty_graphics),
            .kitty_graphics_error = self.kitty_graphics == .failed,
            .synchronized_output = observed(self.synchronized_output),
        };
    }

    pub fn beginQueries(self: *Negotiator) []const u8 {
        self.kitty_keyboard = .pending;
        self.synchronized_output = .pending;
        return query_bytes;
    }

    /// Starts opt-in graphics negotiation plus the existing keyboard,
    /// device-attributes, and synchronized-output queries. The nonzero probe ID
    /// is application-owned and must not be reused while an old reply can arrive.
    /// The returned slice borrows this negotiator until another query begins.
    pub fn beginGraphicsQueries(self: *Negotiator, probe_id: u32) ![]const u8 {
        if (probe_id == 0) return error.InvalidProbeId;
        if (self.kitty_graphics == .pending) return error.GraphicsQueryPending;
        self.kitty_keyboard = .pending;
        self.kitty_graphics = .pending;
        self.synchronized_output = .pending;
        self.graphics_probe_id = probe_id;
        return std.fmt.bufPrint(
            &self.query_storage,
            "\x1b_Ga=q,f=24,t=d,s=1,v=1,i={d};AAAA\x1b\\{s}",
            .{ probe_id, query_bytes },
        ) catch return error.QueryBufferTooSmall;
    }

    pub fn cancelQueries(self: *Negotiator) void {
        if (self.kitty_keyboard == .pending) self.kitty_keyboard = .unknown;
        if (self.kitty_graphics == .pending) {
            self.kitty_graphics = .unknown;
            self.graphics_probe_id = 0;
        }
        if (self.synchronized_output == .pending) self.synchronized_output = .unknown;
    }

    pub inline fn queriesPending(self: *const Negotiator) bool {
        return self.kitty_keyboard == .pending or self.kitty_graphics == .pending or
            self.synchronized_output == .pending;
    }

    pub fn observe(self: *Negotiator, value: input.Event) ?ProbeFailure {
        const reply = switch (value) {
            .terminal_reply => |reply| reply,
            else => return null,
        };
        if (reply.kind == .apc and self.kitty_graphics == .pending) {
            const parsed = kitty.Reply.parse(reply) catch return null;
            if (parsed.image_id != self.graphics_probe_id) return null;
            switch (parsed.status) {
                .ok => self.kitty_graphics = .supported,
                .remote_error => |failure| {
                    self.kitty_graphics = .failed;
                    self.graphics_probe_id = 0;
                    return .{ .code = failure.code, .message = failure.message };
                },
            }
            self.graphics_probe_id = 0;
            return null;
        }
        if (reply.kind != .csi) return null;

        if (self.kitty_keyboard == .pending and reply.final == 'u' and questionNumber(reply.raw) != null) {
            self.kitty_keyboard = .supported;
            return null;
        }
        if (reply.final == 'c' and isPrimaryDeviceAttributes(reply.raw)) {
            if (self.kitty_keyboard == .pending) self.kitty_keyboard = .unsupported;
            if (self.kitty_graphics == .pending) {
                self.kitty_graphics = .unsupported;
                self.graphics_probe_id = 0;
            }
        }
        if (self.synchronized_output == .pending and reply.final == 'y') {
            if (synchronizedReply(reply.raw)) |supported| {
                self.synchronized_output = if (supported) .supported else .unsupported;
            }
        }
        return null;
    }
};

fn observed(state: FeatureState) FeatureSupport {
    return switch (state) {
        .unknown, .pending, .failed => .unknown,
        .unsupported => .unsupported,
        .supported => .supported,
    };
}

fn questionNumber(raw: []const u8) ?u16 {
    if (raw.len < 2 or raw[0] != '?') return null;
    return std.fmt.parseInt(u16, raw[1..], 10) catch null;
}

fn isPrimaryDeviceAttributes(raw: []const u8) bool {
    if (raw.len < 2 or raw[0] != '?') return false;
    var parameters = std.mem.splitScalar(u8, raw[1..], ';');
    var count: usize = 0;
    while (parameters.next()) |parameter| {
        if (parameter.len == 0 or count == 16) return false;
        _ = std.fmt.parseInt(u16, parameter, 10) catch return false;
        count += 1;
    }
    return count != 0;
}

fn synchronizedReply(raw: []const u8) ?bool {
    const prefix = "?2026;";
    if (!std.mem.startsWith(u8, raw, prefix) or raw.len <= prefix.len + 1 or raw[raw.len - 1] != '$') return null;
    const status = std.fmt.parseInt(u8, raw[prefix.len .. raw.len - 1], 10) catch return null;
    if (status > 4) return null;
    return status == 1 or status == 2;
}
