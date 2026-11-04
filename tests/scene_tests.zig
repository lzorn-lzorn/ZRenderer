const std = @import("std");
const scene = @import("zrenderer").scene;
const main = @import("zrenderer").main;
const math = @import("zrenderer").math;
const object = @import("zrenderer").object;
const color = @import("zrenderer").color;
const testing = std.testing;

// @brief 验证实际 PBR 类型、光源注册和可复现的几何，而非仅测试构造函数。
test "scene includes deterministic PBR water jade silk and area emitter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try scene.loadRandomScene(a, .{});
    const second = try scene.loadRandomScene(a, .{});
    try testing.expect(first.light != null);
    try testing.expect(first.world.list.items[first.world.list.items.len - 1] == first.light.?);
    try testing.expectEqual(first.world.list.items.len, second.world.list.items.len);
    var water: usize = 0;
    var jade: usize = 0;
    var pbr: usize = 0;
    var silk: usize = 0;
    for (first.world.list.items, second.world.list.items) |lhs, rhs| {
        try testing.expectEqual(std.meta.activeTag(lhs.*), std.meta.activeTag(rhs.*));
        if (lhs.* == .wavy_sphere) {
            water += 1;
            try testing.expectEqual(lhs.wavy_sphere.center, rhs.wavy_sphere.center);
            try expectWater(lhs);
        }
        if (lhs.* == .sphere) {
            try testing.expectEqual(lhs.sphere.center(0), rhs.sphere.center(0));
            try testing.expectEqual(lhs.sphere.center(1), rhs.sphere.center(1));
            switch (lhs.sphere.material.*) {
                .dielectric => |m| try testing.expect(m.ir != 1.333),
                .subsurface => {
                    jade += 1;
                    try expectJade(lhs);
                },
                .translucent => return error.SceneUsesThinTranslucentJade,
                .pbr => pbr += 1,
                .silk => {
                    silk += 1;
                    try expectSilk(lhs);
                },
                else => {},
            }
        }
    }
    try testing.expect(water >= 2 and jade >= 2 and pbr > 100);
    try testing.expect(silk >= 1);
    var rec: object.HitRecord = .{};
    try testing.expect(first.bvh.hit(math.Ray.init(.{ .x = 3, .y = 0.9 }, .{ .x = -1 }, 0), 0, math.infinity, &rec));
}

// @brief 验证实际几何标签、波场参数及普通介电界面，不接受仅改法线的光滑球。
fn expectWater(obj: *object.Object) !void {
    try testing.expect(obj.* == .wavy_sphere);
    const w = obj.wavy_sphere;
    try testing.expectEqual(@as(f64, 0.045), w.amplitude);
    try testing.expectEqual(@as(f64, 14), w.frequency);
    try testing.expect(w.material.* == .dielectric);
    try testing.expectEqual(@as(f64, 1.333), w.material.dielectric.ir);
    const outer = w.radius * (1 + w.amplitude + 64 * std.math.floatEps(f64));
    try testing.expect(w.center.y >= outer);
}

// @brief 玉石必须有封闭球体及均匀吸收/散射介质，而非兼容用薄层透射材质。
fn expectJade(obj: *object.Object) !void {
    try testing.expect(obj.* == .sphere);
    try testing.expect(obj.sphere.material.* == .subsurface);
    const jade = obj.sphere.material.subsurface;
    try testing.expectEqual(@as(f64, 1.54), jade.ior);
    try testing.expectEqual(math.Color.init(0.65, 0.10, 0.32), jade.medium.sigma_a);
    try testing.expectEqual(@as(f64, 4), jade.medium.sigma_s);
    try testing.expectEqual(@as(f64, 0.35), jade.medium.g);
}

// @brief 丝绸必须有各向异性布料材质及固定的美术参数，而非复用普通 PBR 或毛发。
fn expectSilk(obj: *object.Object) !void {
    try testing.expect(obj.* == .sphere);
    try testing.expect(obj.sphere.material.* == .silk);
    const silk = obj.sphere.material.silk;
    try testing.expectEqual(math.Color.init(0.92, 0.88, 0.80), silk.base_color);
    try testing.expectEqual(@as(f64, 0.25), silk.roughness);
    try testing.expectEqual(@as(f64, 0.75), silk.anisotropy);
    try testing.expectEqual(@as(f64, 1.5), silk.ior);
}

