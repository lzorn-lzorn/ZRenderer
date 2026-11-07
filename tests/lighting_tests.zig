const std = @import("std");
const math = @import("zrenderer").math;
const random = @import("zrenderer").random;
const object = @import("zrenderer").object;
const material = @import("zrenderer").material;
const texture = @import("zrenderer").texture;
const light = @import("zrenderer").light;
const color = @import("zrenderer").color;
const camera = @import("zrenderer").camera;
const render = @import("zrenderer").render;
const testing = std.testing;
const Vec3 = math.Vec3;
const white = Vec3.init(1, 1, 1);
const incoming = math.Ray.init(.{ .y = 0.5 }, .{ .y = -1 }, 0.37);

// @brief 所有测试分配均由局部 arena 管理，不修改或借用其他测试的场景。
fn diffuse(a: std.mem.Allocator, albedo: Vec3) !*material.Material {
    return material.newLambertian(a, try texture.newSolid(a, albedo));
}

fn emitter(a: std.mem.Allocator, radiance: Vec3) !*material.Material {
    const m = try a.create(material.DiffuseLight);
    m.* = .{ .emit = try texture.newSolid(a, radiance) };
    const wrapper = try a.create(material.Material);
    wrapper.* = .{ .diffuse_light = m };
    return wrapper;
}

fn flip(a: std.mem.Allocator, shape: *object.Object) !*object.Object {
    const face = try a.create(object.FlipFace);
    face.* = .{ .ptr = shape };
    const wrapper = try a.create(object.Object);
    wrapper.* = .{ .flip_face = face };
    return wrapper;
}

fn floor(a: std.mem.Allocator, m: *material.Material) !*object.Object {
    return object.newXzRect(a, -100, 100, -100, 100, 0, m);
}

fn worldOf(a: std.mem.Allocator, shapes: []const *object.Object) !*object.BvhNode {
    return object.BvhNode.init(a, shapes, 0, shapes.len, 0, 1);
}

fn expectColor(expected: Vec3, actual: Vec3, tolerance: f64) !void {
    for (0..3) |c| {
        try testing.expect(std.math.isFinite(actual.at(c)));
        try testing.expectApproxEqAbs(expected.at(c), actual.at(c), tolerance);
    }
}

// @brief 固定种子的独立路径均值；关闭自适应停止，null 和轮盘终止均保留为零贡献事件。
// @param count 为固定预算，depth 为轮盘开始的散射次数。
// @return 线性辐亮度平均值，不含相机曝光或显示编码。
fn mean(ray: math.Ray, world: *object.BvhNode, lights: light.Sampler, count: usize, depth: i32, rr: f64, seed: u64) Vec3 {
    random.seed(seed);
    var sum: Vec3 = .{};
    for (0..count) |_| sum = sum.add(color.rayColorLit(ray, world, lights, depth, rr));
    return sum.div(@floatFromInt(count));
}

// @brief 可表示的大距离和极小距离不应先平方溢出/下溢，强度采用分步除距离。
test "lighting point sampler preserves representable extreme distances" {
    for ([_]f64{ 1e200, 1e-200 }) |distance| {
        const intensity: f64 = if (distance > 1) 1e308 else 1e-308;
        const expected: f64 = if (distance > 1) 1e-92 else 1e92;
        const points = [_]light.PointLight{.{ .position = .{ .y = distance }, .intensity = .{ .x = intensity } }};
        const sampler = light.Sampler{ .points = &points };
        try testing.expect(sampler.valid());
        const sample = sampler.sample(.{}, 0) orelse return error.MissingLightSample;
        try testing.expectApproxEqRel(distance, sample.distance, 1e-14);
        try testing.expectApproxEqRel(expected, sample.radiance.x, 1e-14);
        try testing.expectEqual(@as(f64, 1), sample.direction.y);
    }
}

test "lighting Lambertian point analytical inverse square and NEE before roulette" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rho = Vec3.init(0.2, 0.5, 0.8);
    const intensity = Vec3.init(3, 2, 1);
    const world = try worldOf(a, &.{try floor(a, try diffuse(a, rho))});
    for ([_]f64{ 1, 2, 4 }) |distance| {
        const points = [_]light.PointLight{.{ .position = .{ .y = distance }, .intensity = intensity }};
        for (0..32) |seed| {
            random.seed(@intCast(seed));
            // @notice rr=0.01 可终止后续路径，但绝不能缩放或丢掉已求得的直接光照。
            try expectColor(rho.mul(intensity).scale(1 / (math.pi * distance * distance)), color.rayColorLit(incoming, world, .{ .points = &points }, 0, 0.01), 1e-12);
        }
    }
}

