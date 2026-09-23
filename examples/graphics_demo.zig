const std = @import("std");
const tui = @import("tui");

pub const probe_image_id: u32 = 4_000;
const first_image_id: u32 = 4_001;
const last_image_id: u32 = 4_004;
const stage_count = 16;

/// One shared layout for text exclusion, ordinary images, and placeholders.
/// The five-row footer leaves a heading and a bottom margin around the 6x3
/// layered swatch. The 2x2 placeholder and its relative child fit to its right.
pub const Layout = struct {
    heading_y: u16,

    pub fn forSize(size: tui.render.Size) ?Layout {
        // Keep at least two editor rows above the footer.
        if (size.width < 20 or size.height < 12) return null;
        return .{ .heading_y = size.height - 5 };
    }

    pub fn imageOrigin(self: Layout) tui.render.Point {
        return .{ .x = 2, .y = self.heading_y + 1 };
    }

    pub fn placeholderRect(self: Layout) tui.render.Rect {
        return .{ .x = 10, .y = self.heading_y + 1, .width = 2, .height = 2 };
    }
};

pub const Medium = tui.graphics.kitty.Medium;

const rgba = [_]u8{
    0xff, 0x40, 0x20, 0xff, 0x20, 0xff, 0x40, 0x80,
    0x20, 0x40, 0xff, 0x80, 0xff, 0xff, 0xff, 0x00,
};

// Complete 1x1 transparent PNG and an RFC 1950 stream containing twelve zero
// RGB bytes. The demo intentionally does no image encoding at runtime.
const png =
    "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01" ++
    "\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89" ++
    "\x00\x00\x00\x0aIDAT\x78\x9c\x63\x00\x01\x00\x00\x05" ++
    "\x00\x01\x0d\x0a\x2d\xb4\x00\x00\x00\x00IEND\xaeB\x60\x82";
const zlib_rgb =
    "\x78\x01\x01\x0c\x00\xf3\xff" ++ ("\x00" ** 12) ++ "\x00\x0c\x00\x01";

pub const Fixture = struct {
    medium: Medium,
    protocol_name: [160]u8 = undefined,
    protocol_name_len: usize = 0,
    local_path: [192:0]u8 = undefined,
    prepared: bool = false,

    pub fn init(medium: Medium) !Fixture {
        var result = Fixture{ .medium = medium };
        if (medium == .direct) return result;

        const pid = std.os.linux.getpid();
        const protocol_name = if (medium == .shared_memory)
            try std.fmt.bufPrint(&result.protocol_name, "/tui-zig-graphics-{d}", .{pid})
        else
            try std.fmt.bufPrint(&result.protocol_name, "/tmp/tui-zig-tty-graphics-protocol-{d}.rgba", .{pid});
        result.protocol_name_len = protocol_name.len;
        const path = if (medium == .shared_memory)
            try std.fmt.bufPrintZ(&result.local_path, "/dev/shm{s}", .{protocol_name})
        else
            try std.fmt.bufPrintZ(&result.local_path, "{s}", .{protocol_name});

        const opened = std.os.linux.open(
            path.ptr,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true },
            0o600,
        );
        if (std.os.linux.errno(opened) != .SUCCESS) return error.GraphicsFixtureCreateFailed;
        const fd: std.posix.fd_t = @intCast(opened);
        defer _ = std.os.linux.close(fd);
        errdefer _ = std.os.linux.unlink(path.ptr);
        var offset: usize = 0;
        while (offset < rgba.len) {
            const written = std.posix.system.write(fd, rgba[offset..].ptr, rgba.len - offset);
            switch (std.posix.errno(written)) {
                .SUCCESS => {
                    if (written == 0) return error.GraphicsFixtureWriteFailed;
                    offset += @intCast(written);
                },
                .INTR => continue,
                else => return error.GraphicsFixtureWriteFailed,
            }
        }
        result.prepared = true;
        return result;
    }

    pub fn deinit(self: *Fixture) void {
        if (!self.prepared) return;
        _ = std.os.linux.unlink(&self.local_path);
        self.prepared = false;
    }

    fn data(self: *const Fixture) tui.graphics.SenderData {
        const name = self.protocol_name[0..self.protocol_name_len];
        return switch (self.medium) {
            .direct => .{ .direct = &rgba },
            .file => .{ .file = name },
            .temporary_file => .{ .temporary_file = name },
            .shared_memory => .{ .shared_memory = name },
        };
    }
};

