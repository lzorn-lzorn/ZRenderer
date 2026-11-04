// @brief 独立验证主积分器的闭合介质输运；不以生产 BSDF 或介质公式生成解析参考。
// @notice 所有随机测试使用固定预算及种子，不做自适应停止；只分配测试自身的场景。
const std = @import("std");
const math = @import("math.zig");
const random = @import("random.zig");
const material = @import("material.zig");
const object = @import("object.zig");
const texture = @import("texture.zig");
const light = @import("light.zig");
const color = @import("color.zig");
const testing = std.testing;
const Vec3 = math.Vec3;
const Ray = math.Ray;
const white = Vec3.init(1, 1, 1);
const no_rr: i32 = 1000000;
const outside = Ray.init(.{ .z = -3 }, .{ .z = 1 }, 0.37);
const inside = Ray.init(.{}, .{ .z = 1 }, 0.37);

// @brief 逐通道比较并显式拒绝非有限结果。
fn expectColor(expected: Vec3, actual: Vec3, tolerance: f64) !void {
    for (0..3) |c| {
        try testing.expect(std.math.isFinite(actual.at(c)));
        try testing.expectApproxEqAbs(expected.at(c), actual.at(c), tolerance);
    }
}

// @brief 独立 Beer 解析式，不调用 medium.absorption/transmittance。
fn beer(sigma: Vec3, distance: f64) Vec3 {
    return .{ .x = @exp(-sigma.x * distance), .y = @exp(-sigma.y * distance), .z = @exp(-sigma.z * distance) };
}

// @brief 构造静止球；场景 arena 负责释放对象、材质以及 BVH。
fn sphere(a: std.mem.Allocator, center: Vec3, radius: f64, mat: *material.Material) !*object.Object {
    return object.newSphere(a, center, center, 0, 1, radius, mat);
}

// @brief 仅由当前测试提供的形状建立 BVH。
fn worldOf(a: std.mem.Allocator, shapes: []const *object.Object) !*object.BvhNode {
    return object.BvhNode.init(a, shapes, 0, shapes.len, 0, 1);
}

// @brief 固定种子的完整路径均值，终止路径也计入样本总数。
fn mean(ray: Ray, world: *object.BvhNode, lights: light.Sampler, count: usize, depth: i32, rr: f64, seed: u64) Vec3 {
    random.seed(seed);
    var sum: Vec3 = .{};
    for (0..count) |_| sum = sum.add(color.rayColorLit(ray, world, lights, depth, rr));
    return sum.div(@floatFromInt(count));
}

// @brief 两次工厂分配均由泄漏检测分配器追踪，成功路径显式释放两层对象。
fn allocateAndFree(a: std.mem.Allocator) !void {
    const params: material.Subsurface = .{ .ior = 1.54, .medium = .{ .sigma_a = .{ .x = 0.3, .y = 0.7, .z = 1.2 }, .sigma_s = 4, .g = 0.5 } };
    const mat = try material.newSubsurface(a, params);
    defer a.destroy(mat);
    defer a.destroy(mat.subsurface);
    try testing.expectEqualDeep(params, mat.subsurface.*);
    try testing.expect(mat.interiorMedium().? == &mat.subsurface.medium);
}

test "subsurface: factory ownership and both allocation failures are clean" {
    // @notice 包括第二次 Material 包装分配失败：必须回收第一次 Subsurface 分配。
    try testing.checkAllAllocationFailures(testing.allocator, allocateAndFree, .{});
    for (0..2) |index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = index });
        try testing.expectError(error.OutOfMemory, material.newSubsurface(failing.allocator(), .{}));
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

// @brief 非法参数应在分配之前被拒绝，手工构造的非法实例也不能暴露介质或散射样本。
fn expectInvalid(params: material.Subsurface) !void {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.InvalidParameter, material.newSubsurface(failing.allocator(), params));
    try testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
    var p = params;
    const mat: material.Material = .{ .subsurface = &p };
    const rec: object.HitRecord = .{ .front_face = true, .normal = .{ .z = -1 } };
    try testing.expect(!p.valid());
    try testing.expect(mat.interiorMedium() == null);
    try testing.expect(mat.bsdfSample(outside, &rec) == null);
}