test "lighting point shadow segment excludes occluder behind light" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try floor(a, try diffuse(a, white));
    const black = try diffuse(a, .{});
    const points = [_]light.PointLight{.{ .position = .{ .y = 2 }, .intensity = white }};
    for ([_]f64{ 1, 3 }) |height| {
        const blocker = try object.newXzRect(a, -20, 20, -20, 20, height, black);
        const world = try worldOf(a, &.{ base, blocker });
        const expected = if (height < 2) Vec3{} else white.scale(1 / (4 * math.pi));
        for (0..32) |seed| {
            random.seed(@intCast(seed));
            try expectColor(expected, color.rayColorLit(incoming, world, .{ .points = &points }, 5, 0.9), 1e-12);
        }
    }
}

test "lighting distant propagation direction and cosine with infinite shadow" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rho = Vec3.init(0.3, 0.6, 0.9);
    const base = try floor(a, try diffuse(a, rho));
    const world = try worldOf(a, &.{base});
    const distant = [_]light.DistantLight{.{ .direction = .{ .y = -3, .z = -4 }, .radiance = .{ .x = 2, .y = 1, .z = 0.5 } }};
    try expectColor(rho.mul(distant[0].radiance).scale(0.6 / math.pi), color.rayColorLit(incoming, world, .{ .distant = &distant }, 5, 0.9), 1e-12);
    const blocker = try object.newXzRect(a, -200, 200, -200, 200, 100, try diffuse(a, .{}));
    const occluded = try worldOf(a, &.{ base, blocker });
    try expectColor(.{}, color.rayColorLit(incoming, occluded, .{ .distant = &distant }, 5, 0.9), 0);
    const below = [_]light.DistantLight{.{ .direction = .{ .y = 7 }, .radiance = white }};
    try expectColor(.{}, color.rayColorLit(incoming, world, .{ .distant = &below }, 5, 0.9), 0);
}

test "lighting multiple point selection compensates all RGB contributions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rho = Vec3.init(0.4, 0.6, 0.8);
    const world = try worldOf(a, &.{try floor(a, try diffuse(a, rho))});
    const points = [_]light.PointLight{
        .{ .position = .{ .y = 1 }, .intensity = .{ .x = 1 } },
        .{ .position = .{ .y = 2 }, .intensity = .{ .y = 4 } },
        .{ .position = .{ .y = 3 }, .intensity = .{ .z = 9 } },
    };
    const lights = light.Sampler{ .points = &points };
    random.seed(2001);
    for (0..64) |_| {
        const sample = lights.sample(.{}, 0).?;
        try testing.expect(sample.is_delta);
        try testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), sample.pdf, 1e-15);
        try testing.expectEqual(@as(f64, 0), lights.pdf(.{}, sample.direction, 0));
    }
    try expectColor(rho.scale(1 / math.pi), mean(incoming, world, lights, 65536, 5, 0.9, 2002), 0.006);
}

test "lighting primary emission and visible environment have unit MIS weight" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const le = Vec3.init(3, 2, 1);
    const shape = try floor(a, try emitter(a, le));
    const world = try worldOf(a, &.{shape});
    const lights = light.Sampler{ .area = shape, .background = .{ .x = 0.2, .y = 0.4, .z = 0.6 }, .sample_environment = true };
    for (0..32) |seed| {
        random.seed(@intCast(seed));
        try expectColor(le, color.rayColorLit(incoming, world, lights, 0, 0.01), 0);
        try expectColor(lights.background, color.rayColorLit(.{ .origin = .{ .y = 0.5 }, .direction = .{ .y = 1 } }, world, lights, 0, 0.01), 0);
    }
}