pub const Showcase = struct {
    const Sequence = union(enum) { idle, replay: u8, cleanup };
    const LocalUpload = enum { unused, awaiting_reply, accepted, failed };

    fixture: *const Fixture,
    sender: tui.graphics.Sender = tui.graphics.Sender.init(.{}),
    cursor_output: [16]u8 = undefined,
    cursor_len: u8 = 0,
    cursor_accepted: u8 = 0,
    sequence: Sequence = .idle,
    invalidate_output_state: bool = false,
    local_upload: LocalUpload = .unused,
    last_error: [160]u8 = undefined,
    last_error_len: u8 = 0,

    pub fn init(fixture: *const Fixture) Showcase {
        return .{ .fixture = fixture };
    }

    pub fn restart(self: *Showcase, size: tui.render.Size) !void {
        if (self.hasWork()) return error.GraphicsOutputActive;
        const layout = Layout.forSize(size) orelse {
            self.requestCleanup();
            return;
        };
        if (self.local_upload == .failed) return;
        // Explicitly discard previous placements/data, including those clipped
        // by a resize. Every ordinary placement preserves this cursor until the
        // burst completes; the caller must not interleave text presentation.
        try self.sender.beginCommand(ownedDelete(), .errors_only);
        const origin = layout.imageOrigin();
        const cursor = std.fmt.bufPrint(&self.cursor_output, "\x1b[{d};{d}H", .{
            @as(u32, origin.y) + 1, @as(u32, origin.x) + 1,
        }) catch unreachable;
        self.cursor_len = @intCast(cursor.len);
        self.cursor_accepted = 0;
        self.sequence = .{ .replay = 0 };
        self.invalidate_output_state = false;
    }

    pub fn hasWork(self: *const Showcase) bool {
        return self.cursor_len != 0 or self.sender.isActive() or self.sequence != .idle or self.invalidate_output_state;
    }

    pub fn needsReply(self: *const Showcase) bool {
        return self.fixture.medium != .direct and self.sequence == .replay and
            (self.local_upload == .unused or self.local_upload == .awaiting_reply);
    }

    pub fn waitingForReply(self: *const Showcase) bool {
        return self.needsReply() and self.local_upload == .awaiting_reply and !self.sender.isActive();
    }

    pub fn outputStep(self: *Showcase) !?[]const u8 {
        if (self.cursor_len != 0) return self.cursor_output[self.cursor_accepted..self.cursor_len];
        if (self.sender.isActive()) return self.sender.outputStep();
        switch (self.sequence) {
            .idle => return null,
            .cleanup => {
                try self.sender.beginCommand(ownedDelete(), .errors_only);
                self.sequence = .idle;
                self.invalidate_output_state = true;
            },
            .replay => |stage| {
                if (self.waitingForReply()) return null;
                if (stage == stage_count) {
                    self.sequence = .idle;
                    self.invalidate_output_state = true;
                    return null;
                }
                try self.beginStage(stage);
                self.sequence = .{ .replay = stage + 1 };
            },
        }
        return self.sender.outputStep();
    }

    pub fn consumeOutput(self: *Showcase, count: usize) !void {
        if (self.cursor_len != 0) {
            if (count > self.cursor_len - self.cursor_accepted) return error.InvalidByteCount;
            self.cursor_accepted += @intCast(count);
            if (self.cursor_accepted == self.cursor_len) {
                self.cursor_len = 0;
                self.cursor_accepted = 0;
            }
            return;
        }
        try self.sender.consumeOutput(count);
    }

    pub fn takeOutputInvalidation(self: *Showcase) bool {
        if (!self.invalidate_output_state) return false;
        self.invalidate_output_state = false;
        return true;
    }

    pub fn requestCleanup(self: *Showcase) void {
        // Each fixture command fits one small APC. Drain that command (and any
        // exposed CUP suffix), then delete the owned IDs. One sequence owns both
        // replay and cleanup, so they cannot be active together.
        self.sequence = .cleanup;
        self.invalidate_output_state = false;
    }

    pub fn observe(self: *Showcase, event: tui.input.Event) void {
        const terminal_reply = switch (event) {
            .terminal_reply => |reply| reply,
            else => return,
        };
        const reply = tui.graphics.kitty.Reply.parse(terminal_reply) catch return;
        if (reply.image_id < first_image_id or reply.image_id > last_image_id) return;
        const message = switch (reply.status) {
            .ok => {
                if (reply.image_id == first_image_id and reply.placement_id == 1 and self.local_upload == .awaiting_reply) {
                    self.local_upload = .accepted;
                }
                return;
            },
            .remote_error => |failure| failure.message,
        };
        if (reply.image_id == first_image_id and reply.placement_id == 1 and self.fixture.medium != .direct) {
            self.failLocalUpload(message);
            return;
        }
        self.setError(message);
    }

    pub fn failLocalUpload(self: *Showcase, message: []const u8) void {
        self.local_upload = .failed;
        self.setError(message);
        self.requestCleanup();
    }

    fn setError(self: *Showcase, message: []const u8) void {
        self.last_error_len = @intCast(@min(message.len, self.last_error.len));
        for (message[0..self.last_error_len], 0..) |byte, index| {
            self.last_error[index] = if (byte >= 0x20 and byte <= 0x7e) byte else '?';
        }
    }

    pub fn errorMessage(self: *const Showcase) []const u8 {
        return self.last_error[0..self.last_error_len];
    }

    fn beginStage(self: *Showcase, stage: u8) !void {
        const k = tui.graphics.kitty;
        switch (stage) {
            0 => {
                const replay_direct = self.local_upload == .accepted and
                    (self.fixture.medium == .temporary_file or self.fixture.medium == .shared_memory);
                try self.sender.begin(.{ .transmit_and_display = .{
                    .transmission = .{
                        .width_pixels = 2,
                        .height_pixels = 2,
                        .medium = if (replay_direct) .direct else self.fixture.medium,
                        .data_size_bytes = if (replay_direct or self.fixture.medium == .direct) 0 else rgba.len,
                        .identifiers = .{ .image_id = first_image_id, .placement_id = 1 },
                    },
                    .placement = .{ .columns = 6, .rows = 3, .z_order = -1, .cursor = .preserve },
                } }, if (replay_direct) .{ .direct = &rgba } else self.fixture.data(), if (self.fixture.medium == .direct)
                    .errors_only
                else
                    .all);
                if (self.fixture.medium != .direct and self.local_upload == .unused) self.local_upload = .awaiting_reply;
            },
            1 => try self.sender.beginCommand(.{ .display = .{
                .identifiers = .{ .image_id = first_image_id, .placement_id = 2 },
                .placement = .{
                    .source_x_pixels = 1,
                    .source_width_pixels = 1,
                    .source_height_pixels = 2,
                    .cell_x_offset_pixels = 1,
                    .cell_y_offset_pixels = 1,
                    .columns = 3,
                    .rows = 2,
                    .z_order = 1,
                    .cursor = .preserve,
                },
            } }, .errors_only),
            2 => try self.sender.begin(.{ .transmit = .{ .transmission = .{
                .format = .png,
                .identifiers = .{ .image_id = first_image_id + 1 },
            } } }, .{ .direct = png }, .errors_only),
            3 => try self.sender.begin(.{ .transmit = .{ .transmission = .{
                .format = .rgb,
                .width_pixels = 2,
                .height_pixels = 2,
                .compression = .zlib,
                .transient = true,
                .identifiers = .{ .image_id = first_image_id + 2 },
            } } }, .{ .direct = zlib_rgb }, .errors_only),
            4 => try self.sender.beginCommand(.{ .display = .{
                .identifiers = .{ .image_id = first_image_id + 2, .placement_id = 1 },
                .placement = .{ .columns = 2, .rows = 2, .z_order = -2, .cursor = .preserve },
            } }, .errors_only),
            5 => try self.sender.beginCommand(.{ .display = .{
                .identifiers = .{ .image_id = first_image_id, .placement_id = 10 },
                .placement = .{ .columns = 2, .rows = 2, .virtual = true, .cursor = .preserve },
            } }, .errors_only),
            6 => try self.sender.beginCommand(.{ .display = .{
                .identifiers = .{ .image_id = first_image_id + 1, .placement_id = 2 },
                .placement = .{
                    .columns = 2,
                    .rows = 2,
                    .parent_image_id = first_image_id,
                    .parent_placement_id = 10,
                    .parent_x_cells = 3,
                    .cursor = .preserve,
                },
            } }, .errors_only),
            7 => try self.sender.begin(.{ .transmit = .{ .transmission = .{
                .width_pixels = 2,
                .height_pixels = 2,
                .identifiers = .{ .image_id = last_image_id },
            } } }, .{ .direct = &rgba }, .errors_only),
            8 => try self.sender.begin(.{ .animation_frame = .{
                .transmission = .{
                    .width_pixels = 2,
                    .height_pixels = 2,
                    .identifiers = .{ .image_id = last_image_id },
                },
                .gap_ms = 120,
                .composition = .overwrite,
            } }, .{ .direct = &rgba }, .errors_only),
            9 => try self.sender.begin(.{ .animation_frame = .{
                .transmission = .{
                    .width_pixels = 1,
                    .height_pixels = 1,
                    .identifiers = .{ .image_id = last_image_id },
                },
                .destination_x_pixels = 1,
                .destination_y_pixels = 1,
                .edit_frame = 2,
                .composition = .overwrite,
            } }, .{ .direct = rgba[0..4] }, .errors_only),
            10 => try self.sender.beginCommand(.{ .compose_frames = .{
                .identifiers = .{ .image_id = last_image_id },
                .destination_frame = 1,
                .source_frame = 2,
                .width_pixels = 1,
                .height_pixels = 1,
                .composition = .alpha_blend,
            } }, .errors_only),
            11 => try self.sender.beginCommand(.{ .animation_control = .{
                .identifiers = .{ .image_id = last_image_id },
                .state = .run,
                .frame = 1,
                .gap_ms = 160,
                .current_frame = 1,
                .loops = 3,
            } }, .errors_only),
            12 => try self.sender.beginCommand(.{ .display = .{
                .identifiers = .{ .image_id = last_image_id, .placement_id = 1 },
                .placement = .{ .columns = 2, .rows = 2, .cursor = .preserve },
            } }, .errors_only),
            13 => try self.sender.beginCommand(.{ .delete = .{ .selector = .{
                .animation_frames = .{ .image_id = last_image_id, .frame = 2 },
            } } }, .errors_only),
            14 => try self.sender.beginCommand(.{ .delete = .{ .selector = .{
                .image_id = .{ .image_id = first_image_id, .placement_id = 2 },
            } } }, .errors_only),
            15 => try self.sender.beginCommand(.{ .animation_control = .{
                .identifiers = .{ .image_id = last_image_id },
                .state = k.AnimationState.stop,
                .current_frame = 1,
            } }, .errors_only),
            else => unreachable,
        }
    }
};

fn ownedDelete() tui.graphics.kitty.Command {
    return .{ .delete = .{ .selector = .{ .id_range = .{
        .free_data = true,
        .first = first_image_id,
        .last = last_image_id,
    } } } };
}
