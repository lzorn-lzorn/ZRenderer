const std = @import("std");
const math = @import("math.zig");
const random = @import("random.zig");
const camera = @import("camera.zig");
const material = @import("material.zig");
const texture = @import("texture.zig");
const object = @import("object.zig");
const render = @import("render.zig");
const testing = std.testing;

test {
    _ = @import("bvh_tests.zig");
    _ = @import("integrator_tests.zig");
    _ = @import("sampling_tests.zig");
    _ = @import("bsdf_tests.zig");
    _ = @import("camera_tests.zig");
    _ = @import("geometry_tests.zig");
    _ = @import("lighting_tests.zig");
    _ = @import("scene_tests.zig");
}

// @notice Zig 按需分析声明；除入口外，还检查未被使用的公共接口。
fn refAllDeclsRecursive(comptime T: type) void {
    testing.refAllDecls(T);
    inline for (comptime std.meta.declarations(T)) |name| {
        const decl = @field(T, name);
        if (@TypeOf(decl) == type) {
            switch (@typeInfo(decl)) {
                .@"struct", .@"union", .@"enum" => refAllDeclsRecursive(decl),
                else => {},
            }
        }
    }
}

test "all handwritten public declarations compile" {
    inline for (.{ math, random, camera, material, texture, object, render, @import("bsdf.zig"), @import("light.zig"), @import("sampling.zig"), @import("color.zig"), @import("noise.zig"), @import("pdf.zig"), @import("stb.zig"), @import("main.zig") }) |module| {
        refAllDeclsRecursive(module);
    }
}

test "integer random ranges include negative and singleton bounds" {
    try testing.expectEqual(@as(i32, -3), random.randomInt(-3, -3));
    try testing.expectEqual(std.math.minInt(i32), random.randomInt(std.math.minInt(i32), std.math.minInt(i32)));
    try testing.expectEqual(std.math.maxInt(i32), random.randomInt(std.math.maxInt(i32), std.math.maxInt(i32)));
    var seen: [5]bool = @splat(false);
    for (0..1000) |_| {
        const n = random.randomInt(-3, 1);
        try testing.expect(n >= -3 and n <= 1);
        seen[@intCast(n + 3)] = true;
    }
    for (seen) |value| try testing.expect(value);
}

test "factories propagate allocation failures" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const alloc = failing.allocator();
    var dielectric = material.Dielectric{ .ir = 1.5 };
    var mat = material.Material{ .dielectric = &dielectric };
    var solid = texture.SolidColor{};
    var tex = texture.Texture{ .solid = &solid };
    try testing.expectError(error.OutOfMemory, texture.newSolid(alloc, .{}));
    try testing.expectError(error.OutOfMemory, texture.newCheckerColors(alloc, .{}, .{}));
    try testing.expectError(error.OutOfMemory, material.newLambertian(alloc, &tex));
    try testing.expectError(error.OutOfMemory, material.newMetal(alloc, .{}, 0));
    try testing.expectError(error.OutOfMemory, material.newDielectric(alloc, 1.5));
    try testing.expectError(error.OutOfMemory, material.newIsotropic(alloc, .{}));
    try testing.expectError(error.OutOfMemory, object.newSphere(alloc, .{}, .{}, 0, 1, 1, &mat));
    try testing.expectError(error.OutOfMemory, object.newXyRect(alloc, -1, 1, -1, 1, 0, &mat));
    try testing.expectError(error.OutOfMemory, object.newXzRect(alloc, -1, 1, -1, 1, 0, &mat));
    try testing.expectError(error.OutOfMemory, object.newYzRect(alloc, -1, 1, -1, 1, 0, &mat));
    var sphere = object.Sphere.init(.{}, .{}, 0, 1, 1, &mat);
    var obj = object.Object{ .sphere = &sphere };
    try testing.expectError(error.OutOfMemory, object.BvhNode.init(alloc, &.{&obj}, 0, 1, 0, 1));
}

