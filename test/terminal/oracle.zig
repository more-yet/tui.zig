//! Native terminal oracle with bounded replies and image storage. Keep this at
//! a stable address: the stream borrows its terminal and callback context.
const Oracle = @This();
const std = @import("std");
pub const vt = @import("ghostty-vt");

allocator: std.mem.Allocator,
terminal: vt.Terminal,
stream: vt.TerminalStream,
reply_bytes: [4096]u8 = undefined,
reply_len: usize = 0,
reply_overflow: bool = false,
graphics_failure: bool = false,

pub const Options = struct {
    io: std.Io = .failing,
    cols: u16,
    rows: u16,
    replies: bool = true,
    images: ?vt.kitty.graphics.LoadingImage.Limits = null,
};

pub fn init(self: *Oracle, allocator: std.mem.Allocator, options: Options) !void {
    vt.sys.decode_png = decodePng;
    self.* = .{
        .allocator = allocator,
        .terminal = try .init(options.io, allocator, .{
            .cols = options.cols,
            .rows = options.rows,
            .max_scrollback_bytes = 0,
            .kitty_image_storage_limit = if (options.images != null) 1024 * 1024 else 0,
            .kitty_image_loading_limits = options.images orelse .direct,
        }),
        .stream = undefined,
    };
    self.stream = self.terminal.vtStream();
    if (options.replies) self.stream.handler.effects.write_pty = writePty;
}

pub fn deinit(self: *Oracle) void {
    self.stream.deinit();
    self.terminal.deinit(self.allocator);
    self.* = undefined;
}

pub fn write(self: *Oracle, bytes: []const u8) !void {
    self.stream.nextSlice(bytes);
    if (self.reply_overflow) return error.TerminalReplyOverflow;
    if (self.stream.handler.semantic_failure) return error.TerminalSemanticFailure;
    if (self.graphics_failure) return error.TerminalGraphicsFailure;
}

/// Borrowed until the next write. Copy before feeding more terminal output.
pub fn takeReplies(self: *Oracle) []const u8 {
    const bytes = self.reply_bytes[0..self.reply_len];
    self.reply_len = 0;
    return bytes;
}

fn writePty(handler: *vt.TerminalStream.Handler, bytes: []const u8) void {
    const stream: *vt.TerminalStream = @fieldParentPtr("handler", handler);
    const self: *Oracle = @fieldParentPtr("stream", stream);
    if (std.mem.startsWith(u8, bytes, "\x1b_G") and std.mem.indexOf(u8, bytes, ";OK\x1b\\") == null) {
        self.graphics_failure = true;
    }
    if (bytes.len > self.reply_bytes.len - self.reply_len) {
        self.reply_overflow = true;
        return;
    }
    @memcpy(self.reply_bytes[self.reply_len..][0..bytes.len], bytes);
    self.reply_len += bytes.len;
}

fn decodePng(allocator: std.mem.Allocator, bytes: []const u8) vt.sys.DecodeError!vt.sys.Image {
    const image = @import("wuffs").png.decode(allocator, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WuffsError, error.Overflow => return error.InvalidData,
    };
    return .{ .width = image.width, .height = image.height, .data = image.data };
}
