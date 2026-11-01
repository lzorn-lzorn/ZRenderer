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
    exe_mod.addCSourceFile(.{ .file = b.path("src/stb_impl.c"), .flags = &.{} });

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
}
