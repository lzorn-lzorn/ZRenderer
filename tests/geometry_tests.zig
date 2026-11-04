// @brief 胶囊解析几何、变换法线及带时间光源分布的独立回归测试。
// @notice 不导入或修改主测试根；材质仅作为只读借用指针使用。
const std = @import("std");
const testing = std.testing;
const math = @import("zrenderer").math;
const object = @import("zrenderer").object;
const material = @import("zrenderer").material;
const random = @import("zrenderer").random;
const Vec3 = math.Vec3;
const Ray = math.Ray;

var test_dielectric = material.Dielectric{ .ir = 1.5 };
var test_material = material.Material{ .dielectric = &test_dielectric };

fn capsule() object.Capsule {
    return .{ .start = .{}, .end = .{ .y = 2 }, .radius = 1, .material = &test_material };
}

fn expectVector(expected: Vec3, actual: Vec3, tolerance: f64) !void {
    for (0..3) |i| try testing.expectApproxEqAbs(expected.at(i), actual.at(i), tolerance);
}

fn expectHit(obj: object.Object, ray: Ray, t: f64, outward: Vec3, front: bool) !object.HitRecord {
    var rec: object.HitRecord = .{};
    try testing.expect(obj.hit(ray, 0, math.infinity, &rec));
    try testing.expectApproxEqAbs(t, rec.t, 1e-12);
    try expectVector(ray.at(t), rec.p, 1e-12);
    try expectVector(if (front) outward else outward.neg(), rec.normal, 1e-12);
    try testing.expectEqual(front, rec.front_face);
    try testing.expectApproxEqAbs(@as(f64, 1), rec.normal.length(), 1e-12);
    try testing.expect(rec.normal.dot(ray.direction) <= 1e-12);
    try testing.expectEqual(&test_material, rec.material.?);
    try testing.expect(rec.v >= 0 and rec.v <= 1);
    return rec;
}

test "capsule exact cylinder and both hemisphere hits have outward geometry normals" {
    var shape = capsule();
    const obj = object.Object{ .capsule = &shape };
    _ = try expectHit(obj, Ray.init(.{ .x = -3, .y = 1 }, .{ .x = 1 }, 0.7), 2, .{ .x = -1 }, true);
    _ = try expectHit(obj, Ray.init(.{ .y = -3 }, .{ .y = 1 }, 0), 2, .{ .y = -1 }, true);
    _ = try expectHit(obj, Ray.init(.{ .y = 5 }, .{ .y = -1 }, 0), 2, .{ .y = 1 }, true);
    // @notice 轴平行、偏心射线的半球交点为 (0.6,-0.8,0)。
    _ = try expectHit(obj, Ray.init(.{ .x = 0.6, .y = -3 }, .{ .y = 1 }, 0), 2.2, .{ .x = 0.6, .y = -0.8 }, true);
}

test "capsule inside exits reject interior end-sphere surfaces" {
    var shape = capsule();
    const obj = object.Object{ .capsule = &shape };
    _ = try expectHit(obj, Ray.init(.{ .y = 1 }, .{ .x = 1 }, 0), 1, .{ .x = 1 }, false);
    _ = try expectHit(obj, Ray.init(.{ .y = 0.5 }, .{ .y = 1 }, 0), 2.5, .{ .y = 1 }, false);
    _ = try expectHit(obj, Ray.init(.{ .y = 1.5 }, .{ .y = -1 }, 0), 2.5, .{ .y = -1 }, false);
    _ = try expectHit(obj, Ray.init(.{ .y = -0.5 }, .{ .y = -1 }, 0), 0.5, .{ .y = -1 }, false);
    _ = try expectHit(obj, Ray.init(.{ .y = 2.5 }, .{ .x = 1 }, 0), @sqrt(@as(f64, 0.75)), .{ .x = @sqrt(@as(f64, 0.75)), .y = 0.5 }, false);
}

