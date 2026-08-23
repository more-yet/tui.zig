const std = @import("std");

pub const max_title_bytes = 128;
pub const max_body_bytes = 1024;

pub const BellPolicy = enum {
    disabled,
    terminal,
};

pub const BellResult = enum {
    disabled,
    emitted,
};

pub const Urgency = enum {
    low,
    normal,
    critical,
};

/// Title and body slices are valid only for the synchronous backend callback.
pub const Notification = struct {
    title: []const u8 = "",
    body: []const u8,
    urgency: Urgency = .normal,
};

pub const ValidationError = error{
    EmptyBody,
    TitleTooLong,
    BodyTooLong,
    InvalidText,
};

pub const DispatchResult = enum {
    disabled,
    dispatched,
};

pub const Backend = struct {
    context: *anyopaque,
    dispatchFn: *const fn (*anyopaque, Notification) anyerror!void,

    /// `pointer` must point to a value with `notify(self, Notification) !void`.
    pub fn init(pointer: anytype) Backend {
        const Pointer = @TypeOf(pointer);
        const pointer_info = @typeInfo(Pointer);
        comptime {
            if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
                @compileError("notification backend must be a single-item pointer");
            }
        }
        const Adapter = struct {
            fn dispatch(context: *anyopaque, notification: Notification) anyerror!void {
                const typed: Pointer = @ptrCast(@alignCast(context));
                try typed.notify(notification);
            }
        };
        return .{ .context = @ptrCast(pointer), .dispatchFn = Adapter.dispatch };
    }
};

pub fn writeBell(writer: *std.Io.Writer, policy: BellPolicy) std.Io.Writer.Error!BellResult {
    if (policy == .disabled) return .disabled;
    try writer.writeByte(0x07);
    return .emitted;
}

/// Dispatch means only that the configured backend accepted the synchronous call.
pub fn dispatch(backend: ?Backend, notification: Notification) anyerror!DispatchResult {
    const active = backend orelse return .disabled;
    try validate(notification);
    try active.dispatchFn(active.context, notification);
    return .dispatched;
}

fn validate(notification: Notification) ValidationError!void {
    if (notification.body.len == 0) return error.EmptyBody;
    if (notification.title.len > max_title_bytes) return error.TitleTooLong;
    if (notification.body.len > max_body_bytes) return error.BodyTooLong;
    try validateText(notification.title);
    try validateText(notification.body);
}

fn validateText(text: []const u8) ValidationError!void {
    var index: usize = 0;
    while (index < text.len) {
        const first = text[index];
        if (first < 0x80) {
            if (first < 0x20 or first == 0x7f) return error.InvalidText;
            index += 1;
            continue;
        }
        const sequence_len = std.unicode.utf8ByteSequenceLength(first) catch return error.InvalidText;
        if (index + sequence_len > text.len) return error.InvalidText;
        const codepoint = std.unicode.utf8Decode(text[index .. index + sequence_len]) catch return error.InvalidText;
        if (codepoint >= 0x80 and codepoint <= 0x9f) return error.InvalidText;
        index += sequence_len;
    }
}

test "bell and notification dispatch are explicit and bounded" {
    var bell_buffer: [1]u8 = undefined;
    var bell = std.Io.Writer.fixed(&bell_buffer);
    try std.testing.expectEqual(BellResult.disabled, try writeBell(&bell, .disabled));
    try std.testing.expectEqual(BellResult.emitted, try writeBell(&bell, .terminal));
    try std.testing.expectEqualStrings("\x07", bell.buffered());

    const Collector = struct {
        calls: usize = 0,
        urgency: Urgency = .low,

        pub fn notify(self: *@This(), notification: Notification) !void {
            self.calls += 1;
            self.urgency = notification.urgency;
        }
    };
    var collector: Collector = .{};
    try std.testing.expectEqual(
        DispatchResult.disabled,
        try dispatch(null, .{ .body = "build complete" }),
    );
    try std.testing.expectEqual(
        DispatchResult.dispatched,
        try dispatch(Backend.init(&collector), .{
            .title = "tui.zig",
            .body = "build complete",
            .urgency = .critical,
        }),
    );
    try std.testing.expectEqual(@as(usize, 1), collector.calls);
    try std.testing.expectEqual(Urgency.critical, collector.urgency);
}

test "notification validation runs before the backend callback" {
    const Collector = struct {
        calls: usize = 0,

        pub fn notify(self: *@This(), _: Notification) !void {
            self.calls += 1;
        }
    };
    var collector: Collector = .{};
    const backend = Backend.init(&collector);
    const cases = [_]struct { expected: ValidationError, notification: Notification }{
        .{ .expected = error.EmptyBody, .notification = .{ .body = "" } },
        .{ .expected = error.InvalidText, .notification = .{ .body = "unsafe\x1b]9;message" } },
        .{ .expected = error.InvalidText, .notification = .{ .body = "line\nbreak" } },
        .{ .expected = error.InvalidText, .notification = .{ .body = "\xc2\x9d" } },
        .{ .expected = error.InvalidText, .notification = .{ .body = "\xff" } },
    };
    for (cases) |case| try std.testing.expectError(case.expected, dispatch(backend, case.notification));
    const long_title: [max_title_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(
        error.TitleTooLong,
        dispatch(backend, .{ .title = &long_title, .body = "body" }),
    );
    const long_body: [max_body_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.BodyTooLong, dispatch(backend, .{ .body = &long_body }));
    try std.testing.expectEqual(@as(usize, 0), collector.calls);
}
