const std = @import("std");
const testing = std.testing;
const math = @import("math.zig");
const object = @import("object.zig");
const material = @import("material.zig");
const random = @import("random.zig");

fn expectSameHit(expected: object.HitRecord, actual: object.HitRecord) !void {
    try testing.expectApproxEqAbs(expected.t, actual.t, 1e-12);
    try testing.expectApproxEqAbs(expected.u, actual.u, 1e-12);
    try testing.expectApproxEqAbs(expected.v, actual.v, 1e-12);
    inline for (.{ "x", "y", "z" }) |axis| {
        try testing.expectApproxEqAbs(@field(expected.p, axis), @field(actual.p, axis), 1e-12);
        try testing.expectApproxEqAbs(@field(expected.normal, axis), @field(actual.normal, axis), 1e-12);
    }
    try testing.expectEqual(expected.front_face, actual.front_face);
    try testing.expectEqual(expected.material, actual.material);
}

test "AABB parallel slabs include faces and signed zero, exclude outside origins" {
    const box = math.Aabb.init(.{}, .{ .x = 1, .y = 1, .z = 1 });
    inline for (.{ "x", "y", "z" }) |axis| {
        for ([_]f64{ 0.0, -0.0 }) |zero| {
            for ([_]f64{ 0, 0.5, 1, -0.001, 1.001 }) |position| {
                var origin = math.Point3.init(-1, -1, -1);
                var direction = math.Vec3.init(1, 1, 1);
                @field(origin, axis) = position;
                @field(direction, axis) = zero;
                const ray = math.Ray.init(origin, direction, 0);
                const interval = box.interval(ray, 0, math.infinity);
                const inside = position >= 0 and position <= 1;
                try testing.expectEqual(inside, interval != null);
                try testing.expectEqual(inside, box.hit(ray, 0, math.infinity));
                try testing.expectEqualDeep(interval, box.intervalCached(math.AabbRay.init(ray), 0, math.infinity));
                if (interval) |range| {
                    try testing.expectEqual(@as(f64, 1), range.entry);
                    try testing.expectEqual(@as(f64, 2), range.exit);
                }
            }
        }
    }
}

test "AABB intervals handle reverse rays, grazing, clipping, and tiny directions" {
    const box = math.Aabb.init(.{}, .{ .x = 1, .y = 1, .z = 1 });
    const reverse = math.Ray.init(.{ .x = 0.5, .y = 0.5, .z = 2 }, .{ .z = -1 }, 0);
    const range = box.interval(reverse, 1.25, 1.75).?;
    try testing.expectEqual(@as(f64, 1.25), range.entry);
    try testing.expectEqual(@as(f64, 1.75), range.exit);
    try testing.expect(box.interval(reverse, 0, 0.9) == null);
    try testing.expect(box.interval(reverse, 2, 1) == null);
    const grazing = math.Ray.init(.{ .x = -1, .y = 1 }, .{ .x = 1, .y = -1 }, 0);
    const tangent = box.interval(grazing, 0, math.infinity).?;
    try testing.expectEqual(@as(f64, 1), tangent.entry);
    try testing.expectEqual(tangent.entry, tangent.exit);
    // @notice 即使方向非零，其倒数仍可能溢出。
    for ([_]f64{ 1e-310, -1e-310 }) |tiny| {
        const ray = math.Ray.init(.{ .x = if (tiny > 0) 0 else 1, .y = 0.5, .z = -1 }, .{ .x = tiny, .z = 1 }, 0);
        const interval = box.interval(ray, 0, math.infinity).?;
        try testing.expectEqual(@as(f64, 1), interval.entry);
        try testing.expectEqual(@as(f64, 2), interval.exit);
    }
    try testing.expect(box.hit(math.Ray.init(.{ .x = 1 }, .{}, 0), 0, 1));
    try testing.expect(!box.hit(math.Ray.init(.{ .x = 2 }, .{}, 0), 0, 1));
}