test "capsule tangents seams and axis-parallel rays include closed endpoints" {
    var shape = capsule();
    const obj = object.Object{ .capsule = &shape };
    _ = try expectHit(obj, Ray.init(.{ .x = -3, .y = 1, .z = 1 }, .{ .x = 1 }, 0), 3, .{ .z = 1 }, false);
    _ = try expectHit(obj, Ray.init(.{ .x = -3, .y = -1 }, .{ .x = 1 }, 0), 3, .{ .y = -1 }, false);
    _ = try expectHit(obj, Ray.init(.{ .x = -3, .y = 3 }, .{ .x = 1 }, 0), 3, .{ .y = 1 }, false);
    _ = try expectHit(obj, Ray.init(.{ .x = -3 }, .{ .x = 1 }, 0), 2, .{ .x = -1 }, true);
    _ = try expectHit(obj, Ray.init(.{ .x = 1, .y = -3 }, .{ .y = 1 }, 0), 3, .{ .x = 1 }, false);
    var rec: object.HitRecord = .{};
    const ray = Ray.init(.{ .x = -3, .y = 1 }, .{ .x = 1 }, 0);
    try testing.expect(obj.hit(ray, 2, 2, &rec));
    try testing.expectEqual(@as(f64, 2), rec.t);
    try testing.expect(obj.hit(ray, 2.01, 4, &rec));
    try testing.expectEqual(@as(f64, 4), rec.t);
    try testing.expect(!obj.hit(ray, 2.01, 3.99, &rec));
    try testing.expect(!obj.hit(ray, 3, 2, &rec));
    try testing.expect(!obj.hit(ray, std.math.nan(f64), 3, &rec));
}

test "capsule misses parallel exterior zero rays and behind-interval surfaces" {
    var shape = capsule();
    var rec: object.HitRecord = .{};
    const rays = [_]Ray{
        Ray.init(.{ .x = 1.01, .y = -3 }, .{ .y = 1 }, 0),
        Ray.init(.{ .x = -3, .y = 1, .z = 1.00001 }, .{ .x = 1 }, 0),
        Ray.init(.{ .x = -3, .y = 3.01 }, .{ .x = 1 }, 0),
        Ray.init(.{ .x = -3, .y = 1 }, .{ .x = -1 }, 0),
        Ray.init(.{ .y = 1 }, .{}, 0),
        Ray.init(.{}, .{ .x = std.math.nan(f64) }, 0),
    };
    for (rays) |ray| try testing.expect(!shape.hit(ray, 0, math.infinity, &rec));
}

test "capsule nonunit direction scaling preserves positions normals and interval roots" {
    var shape = capsule();
    const obj = object.Object{ .capsule = &shape };
    for ([_]Ray{
        Ray.init(.{ .x = -3, .y = 1 }, .{ .x = 1 }, 0),
        Ray.init(.{ .y = -3 }, .{ .y = 1 }, 0),
        Ray.init(.{ .y = 1 }, .{ .x = 1 }, 0),
        Ray.init(.{ .x = -3, .y = 1, .z = 1 }, .{ .x = 1 }, 0),
    }) |base| {
        var reference: object.HitRecord = .{};
        try testing.expect(obj.hit(base, 0, math.infinity, &reference));
        for ([_]f64{ 1e-200, 0.001, 0.5, 3, 1e6, 1e200 }) |scale| {
            const ray = Ray.init(base.origin, base.direction.scale(scale), base.time);
            var rec: object.HitRecord = .{};
            try testing.expect(obj.hit(ray, 0, math.infinity, &rec));
            try testing.expectApproxEqRel(reference.t / scale, rec.t, 1e-12);
            try expectVector(reference.p, rec.p, 1e-12);
            try expectVector(reference.normal, rec.normal, 1e-12);
            try testing.expectEqual(reference.front_face, rec.front_face);
            try testing.expect(!obj.hit(ray, 0, 0.99 * reference.t / scale, &rec));
        }
    }
}

