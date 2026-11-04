const std = @import("std");

// @brief 配置可执行程序、运行步骤及回归测试，共享 stb C 实现和 libc 链接。
// @param b Zig 构建图上下文，提供目标平台、优化模式及测试过滤选项。
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // @brief 编译 stb 单头文件 C 实现，用于 PNG 输出及图像加载。
    const c_flags = &.{ "-Wall", "-Wextra", "-Wpedantic" };
    exe_mod.addCSourceFile(.{ .file = b.path("vendor/stb_impl.c"), .flags = c_flags });

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

    // @brief 包根模块汇总全部手写源文件，供测试以 @import("zrenderer") 统一访问并共享类型。
    const src_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport("zrenderer", src_mod);
    test_mod.addCSourceFile(.{ .file = b.path("vendor/stb_impl.c"), .flags = c_flags });
    const filters: []const []const u8 = if (b.option([]const u8, "test-filter", "Only run tests matching this text")) |filter| &.{filter} else &.{};
    const tests = b.addTest(.{ .root_module = test_mod, .filters = filters });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run regression tests and render a small PNG");
    test_step.dependOn(&run_tests.step);
}