test "sphere UV and geometry PDFs are finite" {
    var dielectric = material.Dielectric{ .ir = 1.5 };
    var mat = material.Material{ .dielectric = &dielectric };
    const sphere = object.Sphere.init(.{}, .{}, 0, 1, 1, &mat);
    const origin = math.Point3.init(0, 0, -3);
    const direction = math.Vec3.init(0, 0, 1);
    var rec: object.HitRecord = .{};
    try testing.expect(sphere.hit(math.Ray.init(origin, direction, 0), 0.001, math.infinity, &rec));
    try testing.expectApproxEqAbs(@as(f64, 2), rec.t, 1e-12);
    try testing.expect(rec.u >= 0 and rec.u <= 1 and rec.v >= 0 and rec.v <= 1);
    try testing.expect(std.math.isFinite(sphere.pdfValue(origin, direction)));
    try testing.expect(sphere.pdfValue(origin, direction) > 0);
    const rect = object.XzRect{ .x0 = -1, .x1 = 1, .z0 = -1, .z1 = 1, .k = 0, .material = &mat };
    try testing.expectApproxEqAbs(@as(f64, 1), rect.pdfValue(.{ .y = 2 }, .{ .y = -1 }), 1e-12);
}

test "BVH matches a group without changing its object order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const mat = try material.newDielectric(alloc, 1.5);
    var scene = render.Scene.init(alloc, "test");
    for (0..3) |i| {
        const center = math.Point3.init(@as(f64, @floatFromInt(i)) * 3, 0, 0);
        try scene.addObject(try object.newSphere(alloc, center, center, 0, 1, 1, mat));
    }
    const original = try alloc.dupe(*object.Object, scene.world.list.items);
    try scene.buildBvh();
    try testing.expectEqualSlices(*object.Object, original, scene.world.list.items);
    var group_rec: object.HitRecord = .{};
    var bvh_rec: object.HitRecord = .{};
    const ray = math.Ray.init(.{ .z = -3 }, .{ .z = 1 }, 0);
    try testing.expect(scene.world.hit(ray, 0.001, math.infinity, &group_rec));
    try testing.expect(scene.bvh.hit(ray, 0.001, math.infinity, &bvh_rec));
    try testing.expectEqual(group_rec.t, bvh_rec.t);
    const box = try object.Box.init(alloc, .{ .x = -1, .y = -1, .z = -1 }, .{ .x = 1, .y = 1, .z = 1 }, mat);
    try testing.expect(box.hit(ray, 0.001, math.infinity, &bvh_rec));
}

test "BVH rejects empty and invalid ranges" {
    try testing.expectError(error.InvalidObjectRange, object.BvhNode.init(testing.allocator, &.{}, 0, 0, 0, 1));
    try testing.expectError(error.InvalidObjectRange, object.BvhNode.init(testing.allocator, &.{}, 0, 1, 0, 1));
}

test "Perlin noise handles negative coordinates" {
    const noise = @import("noise.zig").Perlin.init();
    const p = math.Point3.init(-1.25, -3.5, -8.75);
    try testing.expect(std.math.isFinite(noise.noise(p)));
    try testing.expect(std.math.isFinite(noise.turb(p, 7)));
}

test "clock supports running stopped and restarted states" {
    var clock = render.Clock{ .io = testing.io };
    try testing.expectEqual(@as(f64, 0), clock.elapsedSeconds());
    clock.start();
    const running = clock.elapsedSeconds();
    try testing.expect(running >= 0);
    clock.stop();
    const stopped = clock.elapsedSeconds();
    try testing.expect(stopped >= running);
    try testing.expectEqual(stopped, clock.elapsedSeconds());
    clock.start();
    try testing.expect(clock.elapsedSeconds() >= 0);
    clock.stop();
}

test "small render writes a readable PNG and releases its buffer" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const filename = try testing.allocator.printSentinel(".zig-cache/tmp/{s}/render.png", .{tmp.sub_path}, 0);
    defer testing.allocator.free(filename);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var scene = render.Scene.init(alloc, "smoke");
    const mat = try material.newLambertian(alloc, try texture.newCheckerColors(alloc, .{ .x = 0.8 }, .{ .y = 0.8 }));
    try scene.addObject(try object.newSphere(alloc, .{}, .{}, 0, 1, 1, mat));
    try scene.buildBvh();
    const args = camera.CameraArgs{
        .lookfrom = .{ .z = -3 },
        .lookat = .{},
        .vup = .{ .y = 1 },
        .aspect_ratio = 1,
    };
    try render.renderImage(testing.allocator, .{
        .cam = args.build(),
        .background = .{ .x = 0.7, .y = 0.8, .z = 1 },
        .image_width = 8,
        .image_height = 8,
        .samples_per_pixel = 2,
        .min_bounce = 2,
        .rr = 0.9,
        .channel = 3,
        .show_progress = false,
    }, scene.bvh, null, filename);
    var image = texture.ImageTexture.init(filename);
    defer image.deinit();
    try testing.expect(image.data != null);
    try testing.expectEqual(@as(i32, 8), image.width);
    try testing.expectEqual(@as(i32, 8), image.height);
    const pixel = image.value(0.5, 0.5, .{});
    try testing.expect(std.math.isFinite(pixel.x) and std.math.isFinite(pixel.y) and std.math.isFinite(pixel.z));
}

