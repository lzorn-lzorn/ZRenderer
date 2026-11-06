const std = @import("std");
const math = @import("zrenderer").math;
const environment = @import("zrenderer").environment;
const testing = std.testing;

test "environment map samples directions with finite positive pdf and radiance" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const width = 8;
    const height = 4;
    const pixels = try alloc.alloc(math.Color, width * height);
    // 一个亮斑（模拟太阳）+ 均匀天空。
    for (pixels) |*p| p.* = math.Color.init(0.1, 0.1, 0.1);
    pixels[0] = math.Color.init(100, 100, 100);

    const env = try environment.EnvironmentMap.build(alloc, pixels, width, height, math.Transform.identity(), 1.0);
    // 采样应返回有限非负 PDF 与有限非负辐亮度。
    for (0..200) |i| {
        const s = env.sampleDirection(@as(f64, @floatFromInt(i)) / 200.0, 0.5);
        try testing.expect(std.math.isFinite(s.pdf));
        try testing.expect(s.pdf >= 0);
        try testing.expectApproxEqAbs(@as(f64, 1), s.direction.length(), 1e-9);
        const r = env.radiance(s.direction);
        try testing.expect(std.math.isFinite(r.x) and r.x >= 0);
    }
    // 总权重应为正，说明亮度 CDF 已正确构建。
    try testing.expect(env.total_weight > 0);
    // 与采样方向一致的 pdf 应返回正数。
    const s = env.sampleDirection(0.3, 0.4);
    try testing.expect(env.pdf(s.direction) > 0);
}