test "subsurface: invalid IOR absorption scattering and anisotropy rejected before allocation" {
    for ([_]f64{ -1, 0, 1e-7, 1e7, std.math.nan(f64), math.infinity, -math.infinity }) |ior| {
        try expectInvalid(.{ .ior = ior });
    }
    for ([_]f64{ -0.001, std.math.nan(f64), math.infinity, -math.infinity }) |value| {
        try expectInvalid(.{ .medium = .{ .sigma_a = .{ .x = value } } });
        try expectInvalid(.{ .medium = .{ .sigma_a = .{ .y = value } } });
        try expectInvalid(.{ .medium = .{ .sigma_a = .{ .z = value } } });
        try expectInvalid(.{ .medium = .{ .sigma_s = value } });
    }
    for ([_]f64{ -1, -0.99, 0.99, 1, std.math.nan(f64), math.infinity, -math.infinity }) |g| {
        try expectInvalid(.{ .medium = .{ .g = g } });
    }
    // @notice 吸收与散射不是反照率，可大于一；折射率合法范围的两个端点均有效。
    for ([_]f64{ 1e-6, 1, 1e6 }) |ior| {
        var p: material.Subsurface = .{ .ior = ior, .medium = .{ .sigma_a = .{ .x = 8 }, .sigma_s = 12, .g = -0.989 } };
        try testing.expect(p.valid());
        try testing.expect((material.Material{ .subsurface = &p }).interiorMedium() != null);
    }
}

test "subsurface: boundary is nonemissive delta only and exposes borrowed interior" {
    var p: material.Subsurface = .{ .ior = 1, .medium = .{ .sigma_a = .{ .x = 2 }, .sigma_s = 4, .g = 0.6 } };
    const mat: material.Material = .{ .subsurface = &p };
    try testing.expect(mat.interiorMedium().? == &p.medium);
    try testing.expect(!mat.hasNonDelta());
    var glass: material.Dielectric = .{ .ir = 1.5 };
    try testing.expect((material.Material{ .dielectric = &glass }).interiorMedium() == null);
    for ([_]bool{ false, true }) |front| {
        const rec: object.HitRecord = .{ .front_face = front, .normal = .{ .z = -1 } };
        try expectColor(.{}, mat.emitted3(0.2, 0.7, .{ .x = 3 }), 0);
        try expectColor(.{}, mat.emitted5(outside, &rec, 0.2, 0.7, rec.p), 0);
        for ([_]Vec3{ .{ .z = 1 }, .{ .z = -1 }, .{ .x = 1 } }) |wi| {
            try expectColor(.{}, mat.bsdfEval(outside, &rec, wi), 0);
            try testing.expectEqual(@as(f64, 0), mat.bsdfPdf(outside, &rec, wi));
        }
        const sample = mat.bsdfSample(outside, &rec).?;
        try testing.expect(sample.is_delta);
        try expectColor(white, sample.weight, 0);
        try expectColor(outside.direction, sample.direction, 0);
        // @notice eta=1 的样本仍然真实跨界，不能用 eta!=1 判断活动介质。
        try testing.expectEqual(@as(f64, 1), sample.eta);
        try testing.expect(sample.direction.dot(rec.normal) < 0);
    }
}

test "subsurface: IOR one sphere absorbs a physical chord of two with unnormalized rays" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sigma = Vec3.init(0.2, 0.7, 1.3);
    const mat = try material.newSubsurface(a, .{ .ior = 1, .medium = .{ .sigma_a = sigma } });
    const world = try worldOf(a, &.{try sphere(a, .{}, 1, mat)});
    const background = Vec3.init(0.8, 0.6, 0.4);
    for ([_]f64{ 0.125, 1, 7, 32 }) |scale| {
        for (0..16) |seed| {
            random.seed(@intCast(seed));
            const ray = Ray.init(outside.origin, .{ .z = scale }, outside.time);
            // @notice 允许 1e-8 法线偏移造成的微小长度损失，但绝不把两米弦长替换为射线参数 t。
            try expectColor(beer(sigma, 2).mul(background), color.rayColorLit(ray, world, .{ .background = background }, no_rr, 0.9), 2e-8);
        }
    }
}

