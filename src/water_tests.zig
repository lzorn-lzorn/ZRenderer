const std = @import("std");
const math = @import("math.zig");
const object = @import("object.zig");
const water = @import("water.zig");
const Material = @import("material.zig").Material;
const Vec3 = math.Vec3;
const Ray = math.Ray;
const expect = std.testing.expect;
const near = std.testing.expectApproxEqAbs;

// @brief 只借用材质地址，几何测试不读取材质内容，不依赖并行中的介质接口改动。
fn sphere(mat: *Material, amplitude: f64, frequency: f64) !water.WavySphere {
    return water.WavySphere.init(.{}, 1, amplitude, frequency, mat);
}

// @brief 验证向量的逐分量绝对误差。
fn vectorNear(a: Vec3, b: Vec3, tolerance: f64) !void {
    try near(a.x, b.x, tolerance);
    try near(a.y, b.y, tolerance);
    try near(a.z, b.z, tolerance);
}

// @brief 确定性方向序列，覆盖波场且不消耗渲染随机状态。
fn direction(i: usize) Vec3 {
    const x: f64 = @floatFromInt(i);
    const y = 1 - 2 * (x + 0.5) / 128;
    const radius = @sqrt(1 - y * y);
    return Vec3.init(radius * @cos(2.399963229728653 * x), y, radius * @sin(2.399963229728653 * x));
}

test "water: zero amplitude analytic sphere, clipping, inside and tangent" {
    var mat: Material = undefined;
    const s = try sphere(&mat, 0, 14);
    var rec: object.HitRecord = .{};
    for ([_]f64{ 0, 0.2, 0.8, 1 }) |height| {
        const ray = Ray.init(Vec3.init(-3, height, 0), Vec3.init(2, 0, 0), 0.7);
        const delta = @sqrt(1 - height * height);
        try expect(s.hit(ray, 0, 10, &rec));
        try near((3 - delta) / 2, rec.t, 2e-14);
        try near(1, rec.normal.length(), 1e-14);
        if (delta > 0) {
            try expect(rec.front_face);
            try expect(s.hit(ray, rec.t + 1e-8, 10, &rec));
            try near((3 + delta) / 2, rec.t, 2e-14);
            try expect(!rec.front_face);
        }
    }
    try expect(s.hit(Ray.init(.{}, Vec3.init(0, 0, 7), 0), 0, 1, &rec));
    try near(1.0 / 7.0, rec.t, 1e-14);
    try expect(!rec.front_face);
    try expect(!s.hit(Ray.init(Vec3.init(-3, 1 + 1e-8, 0), Vec3.init(1, 0, 0), 0), 0, 10, &rec));
    try expect(!s.hit(Ray.init(Vec3.init(-3, 0, 0), Vec3.init(1, 0, 0), 0), 0, 1.9, &rec));
    try expect(s.hit(Ray.init(Vec3.init(-3, 0, 0), Vec3.init(1, 0, 0), 0), 2, 2, &rec));
    try expect(s.hit(Ray.init(Vec3.init(3, 0, 0), Vec3.init(1, 0, 0), 0), -math.infinity, math.infinity, &rec));
    try near(-4, rec.t, 1e-14);
}