// @brief 用独立的水平投影距离检查保守分离；运动球整个扫掠均包含在检查内。
fn expectSeparated(objects: []const *object.Object) !void {
    for (objects) |hero| {
        const is_water = hero.* == .wavy_sphere;
        const is_jade = hero.* == .sphere and hero.sphere.material.* == .subsurface;
        if (!is_water and !is_jade) continue;
        const center = if (is_water) hero.wavy_sphere.center else hero.sphere.center0;
        const radius = if (is_water) hero.wavy_sphere.radius * (1 + hero.wavy_sphere.amplitude) else hero.sphere.radius;
        for (objects) |other| {
            if (other == hero) continue;
            var p: math.Point3 = undefined;
            var q: math.Point3 = undefined;
            var r: f64 = undefined;
            switch (other.*) {
                .sphere => |s| {
                    if (s.radius == 1000) continue;
                    p = s.center0;
                    q = s.center1;
                    r = s.radius;
                },
                .wavy_sphere => |w| {
                    p = w.center;
                    q = w.center;
                    r = w.radius * (1 + w.amplitude);
                },
                else => continue,
            }
            p.y = 0;
            q.y = 0;
            const c = math.Point3.init(center.x, 0, center.z);
            const delta = q.sub(p);
            const t = if (delta.lengthSquared() > 0) math.clamp(c.sub(p).dot(delta) / delta.lengthSquared(), 0, 1) else 0;
            try testing.expect(c.sub(p.add(delta.scale(t))).length() > radius + r);
        }
    }
}

test "scene protected water and jade never overlap swept spheres" {
    for ([_]u64{ 1, 42, 2026 }) |seed| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const s = try scene.loadRandomScene(arena.allocator(), .{ .seed = seed });
        try expectSeparated(s.world.list.items);
    }
}

test "materials scene has only two physical heroes floor and registered studio panels" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try scene.loadMaterialScene(arena.allocator());
    try testing.expectEqual(@as(usize, 6), s.world.list.items.len);
    try testing.expect(s.light != null and s.light.?.* == .group);
    const lamps = s.light.?.group.list.items;
    try testing.expectEqual(@as(usize, 3), lamps.len);
    var water: usize = 0;
    var jade: usize = 0;
    var floor: usize = 0;
    for (s.world.list.items) |obj| {
        switch (obj.*) {
            .wavy_sphere => |w| {
                water += 1;
                try expectWater(obj);
                try testing.expectEqual(math.Point3.init(-1.1, 1, 0), w.center);
                try testing.expectEqual(@as(f64, 0.9), w.radius);
            },
            .sphere => |j| {
                jade += 1;
                try expectJade(obj);
                try testing.expectEqual(math.Point3.init(1.1, 1, 0), j.center0);
                try testing.expectEqual(j.center0, j.center1);
                try testing.expectEqual(@as(f64, 0.9), j.radius);
            },
            .xz_rect => |rect| {
                floor += 1;
                try testing.expectEqual(@as(f64, 0), rect.k);
                try testing.expect(rect.material.* == .lambertian);
            },
            else => try testing.expect(std.mem.indexOfScalar(*object.Object, lamps, obj) != null),
        }
    }
    try testing.expectEqual(@as(usize, 1), water);
    try testing.expectEqual(@as(usize, 1), jade);
    try testing.expectEqual(@as(usize, 1), floor);
    try expectSeparated(s.world.list.items);
    for (lamps) |lamp| {
        try testing.expect(std.mem.indexOfScalar(*object.Object, s.world.list.items, lamp) != null);
        var bounds: math.Aabb = .{};
        try testing.expect(lamp.boundingBox(0, 1, &bounds));
        const origin = math.Point3.init(1.1, 1, 0);
        const direction = bounds.min.add(bounds.max).scale(0.5).sub(origin);
        const ray = math.Ray.init(origin, direction, 0);
        var hit: object.HitRecord = .{};
        try testing.expect(lamp.hit(ray, 0.001, math.infinity, &hit));
        try testing.expect(hit.front_face);
        try testing.expect(s.light.?.pdfValue(origin, direction) > 0);
    }
    // @notice 双球之间的视线看到暗环境，不允许发光背景板占满相机后景。
    var rec: object.HitRecord = .{};
    try testing.expect(!s.bvh.hit(math.Ray.init(.{ .y = 1, .z = 7.5 }, .{ .z = -1 }, 0), 0.001, math.infinity, &rec));
}