test "subsurface: first backface infers camera inside and absorbs one physical meter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sigma = Vec3.init(0, 0.7, 1.3);
    const mat = try material.newSubsurface(a, .{ .ior = 1, .medium = .{ .sigma_a = sigma } });
    const world = try worldOf(a, &.{try sphere(a, .{}, 1, mat)});
    for ([_]f64{ 0.125, 1, 7, 32 }) |scale| {
        const ray = Ray.init(.{}, .{ .z = scale }, 0.37);
        var rec: object.HitRecord = .{};
        try testing.expect(world.hit(ray, 0, math.infinity, &rec));
        try testing.expect(!rec.front_face);
        try testing.expectApproxEqAbs(@as(f64, 1), rec.t * scale, 1e-14);
        random.seed(103);
        // @notice 第一段未经 spawnRay，因而可用近机器精度检查 t*|direction|。
        try expectColor(beer(sigma, 1), color.rayColorLit(ray, world, .{ .background = white }, no_rr, 0.9), 1e-14);
    }
}

test "subsurface: separated same material spheres accumulate chords but not the air gap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sigma = Vec3.init(0.2, 0.4, 0.8);
    const mat = try material.newSubsurface(a, .{ .ior = 1, .medium = .{ .sigma_a = sigma } });
    for ([_]f64{ 4, 40 }) |separation| {
        const first = try sphere(a, .{}, 1, mat);
        const second = try sphere(a, .{ .z = separation }, 0.5, mat);
        const world = try worldOf(a, &.{ first, second });
        // @method 外部相机距离为 2+1=3；内部相机距离为 1+1=2，空气间隙完全不吸收。
        for ([_]Ray{ outside, inside }) |ray| {
            const distance: f64 = if (ray.origin.z == 0) 2 else 3;
            random.seed(104);
            try expectColor(beer(sigma, distance), color.rayColorLit(ray, world, .{ .background = white }, no_rr, 0.9), 3e-8);
        }
    }
}

test "subsurface: zero medium matches ideal dielectric and RNG state for every seed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lights: light.Sampler = .{ .background = .{ .x = 0.3, .y = 0.7, .z = 1.2 }, .sample_environment = true };
    for ([_]f64{ 0.8, 1, 1.5, 2.4 }) |ior| {
        const sub = try material.newSubsurface(a, .{ .ior = ior });
        const dielectric = try material.newDielectric(a, ior);
        const sub_world = try worldOf(a, &.{try sphere(a, .{}, 1, sub)});
        const glass_world = try worldOf(a, &.{try sphere(a, .{}, 1, dielectric)});
        for ([_]Ray{ outside, inside, Ray.init(.{ .x = 0.7, .z = -3 }, .{ .z = 3 }, 0.37) }) |ray| {
            for ([_]i32{ 0, 12 }) |depth| {
                for (0..128) |seed| {
                    random.seed(@intCast(seed));
                    const expected = color.rayColorLit(ray, glass_world, lights, depth, 0.8);
                    const next = random.randomDouble();
                    random.seed(@intCast(seed));
                    try expectColor(expected, color.rayColorLit(ray, sub_world, lights, depth, 0.8), 0);
                    try testing.expectEqual(next, random.randomDouble());
                }
            }
        }
    }
}