test "water: radial displacement, analytic gradient finite differences and bounds" {
    var mat: Material = undefined;
    var largest_displacement: f64 = 0;
    var largest_normal_tilt: f64 = 0;
    for ([_][2]f64{ .{ 0.035, 14 }, .{ 0.1, 40 }, .{ 0.035, 0 } }) |parameters| {
        const s = try water.WavySphere.init(Vec3.init(2, -3, 1), 2.5, parameters[0], parameters[1], &mat);
        var bounds: math.Aabb = undefined;
        try expect(s.boundingBox(-1, 9, &bounds));
        for (0..128) |i| {
            const n = direction(i);
            const p = s.surfacePoint(n);
            const rho = p.sub(s.center).length();
            largest_displacement = @max(largest_displacement, @abs(rho - s.radius));
            try expect(rho >= s.radius * (1 - s.amplitude) - 1e-14);
            try expect(rho <= s.radius * (1 + s.amplitude) + 1e-14);
            for (0..3) |axis| {
                try expect(p.at(axis) >= bounds.min.at(axis));
                try expect(p.at(axis) <= bounds.max.at(axis));
            }
            try near(0, s.implicitValue(p), 3e-15);
            const h = 1e-6;
            const gx = (s.implicitValue(p.add(Vec3.init(h, 0, 0))) - s.implicitValue(p.sub(Vec3.init(h, 0, 0)))) / (2 * h);
            const gy = (s.implicitValue(p.add(Vec3.init(0, h, 0))) - s.implicitValue(p.sub(Vec3.init(0, h, 0)))) / (2 * h);
            const gz = (s.implicitValue(p.add(Vec3.init(0, 0, h))) - s.implicitValue(p.sub(Vec3.init(0, 0, h)))) / (2 * h);
            const normal = s.outwardNormal(p);
            try vectorNear(normal, Vec3.init(gx, gy, gz).normalized(), 2e-8);
            try expect(normal.dot(n) > 0);
            largest_normal_tilt = @max(largest_normal_tilt, normal.sub(n).length());
            var rec: object.HitRecord = .{};
            try expect(s.hit(Ray.init(s.center.add(n.scale(4)), n.neg(), 0), 0, 10, &rec));
            try vectorNear(p, rec.p, 2e-12);
            try vectorNear(normal, rec.normal, 2e-11);
            try expect(rec.material.? == &mat);
            try expect(rec.u >= 0 and rec.u <= 1 and rec.v >= 0 and rec.v <= 1);
        }
    }
    try expect(largest_displacement > 0.04);
    try expect(largest_normal_tilt > 0.1);
}

test "water: nonnormalized direction and world distance scaling, deterministic time" {
    var mat: Material = undefined;
    for ([_]f64{ 0.01, 1, 100 }) |radius| {
        const s = try water.WavySphere.init(Vec3.init(3, -2, 4), radius, 0.035, 14, &mat);
        const origin = s.center.add(Vec3.init(-3, 0.3, 0.2).scale(radius));
        var reference: object.HitRecord = .{};
        try expect(s.hit(Ray.init(origin, Vec3.init(1, 0, 0), 0), 0, math.infinity, &reference));
        for ([_]f64{ 1e-150, 0.01, 7, 1e150 }) |scale| {
            var rec: object.HitRecord = .{};
            try expect(s.hit(Ray.init(origin, Vec3.init(scale, 0, 0), 1234), 0, math.infinity, &rec));
            try near(reference.t, rec.t * scale, 2e-12 * @max(1, radius));
            try vectorNear(reference.p, rec.p, 2e-12 * @max(1, radius));
            try vectorNear(reference.normal, rec.normal, 2e-12);
        }
    }
}

test "water: displaced roots at closed interval endpoints and surface origins" {
    var mat: Material = undefined;
    const s = try sphere(&mat, 0.035, 14);
    for (0..128) |i| {
        const n = direction(i);
        const p = s.surfacePoint(n);
        const distance = 3 - p.length();
        const ray = Ray.init(n.scale(3), n.neg(), 0);
        var rec: object.HitRecord = .{};
        try expect(s.hit(ray, distance, distance, &rec));
        try near(distance, rec.t, 1e-14);
        try expect(s.hit(Ray.init(p, n, 0), 0, 0, &rec));
        try near(0, rec.t, 0);
        try expect(!s.hit(ray, 0, distance - 1e-8, &rec));
    }
}

test "water: enter and exit with 1e-8 geometric normal spawn offsets" {
    var mat: Material = undefined;
    for ([_][2]f64{ .{ 0, 14 }, .{ 0.035, 14 }, .{ 0.1, 40 } }) |parameters| {
        const s = try sphere(&mat, parameters[0], parameters[1]);
        for (0..128) |i| {
            const p = s.surfacePoint(direction(i));
            const n = s.outwardNormal(p);
            const outside = p.add(n.scale(1e-8));
            const inside = p.sub(n.scale(1e-8));
            var rec: object.HitRecord = .{};
            try expect(!s.hit(Ray.init(outside, n, 0), 0, 5e-9, &rec));
            try expect(!s.hit(Ray.init(inside, n.neg(), 0), 0, 5e-9, &rec));
            try expect(s.hit(Ray.init(outside, n.neg().scale(3), 0), 0, 1, &rec));
            try expect(rec.front_face);
            try near(1e-8, rec.t * 3, 3e-12);
            try expect(s.hit(Ray.init(inside, n.scale(3), 0), 0, 1, &rec));
            try expect(!rec.front_face);
            try near(1e-8, rec.t * 3, 3e-12);
            try expect(s.hit(Ray.init(inside, direction(i).neg(), 0), 0, 3, &rec));
            try expect(!rec.front_face);
            try expect(rec.t > 1);
            // @notice 从求交记录再次偏移，而不仅测试解析生成的表面点。
            const exit_normal = rec.normal.neg();
            const exit_origin = rec.p.add(exit_normal.scale(1e-8));
            try expect(!s.hit(Ray.init(exit_origin, exit_normal, 0), 0, 5e-9, &rec));
        }
    }
}