fn parallelTestScene(alloc: std.mem.Allocator) !render.Scene {
    var scene = render.Scene.init(alloc, "parallel");
    const diffuse = try material.newLambertian(alloc, try texture.newCheckerColors(alloc, .{ .x = 0.8 }, .{ .y = 0.8 }));
    const metal = try material.newMetal(alloc, .{ .x = 0.8, .y = 0.8, .z = 0.8 }, 0.2);
    const glass = try material.newDielectric(alloc, 1.5);
    try scene.addObject(try object.newSphere(alloc, .{}, .{ .y = 0.2 }, 0, 1, 0.6, diffuse));
    try scene.addObject(try object.newSphere(alloc, .{ .x = -1.4 }, .{ .x = -1.4 }, 0, 1, 0.6, metal));
    try scene.addObject(try object.newSphere(alloc, .{ .x = 1.4 }, .{ .x = 1.4 }, 0, 1, 0.6, glass));
    try scene.addObject(try object.newSphere(alloc, .{ .y = -100.7 }, .{ .y = -100.7 }, 0, 1, 100, diffuse));
    try scene.buildBvh();
    return scene;
}

fn parallelTestParams() render.RenderParams {
    const args = camera.CameraArgs{
        .lookfrom = .{ .y = 0.4, .z = -4 },
        .lookat = .{},
        .vup = .{ .y = 1 },
        .aspect_ratio = 17.0 / 19.0,
        .vfov = 55,
        .aperture = 0.05,
        .time1 = 1,
    };
    return .{
        .cam = args.build(),
        .background = .{ .x = 0.7, .y = 0.8, .z = 1 },
        .image_width = 17,
        .image_height = 19,
        .samples_per_pixel = 4,
        .min_bounce = 2,
        .rr = 0.9,
        .channel = 3,
        .show_progress = false,
        .thread_count = 1,
    };
}

test "parallel render is byte identical across thread counts and row blocks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scene = try parallelTestScene(arena.allocator());
    var params = parallelTestParams();
    const reference = try render.renderPixels(testing.allocator, params, scene.bvh, null);
    defer testing.allocator.free(reference);
    try testing.expectEqual(@as(usize, 17 * 19 * 3), reference.len);

    // @notice 奇数图像尺寸用于覆盖末尾不完整任务块和工作线程过多的情况。
    for ([_]usize{ 1, 2, 4, 128, 0 }) |thread_count| {
        for ([_]usize{ 1, 3, 8, 128 }) |rows_per_task| {
            params.thread_count = thread_count;
            params.rows_per_task = rows_per_task;
            const pixels = try render.renderPixels(testing.allocator, params, scene.bvh, null);
            defer testing.allocator.free(pixels);
            try testing.expectEqualSlices(u8, reference, pixels);
        }
    }

    params.seed +%= 1;
    const changed = try render.renderPixels(testing.allocator, params, scene.bvh, null);
    defer testing.allocator.free(changed);
    try testing.expect(!std.mem.eql(u8, reference, changed));
}

test "parallel PNG covers every row with red above blue" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const filename = try testing.allocator.printSentinel(".zig-cache/tmp/{s}/orientation.png", .{tmp.sub_path}, 0);
    defer testing.allocator.free(filename);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var red_light = material.DiffuseLight{ .emit = try texture.newSolid(alloc, .{ .x = 1 }) };
    var blue_light = material.DiffuseLight{ .emit = try texture.newSolid(alloc, .{ .z = 1 }) };
    var red = material.Material{ .diffuse_light = &red_light };
    var blue = material.Material{ .diffuse_light = &blue_light };
    var scene = render.Scene.init(alloc, "orientation");
    try scene.addObject(try object.newXyRect(alloc, -100, 100, 0, 100, -1, &red));
    try scene.addObject(try object.newXyRect(alloc, -100, 100, -100, 0, -1, &blue));
    try scene.buildBvh();

    try render.renderImage(testing.allocator, .{
        .cam = .{
            .origin = .{},
            .lower_left_corner = .{ .x = -1, .y = -1, .z = -1 },
            .horizontal = .{ .x = 2 },
            .vertical = .{ .y = 2 },
        },
        .background = .{},
        .image_width = 5,
        .image_height = 6,
        .samples_per_pixel = 2,
        .min_bounce = 2,
        .rr = 0.9,
        .channel = 3,
        .show_progress = false,
        .thread_count = 8,
        .rows_per_task = 2,
    }, scene.bvh, null, filename);
    var image = texture.ImageTexture.init(filename);
    defer image.deinit();
    try testing.expect(image.data != null);
    try testing.expectEqual(@as(i32, 5), image.width);
    try testing.expectEqual(@as(i32, 6), image.height);
    // @notice 检查 PNG 原始行而非 ImageTexture.value()，后者会翻转纹理纵坐标 v。
    for (0..6) |row| {
        for (0..5) |column| {
            const offset = (row * 5 + column) * 3;
            const expected: [3]u8 = if (row < 3) .{ 255, 0, 0 } else .{ 0, 0, 255 };
            try testing.expectEqualSlices(u8, &expected, image.data.?[offset..][0..3]);
        }
    }
}

