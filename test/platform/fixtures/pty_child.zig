const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();
    var output_buffer: [512]u8 = undefined;
    var output = stdout.writer(init.io, &output_buffer);
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 3 and std.mem.eql(u8, args[1], "check-fd")) {
        const fd = try std.fmt.parseInt(c_int, args[2], 10);
        const result = std.posix.system.fcntl(fd, std.posix.F.GETFD, @as(c_int, 0));
        const closed = std.posix.errno(result) == .BADF;
        try output.interface.print("FD_{s}\n", .{if (closed) "CLOSED" else "INHERITED"});
        try output.interface.flush();
        std.process.exit(if (closed) 0 else 9);
    }
    const initial_size = try querySize(init.io, stdin);
    try output.interface.print(
        "READY tty={any},{any},{any} size={d}x{d} arg={s}\n",
        .{
            try stdin.isTty(init.io),
            try stdout.isTty(init.io),
            try std.Io.File.stderr().isTty(init.io),
            initial_size.width,
            initial_size.height,
            if (args.len > 1) args[1] else "",
        },
    );
    try output.interface.flush();
    if (args.len > 1 and std.mem.eql(u8, args[1], "exit-now")) std.process.exit(0);
    if (args.len > 1 and std.mem.eql(u8, args[1], "flood")) {
        while (true) try stdout.writeStreamingAll(init.io, "flood output\n");
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "stop")) {
        try std.posix.raise(.STOP);
        try output.interface.writeAll("CONTINUED\n");
        try output.interface.flush();
    }

    var byte: [1]u8 = undefined;
    var buffers = [1][]u8{&byte};
    _ = try stdin.readStreaming(init.io, &buffers);
    const resized = try querySize(init.io, stdin);
    try output.interface.print("INPUT={c} size={d}x{d}\n", .{ byte[0], resized.width, resized.height });
    try output.interface.flush();
    std.process.exit(7);
}

fn querySize(io: std.Io, file: std.Io.File) !struct { width: u16, height: u16 } {
    var winsize: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    _ = try io.operate(.{ .device_io_control = .{
        .file = file,
        .code = std.posix.T.IOCGWINSZ,
        .arg = &winsize,
    } });
    return .{ .width = winsize.col, .height = winsize.row };
}
