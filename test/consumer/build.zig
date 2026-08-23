const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tui_package = b.dependency("tui", .{ .target = target, .optimize = optimize });
    const executable = b.addExecutable(.{
        .name = "tui-consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    executable.root_module.addImport("tui", tui_package.module("tui"));
    b.installArtifact(executable);
}