const RngProbe = struct {
    seed: u64,
    samples: [256]f64 = undefined,

    fn run(self: *RngProbe) void {
        random.seed(self.seed);
        for (&self.samples) |*sample| sample.* = random.randomDouble();
    }
};

test "native workers have isolated random states" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    random.seed(1234);
    var expected_caller = std.Random.DefaultPrng.init(1234);
    try testing.expectEqual(expected_caller.random().float(f64), random.randomDouble());
    var probes = [_]RngProbe{ .{ .seed = 17 }, .{ .seed = 42 }, .{ .seed = 99 }, .{ .seed = 123 } };
    {
        var threads: [probes.len]std.Thread = undefined;
        var started: usize = 0;
        defer for (threads[0..started]) |thread| thread.join();
        for (&probes, &threads) |*probe, *thread| {
            thread.* = try std.Thread.spawn(.{}, RngProbe.run, .{probe});
            started += 1;
        }
    }
    for (probes) |probe| {
        var expected = std.Random.DefaultPrng.init(probe.seed);
        for (probe.samples) |sample| try testing.expectEqual(expected.random().float(f64), sample);
    }
    try testing.expectEqual(expected_caller.random().float(f64), random.randomDouble());
}

fn renderAndFree(alloc: std.mem.Allocator, params: render.RenderParams, world: *object.BvhNode) !void {
    const pixels = try render.renderPixels(alloc, params, world, null);
    defer alloc.free(pixels);
}

test "parallel render frees allocations on failure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scene = try parallelTestScene(arena.allocator());
    var params = parallelTestParams();
    params.thread_count = 2;
    try testing.checkAllAllocationFailures(testing.allocator, renderAndFree, .{ params, scene.bvh });
}

test "render rejects unsafe dimensions and scheduling parameters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scene = try parallelTestScene(arena.allocator());
    const valid = parallelTestParams();
    inline for (.{ "image_width", "image_height", "samples_per_pixel", "rows_per_task" }) |field| {
        var params = valid;
        @field(params, field) = 0;
        try testing.expectError(error.InvalidRenderParams, render.renderPixels(testing.allocator, params, scene.bvh, null));
    }
    var params = valid;
    params.channel = 4;
    try testing.expectError(error.InvalidRenderParams, render.renderPixels(testing.allocator, params, scene.bvh, null));
    params = valid;
    for ([_]f64{ 0, 1, -1, std.math.nan(f64), std.math.inf(f64) }) |rr| {
        params.rr = rr;
        try testing.expectError(error.InvalidRenderParams, render.renderPixels(testing.allocator, params, scene.bvh, null));
    }
}

test "thread command line options validate input" {
    const Options = @import("main.zig").Options;
    try testing.expectEqual(@as(usize, 0), (try Options.parse(&.{})).thread_count);
    try testing.expectEqual(@as(usize, 8), (try Options.parse(&.{ "--threads", "8" })).thread_count);
    try testing.expectEqual(@as(usize, 0), (try Options.parse(&.{ "--threads", "0" })).thread_count);
    try testing.expect((try Options.parse(&.{"--help"})).help);
    try testing.expectError(error.MissingThreadCount, Options.parse(&.{"--threads"}));
    try testing.expectError(error.InvalidThreadCount, Options.parse(&.{ "--threads", "-1" }));
    try testing.expectError(error.InvalidThreadCount, Options.parse(&.{ "--threads", "abc" }));
    try testing.expectError(error.UnknownArgument, Options.parse(&.{"--unknown"}));
}

