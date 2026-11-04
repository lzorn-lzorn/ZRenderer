const std = @import("std");
const math = @import("math.zig");
const random = @import("random.zig");
const object = @import("object.zig");
const material = @import("material.zig");
const texture = @import("texture.zig");
const color = @import("color.zig");
const testing = std.testing;

fn plane(alloc: std.mem.Allocator, mat: *material.Material) !*object.BvhNode {
    const obj = try object.newXzRect(alloc, -100, 100, -100, 100, 0, mat);
    return object.BvhNode.init(alloc, &.{obj}, 0, 1, 0, 1);
}

fn expectColor(expected: math.Color, actual: math.Color, tolerance: f64) !void {
    for (0..3) |channel| try testing.expectApproxEqAbs(expected.at(channel), actual.at(channel), tolerance);
}

test "integrator does not amplify diffuse or mirror paths before roulette" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const albedo = math.Color.init(0.25, 0.5, 0.75);
    const background = math.Color.init(0.8, 0.6, 0.4);
    const diffuse = try material.newLambertian(alloc, try texture.newSolid(alloc, albedo));
    const mirror = try material.newMetal(alloc, albedo, 0);
    const ray = math.Ray.init(.{ .y = 1 }, .{ .y = -1 }, 0);
    for ([_]*material.Material{ diffuse, mirror }) |mat| {
        const world = try plane(alloc, mat);
        for (0..64) |seed| {
            random.seed(@intCast(seed));
            try expectColor(albedo.mul(background), color.rayColor(ray, background, world, null, 5, 0.9), 1e-12);
        }
    }
}

test "integrator preserves emission and direct background before roulette" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const emission = math.Color.init(3, 2, 1);
    var light = material.DiffuseLight{ .emit = try texture.newSolid(alloc, emission) };
    var mat = material.Material{ .diffuse_light = &light };
    const world = try plane(alloc, &mat);
    const background = math.Color.init(0.25, 0.5, 0.75);
    for (0..64) |seed| {
        random.seed(@intCast(seed));
        try expectColor(emission, color.rayColor(math.Ray.init(.{ .y = 1 }, .{ .y = -1 }, 0), background, world, null, 0, 0.1), 0);
        try expectColor(background, color.rayColor(math.Ray.init(.{ .y = 1 }, .{ .y = 1 }, 0), background, world, null, 0, 0.1), 0);
    }
}

test "roulette preserves mean Lambertian radiance" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const albedo = math.Color.init(0.25, 0.5, 0.75);
    const mat = try material.newLambertian(alloc, try texture.newSolid(alloc, albedo));
    const world = try plane(alloc, mat);
    const background = math.Color.init(0.8, 0.6, 0.4);
    const ray = math.Ray.init(.{ .y = 1 }, .{ .y = -1 }, 0);
    random.seed(0xaffe);
    var sum: math.Color = .{};
    const samples = 32768;
    for (0..samples) |_| sum = sum.add(color.rayColor(ray, background, world, null, 0, 0.9));
    try expectColor(albedo.mul(background), sum.div(samples), 0.01);
}

test "mixed light and BSDF sampling preserves constant-environment expectation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const albedo = math.Color.init(0.25, 0.5, 0.75);
    const mat = try material.newLambertian(alloc, try texture.newSolid(alloc, albedo));
    const world = try plane(alloc, mat);
    // @notice 此采样代理故意不加入场景，因此每条出射光线看到相同环境。
    // @method 解析结果为反照率与背景颜色逐分量相乘，即 albedo * background。
    const proxy = try object.newXzRect(alloc, -2, 2, -2, 2, 2, mat);
    const background = math.Color.init(0.8, 0.6, 0.4);
    random.seed(123);
    var sum: math.Color = .{};
    const samples = 32768;
    for (0..samples) |_| sum = sum.add(color.rayColor(math.Ray.init(.{ .y = 1 }, .{ .y = -1 }, 0), background, world, proxy, 5, 0.9));
    try expectColor(albedo.mul(background), sum.div(samples), 0.01);
}

test "iterative integrator handles ten thousand mirror bounces without recursion" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const mat = try material.newMetal(alloc, .{ .x = 1, .y = 1, .z = 1 }, 0);
    const top = try object.newXzRect(alloc, -100, 100, -100, 100, 1, mat);
    const bottom = try object.newXzRect(alloc, -100, 100, -100, 100, -1, mat);
    const world = try object.BvhNode.init(alloc, &.{ top, bottom }, 0, 2, 0, 1);
    random.seed(999);
    try expectColor(.{}, color.rayColor(math.Ray.init(.{}, .{ .y = 1 }, 0), .{}, world, null, 10000, 0.9), 0);
}