test "subsurface: conservative multiple scattering exits with exactly unit radiance" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]f64{ 3, 4 }) |sigma_s| {
        for ([_]f64{ -0.6, 0, 0.7 }) |g| {
            const mat = try material.newSubsurface(a, .{ .ior = 1, .medium = .{ .sigma_s = sigma_s, .g = g } });
            const world = try worldOf(a, &.{try sphere(a, .{}, 1, mat)});
            for ([_]Ray{ outside, Ray.init(.{}, .{ .z = 7 }, 0.37) }) |ray| {
                for (0..128) |seed| {
                    random.seed(@intCast(1000 + seed));
                    // @notice 每条完整路径都应为一；重复乘散射消光、相函数或余弦会直接失败。
                    try expectColor(white, color.rayColorLit(ray, world, .{ .background = white }, no_rr, 0.95), 2e-13);
                }
            }
        }
    }
}

test "subsurface: ballistic probability and absorbed random walk path length distribution" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const samples = 8192;
    const ballistic = @exp(@as(f64, -0.2));
    for ([_]f64{ 3, 4 }) |sigma_s| {
        const mat = try material.newSubsurface(a, .{ .ior = 1, .medium = .{ .sigma_a = .{ .x = 0.2, .y = 0.4 }, .sigma_s = sigma_s } });
        const world = try worldOf(a, &.{try sphere(a, .{}, 1, mat)});
        var unscattered: usize = 0;
        var sum: f64 = 0;
        random.seed(2011);
        for (0..samples) |_| {
            const result = color.rayColorLit(inside, world, .{ .background = white }, no_rr, 0.95);
            try testing.expect(result.x > 0 and result.x <= ballistic + 1e-12);
            try testing.expectApproxEqAbs(result.x * result.x, result.y, 2e-13);
            try testing.expectEqual(@as(f64, 1), result.z);
            if (@abs(result.x - ballistic) < 1e-12) unscattered += 1;
            sum += result.x;
        }
        // @method 中心到球面距离一，零碰撞原子质量为 exp(-sigma_s)；容差大于六倍二项标准误。
        try testing.expectApproxEqAbs(@exp(-sigma_s), @as(f64, @floatFromInt(unscattered)) / samples, 0.015);
        // @notice 多数路径必须具有额外空间行程，不能只在原点抽方向或把总距离固定为半径。
        try testing.expect(sum / samples < ballistic * 0.95);
    }
}

test "subsurface: scattering with absorption responds monotonically to physical thickness" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mat = try material.newSubsurface(a, .{ .ior = 1, .medium = .{ .sigma_a = .{ .x = 0.35, .y = 0.7 }, .sigma_s = 3 } });
    const small = try worldOf(a, &.{try sphere(a, .{}, 0.5, mat)});
    const large = try worldOf(a, &.{try sphere(a, .{}, 1.5, mat)});
    var small_sum: f64 = 0;
    var large_sum: f64 = 0;
    for (0..1024) |seed| {
        random.seed(@intCast(3000 + seed));
        const thin = color.rayColorLit(inside, small, .{ .background = white }, no_rr, 0.95);
        random.seed(@intCast(3000 + seed));
        const thick = color.rayColorLit(inside, large, .{ .background = white }, no_rr, 0.95);
        // @method 共享随机数使大球路径包含小球退出之前的全部行程；因此逐样本而非仅均值单调。
        try testing.expect(thick.x <= thin.x + 1e-13 and thick.y <= thin.y + 1e-13);
        try testing.expectEqual(@as(f64, 1), thick.z);
        small_sum += thin.x;
        large_sum += thick.x;
    }
    try testing.expect(large_sum < 0.8 * small_sum);
}