test "capsule stable roots retain distant cylinder cap and near-surface entry" {
    var shape = capsule();
    const obj = object.Object{ .capsule = &shape };
    _ = try expectHit(obj, Ray.init(.{ .x = -1e8, .y = 1 }, .{ .x = 1 }, 0), 1e8 - 1, .{ .x = -1 }, true);
    _ = try expectHit(obj, Ray.init(.{ .y = -1e8 }, .{ .y = 1 }, 0), 1e8 - 1, .{ .y = -1 }, true);
    const x: f64 = 1.0 + 1e-10;
    _ = try expectHit(obj, Ray.init(.{ .x = x, .y = 1 }, .{ .x = -1 }, 0), x - 1, .{ .x = 1 }, true);
    // @notice 极小径向分量不应当被当成严格轴平行。
    shape.end.y = 1e12;
    var rec: object.HitRecord = .{};
    try testing.expect(shape.hit(Ray.init(.{ .x = 2 }, .{ .x = -1e-10, .y = 1 }, 0), 0, math.infinity, &rec));
    try testing.expectApproxEqRel(@as(f64, 1e10), rec.t, 1e-12);
    try expectVector(.{ .x = 1 }, rec.normal, 1e-12);
}

test "capsule arbitrary segment orientation endpoint reversal and exact bounds" {
    var shape = object.Capsule{ .start = .{ .x = 1, .y = 2, .z = 3 }, .end = .{ .x = 4, .y = 6, .z = 3 }, .radius = 0.5, .material = &test_material };
    const obj = object.Object{ .capsule = &shape };
    _ = try expectHit(obj, Ray.init(.{ .x = 2.5, .y = 4, .z = 5 }, .{ .z = -1 }, 0), 1.5, .{ .z = 1 }, true);
    _ = try expectHit(obj, Ray.init(.{ .x = 5.2, .y = 7.6, .z = 3 }, .{ .x = -0.6, .y = -0.8 }, 0), 1.5, .{ .x = 0.6, .y = 0.8 }, true);
    var bounds: math.Aabb = undefined;
    try testing.expect(obj.boundingBox(-10, 10, &bounds));
    try expectVector(.{ .x = 0.5, .y = 1.5, .z = 2.5 }, bounds.min, 0);
    try expectVector(.{ .x = 4.5, .y = 6.5, .z = 3.5 }, bounds.max, 0);
    std.mem.swap(Vec3, &shape.start, &shape.end);
    var reversed: math.Aabb = undefined;
    try testing.expect(obj.boundingBox(0, 0, &reversed));
    try testing.expectEqualDeep(bounds, reversed);
    _ = try expectHit(obj, Ray.init(.{ .x = 2.5, .y = 4, .z = 5 }, .{ .z = -1 }, 0), 1.5, .{ .z = 1 }, true);
}

fn allocateCapsule(alloc: std.mem.Allocator) !void {
    const obj = try object.newCapsule(alloc, .{}, .{ .y = 2 }, 1, &test_material);
    defer alloc.destroy(obj);
    defer alloc.destroy(obj.capsule);
    try testing.expectEqual(&test_material, obj.capsule.material);
}

test "capsule factory validates before allocation and cleans every OOM path" {
    try testing.checkAllAllocationFailures(testing.allocator, allocateCapsule, .{});
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const alloc = failing.allocator();
    for ([_]f64{ 0, -1, math.infinity, -math.infinity, std.math.nan(f64) }) |radius| {
        try testing.expectError(error.InvalidCapsule, object.newCapsule(alloc, .{}, .{ .y = 2 }, radius, &test_material));
    }
    try testing.expectError(error.InvalidCapsule, object.newCapsule(alloc, .{}, .{}, 1, &test_material));
    try testing.expectError(error.InvalidCapsule, object.newCapsule(alloc, .{ .x = math.infinity }, .{}, 1, &test_material));
    try testing.expectError(error.InvalidCapsule, object.newCapsule(alloc, .{}, .{ .y = std.math.nan(f64) }, 1, &test_material));
    try testing.expectError(error.OutOfMemory, object.newCapsule(alloc, .{}, .{ .y = 2 }, 1, &test_material));
}