test "lighting mirror delta chain emission is full with area and environment registered" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rho = Vec3.init(0.25, 0.5, 0.75);
    const le = Vec3.init(3, 2, 1);
    const base = try floor(a, try material.newMetal(a, rho, 0));
    const top = try flip(a, try object.newXzRect(a, -2, 2, -2, 2, 2, try emitter(a, le)));
    const world = try worldOf(a, &.{ base, top });
    const empty_above = try worldOf(a, &.{base});
    const lights = light.Sampler{ .area = top, .background = .{ .x = 0.8, .y = 0.6, .z = 0.4 }, .sample_environment = true };
    for (0..32) |seed| {
        random.seed(@intCast(seed));
        try expectColor(rho.mul(le), color.rayColorLit(incoming, world, lights, 5, 0.9), 1e-12);
        try expectColor(rho.mul(lights.background), color.rayColorLit(incoming, empty_above, lights, 5, 0.9), 1e-12);
    }
}

test "lighting dielectric eta affects contribution but roulette eta scale only importance" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const world = try worldOf(a, &.{try floor(a, try material.newDielectric(a, 1.5))});
    const background = Vec3.init(0.8, 0.6, 0.4);
    const lights = light.Sampler{ .background = background, .sample_environment = true };
    // @method 法向 Fresnel=0.04，单界面环境期望为 [0.04+0.96/1.5²]L；不以实现的 BSDF 求参考。
    const reference = background.scale(0.04 + 0.96 / 2.25);
    for ([_]i32{ 5, 0 }) |depth| try expectColor(reference, mean(incoming, world, lights, 65536, depth, 0.7, 2010), 0.008);
}

test "lighting legacy no-environment-NEE diffuse remains exactly analytical" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rho = Vec3.init(0.25, 0.5, 0.75);
    const background = Vec3.init(0.8, 0.6, 0.4);
    const world = try worldOf(a, &.{try floor(a, try diffuse(a, rho))});
    const lights = light.Sampler{ .background = background };
    try testing.expectEqual(@as(usize, 0), lights.count());
    for (0..64) |seed| {
        random.seed(@intCast(seed));
        try expectColor(rho.mul(background), color.rayColor(incoming, background, world, null, 5, 0.9), 1e-12);
        try expectColor(rho.mul(background), color.rayColorLit(incoming, world, lights, 5, 0.9), 1e-12);
    }
}

test "lighting explicit uniform environment MIS analytical mean with and without roulette" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rho = Vec3.init(0.3, 0.6, 0.9);
    const background = Vec3.init(0.8, 0.6, 0.4);
    const world = try worldOf(a, &.{try floor(a, try diffuse(a, rho))});
    const lights = light.Sampler{ .background = background, .sample_environment = true };
    try testing.expectEqual(@as(usize, 1), lights.count());
    try testing.expectApproxEqAbs(@as(f64, 1 / (4 * math.pi)), lights.pdf(.{}, .{ .y = 1 }, 0), 1e-15);
    for ([_]i32{ 5, 0 }) |depth| try expectColor(rho.mul(background), mean(incoming, world, lights, 65536, depth, 0.7, 2020), 0.006);
}

test "lighting missing area proxy still estimates background using full mixed direction PDF" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rho = Vec3.init(0.3, 0.6, 0.9);
    const mat = try diffuse(a, rho);
    const world = try worldOf(a, &.{try floor(a, mat)});
    const proxy = try object.newXzRect(a, -1, 1, -1, 1, 2, mat);
    const points = [_]light.PointLight{.{ .position = .{ .y = 4 }, .intensity = .{} }};
    const distant = [_]light.DistantLight{.{ .direction = .{ .y = -1 }, .radiance = .{} }};
    const lights = light.Sampler{ .area = proxy, .background = .{ .x = 0.8, .y = 0.6, .z = 0.4 }, .sample_environment = true, .points = &points, .distant = &distant };
    try testing.expectEqual(@as(usize, 4), lights.count());
    // @method 正上方矩形 p_A=d²/A=1；delta 不加入连续密度，但仍占四分之一的选光概率。
    try testing.expectApproxEqAbs((1 + 1 / (4 * math.pi)) / 4, lights.pdf(.{}, .{ .y = 1 }, incoming.time), 1e-14);
    try testing.expectApproxEqAbs(@as(f64, 1 / (16 * math.pi)), lights.pdf(.{}, .{ .y = -1 }, incoming.time), 1e-14);
    random.seed(2030);
    for (0..512) |_| {
        const sample = lights.sample(.{}, incoming.time).?;
        if (!sample.is_delta) try testing.expectApproxEqAbs(lights.pdf(.{}, sample.direction, incoming.time), sample.pdf, 1e-14);
    }
    try expectColor(rho.mul(lights.background), mean(incoming, world, lights, 65536, 5, 0.9, 2031), 0.007);
}