// @brief 独立各向同性随机游走参考：单位球解析出口、世界空间均匀方向、自有 PRNG。
// @notice 不调用生产求交、介质、相函数、BSDF、射线偏移或积分器；仅比较统计期望。
fn isotropicReference(sigma_a: Vec3, sigma_s: f64, count: usize) Vec3 {
    var prng = std.Random.DefaultPrng.init(0x9af02);
    const rng = prng.random();
    var sum: Vec3 = .{};
    for (0..count) |_| {
        var p: Vec3 = .{};
        var w = Vec3.init(0, 0, 1);
        var length: f64 = 0;
        while (true) {
            const b = p.dot(w);
            const exit = -b + @sqrt(@max(0, b * b + 1 - p.lengthSquared()));
            const distance = -@log(1 - rng.float(f64)) / sigma_s;
            length += @min(distance, exit);
            if (distance >= exit) break;
            p = p.add(w.scale(distance));
            const z = 2 * rng.float(f64) - 1;
            const phi = 2 * math.pi * rng.float(f64);
            const r = @sqrt(1 - z * z);
            w = .{ .x = r * @cos(phi), .y = r * @sin(phi), .z = z };
        }
        sum = sum.add(beer(sigma_a, length));
    }
    return sum.div(@floatFromInt(count));
}

test "subsurface: absorbed multiple scattering agrees with independent spatial reference" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sigma = Vec3.init(0.2, 0.6, 1);
    const mat = try material.newSubsurface(a, .{ .ior = 1, .medium = .{ .sigma_a = sigma, .sigma_s = 3 } });
    const world = try worldOf(a, &.{try sphere(a, .{}, 1, mat)});
    const reference = isotropicReference(sigma, 3, 16384);
    const actual = mean(Ray.init(.{}, .{ .z = 7 }, 0.37), world, .{ .background = white }, 8192, no_rr, 0.95, 4001);
    // @method 两个独立有界 [0,1] 均值的合并标准误至多 0.00677；0.041 超过六倍该上界。
    try expectColor(reference, actual, 0.041);
}

// @brief 翻转几何外向侧；保存的法线仍应朝向入射方向。
fn flip(a: std.mem.Allocator, shape: *object.Object) !*object.Object {
    const face = try a.create(object.FlipFace);
    face.* = .{ .ptr = shape };
    const wrapper = try a.create(object.Object);
    wrapper.* = .{ .flip_face = face };
    return wrapper;
}

test "subsurface: off axis exterior colored emitter is reached only by spatial scattering" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const emission = Vec3.init(2, 0.5, 0.125);
    var lamp: material.DiffuseLight = .{ .emit = try texture.newSolid(a, emission) };
    var lamp_mat: material.Material = .{ .diffuse_light = &lamp };
    const emitter = try flip(a, try object.newXzRect(a, -3, 3, -3, 3, 2, &lamp_mat));
    const ballistic_mat = try material.newSubsurface(a, .{ .ior = 1 });
    const scatter_mat = try material.newSubsurface(a, .{ .ior = 1, .medium = .{ .sigma_s = 4 } });
    const ballistic_world = try worldOf(a, &.{ try sphere(a, .{}, 1, ballistic_mat), emitter });
    const scatter_world = try worldOf(a, &.{ try sphere(a, .{}, 1, scatter_mat), emitter });
    var hits: usize = 0;
    const samples = 4096;
    for (0..samples) |seed| {
        random.seed(@intCast(5000 + seed));
        try expectColor(.{}, color.rayColorLit(outside, ballistic_world, .{ .area = emitter }, no_rr, 0.95), 0);
        random.seed(@intCast(5000 + seed));
        const result = color.rayColorLit(outside, scatter_world, .{ .area = emitter }, no_rr, 0.95);
        if (result.x > 0) {
            hits += 1;
            // @notice 体积路径通过 delta 出口命中灯，MIS 权重必须为一，不能错误减弱颜色。
            try expectColor(emission, result, 2e-13);
        } else try expectColor(.{}, result, 0);
    }
    // @notice 宽阈值只要求稳定的非零侧向输运；避免把个别罕见命中作为成功依据。
    try testing.expect(hits > samples / 100 and hits < samples / 2);
}