test "capsule works in unchanged BVH traversal including tangent bounds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const near = try object.newCapsule(alloc, .{}, .{ .y = 2 }, 1, &test_material);
    const far = try object.newCapsule(alloc, .{ .z = 5 }, .{ .y = 2, .z = 5 }, 0.5, &test_material);
    const node = try object.BvhNode.init(alloc, &.{ far, near }, 0, 2, 0, 1);
    const world = object.Object{ .bvh = node };
    for ([_]f64{ 0, 1 }) |x| {
        const ray = Ray.init(.{ .x = x, .y = 1, .z = -3 }, .{ .z = 1 }, 0);
        var expected: object.HitRecord = .{};
        var actual: object.HitRecord = .{};
        try testing.expect(near.hit(ray, 0, 3, &expected));
        try testing.expect(world.hit(ray, 0, 3, &actual));
        try testing.expectEqualDeep(expected, actual);
    }
    try testing.expectEqual(@as(f64, 0), near.pdfValueAt(.{}, .{ .x = 1 }, 0));
    try testing.expectEqual(@as(f64, 0), world.pdfValueAt(.{}, .{ .x = 1 }, 0));
}

test "moving sphere PDF and generated directions use current time not center0" {
    var sphere = object.Sphere.init(.{ .x = -4, .z = 5 }, .{ .x = 4, .z = 5 }, 2, 4, 1, &test_material);
    const obj = object.Object{ .sphere = &sphere };
    const origin = Vec3.init(0, 0, -1);
    random.seed(1042);
    for ([_]f64{ 0, 2, 2.5, 3, 4, 5 }) |time| {
        const axis = sphere.center(time).sub(origin);
        const expected = 1.0 / (2.0 * math.pi * (1.0 - @sqrt(1.0 - 1.0 / axis.lengthSquared())));
        try testing.expectApproxEqRel(expected, obj.pdfValueAt(origin, axis, time), 1e-12);
        try testing.expectEqual(@as(f64, 0), obj.pdfValueAt(origin, axis.neg(), time));
        for (0..512) |_| {
            const v = obj.randomAt(origin, time);
            try testing.expectApproxEqAbs(@as(f64, 1), v.length(), 1e-12);
            try testing.expectApproxEqRel(expected, obj.pdfValueAt(origin, v, time), 1e-12);
            try testing.expectApproxEqRel(expected, obj.pdfValueAt(origin, v.scale(1e100), time), 1e-12);
            var rec: object.HitRecord = .{};
            try testing.expect(obj.hit(Ray.init(origin, v, time), 0, math.infinity, &rec));
        }
    }
    try testing.expectEqual(@as(f64, 0), obj.pdfValueAt(origin, sphere.center(2).sub(origin), 4));
    try testing.expectEqual(obj.pdfValueAt(origin, sphere.center(0).sub(origin), 0), obj.pdfValue(origin, sphere.center(0).sub(origin)));
    random.seed(56);
    const legacy = obj.random(origin);
    random.seed(56);
    try testing.expectEqualDeep(legacy, obj.randomAt(origin, 0));
}

