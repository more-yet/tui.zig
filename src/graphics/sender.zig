const std = @import("std");
const kitty = @import("kitty.zig");

pub const Limits = struct {
    max_payload_bytes: usize = 64 * 1024 * 1024,
    max_pixels: u64 = 100_000_000,
    /// May reduce, but never increase, `Sender.max_local_name_bytes`.
    max_local_name_bytes: usize = Sender.max_local_name_bytes,
};

pub const Data = union(kitty.Medium) {
    direct: []const u8,
    file: []const u8,
    temporary_file: []const u8,
    shared_memory: []const u8,

    fn bytes(self: Data) []const u8 {
        return switch (self) {
            inline else => |value| value,
        };
    }
};

pub const Sender = struct {
    pub const max_source_chunk_bytes = 3_072;
    pub const max_base64_chunk_bytes = 4_096;
    pub const max_local_name_bytes = 2_048;
    pub const output_capacity = 4_608;

    const State = enum {
        idle,
        sending,
        cancellation_requested,
        sending_delete,
    };

    limits: Limits,
    command: kitty.Command = undefined,
    data: Data = undefined,
    response: kitty.ResponseMode = .all,
    state: State = .idle,
    source_offset: usize = 0,
    pending_source_count: usize = 0,
    pending_len: u16 = 0,
    pending_accepted: u16 = 0,
    first_chunk: bool = true,
    cancel_command: ?kitty.Delete = null,
    output: [output_capacity]u8 = undefined,

    pub fn init(limits: Limits) Sender {
        return .{ .limits = limits };
    }

    pub fn isActive(self: *const Sender) bool {
        return self.state != .idle;
    }

    /// Starts one validated operation. `data` is borrowed unchanged until the
    /// operation completes or its cancellation delete is fully acknowledged.
    pub fn begin(self: *Sender, command: kitty.Command, data: Data, response: kitty.ResponseMode) !void {
        if (self.state != .idle) return error.TransferActive;
        try self.validate(command, data);
        self.command = command;
        self.data = data;
        self.response = response;
        self.state = .sending;
        self.source_offset = 0;
        self.pending_source_count = 0;
        self.pending_len = 0;
        self.pending_accepted = 0;
        self.first_chunk = true;
        self.cancel_command = null;
    }

    pub fn beginCommand(self: *Sender, command: kitty.Command, response: kitty.ResponseMode) !void {
        return self.begin(command, .{ .direct = &.{} }, response);
    }

    /// Requests cancellation. Any accepted prefix remains stable; after its APC
    /// drains, the selected delete command aborts the terminal-side upload.
    pub fn cancel(self: *Sender, command: kitty.Delete) !void {
        if (self.state != .sending or self.command.transmission() == null) return error.NoActiveTransfer;
        try kitty.validate(.{ .delete = command });
        self.cancel_command = command;
        self.state = .cancellation_requested;
        if (self.pending_len == 0) {
            self.beginCancellationDelete();
        }
    }

    /// Returns a stable nonempty suffix, or null after completion. The slice is
    /// valid until its accepted prefix is passed to `consumeOutput`.
    pub fn outputStep(self: *Sender) !?[]const u8 {
        if (self.state == .idle) return null;
        if (self.pending_len != 0) return self.output[self.pending_accepted..self.pending_len];
        try self.generate();
        return self.output[0..self.pending_len];
    }

    pub fn consumeOutput(self: *Sender, count: usize) !void {
        if (self.pending_len == 0) return error.NoSenderOutput;
        const remaining: usize = self.pending_len - self.pending_accepted;
        if (count > remaining) return error.InvalidByteCount;
        if (count == 0) return;
        self.pending_accepted += @intCast(count);
        if (self.pending_accepted != self.pending_len) return;

        self.pending_len = 0;
        self.pending_accepted = 0;
        if (self.state == .sending_delete) {
            self.state = .idle;
            self.cancel_command = null;
            return;
        }
        if (self.state == .cancellation_requested) {
            self.beginCancellationDelete();
            return;
        }

        self.source_offset += self.pending_source_count;
        self.pending_source_count = 0;
        self.first_chunk = false;
        if (self.source_offset == self.data.bytes().len) self.state = .idle;
    }

    fn beginCancellationDelete(self: *Sender) void {
        self.command = .{ .delete = self.cancel_command.? };
        self.data = .{ .direct = &.{} };
        self.source_offset = 0;
        self.pending_source_count = 0;
        self.first_chunk = true;
        self.state = .sending_delete;
    }

    fn validate(self: *const Sender, command: kitty.Command, data: Data) !void {
        try kitty.validate(command);
        var control: [kitty.max_control_bytes]u8 = undefined;
        _ = try kitty.encodeControl(&control, command, .{ .response = .none });
        const bytes = data.bytes();
        const transmission = command.transmission();
        if (transmission == null) {
            if (bytes.len != 0) return error.UnexpectedPayload;
            return;
        }
        const tx = transmission.?;
        if (std.meta.activeTag(data) != tx.medium) return error.MediumMismatch;
        if (tx.data_size_bytes > self.limits.max_payload_bytes) return error.PayloadLimitExceeded;
        const pixels = std.math.mul(u64, tx.width_pixels, tx.height_pixels) catch return error.DimensionOverflow;
        if (pixels > self.limits.max_pixels) return error.PixelLimitExceeded;
        if (tx.format == .rgb or tx.format == .rgba) {
            if (tx.width_pixels == 0 or tx.height_pixels == 0) return error.InvalidDimensions;
        }
        if (tx.format == .png and tx.compression == .zlib and tx.data_size_bytes == 0) {
            return error.MissingDataSize;
        }
        if (tx.medium != .direct) {
            const name_limit = @min(self.limits.max_local_name_bytes, max_local_name_bytes);
            if (bytes.len == 0 or bytes.len > name_limit) return error.InvalidLocalName;
            if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidLocalName;
            if (tx.medium == .shared_memory and
                (bytes[0] != '/' or std.mem.indexOfScalar(u8, bytes[1..], '/') != null))
            {
                return error.InvalidLocalName;
            }
            if (tx.data_offset_bytes != 0 and tx.data_size_bytes == 0) return error.InvalidDataRange;
            _ = std.math.add(u32, tx.data_offset_bytes, tx.data_size_bytes) catch return error.DataRangeOverflow;
            return;
        }
        if (bytes.len > self.limits.max_payload_bytes) return error.PayloadLimitExceeded;
        if (bytes.len == 0) return error.InvalidDataLength;
        if (tx.data_offset_bytes != 0) return error.InvalidDataRange;
        if (tx.format == .png and tx.compression == .none) {
            try self.validatePng(bytes, tx);
        }
        if ((tx.format == .rgb or tx.format == .rgba) and tx.compression == .none) {
            const channels: u64 = if (tx.format == .rgb) 3 else 4;
            const expected = std.math.mul(u64, pixels, channels) catch return error.DimensionOverflow;
            if (expected != bytes.len) return error.InvalidDataLength;
        }
    }

    fn validatePng(self: *const Sender, bytes: []const u8, tx: kitty.Transmission) !void {
        const signature = "\x89PNG\r\n\x1a\n";
        if (bytes.len < 33 or !std.mem.eql(u8, bytes[0..signature.len], signature) or
            !std.mem.eql(u8, bytes[8..12], "\x00\x00\x00\x0d") or
            !std.mem.eql(u8, bytes[12..16], "IHDR"))
        {
            return error.InvalidPng;
        }
        const width = bigEndianU32(bytes[16..20]);
        const height = bigEndianU32(bytes[20..24]);
        if (width == 0 or height == 0) return error.InvalidPng;
        if (tx.width_pixels != 0 and tx.width_pixels != width) return error.InvalidDimensions;
        if (tx.height_pixels != 0 and tx.height_pixels != height) return error.InvalidDimensions;
        const pixels = std.math.mul(u64, width, height) catch return error.DimensionOverflow;
        if (pixels > self.limits.max_pixels) return error.PixelLimitExceeded;
    }

    fn generate(self: *Sender) !void {
        const bytes = self.data.bytes();
        const remaining = bytes.len - self.source_offset;
        const direct = std.meta.activeTag(self.data) == .direct;
        const source_count = if (direct) @min(remaining, max_source_chunk_bytes) else remaining;
        const more = direct and source_count < remaining;
        self.pending_source_count = source_count;

        var control_storage: [kitty.max_control_bytes]u8 = undefined;
        const control = try kitty.encodeControl(&control_storage, self.command, .{
            .first_chunk = self.first_chunk,
            .more_chunks = more,
            .response = self.response,
        });
        var len: usize = 0;
        try append(&self.output, &len, "\x1b_G");
        try append(&self.output, &len, control);
        try append(&self.output, &len, ";");
        len += try encodeBase64(self.output[len..], bytes[self.source_offset..][0..source_count]);
        try append(&self.output, &len, "\x1b\\");
        self.pending_len = @intCast(len);
    }
};

fn bigEndianU32(bytes: *const [4]u8) u32 {
    return (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) |
        bytes[3];
}

fn append(buffer: []u8, len: *usize, bytes: []const u8) !void {
    if (bytes.len > buffer.len - len.*) return error.SenderOutputTooLarge;
    @memcpy(buffer[len.*..][0..bytes.len], bytes);
    len.* += bytes.len;
}

fn encodeBase64(output: []u8, input: []const u8) !usize {
    const encoder = std.base64.standard.Encoder;
    const required = encoder.calcSize(input.len);
    if (output.len < required) return error.SenderOutputTooLarge;
    return encoder.encode(output[0..required], input).len;
}