// @brief 独立二维中点积分；矩形 x∈[-1.5,1.5]、z∈[-1,1]、y=2，wo=n。
// @param rough 为 null 时用 Lambertian，否则以独立公式计算纯 GGX；rho 为反照率或 F0。
// @method dω=h/r³ dA，cos_i=h/r；Lambertian 核为 rho*h²/(pi*r⁴)。
// @return 单位发光辐亮度下的反射响应，不调用生产 BSDF、PDF、采样或求交代码。
fn rectangleReference(rho: Vec3, rough: ?f64, resolution: usize) Vec3 {
    const n: f64 = @floatFromInt(resolution);
    var result: Vec3 = .{};
    for (0..resolution) |i| {
        const x = -1.5 + 3 * (@as(f64, @floatFromInt(i)) + 0.5) / n;
        for (0..resolution) |j| {
            const z = -1 + 2 * (@as(f64, @floatFromInt(j)) + 0.5) / n;
            const r2 = x * x + z * z + 4;
            const ci = 2 / @sqrt(r2);
            var f = rho.scale(1 / math.pi);
            if (rough) |roughness| {
                const alpha = roughness * roughness;
                const a2 = alpha * alpha;
                const ch2 = (1 + ci) / 2;
                const d = a2 / (math.pi * std.math.pow(f64, 1 + (a2 - 1) * ch2, 2));
                const g1 = 2 * ci / (ci + @sqrt(a2 + (1 - a2) * ci * ci));
                const fresnel = rho.add(white.sub(rho).scale(std.math.pow(f64, 1 - @sqrt(ch2), 5)));
                f = fresnel.scale(d * g1 / (4 * ci));
            }
            result = result.add(f.scale(4 / (r2 * r2) * 6 / (n * n)));
        }
    }
    return result;
}

test "lighting area NEE plus BSDF MIS matches independent quadrature without double counting" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rho = Vec3.init(0.7, 0.45, 0.2);
    const le = Vec3.init(1.7, 0.8, 0.3);
    const base = try floor(a, try diffuse(a, rho));
    const top = try flip(a, try object.newXzRect(a, -1.5, 1.5, -1, 1, 2, try emitter(a, le)));
    const world = try worldOf(a, &.{ base, top });
    const response = rectangleReference(rho, null, 256);
    try expectColor(response, rectangleReference(rho, null, 128), 2e-5);
    const dark_points = [_]light.PointLight{.{ .position = .{ .x = 4, .y = 2 }, .intensity = .{} }};
    const dark_distant = [_]light.DistantLight{.{ .direction = .{ .y = -1 }, .radiance = .{} }};
    const cases = [_]light.Sampler{
        .{},
        .{ .area = top },
        .{ .area = top, .background = .{ .x = 0.2, .y = 0.1, .z = 0.05 }, .sample_environment = true, .points = &dark_points, .distant = &dark_distant },
    };
    for (cases, 0..) |lights, index| {
        // @method 背景在矩形外可见：rho*B + response*(Le-B)，不能把整球背景另加一遍。
        const reference = rho.mul(lights.background).add(response.mul(le.sub(lights.background)));
        try expectColor(reference, mean(incoming, world, lights, 65536, 5, 0.9, 2040 + index), 0.007);
    }
}

test "lighting rough GGX area MIS matches independent microfacet quadrature" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f0 = Vec3.init(0.8, 0.5, 0.2);
    const le = Vec3.init(1.3, 0.8, 0.4);
    const roughness = 0.65;
    const base = try floor(a, try material.newMetal(a, f0, roughness));
    const top = try flip(a, try object.newXzRect(a, -1.5, 1.5, -1, 1, 2, try emitter(a, le)));
    const world = try worldOf(a, &.{ base, top });
    const reference = rectangleReference(f0, roughness, 256).mul(le);
    try expectColor(reference, rectangleReference(f0, roughness, 128).mul(le), 2e-5);
    try expectColor(reference, mean(incoming, world, .{ .area = top }, 65536, 5, 0.9, 2050), 0.008);
}