test "sphere interior sampling is uniform over the full sphere including off-center origins" {
    var sphere = object.Sphere.init(.{}, .{ .x = 3 }, 0, 1, 2, &test_material);
    const obj = object.Object{ .sphere = &sphere };
    const time: f64 = 0.7;
    const density = 1.0 / (4.0 * math.pi);
    random.seed(9001);
    for ([_]Vec3{ sphere.center(time), sphere.center(time).add(.{ .x = 1.5 }) }) |origin| {
        var mean = Vec3{};
        var second = Vec3{};
        for (0..12000) |_| {
            const v = obj.randomAt(origin, time);
            mean = mean.add(v);
            second = second.add(v.mul(v));
            try testing.expectEqual(density, obj.pdfValueAt(origin, v, time));
            try testing.expectEqual(density, obj.pdfValueAt(origin, v.neg().scale(1e-200), time));
            try testing.expectApproxEqAbs(@as(f64, 1), v.length(), 1e-12);
            var rec: object.HitRecord = .{};
            try testing.expect(obj.hit(Ray.init(origin, v, time), 0.000001, math.infinity, &rec));
            try testing.expect(!rec.front_face);
        }
        try expectVector(.{}, mean.div(12000), 0.025);
        try expectVector(.{ .x = 1.0 / 3.0, .y = 1.0 / 3.0, .z = 1.0 / 3.0 }, second.div(12000), 0.025);
    }
    try testing.expectEqual(@as(f64, 0), obj.pdfValueAt(.{}, .{}, time));
    try testing.expectEqual(@as(f64, 0), obj.pdfValueAt(.{}, .{ .x = math.infinity }, time));
}

test "sphere zero shutter span surface hemisphere and tiny distant cone stay finite" {
    var sphere = object.Sphere.init(.{}, .{ .x = 100 }, 2, 2, 1, &test_material);
    const obj = object.Object{ .sphere = &sphere };
    try testing.expectEqualDeep(Vec3{}, sphere.center(19));
    try testing.expectEqual(@as(f64, 1) / (2.0 * math.pi), obj.pdfValueAt(.{ .z = -1 }, .{ .z = 1 }, 19));
    try testing.expectEqual(@as(f64, 0), obj.pdfValueAt(.{ .z = -1 }, .{ .z = -1 }, 19));
    random.seed(17);
    const origin = Vec3.init(0, 0, -1e10);
    for (0..1024) |_| {
        const direction = obj.randomAt(origin, 19);
        const density = obj.pdfValueAt(origin, direction, 19);
        try testing.expect(density > 0 and std.math.isFinite(density));
        try testing.expectApproxEqRel(@as(f64, 1e20) / math.pi, density, 1e-12);
        try testing.expect(direction.x != 0 or direction.y != 0);
    }
}

test "all rectangle planes match area-to-solid-angle PDF and reject parallel coplanar rays" {
    var xy = object.XyRect{ .x0 = -1, .x1 = 1, .y0 = -1, .y1 = 1, .k = 2, .material = &test_material };
    var xz = object.XzRect{ .x0 = -1, .x1 = 1, .z0 = -1, .z1 = 1, .k = 2, .material = &test_material };
    var yz = object.YzRect{ .y0 = -1, .y1 = 1, .z0 = -1, .z1 = 1, .k = 2, .material = &test_material };
    const objects = [_]object.Object{ .{ .xy_rect = &xy }, .{ .xz_rect = &xz }, .{ .yz_rect = &yz } };
    const normals = [_]Vec3{ .{ .z = 1 }, .{ .y = 1 }, .{ .x = 1 } };
    random.seed(83);
    for (objects, normals) |obj, normal| {
        for ([_]f64{ 1e-200, 1, 1e200 }) |scale| try testing.expectApproxEqAbs(@as(f64, 1), obj.pdfValueAt(.{}, normal.scale(scale), 0.4), 1e-12);
        for (0..256) |_| {
            const v = obj.randomAt(.{}, 0.7);
            try testing.expectApproxEqAbs(@as(f64, 2), v.dot(normal), 1e-12);
            const expected = v.lengthSquared() / (4.0 * @abs(v.normalized().dot(normal)));
            try testing.expectApproxEqRel(expected, obj.pdfValueAt(.{}, v, 0.7), 1e-12);
            try testing.expectEqual(obj.pdfValue(.{}, v), obj.pdfValueAt(.{}, v, 0));
        }
        const tangent = if (normal.x == 1) Vec3.init(0, 1, 0) else Vec3.init(1, 0, 0);
        var rec: object.HitRecord = .{};
        try testing.expect(!obj.hit(Ray.init(normal.scale(2), tangent, 0), 0, math.infinity, &rec));
        try testing.expect(!obj.hit(Ray.init(.{}, tangent, 0), 0, math.infinity, &rec));
        try testing.expectEqual(@as(f64, 0), obj.pdfValueAt(normal.scale(2), tangent, 0));
        try testing.expectEqual(@as(f64, 0), obj.pdfValueAt(.{}, .{}, 0));
        // @notice 很近的有效光源不因旧的 t=0.001 截断或方向缩放消失。
        try testing.expectApproxEqAbs(@as(f64, 1e-8) / 4, obj.pdfValueAt(normal.scale(1.9999), normal, 0), 1e-19);
    }
}

