const std = @import("std");
const tui = @import("tui");

pub const forms = @import("composition/forms.zig");
pub const responsive_table = @import("composition/responsive_table.zig");
pub const warning_log = @import("composition/warning_log.zig");
pub const deadline_progress = @import("composition/deadline_progress.zig");

pub fn main(init: std.process.Init) !void {
    var renderer_storage: tui.render.FixedRendererStorage(80, 16, 64, 32) = .{};
    var renderer = try tui.render.Renderer.init(renderer_storage.slices(), .{ .width = 80, .height = 16 });
    defer renderer.deinit();

    var name_storage: tui.editor.FixedStorage(32) = .{};
    var name_model = try tui.editor.Model.initSingleLine(name_storage.slices(), "Ada");
    var password_storage: tui.editor.FixedStorage(32) = .{};
    var password_model = try tui.editor.Model.initSingleLine(password_storage.slices(), "secret");
    var focus_storage: [4]tui.focus.Node = undefined;
    var form = try forms.App.init(&name_model, &password_model, &focus_storage);
    try form.layout(renderer.size());
    try draw(&renderer, &form);

    const rows = [_]responsive_table.Row{
        .{ .name = "renderer", .status = "ready", .detail = "incremental" },
        .{ .name = "runtime", .status = "idle", .detail = "event driven" },
    };
    var provider = responsive_table.Provider{ .rows = &rows };
    var table_state: tui.widget.ScrollState = .{};
    var table = responsive_table.App{ .provider = &provider, .state = &table_state };
    table.layout(renderer.size());
    try draw(&renderer, &table);

    var slots: [8]warning_log.Ring.Slot = undefined;
    var ring = warning_log.Ring.init(&slots);
    var log = warning_log.App{ .ring = &ring };
    log.layout(renderer.size());
    _ = try log.feed("one\ntwo\nthree\n");
    try draw(&renderer, &log);

    var progress = try deadline_progress.App.init(deadline_progress.timestamp(0), 5 * std.time.ns_per_s);
    progress.layout(renderer.size());
    _ = try progress.advance(deadline_progress.timestamp(2 * std.time.ns_per_s));
    try draw(&renderer, &progress);

    var stdout_buffer: [128]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try file_writer.interface.writeAll("composition recipes completed\n");
    try file_writer.interface.flush();
}

fn draw(renderer: *tui.render.Renderer, application: anytype) !void {
    var surface = renderer.surface(tui.render.Rect.fromSize(renderer.size()));
    try application.draw(&surface);
}