test "lighting emitter backside contributes neither NEE nor BSDF emission" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try floor(a, try diffuse(a, white));
    const top = try object.newXzRect(a, -1.5, 1.5, -1, 1, 2, try emitter(a, white.scale(10)));
    const world = try worldOf(a, &.{ base, top });
    try expectColor(.{}, mean(incoming, world, .{ .area = top }, 1024, 5, 0.9, 2060), 0);
    try expectColor(.{}, color.rayColorLit(.{ .origin = .{ .y = 1 }, .direction = .{ .y = 1 } }, world, .{ .area = top }, 5, 0.9), 0);
}

test "lighting moving area proposal PDF shadow and continuation share ray time" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rho = Vec3.init(0.7, 0.5, 0.3);
    const le = Vec3.init(2, 1.5, 1);
    const base = try floor(a, try diffuse(a, rho));
    const sphere = try object.newSphere(a, .{ .y = 2 }, .{ .x = 1.5, .y = 3 }, 0, 1, 0.5, try emitter(a, le));
    const world = try worldOf(a, &.{ base, sphere });
    const lights = light.Sampler{ .area = sphere };
    for ([_]f64{ 0, 0.5, 1 }) |time| {
        var ray = incoming;
        ray.time = time;
        const center = Vec3.init(1.5 * time, 2 + time, 0);
        const d2 = center.lengthSquared();
        const cap = 1 - @sqrt(1 - 0.25 / d2);
        random.seed(2070);
        for (0..128) |_| {
            const sample = lights.sample(.{}, time).?;
            try testing.expectApproxEqRel(1 / (2 * math.pi * cap), sample.pdf, 1e-12);
            var hit: object.HitRecord = .{};
            try testing.expect(sphere.hit(.{ .direction = sample.direction, .time = time }, 0, math.infinity, &hit));
            try testing.expect(hit.front_face);
        }
        // @method 球面帽的一阶方向矩为 pi*sin²(theta_max)*axis，故响应=rho*Le*r²/d²*cos(axis,n)。
        const reference = rho.mul(le).scale(0.25 / d2 * center.y / @sqrt(d2));
        try expectColor(reference, mean(ray, world, lights, 32768, 5, 0.9, 2071), 0.001);
    }
}

test "lighting translucent direct connection uses opposite hemisphere and signed origin offset" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rho = Vec3.init(0.3, 0.6, 0.9);
    const intensity = Vec3.init(3, 2, 1);
    for ([_]f64{ 0, 0.3, 1 }) |transmission| {
        const world = try worldOf(a, &.{try floor(a, try material.newTranslucent(a, rho, transmission))});
        for ([_]f64{ -2, 2 }) |height| {
            const points = [_]light.PointLight{.{ .position = .{ .y = height }, .intensity = intensity }};
            const fraction = if (height < 0) transmission else 1 - transmission;
            try expectColor(rho.mul(intensity).scale(fraction / (4 * math.pi)), color.rayColorLit(incoming, world, .{ .points = &points }, 5, 0.9), 1e-12);
        }
    }
}

test "lighting power heuristic stays finite complementary and scale invariant for extreme finite PDFs" {
    const values = [_]f64{ 0, 5e-324, 1e-300, 1e-150, 1, 1e150, 1e300, 1.7e308 };
    for (values) |a| {
        for (values) |b| {
            const wa = light.powerHeuristic(a, b);
            const wb = light.powerHeuristic(b, a);
            try testing.expect(std.math.isFinite(wa) and wa >= 0 and wa <= 1);
            if (a > 0 or b > 0) try testing.expectApproxEqAbs(@as(f64, 1), wa + wb, 2e-15);
            if (a > 0 and a == b) try testing.expectEqual(@as(f64, 0.5), wa);
        }
    }
    try testing.expectEqual(@as(f64, 0), light.powerHeuristic(0, 0));
    for ([_]f64{ 1e-300, 1, 1e300 }) |scale| try testing.expectApproxEqAbs(@as(f64, 9.0 / 25.0), light.powerHeuristic(3 * scale, 4 * scale), 1e-15);
}

