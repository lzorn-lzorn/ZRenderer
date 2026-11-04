const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Compile the stb single-header C implementation for PNG output / image loading.
    const c_flags = &.{ "-Wall", "-Wextra", "-Wpedantic" };
    exe_mod.addCSourceFile(.{ .file = b.path("src/stb_impl.c"), .flags = c_flags });

    const exe = b.addExecutable(.{
        .name = "zrenderer",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the path tracer");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addCSourceFile(.{ .file = b.path("src/stb_impl.c"), .flags = c_flags });
    const filters: []const []const u8 = if (b.option([]const u8, "test-filter", "Only run tests matching this text")) |filter| &.{filter} else &.{};
    const tests = b.addTest(.{ .root_module = test_mod, .filters = filters });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run regression tests and render a small PNG");
    test_step.dependOn(&run_tests.step);
}