test "subsurface: Fresnel entry exit pair conserves energy and absorbing reflections retain medium" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ior: f64 = 2;
    const f: f64 = 1.0 / 9.0;
    const sigma = Vec3.init(0, 0.4, 1.1);
    const mat = try material.newSubsurface(a, .{ .ior = ior, .medium = .{ .sigma_a = sigma } });
    const world = try worldOf(a, &.{try sphere(a, .{}, 1, mat)});
    const attenuation = beer(sigma, 2);
    var expected: Vec3 = .{};
    // @method 从外部法向入射：F+(1-F)^2 A/(1-F A)，A=exp(-2 sigma_a)；完整 eta 因子相消。
    expected.x = f + (1 - f) * (1 - f) * attenuation.x / (1 - f * attenuation.x);
    expected.y = f + (1 - f) * (1 - f) * attenuation.y / (1 - f * attenuation.y);
    expected.z = f + (1 - f) * (1 - f) * attenuation.z / (1 - f * attenuation.z);
    const actual = mean(outside, world, .{ .background = white }, 32768, no_rr, 0.95, 6001);
    try testing.expectApproxEqAbs(@as(f64, 1), actual.x, 1e-13);
    // @notice 每通道位于 [0,1]，0.02 大于六倍最坏均值标准误 0.00277。
    try expectColor(expected, actual, 0.02);
}

// @brief 独立 Fresnel 偏振平均，仅用于非全反射出口的解析级数参考。
fn fresnel(ior: f64, cosine: f64) f64 {
    const transmitted = @sqrt(1 - ior * ior * (1 - cosine * cosine));
    const rs = (ior * cosine - transmitted) / (ior * cosine + transmitted);
    const rp = (cosine - ior * transmitted) / (cosine + ior * transmitted);
    return (rs * rs + rp * rp) / 2;
}

test "subsurface: camera inside TIR keeps absorption until a later transmissive face" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sigma = Vec3.init(0.2, 0.5, 0.9);
    const ior: f64 = 1.5;
    const mat = try material.newSubsurface(a, .{ .ior = ior, .medium = .{ .sigma_a = sigma } });
    // @notice 手工构造外向朝向一致的六面闭合体，不依赖 Box 的面朝向约定。
    const world = try worldOf(a, &.{
        try object.newYzRect(a, -1, 1, -1, 1, 0.3, mat),
        try flip(a, try object.newYzRect(a, -1, 1, -1, 1, -0.3, mat)),
        try object.newXzRect(a, -0.3, 0.3, -1, 1, 1, mat),
        try flip(a, try object.newXzRect(a, -0.3, 0.3, -1, 1, -1, mat)),
        try object.newXyRect(a, -0.3, 0.3, -1, 1, 1, mat),
        try flip(a, try object.newXyRect(a, -0.3, 0.3, -1, 1, -1, mat)),
    });
    const ray = Ray.init(.{}, .{ .x = 3, .y = 4 }, 0.37);
    var rec: object.HitRecord = .{};
    try testing.expect(world.hit(ray, 0, math.infinity, &rec));
    try testing.expect(!rec.front_face);
    try testing.expectApproxEqAbs(@as(f64, 0.5), rec.t * 5, 1e-14);
    try expectColor(.{ .x = -1 }, rec.normal, 0);
    // @method 首个 x 面 cos=0.6 全反射；y 面 cos=0.8 可透射。到首次 y 面距离 1.25，随后间隔 2.5。
    const f = fresnel(ior, 0.8);
    var expected: Vec3 = .{};
    expected.x = ior * ior * (1 - f) * @exp(-sigma.x * 1.25) / (1 - f * @exp(-sigma.x * 2.5));
    expected.y = ior * ior * (1 - f) * @exp(-sigma.y * 1.25) / (1 - f * @exp(-sigma.y * 2.5));
    expected.z = ior * ior * (1 - f) * @exp(-sigma.z * 1.25) / (1 - f * @exp(-sigma.z * 2.5));
    var sum: Vec3 = .{};
    var reflected_y: usize = 0;
    const samples = 8192;
    for (0..samples) |seed| {
        random.seed(@intCast(7000 + seed));
        const first = mat.bsdfSample(ray, &rec).?;
        try testing.expect(first.is_delta and first.direction.dot(rec.normal) > 0);
        try expectColor(white, first.weight, 0);
        random.seed(@intCast(7000 + seed));
        const result = color.rayColorLit(ray, world, .{ .background = white }, no_rr, 0.95);
        try testing.expect(result.x > 0);
        const length = -@log(result.x / (ior * ior)) / sigma.x;
        const k = @round((length - 1.25) / 2.5);
        try testing.expect(k >= 0);
        if (k > 0) reflected_y += 1;
        // @notice 每条路径都须落在解析行程格点上；容差仅覆盖各次 1e-8 法线偏移。
        try testing.expectApproxEqAbs(1.25 + 2.5 * k, length, 2e-6);
        try expectColor(beer(sigma, 1.25 + 2.5 * k).scale(ior * ior), result, 2e-6);
        sum = sum.add(result);
    }
    try testing.expect(reflected_y > 100);
    // @notice 样本上界为 2.25，0.08 大于六倍最坏均值标准误；逐路径格点断言更严格。
    try expectColor(expected, sum.div(samples), 0.08);
}

