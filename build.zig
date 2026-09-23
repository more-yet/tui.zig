const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    if (target.result.cpu.arch != .x86_64 or target.result.os.tag != .linux or target.result.abi != .gnu) {
        @panic("tui supports only x86_64-linux-gnu");
    }

    const tui = b.addModule("tui", .{
        .root_source_file = b.path("src/tui.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    tui.linkSystemLibrary("util", .{});

    const demo_module = b.createModule(.{
        .root_source_file = b.path("examples/demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    demo_module.addImport("tui", tui);
    const demo = b.addExecutable(.{
        .name = "tui-demo",
        .root_module = demo_module,
    });
    b.installArtifact(demo);

    const compositions_module = b.createModule(.{
        .root_source_file = b.path("examples/compositions.zig"),
        .target = target,
        .optimize = optimize,
    });
    compositions_module.addImport("tui", tui);
    const compositions = b.addExecutable(.{
        .name = "tui-compositions",
        .root_module = compositions_module,
    });
    b.installArtifact(compositions);

    const unicode_generator_module = b.createModule(.{
        .root_source_file = b.path("tools/gen_unicode.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const unicode_generator = b.addExecutable(.{
        .name = "gen-unicode",
        .root_module = unicode_generator_module,
    });

    const unicode_update_run = b.addRunArtifact(unicode_generator);
    unicode_update_run.setCwd(b.path("."));
    const unicode_update = b.step("unicode-update", "Regenerate Unicode property tables");
    unicode_update.dependOn(&unicode_update_run.step);

    const unicode_check_run = b.addRunArtifact(unicode_generator);
    unicode_check_run.setCwd(b.path("."));
    unicode_check_run.addArg("--check");
    const unicode_check = b.step("unicode-check", "Verify generated Unicode tables are current");
    unicode_check.dependOn(&unicode_check_run.step);

    const unit_test_module = b.createModule(.{
        .root_source_file = b.path("test/contracts.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_test_module.addImport("tui", tui);
    unit_test_module.addImport("demo_app", demo_module);
    const unit_tests = b.addTest(.{
        .root_module = unit_test_module,
    });
    const unit_test_run = b.addRunArtifact(unit_tests);
    const unit_test_step = b.step("test-unit", "Run deterministic contract tests");
    unit_test_step.dependOn(&unit_test_run.step);

    const test_step = b.step("test", "Run contract tests and any enabled integration tests");
    test_step.dependOn(unit_test_step);

    const system_tests = b.addExecutable(.{ .name = "tui-system-tests", .root_module = b.createModule(.{
        .root_source_file = b.path("test/system/subprocess.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "tui", .module = tui }},
    }) });
    const system_test_step = b.step("test-system", "Run isolated Linux process contracts");
    test_step.dependOn(system_test_step);
    for ([_][]const u8{ "spawn", "closed_stdio", "close_range_denied", "close_range_unavailable", "auto_reap", "no_child_wait" }) |scenario| {
        const run = b.addRunArtifact(system_tests);
        run.step.name = b.fmt("subprocess {s}", .{scenario});
        run.addArg(scenario);
        run.expectExitCode(0);
        run.has_side_effects = true;
        system_test_step.dependOn(&run.step);
    }

    const terminal_test_step = b.step("test-terminal", "Run opt-in headless terminal tests (requires -Dterminal-tests=true)");
    if (b.option(bool, "terminal-tests", "Enable pinned libghostty-vt and private-PTY integration tests") orelse false) {
        test_step.dependOn(terminal_test_step);
        if (b.lazyDependency("ghostty", .{
            .target = target,
            .optimize = optimize,
            .@"emit-lib-vt" = true,
            .@"app-runtime" = .none,
            .simd = false,
            .@"vt-features" = "-all,+render-state,+formatter,+kitty-graphics",
        })) |ghostty| {
            const imports = [_]std.Build.Module.Import{
                .{ .name = "tui", .module = tui },
                .{ .name = "ghostty-vt", .module = ghostty.module("ghostty-vt") },
                .{ .name = "wuffs", .module = ghostty.module("ghostty-vt").import_table.get("wuffs").? },
            };
            const terminal_tests = b.addTest(.{ .root_module = b.createModule(.{
                .root_source_file = b.path("test/terminal/tests.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &imports,
            }) });
            terminal_tests.root_module.addImport("demo_app", demo_module);
            terminal_test_step.dependOn(&b.addRunArtifact(terminal_tests).step);

            const fixture = b.addExecutable(.{
                .name = "tui-pty-fixture",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("test/terminal/fixture.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                }),
            });
            const pty_tests = b.addExecutable(.{
                .name = "tui-pty-tests",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("test/terminal/pty.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &imports,
                }),
            });
            // Each scenario forks before initializing its oracle or doing I/O
            // that could start worker threads, and owns a private controlling PTY.
            for ([_][]const u8{
                "edit_resize",       "escape",                 "interrupt",               "terminate",
                "suspend_resume",    "oversize",               "silent",                  "forced_cleanup",
                "graphics_direct",   "graphics_file",          "graphics_temporary_file", "graphics_shared_memory",
                "graphics_oversize", "graphics_reply_timeout", "graphics_write_failure",
            }) |scenario| {
                const run = b.addRunArtifact(pty_tests);
                run.step.name = b.fmt("PTY {s}", .{scenario});
                run.addArtifactArg(fixture);
                run.addArtifactArg(demo);
                run.addArg(scenario);
                run.expectExitCode(0);
                run.has_side_effects = true;
                terminal_test_step.dependOn(&run.step);
            }
        }
    } else {
        terminal_test_step.dependOn(&b.addFail("Enable the test-only dependency with: zig build test-terminal -Dterminal-tests=true").step);
    }

    const demo_run = b.addRunArtifact(demo);
    if (b.args) |args| demo_run.addArgs(args);
    const demo_step = b.step("demo", "Run the interactive tui.zig portfolio");
    demo_step.dependOn(&demo_run.step);

    const example_step = b.step("example", "Compile examples");
    example_step.dependOn(&demo.step);
    example_step.dependOn(&compositions.step);

    const compositions_run = b.addRunArtifact(compositions);
    const compositions_step = b.step("compositions", "Run finite headless composition recipes");
    compositions_step.dependOn(&compositions_run.step);

    const benchmark_tui = b.createModule(.{
        .root_source_file = b.path("src/tui.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    benchmark_tui.linkSystemLibrary("util", .{});
    const benchmark_module = b.createModule(.{
        .root_source_file = b.path("bench/base.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    });
    benchmark_module.addImport("tui", benchmark_tui);
    const benchmark_demo = b.createModule(.{
        .root_source_file = b.path("examples/demo.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    });
    benchmark_demo.addImport("tui", benchmark_tui);
    benchmark_module.addImport("demo_app", benchmark_demo);
    const benchmark = b.addExecutable(.{
        .name = "tui-base-benchmark",
        .root_module = benchmark_module,
    });
    const benchmark_run = b.addRunArtifact(benchmark);
    if (b.args) |args| benchmark_run.addArgs(args);
    const benchmark_step = b.step("bench", "Run the ReleaseFast baseline benchmark");
    benchmark_step.dependOn(&benchmark_run.step);
}