fn rotate(v: Vec3, angle: f64) Vec3 {
    const radians = math.degreesToRadians(angle);
    return .{ .x = @cos(radians) * v.x + @sin(radians) * v.z, .y = v.y, .z = -@sin(radians) * v.x + @cos(radians) * v.z };
}

test "translation rotation and flip preserve interior exterior normal orientation" {
    var shape = capsule();
    var base = object.Object{ .capsule = &shape };
    var flip = object.FlipFace{ .ptr = &base };
    var flipped = object.Object{ .flip_face = &flip };
    const offset = Vec3.init(5, -2, 3);
    for ([_]*object.Object{ &base, &flipped }, 0..) |child, flip_index| {
        for ([_]f64{ 0, 37, 90, 150, 240 }) |angle| {
            var rotation = object.RotateY.init(testing.allocator, child, angle);
            var rotated = object.Object{ .rotate_y = &rotation };
            var translation = object.Translate{ .ptr = &rotated, .offset = offset };
            const transformed = object.Object{ .translate = &translation };
            for ([_]Ray{
                Ray.init(.{ .x = -3, .y = 1 }, .{ .x = 1 }, 0.6),
                Ray.init(.{ .y = 1 }, .{ .x = 1 }, 0.6),
            }, 0..) |local, ray_index| {
                const world = Ray.init(rotate(local.origin, angle).add(offset), rotate(local.direction, angle), local.time);
                var expected: object.HitRecord = .{};
                var actual: object.HitRecord = .{};
                try testing.expect(child.hit(local, 0.001, math.infinity, &expected));
                try testing.expect(transformed.hit(world, 0.001, math.infinity, &actual));
                try testing.expectEqual((ray_index == 0) != (flip_index == 1), actual.front_face);
                try testing.expectEqual(expected.front_face, actual.front_face);
                try testing.expectApproxEqAbs(expected.t, actual.t, 1e-12);
                try expectVector(rotate(expected.p, angle).add(offset), actual.p, 1e-12);
                try expectVector(rotate(expected.normal, angle), actual.normal, 1e-12);
                try testing.expect(actual.normal.dot(world.direction) < 0);
            }
        }
    }
}