test "subsurface: NEE registration leaves delta chains and random walk energy unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var lamp: material.DiffuseLight = .{ .emit = try texture.newSolid(a, .{ .x = 3, .y = 2, .z = 1 }) };
    var lamp_mat: material.Material = .{ .diffuse_light = &lamp };
    const emitter = try flip(a, try object.newXyRect(a, -10, 10, -10, 10, 3, &lamp_mat));
    const background = Vec3.init(0.2, 0.4, 0.8);
    const off: light.Sampler = .{ .background = background };
    const on: light.Sampler = .{ .area = emitter, .background = background, .sample_environment = true };
    for ([_]f64{ 1, 1.5 }) |ior| {
        for ([_]f64{ 0, 3 }) |sigma_s| {
            const mat = try material.newSubsurface(a, .{ .ior = ior, .medium = .{ .sigma_a = .{ .x = 0.1, .y = 0.3 }, .sigma_s = sigma_s } });
            const world = try worldOf(a, &.{ try sphere(a, .{}, 1, mat), emitter });
            for (0..256) |seed| {
                random.seed(@intCast(8000 + seed));
                const expected = color.rayColorLit(outside, world, off, no_rr, 0.95);
                const next = random.randomDouble();
                random.seed(@intCast(8000 + seed));
                try expectColor(expected, color.rayColorLit(outside, world, on, no_rr, 0.95), 0);
                try testing.expectEqual(next, random.randomDouble());
            }
        }
    }
}

test "subsurface: roulette compensates both volume events and full dielectric chains in mean" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lights: light.Sampler = .{ .background = white };
    const scattering = try material.newSubsurface(a, .{ .ior = 1, .medium = .{ .sigma_s = 1 } });
    const scatter_world = try worldOf(a, &.{try sphere(a, .{}, 1, scattering)});
    // @notice rr=0.95 且光学厚度一使长路径方差温和；固定 16384 样本、不提高散射至重尾区。
    try expectColor(white, mean(inside, scatter_world, lights, 16384, 0, 0.95, 9001), 0.04);
    const sigma = Vec3.init(0.1, 0.3, 0.7);
    const absorbing = try material.newSubsurface(a, .{ .ior = 1, .medium = .{ .sigma_a = sigma } });
    const absorb_world = try worldOf(a, &.{try sphere(a, .{}, 1, absorbing)});
    // @method 两次 delta 跨界的解析目标仍为 exp(-2 sigma_a)，不能在轮盘前放大或漏掉补偿。
    try expectColor(beer(sigma, 2), mean(outside, absorb_world, lights, 16384, 0, 0.8, 9002), 0.04);
    const glass = try material.newSubsurface(a, .{ .ior = 1.5 });
    const glass_world = try worldOf(a, &.{try sphere(a, .{}, 1, glass)});
    // @notice eta² 只在透射通量中成对相消；轮盘的重要性 eta_scale 不能成为额外颜色权重。
    try expectColor(white, mean(outside, glass_world, lights, 16384, 0, 0.8, 9003), 0.04);
}