test "scene CLI validates presets and preserves explicit camera overrides in either order" {
    const defaults = try main.Options.parse(&.{});
    try testing.expectEqual(main.SceneKind.random, defaults.scene);
    try testing.expectEqual(@as(i32, 8640), defaults.image_width);
    try testing.expectEqual(@as(f64, 13.3), defaults.focus_distance);
    try testing.expectEqual(math.Color.init(0.3, 0.4, 0.6), defaults.background());
    const studio = try main.Options.parse(&.{ "--scene", "materials" });
    try testing.expectEqual(main.SceneKind.materials, studio.scene);
    try testing.expectApproxEqAbs(@sqrt(@as(f64, 7.5 * 7.5 + 0.6 * 0.6)), studio.focus_distance, 1e-12);
    try testing.expectEqual(math.Color.init(0.008, 0.008, 0.008), studio.background());
    const args = studio.cameraArgs();
    try testing.expectEqual(math.Point3.init(0, 1.6, 7.5), args.lookfrom);
    try testing.expectEqual(math.Point3.init(0, 1, 0), args.lookat);
    const cam = try args.build();
    try testing.expectApproxEqAbs(@as(f64, 5.4), cam.horizontal.length(), 0.1);
    const before = try main.Options.parse(&.{ "--focus-distance", "4", "--scene", "materials" });
    const after = try main.Options.parse(&.{ "--scene", "materials", "--focus-distance", "6" });
    try testing.expectEqual(@as(f64, 4), before.cameraArgs().focus_distance);
    try testing.expectEqual(@as(f64, 6), after.cameraArgs().focus_distance);
    const reset = try main.Options.parse(&.{ "--scene", "materials", "--scene", "random" });
    try testing.expectEqual(@as(f64, 13.3), reset.focus_distance);
    try testing.expectError(error.InvalidScene, main.Options.parse(&.{ "--scene", "jade" }));
    try testing.expectError(error.InvalidScene, main.Options.parse(&.{ "--scene", "Materials" }));
    try testing.expectError(error.MissingOptionValue, main.Options.parse(&.{"--scene"}));
}

test "physical camera CLI accepts values and rejects invalid input" {
    const o = try main.Options.parse(&.{ "--focal-length", "85", "--f-number", "2", "--focus-distance", "5", "--shutter", "0.01", "--iso", "200", "--exposure", "-1" });
    try testing.expectEqual(@as(f64, 85), o.focal_length_mm);
    try testing.expectEqual(@as(f64, 2), o.f_number);
    try testing.expectEqual(@as(f64, -1), o.exposure_compensation);
    try testing.expectError(error.InvalidCameraParameter, main.Options.parse(&.{ "--iso", "nan" }));
    try testing.expectError(error.InvalidCameraParameter, main.Options.parse(&.{ "--f-number", "0" }));
    try testing.expectError(error.InvalidCameraParameter, main.Options.parse(&.{ "--shutter", "-1" }));
    try testing.expectError(error.ShutterOutsideSceneInterval, main.Options.parse(&.{ "--shutter", "2" }));
    try testing.expectError(error.MissingOptionValue, main.Options.parse(&.{"--exposure"}));
}

// @brief 编码阶段必须在幂运算之前处理负值、NaN 和无穷，不能触发整数转换异常。
test "display conversion sanitizes invalid radiance before gamma" {
    var bytes: [3]u8 = undefined;
    color.writeColor(&bytes, .{ .x = -1, .y = std.math.nan(f64), .z = std.math.inf(f64) }, 1);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255 }, &bytes);
}