test "BVH nearest hits match group including motion, UVs, misses, and bounded intervals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const glass = try material.newDielectric(alloc, 1.5);
    const metal = try material.newMetal(alloc, .{ .x = 0.5 }, 0);
    var group = object.ObjectGroup.init(alloc);
    try group.add(try object.newSphere(alloc, .{}, .{}, 2, 4, 1, glass));
    try group.add(try object.newSphere(alloc, .{ .x = -3, .z = 2 }, .{ .x = -1, .z = 2 }, 2, 4, 0.7, metal));
    try group.add(try object.newSphere(alloc, .{ .x = 2, .y = -1, .z = 1 }, .{ .x = 2, .y = 1, .z = 1 }, 2, 4, 0.8, glass));
    try group.add(try object.newSphere(alloc, .{ .z = 5 }, .{ .z = 5 }, 2, 4, 1, metal));
    try group.add(try object.newSphere(alloc, .{ .x = -4, .z = -2 }, .{ .x = -4, .z = -2 }, 2, 4, 0.5, glass));
    const original = try alloc.dupe(*object.Object, group.list.items);
    const node = try object.BvhNode.init(alloc, group.list.items, 0, group.list.items.len, 2, 4);
    var world = object.Object{ .bvh = node };
    try testing.expectEqualSlices(*object.Object, original, group.list.items);
    var hit_count: usize = 0;
    var miss_count: usize = 0;
    for ([_]f64{ 2, 2.5, 3, 3.5, 4 }) |time| {
        for ([_]f64{ -4, -3, -2, -1, 0, 0.5, 1, 2, 3 }) |x| {
            for ([_]f64{ -1, 0, 0.5, 1 }) |y| {
                for ([_]f64{ -1, 1 }) |sign| {
                    const ray = math.Ray.init(.{ .x = x, .y = y, .z = -8 * sign }, .{ .z = sign }, time);
                    for ([_][2]f64{ .{ 0.001, math.infinity }, .{ 0.001, 6 }, .{ 8, 20 } }) |limits| {
                        var expected: object.HitRecord = .{};
                        var actual: object.HitRecord = .{};
                        const found = group.hit(ray, limits[0], limits[1], &expected);
                        try testing.expectEqual(found, world.hit(ray, limits[0], limits[1], &actual));
                        if (found) {
                            hit_count += 1;
                            try expectSameHit(expected, actual);
                        } else {
                            miss_count += 1;
                        }
                    }
                }
            }
        }
        // @notice 使用非轴对齐射线，瞄准当前时刻实际移动后的球心。
        for (group.list.items) |item| {
            const origin = math.Point3.init(7, 4, -10);
            const ray = math.Ray.init(origin, item.sphere.center(time).sub(origin), time);
            var expected: object.HitRecord = .{};
            var actual: object.HitRecord = .{};
            try testing.expect(group.hit(ray, 0.001, math.infinity, &expected));
            try testing.expect(world.hit(ray, 0.001, math.infinity, &actual));
            try expectSameHit(expected, actual);
        }
    }
    try testing.expect(hit_count > 0 and miss_count > 0);
}

test "BVH singleton medium intersects once and preserves RNG state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const mat = try material.newDielectric(alloc, 1.5);
    const boundary = try object.newSphere(alloc, .{}, .{}, 0, 1, 1, mat);
    var medium = object.ConstantMedium.init(boundary, 1000, mat);
    var leaf = object.Object{ .constant_medium = &medium };
    const node = try object.BvhNode.init(alloc, &.{&leaf}, 0, 1, 0, 1);
    try testing.expect(node.left == node.right);
    const ray = math.Ray.init(.{ .z = -3 }, .{ .z = 1 }, 0.5);
    for ([_]u64{ 1, 42, 1234 }) |seed| {
        var expected: object.HitRecord = .{};
        var actual: object.HitRecord = .{};
        random.seed(seed);
        try testing.expect(leaf.hit(ray, 0.001, math.infinity, &expected));
        const next = random.randomDouble();
        random.seed(seed);
        try testing.expect(node.hit(ray, 0.001, math.infinity, &actual));
        try expectSameHit(expected, actual);
        try testing.expectEqual(next, random.randomDouble());
    }
}

