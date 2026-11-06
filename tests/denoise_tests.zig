const std = @import("std");
const math = @import("zrenderer").math;
const denoise = @import("zrenderer").denoise;
const testing = std.testing;

const Color = math.Color;
const Vec3 = math.Vec3;

test "joint bilateral denoise preserves the mean and reduces variance" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const width: usize = 32;
    const height: usize = 32;
    const image = try alloc.alloc(Color, width * height);
    const guides = try alloc.alloc(denoise.Guide, width * height);
    var prng = std.Random.DefaultPrng.init(0x1234);
    const rnd = prng.random();
    var len: f64 = 0;
    var sum_before: f64 = 0;
    for (image, 0..) |*p, i| {
        const noise = (rnd.float(f64) - 0.5) * 0.2;
        const v = 0.5 + noise;
        p.* = Color.init(v, v, v);
        sum_before += v;
        guides[i] = .{ .albedo = Color.init(0.5, 0.5, 0.5), .normal = Vec3.init(0, 1, 0), .depth = 5, .hit = true };
        len += 1;
    }
    var var_before: f64 = 0;
    for (image) |p| {
        const d = p.x - sum_before / len;
        var_before += d * d;
    }
    try denoise.denoiseJointBilateral(alloc, image, guides, width, height, .{ .radius = 3, .iterations = 2 });

    var sum_after: f64 = 0;
    for (image) |p| sum_after += p.x;
    var var_after: f64 = 0;
    for (image) |p| {
        const d = p.x - sum_after / len;
        var_after += d * d;
    }
    // 均值基本不变（纯噪声区域的双边滤波是归一化加权平均）。
    try testing.expectApproxEqAbs(sum_before / len, sum_after / len, 0.01);
    // 方差显著下降。
    try testing.expect(var_after < var_before * 0.5);
}

test "joint bilateral denoise keeps a sharp albedo edge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const width: usize = 32;
    const height: usize = 8;
    const image = try alloc.alloc(Color, width * height);
    const guides = try alloc.alloc(denoise.Guide, width * height);
    var prng = std.Random.DefaultPrng.init(0x5678);
    const rnd = prng.random();
    for (0..height) |y| {
        for (0..width) |x| {
            const i = y * width + x;
            const left = x < width / 2;
            const base: f64 = if (left) 0.1 else 0.9;
            const noise = (rnd.float(f64) - 0.5) * 0.04;
            const v = base + noise;
            image[i] = Color.init(v, v, v);
            // 反照率在边缘两侧截然不同，引导滤波器不应跨边缘平均。
            guides[i] = .{ .albedo = Color.init(base, base, base), .normal = Vec3.init(0, 1, 0), .depth = 5, .hit = true };
        }
    }
    try denoise.denoiseJointBilateral(alloc, image, guides, width, height, .{ .radius = 3, .iterations = 2 });
    const left_val = image[width / 2 - 1].x;
    const right_val = image[width / 2].x;
    // 边缘两侧仍保持约 0.1 与 0.9 的差异，没有被抹平。
    try testing.expect(left_val < 0.3);
    try testing.expect(right_val > 0.7);
}
