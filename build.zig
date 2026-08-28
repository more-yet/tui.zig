const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tui = b.addModule("tui", .{
        .root_source_file = b.path("src/tui.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (target.result.os.tag == .linux and target.result.abi == .gnu) tui.linkSystemLibrary("util", .{});

    const c_api = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_api.addImport("tui", tui);
    if (target.result.os.tag == .linux and target.result.abi == .gnu) c_api.linkSystemLibrary("util", .{});
    const library = b.addLibrary(.{
        .name = "tui",
        .root_module = c_api,
        .linkage = .static,
    });
    const shared_library = b.addLibrary(.{
        .name = "tui",
        .root_module = c_api,
        .linkage = .dynamic,
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
    });
    b.installArtifact(library);
    b.installArtifact(shared_library);
    b.getInstallStep().dependOn(&b.addInstallHeaderFile(b.path("include/tui.h"), "tui.h").step);

    const unit_tests = b.addTest(.{ .root_module = tui });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const unit_step = b.step("test-unit", "Run unit tests");
    unit_step.dependOn(&run_unit_tests.step);

    const conformance_module = b.createModule(.{
        .root_source_file = b.path("test/conformance/unicode.zig"),
        .target = target,
        .optimize = optimize,
    });
    conformance_module.addImport("tui", tui);
    conformance_module.addAnonymousImport("unicode_test_data", .{
        .root_source_file = b.path("tools/unicode/embed.zig"),
    });
    const conformance_tests = b.addTest(.{ .root_module = conformance_module });
    const run_conformance_tests = b.addRunArtifact(conformance_tests);
    const conformance_step = b.step("test-conformance", "Run standards conformance tests");
    conformance_step.dependOn(&run_conformance_tests.step);

    const integration_step = b.step("test-integration", "Run integration tests");
    const integration_paths = [_][]const u8{
        "test/integration/rendering.zig",
        "test/integration/input_terminal.zig",
        "test/integration/application.zig",
        "test/integration/allocation.zig",
    };
    for (integration_paths) |path| {
        const run = addTuiTest(b, tui, target, optimize, path);
        integration_step.dependOn(&run.step);
    }

    const model_step = b.step("test-model", "Run model-based tests");
    const run_model_tests = addTuiTest(b, tui, target, optimize, "test/model/public_contracts.zig");
    model_step.dependOn(&run_model_tests.step);

    const stress_step = b.step("test-stress", "Run deterministic stress tests");
    const run_stress_tests = addTuiTest(b, tui, target, optimize, "test/stress/state_machines.zig");
    stress_step.dependOn(&run_stress_tests.step);

    const consumer_build = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "-Doptimize=ReleaseSafe",
        "--cache-dir",
        "../../.zig-cache/consumer",
        "--prefix",
        "../../zig-out/consumer",
    });
    consumer_build.setCwd(b.path("test/consumer"));
    const consumer_step = b.step("test-consumer", "Compile an external package consumer");
    consumer_step.dependOn(&consumer_build.step);

    const c_abi_step = b.step("test-c-abi", "Build and run C11 and C++11 ABI consumers");
    const c_consumer = addCConsumer(b, target, optimize, library, "test/c/main.c", "tui-c-consumer", false);
    const cpp_consumer = addCConsumer(b, target, optimize, library, "test/c/main.cpp", "tui-cpp-consumer", true);
    c_abi_step.dependOn(&b.addRunArtifact(c_consumer).step);
    c_abi_step.dependOn(&b.addRunArtifact(cpp_consumer).step);
    c_abi_step.dependOn(&shared_library.step);

    const platform_step = b.step("test-platform", "Run platform tests");
    const subprocess_fixture_module = b.createModule(.{
        .root_source_file = b.path("test/platform/fixtures/pty_child.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const subprocess_fixture = b.addExecutable(.{
        .name = "tui-pty-child",
        .root_module = subprocess_fixture_module,
    });
    const fixture_options = b.addOptions();
    fixture_options.addOptionPath("fixture_path", subprocess_fixture.getEmittedBin());
    const platform_paths = [_][]const u8{
        "test/platform/posix.zig",
        "test/platform/posix_runtime.zig",
        "test/platform/posix_signals.zig",
        "test/platform/subprocess.zig",
    };
    for (platform_paths) |path| {
        const platform_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        platform_module.addImport("tui", tui);
        if (std.mem.eql(u8, path, "test/platform/subprocess.zig")) {
            platform_module.addImport("fixture_options", fixture_options.createModule());
        }
        if (target.result.os.tag == .linux) platform_module.linkSystemLibrary("util", .{});
        const run = b.addRunArtifact(b.addTest(.{ .root_module = platform_module }));
        platform_step.dependOn(&run.step);
    }

    const test_step = b.step("test", "Run the test suite");
    test_step.dependOn(unit_step);
    test_step.dependOn(conformance_step);
    test_step.dependOn(integration_step);
    test_step.dependOn(model_step);
    test_step.dependOn(stress_step);
    test_step.dependOn(platform_step);
    test_step.dependOn(consumer_step);
    test_step.dependOn(c_abi_step);

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
    const unicode_check = b.step("unicode-check", "Verify Unicode tables and grapheme conformance");
    unicode_check.dependOn(&unicode_check_run.step);
    unicode_check.dependOn(&run_conformance_tests.step);

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
    const demo_run = b.addRunArtifact(demo);
    if (b.args) |args| demo_run.addArgs(args);
    const demo_step = b.step("demo", "Run the interactive tui.zig portfolio");
    demo_step.dependOn(&demo_run.step);

    const console_module = b.createModule(.{
        .root_source_file = b.path("test/platform/fixtures/process_console.zig"),
        .target = target,
        .optimize = optimize,
    });
    console_module.addImport("tui", tui);
    const console = b.addExecutable(.{
        .name = "tui-process-console-fixture",
        .root_module = console_module,
    });
    fixture_options.addOptionPath("console_path", console.getEmittedBin());

    const demo_test_module = b.createModule(.{
        .root_source_file = b.path("test/integration/demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    demo_test_module.addImport("tui", tui);
    demo_test_module.addImport("demo_app", demo_module);
    const demo_tests = b.addTest(.{ .root_module = demo_test_module });
    const run_demo_tests = b.addRunArtifact(demo_tests);
    integration_step.dependOn(&run_demo_tests.step);
    fixture_options.addOptionPath("demo_path", demo.getEmittedBin());

    const c_showcase = addCConsumer(
        b,
        target,
        optimize,
        library,
        "test/c/showcase.c",
        "tui-c-showcase",
        false,
    );
    const verify_showcase = b.addRunArtifact(c_showcase);
    verify_showcase.addArg("--headless-hash");
    verify_showcase.expectStdOutEqual("3ef79199ac9f474c 8008\n");
    const verify_showcase_step = b.step("test-showcase", "Verify deterministic C showcase output");
    verify_showcase_step.dependOn(&verify_showcase.step);
    test_step.dependOn(verify_showcase_step);

    const library_directory = b.getInstallPath(.lib, "");
    const library_path_variable = if (b.graph.host.result.os.tag == .macos) "DYLD_LIBRARY_PATH" else "LD_LIBRARY_PATH";
    const expected_showcase = "3ef79199ac9f474c 8008\n";
    const bindings_step = b.step("bindings", "Build all language bindings");
    const test_bindings_step = b.step("test-bindings", "Test all language bindings and canonical showcases");
    test_bindings_step.dependOn(verify_showcase_step);

    const rust_build = b.addSystemCommand(&.{ "cargo", "build", "--locked", "--examples" });
    rust_build.setCwd(b.path("bindings/rust"));
    rust_build.step.dependOn(b.getInstallStep());
    bindings_step.dependOn(&rust_build.step);
    const rust_test = b.addSystemCommand(&.{ "cargo", "test", "--locked" });
    rust_test.setCwd(b.path("bindings/rust"));
    rust_test.setEnvironmentVariable(library_path_variable, library_directory);
    rust_test.step.dependOn(&rust_build.step);
    test_bindings_step.dependOn(&rust_test.step);
    const rust_showcase = b.addSystemCommand(&.{ "cargo", "run", "--locked", "--example", "showcase", "--", "--headless-hash" });
    rust_showcase.setCwd(b.path("bindings/rust"));
    rust_showcase.setEnvironmentVariable(library_path_variable, library_directory);
    rust_showcase.expectStdOutEqual(expected_showcase);
    rust_showcase.step.dependOn(&rust_test.step);
    test_bindings_step.dependOn(&rust_showcase.step);

    const go_build = b.addSystemCommand(&.{ "go", "build", "./..." });
    go_build.setCwd(b.path("bindings/go"));
    go_build.step.dependOn(b.getInstallStep());
    bindings_step.dependOn(&go_build.step);
    const go_test = b.addSystemCommand(&.{ "go", "test", "./..." });
    go_test.setCwd(b.path("bindings/go"));
    go_test.setEnvironmentVariable(library_path_variable, library_directory);
    go_test.step.dependOn(&go_build.step);
    test_bindings_step.dependOn(&go_test.step);
    const go_showcase = b.addSystemCommand(&.{ "go", "run", "./cmd/showcase", "--headless-hash" });
    go_showcase.setCwd(b.path("bindings/go"));
    go_showcase.setEnvironmentVariable(library_path_variable, library_directory);
    go_showcase.expectStdOutEqual(expected_showcase);
    go_showcase.step.dependOn(&go_test.step);
    test_bindings_step.dependOn(&go_showcase.step);

    const python_build = b.addSystemCommand(&.{ "uv", "build" });
    python_build.setCwd(b.path("bindings/python"));
    python_build.step.dependOn(b.getInstallStep());
    bindings_step.dependOn(&python_build.step);
    const python_test = b.addSystemCommand(&.{ "uv", "run", "--frozen", "--with-editable", ".", "-m", "unittest", "discover", "-s", "tests" });
    python_test.setCwd(b.path("bindings/python"));
    python_test.setEnvironmentVariable(library_path_variable, library_directory);
    python_test.step.dependOn(&python_build.step);
    test_bindings_step.dependOn(&python_test.step);
    const python_showcase = b.addSystemCommand(&.{ "uv", "run", "--frozen", "--with-editable", ".", "-m", "tui_zig.showcase", "--headless-hash" });
    python_showcase.setCwd(b.path("bindings/python"));
    python_showcase.setEnvironmentVariable(library_path_variable, library_directory);
    python_showcase.expectStdOutEqual(expected_showcase);
    python_showcase.step.dependOn(&python_test.step);
    test_bindings_step.dependOn(&python_showcase.step);

    const dotnet_build = b.addSystemCommand(&.{ "dotnet", "build", "Showcase/Showcase.csproj", "--configuration", "Release", "--nologo" });
    dotnet_build.setCwd(b.path("bindings/dotnet"));
    dotnet_build.step.dependOn(b.getInstallStep());
    bindings_step.dependOn(&dotnet_build.step);
    const dotnet_showcase = b.addSystemCommand(&.{ "dotnet", "run", "--no-build", "--configuration", "Release", "--project", "Showcase/Showcase.csproj", "--", "--headless-hash" });
    dotnet_showcase.setCwd(b.path("bindings/dotnet"));
    dotnet_showcase.setEnvironmentVariable(library_path_variable, library_directory);
    dotnet_showcase.expectStdOutEqual(expected_showcase);
    dotnet_showcase.step.dependOn(&dotnet_build.step);
    test_bindings_step.dependOn(&dotnet_showcase.step);

    const node_install = b.addSystemCommand(&.{ "npm", "ci" });
    node_install.setCwd(b.path("bindings/node"));
    node_install.step.dependOn(b.getInstallStep());
    const node_build = b.addSystemCommand(&.{ "npm", "run", "build" });
    node_build.setCwd(b.path("bindings/node"));
    node_build.step.dependOn(&node_install.step);
    bindings_step.dependOn(&node_build.step);
    const node_test = b.addSystemCommand(&.{ "npm", "test" });
    node_test.setCwd(b.path("bindings/node"));
    node_test.setEnvironmentVariable(library_path_variable, library_directory);
    node_test.step.dependOn(&node_build.step);
    test_bindings_step.dependOn(&node_test.step);
    const node_showcase = b.addSystemCommand(&.{ "node", "dist/showcase.js", "--headless-hash" });
    node_showcase.setCwd(b.path("bindings/node"));
    node_showcase.setEnvironmentVariable(library_path_variable, library_directory);
    node_showcase.expectStdOutEqual(expected_showcase);
    node_showcase.step.dependOn(&node_test.step);
    test_bindings_step.dependOn(&node_showcase.step);

    const example_step = b.step("example", "Compile examples");
    example_step.dependOn(&demo.step);
    example_step.dependOn(&c_showcase.step);

    const benchmark_tui = b.createModule(.{
        .root_source_file = b.path("src/tui.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    if (b.graph.host.result.os.tag == .linux and b.graph.host.result.abi == .gnu) {
        benchmark_tui.linkSystemLibrary("util", .{});
    }
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

fn addCConsumer(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    library: *std.Build.Step.Compile,
    path: []const u8,
    name: []const u8,
    cpp: bool,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = cpp,
    });
    module.addCSourceFile(.{
        .file = b.path(path),
        .flags = if (cpp) &.{"-std=c++11"} else &.{"-std=c11"},
    });
    module.addIncludePath(b.path("include"));
    const executable = b.addExecutable(.{
        .name = name,
        .root_module = module,
    });
    module.linkLibrary(library);
    return executable;
}

fn addTuiTest(
    b: *std.Build,
    tui: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    path: []const u8,
) *std.Build.Step.Run {
    const module = b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("tui", tui);
    return b.addRunArtifact(b.addTest(.{ .root_module = module }));
}