test "water: displaced tangent, grazing crossings and nearby misses" {
    var mat: Material = undefined;
    const s = try sphere(&mat, 0.035, 14);
    for (0..128) |i| {
        const p = s.surfacePoint(direction(i));
        const n = s.outwardNormal(p);
        const tangent = n.cross(if (@abs(n.y) < 0.9) Vec3.init(0, 1, 0) else Vec3.init(1, 0, 0)).normalized();
        // @notice 局部曲率可能向内或向外，先判断偏移符号再构造应命中/应漏过的射线。
        const half: f64 = 1e-3;
        const side_value = s.implicitValue(p.add(tangent.scale(half)));
        const side: f64 = if (side_value > 0) 1 else -1;
        if (@abs(side_value) < 5e-8) continue;
        var rec: object.HitRecord = .{};
        const origin = p.sub(tangent.scale(half));
        try expect(s.hit(Ray.init(origin, tangent, 0), 0, 2 * half, &rec));
        // @notice 双精度切点的参数不确定度是 O(sqrt(epsilon))，不能要求 1e-12 的切向误差。
        try near(half, rec.t, 2e-6);
        try near(0, s.implicitValue(rec.p), 2e-14);
        try expect(!s.hit(Ray.init(origin.add(n.scale(side * 1e-8)), tangent, 0), 0, 2 * half, &rec));
        try expect(s.hit(Ray.init(origin.sub(n.scale(side * 1e-8)), tangent, 0), 0, 2 * half, &rec));
        try expect(rec.t < half);
        const entry = rec.t;
        try expect(s.hit(Ray.init(origin.sub(n.scale(side * 1e-8)), tangent, 0), entry + 1e-7, 2 * half, &rec));
        try expect(rec.t > half);
    }
}

// @brief 独立稠密采样加二分参考，测试高频非凸轮廓的第一个穿越根。
fn referenceHit(s: water.WavySphere, ray: Ray) ?f64 {
    var lo: f64 = 0;
    var value = s.implicitValue(ray.at(lo));
    for (1..8193) |i| {
        const hi = @as(f64, @floatFromInt(i)) * 4 / 8192;
        const next = s.implicitValue(ray.at(hi));
        if ((value < 0) != (next < 0)) {
            var upper = hi;
            for (0..48) |_| {
                const mid = (lo + upper) * 0.5;
                if ((s.implicitValue(ray.at(mid)) < 0) == (value < 0)) lo = mid else upper = mid;
            }
            return (lo + upper) * 0.5;
        }
        lo = hi;
        value = next;
    }
    return null;
}

test "water: closest nonradial root agrees with independent dense reference" {
    var mat: Material = undefined;
    const s = try sphere(&mat, 0.1, 40);
    var multiple: usize = 0;
    for (0..128) |i| {
        const n = direction(i);
        const ray = Ray.init(Vec3.init(-2, n.y * 1.05, n.z * 1.05), Vec3.init(1, 0, 0), 0);
        var rec: object.HitRecord = .{};
        if (referenceHit(s, ray)) |t| {
            try expect(s.hit(ray, 0, 4, &rec));
            try near(t, rec.t, 2e-11);
            try expect(rec.front_face);
            const second_origin = ray.at(rec.t + 1e-7);
            const second_ray = Ray.init(second_origin, ray.direction, 0);
            const second = referenceHit(s, second_ray).?;
            try expect(s.hit(second_ray, 0, 4, &rec));
            try near(second, rec.t, 2e-11);
            try expect(!rec.front_face);
            if (s.hit(second_ray, rec.t + 1e-7, 4, &rec)) multiple += 1;
        } else {
            try expect(!s.hit(ray, 0, 4, &rec));
        }
    }
    try expect(multiple > 0);
}