test "BVH visits nearer right child first and prunes farther medium" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const mat = try material.newDielectric(alloc, 1.5);
    const far_boundary = try object.newSphere(alloc, .{}, .{}, 0, 1, 1, mat);
    const near_boundary = try object.newSphere(alloc, .{ .z = 5 }, .{ .z = 5 }, 0, 1, 1, mat);
    var far_medium = object.ConstantMedium.init(far_boundary, 1000, mat);
    var near_medium = object.ConstantMedium.init(near_boundary, 1000, mat);
    var far = object.Object{ .constant_medium = &far_medium };
    var near = object.Object{ .constant_medium = &near_medium };
    const node = try object.BvhNode.init(alloc, &.{ &near, &far }, 0, 2, 0, 1);
    try testing.expect(node.left == &far and node.right == &near);
    const ray = math.Ray.init(.{ .z = 10 }, .{ .z = -1 }, 0.5);
    var expected: object.HitRecord = .{};
    var actual: object.HitRecord = .{};
    random.seed(42);
    try testing.expect(near.hit(ray, 0.001, math.infinity, &expected));
    const next = random.randomDouble();
    random.seed(42);
    try testing.expect(node.hit(ray, 0.001, math.infinity, &actual));
    try expectSameHit(expected, actual);
    try testing.expectEqual(next, random.randomDouble());
}

test "BVH falls back after near box misses primitive and retains endpoint hits" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const mat = try material.newDielectric(alloc, 1.5);
    const near = try object.newSphere(alloc, .{}, .{}, 0, 1, 1, mat);
    const far = try object.newSphere(alloc, .{ .x = 0.9, .y = 0.9, .z = 5 }, .{ .x = 0.9, .y = 0.9, .z = 5 }, 0, 1, 1, mat);
    const node = try object.BvhNode.init(alloc, &.{ near, far }, 0, 2, 0, 1);
    const ray = math.Ray.init(.{ .x = 0.9, .y = 0.9, .z = -3 }, .{ .z = 1 }, 0);
    var expected: object.HitRecord = .{};
    var actual: object.HitRecord = .{};
    try testing.expect(far.hit(ray, 0, 7, &expected));
    try testing.expect(node.hit(ray, 0, 7, &actual));
    try expectSameHit(expected, actual);
    try testing.expect(!node.hit(ray, 0, 6.99, &actual));
    // @notice 切点位于平行夹层边界，且射线参数恰好等于 tmax。
    const tangent = math.Ray.init(.{ .x = 1, .z = -3 }, .{ .z = 1 }, 0);
    try testing.expect(near.hit(tangent, 0, 3, &expected));
    try testing.expect(node.hit(tangent, 0, 3, &actual));
    try expectSameHit(expected, actual);
}

test "BVH overlapping child bounds allow the second child to improve the hit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const glass = try material.newDielectric(alloc, 1.5);
    const metal = try material.newMetal(alloc, .{ .x = 0.5 }, 0);
    const large = try object.newSphere(alloc, .{}, .{}, 0, 1, 5, glass);
    const small = try object.newSphere(alloc, .{ .x = 4.8, .z = -2 }, .{ .x = 4.8, .z = -2 }, 0, 1, 0.5, metal);
    const node = try object.BvhNode.init(alloc, &.{ large, small }, 0, 2, 0, 1);
    const ray = math.Ray.init(.{ .x = 4.8, .z = -10 }, .{ .z = 1 }, 0);
    try testing.expect(node.left_box.interval(ray, 0, math.infinity).?.entry < node.right_box.interval(ray, 0, math.infinity).?.entry);
    var large_rec: object.HitRecord = .{};
    var expected: object.HitRecord = .{};
    var actual: object.HitRecord = .{};
    try testing.expect(large.hit(ray, 0, math.infinity, &large_rec));
    try testing.expect(small.hit(ray, 0, math.infinity, &expected));
    try testing.expect(expected.t < large_rec.t);
    try testing.expect(node.hit(ray, 0, math.infinity, &actual));
    try expectSameHit(expected, actual);
}