test "adaptive rendering stops constant pixels early without changing normalization" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const mat = try material.newMetal(alloc, .{ .x = 1, .y = 1, .z = 1 }, 0);
    var scene = render.Scene.init(alloc, "constant");
    try scene.addObject(try object.newSphere(alloc, .{ .z = 100 }, .{ .z = 100 }, 0, 1, 1, mat));
    try scene.buildBvh();
    var params = parallelTestParams();
    params.cam = .{ .lower_left_corner = .{ .x = -1, .y = -1, .z = -1 }, .horizontal = .{ .x = 2 }, .vertical = .{ .y = 2 } };
    params.samples_per_pixel = 128;
    params.background = .{ .x = 0.25, .y = 0.5, .z = 1 };
    var stats: render.RenderStats = .{};
    params.stats = &stats;
    params.thread_count = 4;
    const adaptive = try render.renderPixels(testing.allocator, params, scene.bvh, null);
    defer testing.allocator.free(adaptive);
    try testing.expectEqual(@as(u64, 17 * 19 * 32), stats.total_samples);
    try testing.expectEqual(@as(u64, 17 * 19), stats.early_stopped_pixels);
    params.adaptive = false;
    const fixed = try render.renderPixels(testing.allocator, params, scene.bvh, null);
    defer testing.allocator.free(fixed);
    try testing.expectEqual(@as(u64, 17 * 19 * 128), stats.total_samples);
    try testing.expectEqual(@as(u64, 0), stats.early_stopped_pixels);
    try testing.expectEqualSlices(u8, fixed, adaptive);
    params.adaptive = true;
    params.min_samples = 256;
    params.samples_per_pixel = 35; // @notice 样本预算不必恰好覆盖完整副本块。
    const capped = try render.renderPixels(testing.allocator, params, scene.bvh, null);
    defer testing.allocator.free(capped);
    try testing.expectEqual(@as(u64, 17 * 19 * 35), stats.total_samples);
    try testing.expectEqual(@as(u64, 0), stats.early_stopped_pixels);
    try testing.expectEqualSlices(u8, fixed, capped);
}

test "adaptive samples and pixels are independent of thread scheduling" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scene = try parallelTestScene(arena.allocator());
    var params = parallelTestParams();
    params.samples_per_pixel = 96;
    params.absolute_error = 0.1;
    params.relative_error = 0.1;
    var stats: render.RenderStats = .{};
    params.stats = &stats;
    for ([_]@import("sampling.zig").Sampler{ .sobol, .random }) |mode| {
        params.sampler = mode;
        params.thread_count = 1;
        params.rows_per_task = 8;
        const reference = try render.renderPixels(testing.allocator, params, scene.bvh, null);
        defer testing.allocator.free(reference);
        const reference_stats = stats;
        params.thread_count = 4;
        params.rows_per_task = 3;
        const parallel = try render.renderPixels(testing.allocator, params, scene.bvh, null);
        defer testing.allocator.free(parallel);
        try testing.expectEqualSlices(u8, reference, parallel);
        try testing.expectEqualDeep(reference_stats, stats);
    }
}

test "sampling options reject invalid values and keep the configured large default" {
    const Options = @import("main.zig").Options;
    try testing.expectEqual(@as(i32, 8640), (try Options.parse(&.{})).image_width);
    const options = try Options.parse(&.{ "--width", "320", "--samples", "64", "--sampler", "random", "--no-adaptive", "--rr-depth", "7", "--output", "test.png" });
    try testing.expectEqual(@as(i32, 320), options.image_width);
    try testing.expectEqual(@as(i32, 64), options.samples);
    try testing.expectEqual(@as(i32, 7), options.min_bounce);
    try testing.expect(!options.adaptive);
    try testing.expectEqual(@import("sampling.zig").Sampler.random, options.sampler);
    try testing.expectError(error.InvalidSampler, Options.parse(&.{ "--sampler", "invalid" }));
    try testing.expectError(error.InvalidTolerance, Options.parse(&.{ "--relative-error", "nan" }));
    try testing.expectError(error.InvalidTolerance, Options.parse(&.{ "--absolute-error", "-0.1" }));
    try testing.expectError(error.InvalidSamples, Options.parse(&.{ "--min-samples", "0" }));
    try testing.expectError(error.InvalidSamples, Options.parse(&.{ "--samples", "0" }));
    try testing.expectError(error.InvalidWidth, Options.parse(&.{ "--width", "0" }));
    try testing.expectError(error.MissingOptionValue, Options.parse(&.{"--width"}));
}