// @brief 对两次工厂分配逐一注入失败，成功路径显式销毁以便检测泄漏。
fn allocationCase(alloc: std.mem.Allocator) !void {
    var mat: Material = undefined;
    const obj = try object.newWavySphere(alloc, .{}, 1, 0.035, 14, &mat);
    defer alloc.destroy(obj);
    defer alloc.destroy(obj.wavy_sphere);
}

test "water: invalid parameters, rays and allocation failure cleanup" {
    var mat: Material = undefined;
    for ([_]f64{ -1, 0, std.math.nan(f64), math.infinity }) |radius| {
        try std.testing.expectError(error.InvalidWavySphere, object.newWavySphere(std.testing.allocator, .{}, radius, 0.035, 14, &mat));
    }
    for ([_]f64{ -0.001, 0.10001, std.math.nan(f64), math.infinity }) |a| {
        try std.testing.expectError(error.InvalidWavySphere, object.newWavySphere(std.testing.allocator, .{}, 1, a, 14, &mat));
    }
    for ([_]f64{ -1, 40.001, std.math.nan(f64), math.infinity }) |f| {
        try std.testing.expectError(error.InvalidWavySphere, object.newWavySphere(std.testing.allocator, .{}, 1, 0.035, f, &mat));
    }
    try std.testing.expectError(error.InvalidWavySphere, object.newWavySphere(std.testing.allocator, Vec3.init(math.infinity, 0, 0), 1, 0.035, 14, &mat));
    try std.testing.expectError(error.InvalidWavySphere, object.newWavySphere(std.testing.allocator, Vec3.init(0, std.math.nan(f64), 0), 1, 0.035, 14, &mat));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
    const s = try sphere(&mat, 0.035, 14);
    var rec: object.HitRecord = .{};
    try expect(!s.hit(Ray.init(.{}, .{}, 0), 0, 10, &rec));
    try expect(!s.hit(Ray.init(.{}, Vec3.init(math.infinity, 0, 0), 0), 0, 10, &rec));
    try expect(!s.hit(Ray.init(Vec3.init(std.math.nan(f64), 0, 0), Vec3.init(1, 0, 0), 0), 0, 10, &rec));
    try expect(!s.hit(Ray.init(.{}, Vec3.init(1, 0, 0), 0), 1, 0, &rec));
    try expect(!s.hit(Ray.init(.{}, Vec3.init(1, 0, 0), 0), std.math.nan(f64), 10, &rec));
}

test "water: Object union, unsupported light sampling, group and BVH nearest hit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var mat: Material = undefined;
    const wavy = try object.newWavySphere(alloc, .{}, 1, 0.035, 14, &mat);
    const plain = try object.newSphere(alloc, Vec3.init(3, 0, 0), Vec3.init(3, 0, 0), 0, 1, 0.7, &mat);
    const other = try object.newWavySphere(alloc, Vec3.init(-3, 0, 0), 0.5, 0.05, 10, &mat);
    try near(0, wavy.pdfValueAt(Vec3.init(-3, 0, 0), Vec3.init(1, 0, 0), 0), 0);
    try vectorNear(.{}, wavy.randomAt(.{}, 0), 0);
    var group = object.ObjectGroup.init(alloc);
    try group.add(wavy);
    try group.add(plain);
    try group.add(other);
    const tree = try object.BvhNode.init(alloc, group.list.items, 0, group.list.items.len, 0, 1);
    const wrapped: object.Object = .{ .bvh = tree };
    for (0..128) |i| {
        const ray = Ray.init(direction(i).scale(5), direction(i).neg().scale(3), 0.5);
        var expected: object.HitRecord = .{};
        var actual: object.HitRecord = .{};
        try expect(group.hit(ray, 0, 10, &expected));
        try expect(wrapped.hit(ray, 0, 10, &actual));
        try near(expected.t, actual.t, 1e-13);
        try vectorNear(expected.normal, actual.normal, 1e-13);
        try expect(expected.front_face == actual.front_face);
    }
}