test "BVH missing bounds fail before sorting, including wrapped objects and subranges" {
    var dielectric = material.Dielectric{ .ir = 1.5 };
    var mat = material.Material{ .dielectric = &dielectric };
    var sphere = object.Sphere.init(.{}, .{}, 0, 1, 1, &mat);
    var valid = object.Object{ .sphere = &sphere };
    var empty = object.ObjectGroup.init(testing.allocator);
    var missing = object.Object{ .group = &empty };
    var transform = object.Translate{ .ptr = &missing, .offset = .{ .x = 1 } };
    var wrapped = object.Object{ .translate = &transform };
    for ([_]*object.Object{ &missing, &wrapped }) |bad| {
        try testing.expectError(error.MissingBoundingBox, object.BvhNode.init(testing.allocator, &.{bad}, 0, 1, 0, 1));
        try testing.expectError(error.MissingBoundingBox, object.BvhNode.init(testing.allocator, &.{ &valid, bad }, 0, 2, 0, 1));
        try testing.expectError(error.MissingBoundingBox, object.BvhNode.init(testing.allocator, &.{ &valid, &valid, bad, &valid, &valid }, 0, 5, 0, 1));
    }
    // @notice 请求范围外的对象既不参与查询，也不被构建结果持有。
    const node = try object.BvhNode.init(testing.allocator, &.{ &missing, &valid, &wrapped }, 1, 2, 0, 1);
    defer testing.allocator.destroy(node);
    try testing.expect(node.left == &valid and node.right == &valid);
}

test "BVH split uses longest centroid extent without consuming random samples" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const mat = try material.newDielectric(alloc, 1.5);
    const low = try object.newSphere(alloc, .{ .x = 2, .y = -5 }, .{ .x = 2, .y = -5 }, 0, 1, 1, mat);
    const high = try object.newSphere(alloc, .{ .x = -2, .y = 5 }, .{ .x = -2, .y = 5 }, 0, 1, 1, mat);
    random.seed(123);
    const next = random.randomDouble();
    random.seed(123);
    const node = try object.BvhNode.init(alloc, &.{ high, low }, 0, 2, 0, 1);
    try testing.expectEqual(next, random.randomDouble());
    try testing.expect(node.left == low and node.right == high);
    var bounds: math.Aabb = undefined;
    try testing.expect(low.boundingBox(0, 1, &bounds));
    try testing.expectEqualDeep(bounds, node.left_box);
    try testing.expect(high.boundingBox(0, 1, &bounds));
    try testing.expectEqualDeep(bounds, node.right_box);
}

// @notice 只销毁构建器拥有的节点和包装，绝不销毁借用的输入对象。
fn freeTestTree(alloc: std.mem.Allocator, node: *object.BvhNode, count: usize) void {
    if (count > 2) {
        freeTestTree(alloc, node.left.bvh, count / 2);
        freeTestTree(alloc, node.right.bvh, count - count / 2);
        alloc.destroy(node.left);
        alloc.destroy(node.right);
    }
    alloc.destroy(node);
}

fn buildAndFree(alloc: std.mem.Allocator, objects: []const *object.Object) !void {
    const node = try object.BvhNode.init(alloc, objects, 0, objects.len, 0, 1);
    defer freeTestTree(alloc, node, objects.len);
}

test "BVH partial build allocation failures release owned nodes and wrappers" {
    var dielectric = material.Dielectric{ .ir = 1.5 };
    var mat = material.Material{ .dielectric = &dielectric };
    var sphere = object.Sphere.init(.{}, .{}, 0, 1, 1, &mat);
    var leaf = object.Object{ .sphere = &sphere };
    const objects = [_]*object.Object{ &leaf, &leaf, &leaf, &leaf, &leaf, &leaf, &leaf };
    try testing.checkAllAllocationFailures(testing.allocator, buildAndFree, .{@as([]const *object.Object, &objects)});
}