test "lighting renderPixels applies physical exposure to analytical NEE before gamma" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rho = Vec3.init(0.2, 0.4, 0.6);
    const world = try worldOf(a, &.{try floor(a, try diffuse(a, rho))});
    const distant = [_]light.DistantLight{.{ .direction = .{ .y = -1 }, .radiance = white.scale(math.pi * 0.4) }};
    for ([_]f64{ -1, 0, 1 }) |ev| {
        const cam = try (camera.PhysicalCameraArgs{ .lookfrom = .{ .y = 1 }, .lookat = .{}, .vup = .{ .z = -1 }, .focus_distance = 1, .exposure_compensation = ev }).build();
        const pixels = try render.renderPixels(testing.allocator, .{
            .cam = cam,
            .background = .{},
            .image_width = 3,
            .image_height = 2,
            .samples_per_pixel = 8,
            .min_bounce = 5,
            .rr = 0.9,
            .channel = 3,
            .show_progress = false,
            .thread_count = 2,
            .rows_per_task = 1,
            .adaptive = false,
            .distant_lights = &distant,
        }, world, null);
        defer testing.allocator.free(pixels);
        // @notice 独立编码参考不调用 sampleWeight 或 writeColor，且所有通道远离裁剪阈值。
        for (pixels, 0..) |value, i| {
            const linear = rho.at(i % 3) * 0.4 * @exp2(ev);
            const expected: u8 = @intFromFloat(256 * std.math.pow(f64, color.acesFilm(linear), 1.0 / 2.2));
            try testing.expectEqual(expected, value);
        }
    }
}

test "lighting renderPixels NEE physical camera is schedule deterministic including adaptive stats" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try floor(a, try diffuse(a, .{ .x = 0.3, .y = 0.5, .z = 0.7 }));
    const top = try flip(a, try object.newXzRect(a, -1, 1, -1, 1, 2, try emitter(a, white)));
    const world = try worldOf(a, &.{ base, top });
    const points = [_]light.PointLight{.{ .position = .{ .x = 2, .y = 1 }, .intensity = .{ .x = 2, .y = 1, .z = 0.5 } }};
    const distant = [_]light.DistantLight{.{ .direction = .{ .x = 1, .y = -1 }, .radiance = white.scale(0.2) }};
    const cam = try (camera.PhysicalCameraArgs{ .lookfrom = .{ .y = 1, .z = 3 }, .lookat = .{}, .focus_distance = 3, .exposure_compensation = -2, .sensor_cos4_vignetting = true }).build();
    for ([_]bool{ false, true }) |adaptive| {
        for ([_]@import("zrenderer").sampling.Sampler{ .random, .sobol }) |sampler| {
            var reference_stats: render.RenderStats = .{};
            var params = render.RenderParams{
                .cam = cam,
                .background = white.scale(0.05),
                .image_width = 8,
                .image_height = 9,
                .samples_per_pixel = 64,
                .min_bounce = 3,
                .rr = 0.8,
                .channel = 3,
                .show_progress = false,
                .thread_count = 1,
                .rows_per_task = 1,
                .seed = 2080,
                .sampler = sampler,
                .adaptive = adaptive,
                .min_samples = 8,
                .absolute_error = 0.1,
                .point_lights = &points,
                .distant_lights = &distant,
                .sample_environment = true,
                .stats = &reference_stats,
            };
            const reference = try render.renderPixels(testing.allocator, params, world, top);
            defer testing.allocator.free(reference);
            if (adaptive) {
                try testing.expect(reference_stats.early_stopped_pixels > 0);
            } else {
                try testing.expectEqual(@as(u64, 8 * 9 * 64), reference_stats.total_samples);
            }
            for ([_]usize{ 2, 4 }) |workers| {
                var stats: render.RenderStats = .{};
                params.thread_count = workers;
                params.rows_per_task = if (workers == 2) 3 else 1;
                params.stats = &stats;
                const actual = try render.renderPixels(testing.allocator, params, world, top);
                defer testing.allocator.free(actual);
                try testing.expectEqualSlices(u8, reference, actual);
                try testing.expectEqual(reference_stats.total_samples, stats.total_samples);
                try testing.expectEqual(reference_stats.early_stopped_pixels, stats.early_stopped_pixels);
            }
        }
    }
}
