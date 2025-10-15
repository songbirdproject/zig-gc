const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // from bdwgc's build script; no threading on emscripten/wasi
    const default_enable_threads = !target.result.cpu.arch.isWasm();
    const threading = b.option(bool, "threading", "Enable multi-threading") orelse default_enable_threads;

    const module = blk: {
        const module = b.addModule("gc", .{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });

        const bdwgc = b.dependency("bdwgc", .{
            .target = target,
            .optimize = optimize,
            .enable_threads = threading,
            // disable unused features
            .build_cord = false,
            .enable_gcj_support = false,
            .enable_atomic_uncollectable = false,
            .enable_disclaim = false,
        });
        const artifact = bdwgc.artifact("gc");
        module.linkLibrary(artifact);

        const translated = b.addTranslateC(.{
            .root_source_file = artifact.getEmittedIncludeTree().path(b, "gc.h"),
            .target = target,
            .optimize = optimize,
        });

        const options = b.addOptions();
        options.addOption(bool, "threading", threading);
        translated.defineCMacro("GC_THREADS", null);
        const options_module = options.createModule();

        module.addImport("gc", translated.createModule());
        module.addImport("options", options_module);

        break :blk module;
    };

    {
        const tests = b.addTest(.{ .root_module = module });
        const run_tests = b.addRunArtifact(tests);

        const test_step = b.step("test", "Run library tests");
        test_step.dependOn(&run_tests.step);
    }

    {
        const example_module = b.createModule(.{
            .root_source_file = b.path("example/basic.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "gc", .module = module },
            },
        });

        const exe = b.addExecutable(.{
            .name = "example",
            .root_module = example_module,
        });
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("run_example", "run example");
        run_step.dependOn(&run_cmd.step);
    }
}