test "nested transformed moving lights preserve PDFs directions and time in groups" {
    var sphere = object.Sphere.init(.{ .x = -2, .z = 4 }, .{ .x = 2, .z = 4 }, 0, 1, 0.5, &test_material);
    var base = object.Object{ .sphere = &sphere };
    var flip = object.FlipFace{ .ptr = &base };
    var flipped = object.Object{ .flip_face = &flip };
    const angle: f64 = 61;
    var rotation = object.RotateY.init(testing.allocator, &flipped, angle);
    var rotated = object.Object{ .rotate_y = &rotation };
    const offset = Vec3.init(7, -3, 2);
    var translation = object.Translate{ .ptr = &rotated, .offset = offset };
    var transformed = object.Object{ .translate = &translation };
    var group = object.ObjectGroup.init(testing.allocator);
    defer group.list.deinit(testing.allocator);
    try group.add(&transformed);
    try group.add(&base);
    const lights = object.Object{ .group = &group };
    const local_origin = Vec3.init(0, 1, -2);
    const origin = rotate(local_origin, angle).add(offset);
    for ([_]f64{ 0, 0.3, 0.9, 1 }) |time| {
        random.seed(193);
        const local_direction = base.randomAt(local_origin, time);
        random.seed(193);
        const direction = transformed.randomAt(origin, time);
        try expectVector(rotate(local_direction, angle), direction, 1e-12);
        const expected = base.pdfValueAt(local_origin, local_direction, time);
        try testing.expectApproxEqRel(expected, transformed.pdfValueAt(origin, direction, time), 1e-12);
        try testing.expectEqual(base.pdfValueAt(local_origin, local_direction, time), flipped.pdfValueAt(local_origin, local_direction, time));
        for (0..512) |_| {
            const v = lights.randomAt(origin, time);
            const mixture = (transformed.pdfValueAt(origin, v, time) + base.pdfValueAt(origin, v, time)) / 2;
            try testing.expect(mixture > 0);
            try testing.expectApproxEqRel(mixture, lights.pdfValueAt(origin, v, time), 1e-12);
            var rec: object.HitRecord = .{};
            try testing.expect(lights.hit(Ray.init(origin, v, time), 0.000001, math.infinity, &rec));
        }
    }
    random.seed(77);
    const legacy = lights.random(origin);
    random.seed(77);
    try testing.expectEqualDeep(legacy, lights.randomAt(origin, 0));
    try testing.expectEqual(lights.pdfValue(origin, legacy), lights.pdfValueAt(origin, legacy, 0));
}

test "transformed rectangle light sampling rotates vectors without translating them" {
    var rect = object.XyRect{ .x0 = -1, .x1 = 1, .y0 = -1, .y1 = 1, .k = 2, .material = &test_material };
    var base = object.Object{ .xy_rect = &rect };
    var rotation = object.RotateY.init(testing.allocator, &base, 90);
    var rotated = object.Object{ .rotate_y = &rotation };
    var translation = object.Translate{ .ptr = &rotated, .offset = .{ .x = 3, .y = 4, .z = 5 } };
    var moved = object.Object{ .translate = &translation };
    var flip = object.FlipFace{ .ptr = &moved };
    const obj = object.Object{ .flip_face = &flip };
    const origin = translation.offset;
    random.seed(144);
    for (0..512) |_| {
        const v = obj.randomAt(origin, 0.8);
        try testing.expectApproxEqAbs(@as(f64, 2), v.x, 1e-12);
        const expected = v.lengthSquared() / (4 * @abs(v.normalized().x));
        try testing.expectApproxEqRel(expected, obj.pdfValueAt(origin, v, 0.8), 1e-12);
        var rec: object.HitRecord = .{};
        try testing.expect(obj.hit(Ray.init(origin, v, 0.8), 0, math.infinity, &rec));
        try testing.expect(rec.front_face);
        try testing.expectApproxEqAbs(@as(f64, 1), rec.t, 1e-12);
    }
}

test "empty groups and unsupported capsule lights explicitly have zero PDF" {
    var shape = capsule();
    const obj = object.Object{ .capsule = &shape };
    var group = object.ObjectGroup.init(testing.allocator);
    const empty = object.Object{ .group = &group };
    for ([_]object.Object{ obj, empty }) |light| {
        try testing.expectEqual(@as(f64, 0), light.pdfValueAt(.{}, .{ .x = 1 }, 0.6));
        try expectVector(.{ .x = 1 }, light.randomAt(.{}, 0.6), 0);
    }
}
