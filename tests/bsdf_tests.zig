const std = @import("std");
const math = @import("zrenderer").math;
const random = @import("zrenderer").random;
const bsdf = @import("zrenderer").bsdf;
const material = @import("zrenderer").material;
const object = @import("zrenderer").object;
const texture = @import("zrenderer").texture;
const testing = std.testing;
const Vec3 = math.Vec3;
const white = Vec3.init(1, 1, 1);
const normal = Vec3.init(0, 0, 1);

fn expectColor(expected: Vec3, actual: Vec3, tolerance: f64) !void {
    for (0..3) |i| try testing.expectApproxEqAbs(expected.at(i), actual.at(i), tolerance);
}

fn direction(z: f64, phi: f64) Vec3 {
    const r = @sqrt(@max(0, 1 - z * z));
    return .{ .x = r * @cos(phi), .y = r * @sin(phi), .z = z };
}

fn checkSamples(mat: material.Material, rec: object.HitRecord, wo: Vec3) !void {
    const ray = math.Ray.init(.{}, wo.neg().scale(3.7), 0.3);
    var accepted: usize = 0;
    for (0..4096) |_| {
        if (mat.bsdfSample(ray, &rec)) |s| {
            accepted += 1;
            try testing.expect(!s.is_delta);
            try testing.expectEqual(@as(f64, 1), s.eta);
            try testing.expectApproxEqAbs(@as(f64, 1), s.direction.length(), 1e-12);
            const p = mat.bsdfPdf(ray, &rec, s.direction);
            try testing.expect(p > 0 and std.math.isFinite(p));
            try testing.expectApproxEqRel(p, s.pdf, 1e-10);
            const f = mat.bsdfEval(ray, &rec, s.direction);
            try expectColor(f.scale(@abs(rec.normal.normalized().dot(s.direction)) / p), s.weight, 1e-9);
            for (0..3) |c| try testing.expect(std.math.isFinite(s.weight.at(c)) and s.weight.at(c) >= 0);
        }
    }
    try testing.expect(accepted > 1000);
}

test "BSDF material sample eval pdf consistency in rotated world frame" {
    random.seed(71);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = Vec3.init(0.2, 0.5, 0.8);
    const mats = [_]*material.Material{
        try material.newLambertian(a, try texture.newSolid(a, c)),
        try material.newMetal(a, c, 0.7),
        try material.newPbr(a, .{ .base_color = c, .metallic = 0.3, .roughness = 0.6 }),
        try material.newPbr(a, .{ .base_color = white, .metallic = 1, .roughness = 0 }),
        try material.newTranslucent(a, c, 0.7),
    };
    const n = Vec3.init(1, 2, 3).normalized();
    var frame: math.Onb = .{};
    frame.buildFromW(n);
    for (mats) |m| {
        try testing.expect(m.hasNonDelta());
        try checkSamples(m.*, .{ .normal = n.scale(2), .front_face = true }, frame.local(direction(0.3, 0.7)));
    }
}

test "BSDF Lambertian and translucent cosine mixture preserve albedo and branch probability" {
    random.seed(991);
    const c = Vec3.init(0.15, 0.6, 0.9);
    for ([_]f64{ 0, 0.25, 0.8, 1 }) |t| {
        const surface = bsdf.Surface{ .diffuse = c, .transmission = t };
        var transmitted: usize = 0;
        const count = 16384;
        for (0..count) |_| {
            const s = surface.sample(normal, normal).?;
            try expectColor(c, s.weight, 1e-12);
            if (s.direction.z < 0) transmitted += 1;
            try testing.expectApproxEqAbs(surface.pdf(normal, normal, s.direction), s.pdf, 1e-12);
        }
        try testing.expectApproxEqAbs(t, @as(f64, @floatFromInt(transmitted)) / count, 0.015);
        try expectColor(c.scale((1 - t) / math.pi), surface.eval(normal, normal, normal), 1e-12);
        try expectColor(c.scale(t / math.pi), surface.eval(normal, normal, normal.neg()), 1e-12);
        var integral: f64 = 0;
        for (0..1024) |i| {
            const z = (@as(f64, @floatFromInt(i)) + 0.5) / 1024;
            integral += (surface.pdf(normal, normal, direction(z, 0)) + surface.pdf(normal, normal, direction(-z, 0))) * 2 * math.pi / 1024;
        }
        try testing.expectApproxEqAbs(@as(f64, 1), integral, 1e-12);
    }
}

test "BSDF reciprocity for GGX diffuse and opposite-side translucent" {
    random.seed(231);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const m = try material.newPbr(arena.allocator(), .{ .base_color = .{ .x = 0.9, .y = 0.4, .z = 0.1 }, .roughness = 0.7, .metallic = 0.2 });
    const rec = object.HitRecord{ .normal = normal };
    for (0..4096) |_| {
        const wo = direction(random.randomDouble(), 2 * math.pi * random.randomDouble());
        const wi = direction(random.randomDouble(), 2 * math.pi * random.randomDouble());
        try expectColor(m.bsdfEval(.{ .direction = wo.neg() }, &rec, wi), m.bsdfEval(.{ .direction = wi.neg() }, &rec, wo), 1e-10);
        const thin = bsdf.Surface{ .diffuse = .{ .x = 0.7, .y = 0.9 }, .transmission = 0.8 };
        try expectColor(thin.eval(wo, normal, wi.neg()), thin.eval(wi.neg(), normal.neg(), wo), 1e-12);
    }
}

test "BSDF GGX remains finite at grazing and minimum roughness" {
    for ([_]f64{ 0, 1e-12, 0.05, 0.5, 1 }) |roughness| {
        const surface = bsdf.Surface{ .specular = .{ .x = 0.04, .y = 0.7, .z = 1 }, .roughness = roughness };
        for ([_]f64{ 1e-150, 1e-12, 1e-6, 0.5, 1 }) |co| {
            const wo = direction(co, 0);
            const wi = direction(co, math.pi);
            const f = surface.eval(wo, normal, wi);
            const p = surface.pdf(wo, normal, wi);
            try testing.expect(std.math.isFinite(p) and p > 0);
            for (0..3) |c| try testing.expect(std.math.isFinite(f.at(c)) and f.at(c) >= 0);
            for (0..64) |_| if (surface.sample(wo, normal)) |s| {
                for (0..3) |c| try testing.expect(std.math.isFinite(s.weight.at(c)) and s.weight.at(c) <= 1.000001);
            };
        }
    }
}

test "BSDF white furnace bound for PBR dielectric metal and mixed lobes" {
    random.seed(8871);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rec = object.HitRecord{ .normal = normal, .front_face = true };
    for ([_]f64{ 0, 0.3, 0.7, 1 }) |roughness| {
        for ([_]f64{ 0, 0.4, 1 }) |metallic| {
            const m = try material.newPbr(arena.allocator(), .{ .base_color = white, .metallic = metallic, .roughness = roughness });
            for ([_]f64{ 0.001, 0.2, 1 }) |co| {
                const ray = math.Ray{ .direction = direction(co, 0).neg() };
                var sum: Vec3 = .{};
                const count = 16384;
                for (0..count) |_| if (m.bsdfSample(ray, &rec)) |s| {
                    sum = sum.add(s.weight);
                };
                const mean = sum.div(count);
                for (0..3) |c| try testing.expect(mean.at(c) >= 0 and mean.at(c) <= 1.025);
            }
        }
    }
    const rough_white = bsdf.Surface{ .specular = white, .roughness = 1 };
    var sum: f64 = 0;
    for (0..32768) |_| if (rough_white.sample(normal, normal)) |s| {
        sum += s.weight.x;
    };
    // @notice alpha=1 的单次散射白金属在法向处为 1-ln(2)，不是能量补偿模型。
    try testing.expectApproxEqAbs(1 - @log(@as(f64, 2)), sum / 32768, 0.012);
}

test "BSDF VNDF empirical bins and density normalization include null events" {
    random.seed(69123);
    const Cases = struct { roughness: f64, cosine: f64, diffuse: Vec3 = .{} };
    for ([_]Cases{
        .{ .roughness = 1, .cosine = 1 },
        .{ .roughness = 1, .cosine = 0.1 },
        .{ .roughness = 0.65, .cosine = 0.4 },
        .{ .roughness = 0.8, .cosine = 0.3, .diffuse = white },
    }) |case| {
        const surface = bsdf.Surface{ .specular = white, .diffuse = case.diffuse, .roughness = case.roughness };
        const wo = direction(case.cosine, 0);
        var expected: [32]f64 = @splat(0);
        var observed: [32]usize = @splat(0);
        var nulls: usize = 0;
        const count = 65536;
        for (0..count) |_| {
            if (surface.sample(wo, normal)) |s| {
                const z_bin: usize = @min(3, @as(usize, @intFromFloat(s.direction.z * 4)));
                var phi = std.math.atan2(s.direction.y, s.direction.x);
                if (phi < 0) phi += 2 * math.pi;
                const phi_bin: usize = @min(7, @as(usize, @intFromFloat(phi * 8 / (2 * math.pi))));
                observed[z_bin * 8 + phi_bin] += 1;
            } else nulls += 1;
        }
        for (0..128) |zi| {
            for (0..256) |pi| {
                const z = (@as(f64, @floatFromInt(zi)) + 0.5) / 128;
                const phi = (@as(f64, @floatFromInt(pi)) + 0.5) * 2 * math.pi / 256;
                expected[(zi / 32) * 8 + pi / 32] += surface.pdf(wo, normal, direction(z, phi)) * 2 * math.pi / (128 * 256);
            }
        }
        var mass: f64 = 0;
        for (expected, observed) |p, n| {
            mass += p;
            try testing.expectApproxEqAbs(p, @as(f64, @floatFromInt(n)) / count, 0.007);
        }
        try testing.expect(nulls > 0);
        try testing.expectApproxEqAbs(@as(f64, 1), mass + @as(f64, @floatFromInt(nulls)) / count, 0.012);
        if (case.roughness == 1 and case.cosine == 1) try testing.expectApproxEqAbs(@as(f64, 0.5), mass, 1e-12);
    }
}

test "BSDF delta mirror retains analytical constant albedo" {
    var metal = material.Metal{ .albedo = .{ .x = 0.2, .y = 0.6, .z = 0.9 }, .fuzz = 0 };
    const m = material.Material{ .metal = &metal };
    const rec = object.HitRecord{ .normal = normal };
    try testing.expect(!m.hasNonDelta());
    for ([_]f64{ 1e-9, 0.2, 1 }) |co| {
        const ray = math.Ray{ .direction = direction(co, 0).neg() };
        const s = m.bsdfSample(ray, &rec).?;
        try testing.expect(s.is_delta);
        try expectColor(metal.albedo, s.weight, 0);
        try expectColor(math.reflect(ray.direction, normal), s.direction, 1e-12);
        try testing.expectEqual(@as(f64, 1), s.pdf);
        try testing.expectEqual(@as(f64, 1), s.eta);
        try testing.expectEqual(@as(f64, 0), m.bsdfPdf(ray, &rec, s.direction));
        try expectColor(.{}, m.bsdfEval(ray, &rec, s.direction), 0);
    }
}

test "BSDF dielectric exact Fresnel water radiance eta and total internal reflection" {
    random.seed(429);
    try testing.expectApproxEqAbs(@as(f64, 0.04), bsdf.fresnelDielectric(1, 1.0 / 1.5), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.08918671280221276), bsdf.fresnelDielectric(0.5, 1.0 / 1.5), 1e-12);
    var glass = material.Dielectric{ .ir = 1.333 };
    const m = material.Material{ .dielectric = &glass };
    const ray = math.Ray{ .direction = normal.neg() };
    const rec = object.HitRecord{ .normal = normal, .front_face = true };
    const eta = 1 / glass.ir;
    const f = bsdf.fresnelDielectric(1, eta);
    var reflection: usize = 0;
    const count = 32768;
    var sum: f64 = 0;
    for (0..count) |_| {
        const s = m.bsdfSample(ray, &rec).?;
        try testing.expect(s.is_delta);
        try testing.expectApproxEqAbs(@as(f64, 1), s.direction.length(), 1e-12);
        sum += s.weight.x;
        if (s.direction.z > 0) {
            reflection += 1;
            try testing.expectEqual(@as(f64, 1), s.eta);
            try expectColor(white, s.weight, 0);
            try testing.expectApproxEqAbs(f, s.pdf, 1e-12);
        } else {
            try testing.expectApproxEqAbs(eta, s.eta, 1e-12);
            try expectColor(white.scale(eta * eta), s.weight, 1e-12);
            try testing.expectApproxEqAbs(1 - f, s.pdf, 1e-12);
        }
    }
    try testing.expectApproxEqAbs(f, @as(f64, @floatFromInt(reflection)) / count, 0.004);
    try testing.expectApproxEqAbs(f + (1 - f) * eta * eta, sum / count, 0.004);
    for (0..1024) |_| {
        const s = bsdf.sampleDielectric(direction(0.2, 0), normal, 1.333, false).?;
        try testing.expectEqual(@as(f64, 1), s.pdf);
        try testing.expectEqual(@as(f64, 1), s.eta);
        try expectColor(white, s.weight, 0);
        try testing.expect(s.direction.z > 0);
    }
    var exits: usize = 0;
    for (0..1024) |_| {
        const s = bsdf.sampleDielectric(direction(0.9, 0), normal, 1.333, false).?;
        if (s.direction.z < 0) {
            exits += 1;
            try testing.expectApproxEqAbs(@as(f64, 1.333), s.eta, 1e-12);
            try expectColor(white.scale(1.333 * 1.333), s.weight, 1e-12);
            try testing.expectApproxEqAbs(1.333 * @sqrt(1 - 0.9 * 0.9), @sqrt(s.direction.x * s.direction.x + s.direction.y * s.direction.y), 1e-12);
        }
    }
    try testing.expect(exits > 900);
    const unchanged = bsdf.sampleDielectric(direction(1e-8, 0), normal, 1, true).?;
    try testing.expectEqual(@as(f64, 1), unchanged.pdf);
    try expectColor(white, unchanged.weight, 0);
    try testing.expect(!m.hasNonDelta());
    try testing.expectEqual(@as(f64, 0), m.bsdfPdf(ray, &rec, normal));
}

test "BSDF rejects invalid parameters and degenerate directions without silent NaN clamping" {
    const a = testing.allocator;
    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64), -0.1, 1.1 }) |bad| {
        try testing.expectError(error.InvalidParameter, material.newMetal(a, white, bad));
        try testing.expectError(error.InvalidParameter, material.newMetal(a, .{ .x = bad }, 0));
        try testing.expectError(error.InvalidParameter, material.newPbr(a, .{ .base_color = white, .metallic = bad, .roughness = 0.5 }));
        try testing.expectError(error.InvalidParameter, material.newPbr(a, .{ .base_color = white, .metallic = 0, .roughness = bad }));
        try testing.expectError(error.InvalidParameter, material.newPbr(a, .{ .base_color = .{ .z = bad }, .metallic = 0, .roughness = 0.5 }));
        try testing.expectError(error.InvalidParameter, material.newTranslucent(a, white, bad));
        try testing.expectError(error.InvalidParameter, material.newTranslucent(a, .{ .y = bad }, 0));
        try testing.expectError(error.InvalidParameter, material.newIsotropic(a, .{ .x = bad }));
        var solid = texture.SolidColor{ .color_value = .{ .x = bad } };
        var tex = texture.Texture{ .solid = &solid };
        try testing.expectError(error.InvalidParameter, material.newLambertian(a, &tex));
    }
    for ([_]f64{ 0, -1, 1e-9, 1e9, std.math.nan(f64), std.math.inf(f64) }) |bad| {
        try testing.expectError(error.InvalidParameter, material.newDielectric(a, bad));
        try testing.expectError(error.InvalidParameter, material.newPbr(a, .{ .base_color = white, .roughness = 0.5, .metallic = 0, .ior = bad }));
    }
    const surface = bsdf.Surface{ .diffuse = white };
    for ([_]Vec3{ .{}, .{ .z = std.math.nan(f64) }, .{ .x = std.math.inf(f64) }, normal.neg() }) |bad| {
        try testing.expect(surface.sample(bad, normal) == null);
        try expectColor(.{}, surface.eval(bad, normal, normal), 0);
        try testing.expectEqual(@as(f64, 0), surface.pdf(bad, normal, normal));
    }
    try testing.expect(surface.sample(normal, .{}) == null);
    try testing.expect(bsdf.unit(.{ .x = 1e308, .z = 1e308 }) != null);
    try testing.expect(bsdf.unit(.{ .z = 1e-308 }) != null);
}

test "BSDF light and isotropic are explicitly unsupported and legacy interfaces remain callable" {
    var solid = texture.SolidColor{ .color_value = white };
    var tex = texture.Texture{ .solid = &solid };
    var light = material.DiffuseLight{ .emit = &tex };
    var phase = material.Isotropic{ .albedo = &tex };
    const rec = object.HitRecord{ .normal = normal, .front_face = true };
    const ray = math.Ray{ .direction = normal.neg() };
    for ([_]material.Material{ .{ .diffuse_light = &light }, .{ .isotropic = &phase } }) |m| {
        try testing.expect(!m.hasNonDelta());
        try testing.expect(m.bsdfSample(ray, &rec) == null);
        try expectColor(.{}, m.bsdfEval(ray, &rec, normal), 0);
        try testing.expectEqual(@as(f64, 0), m.bsdfPdf(ray, &rec, normal));
    }
    var lambert = material.Lambertian{ .albedo = &tex };
    var metal = material.Metal{ .albedo = white, .fuzz = 0 };
    var glass = material.Dielectric{ .ir = 1.5 };
    var pbr = material.Pbr{ .base_color = white, .metallic = 0, .roughness = 0.5 };
    var thin = material.Translucent{ .color = white, .transmission = 0.5 };
    for ([_]material.Material{ .{ .lambertian = &lambert }, .{ .metal = &metal }, .{ .dielectric = &glass }, .{ .isotropic = &phase }, .{ .diffuse_light = &light }, .{ .pbr = &pbr }, .{ .translucent = &thin } }) |m| {
        var attenuation: Vec3 = .{};
        var scattered: math.Ray = .{};
        var srec: material.ScatterRecord = .{};
        var density: f64 = 0;
        _ = m.scatter(ray, &rec, &attenuation, &scattered);
        _ = m.scatterPdf(ray, &rec, &attenuation, &scattered, &density);
        _ = m.scatterSrec(ray, &rec, &srec);
        _ = m.scatteringPdf(ray, &rec, scattered);
        _ = m.emitted3(0, 0, .{});
        _ = m.emitted5(ray, &rec, 0, 0, .{});
    }
}

fn allocateAndFree(a: std.mem.Allocator) !void {
    const pbr = try material.newPbr(a, .{ .base_color = white, .metallic = 0.3, .roughness = 0.5 });
    defer a.destroy(pbr);
    defer a.destroy(pbr.pbr);
    const thin = try material.newTranslucent(a, white, 0.7);
    defer a.destroy(thin);
    defer a.destroy(thin.translucent);
    const metal = try material.newMetal(a, white, 0.5);
    defer a.destroy(metal);
    defer a.destroy(metal.metal);
    const glass = try material.newDielectric(a, 1.333);
    defer a.destroy(glass);
    defer a.destroy(glass.dielectric);
    var solid = texture.SolidColor{ .color_value = white };
    var tex = texture.Texture{ .solid = &solid };
    const lambert = try material.newLambertian(a, &tex);
    defer a.destroy(lambert);
    defer a.destroy(lambert.lambertian);
    const phase = try material.newIsotropic(a, white);
    defer a.destroy(phase);
    defer a.destroy(phase.isotropic);
    defer a.destroy(phase.isotropic.albedo);
    defer a.destroy(phase.isotropic.albedo.solid);
}

test "BSDF constructors clean up every partial allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, allocateAndFree, .{});
}

test "BSDF direct Surface construction rejects invalid and incompatible parameters" {
    for ([_]bsdf.Surface{
        .{ .diffuse = .{ .x = std.math.nan(f64) } },
        .{ .diffuse = .{ .y = 1.01 } },
        .{ .specular = .{ .z = -0.01 } },
        .{ .specular = .{ .x = std.math.inf(f64) } },
        .{ .roughness = std.math.nan(f64) },
        .{ .roughness = -0.1 },
        .{ .roughness = 1.1 },
        .{ .transmission = std.math.nan(f64) },
        .{ .transmission = -0.1 },
        .{ .transmission = 1.1 },
        .{ .specular = white, .diffuse = white, .transmission = 0.5 },
    }) |surface| {
        try testing.expect(surface.sample(normal, normal) == null);
        for ([_]Vec3{ normal, normal.neg() }) |wi| {
            try expectColor(.{}, surface.eval(normal, normal, wi), 0);
            try testing.expectEqual(@as(f64, 0), surface.pdf(normal, normal, wi));
        }
    }
}

test "BSDF high IOR near-normal refraction retains small incident tangent" {
    random.seed(513);
    // @notice c 舍入为 1，但 eta*sin(theta)=0.01 不可丢失；只由 1-c² 求折射角会破坏 Snell。
    const wo = Vec3.init(1e-8, 0, 1);
    const ior: f64 = 1e6;
    const expected_x: f64 = -0.01;
    const expected_z = -@sqrt(1 - expected_x * expected_x);
    var transmitted: usize = 0;
    for (0..2_000_000) |_| {
        const s = bsdf.sampleDielectric(wo, normal, ior, false).?;
        if (s.direction.z < 0) {
            transmitted += 1;
            try expectColor(.{ .x = expected_x, .z = expected_z }, s.direction, 1e-12);
            try testing.expectEqual(ior, s.eta);
            try expectColor(white.scale(ior * ior), s.weight, 0);
            if (transmitted == 3) break;
        }
    }
    try testing.expect(transmitted == 3);
}

test "BSDF analytical GGX full mixture value and VNDF Jacobian" {
    const f0 = Vec3.init(0.02, 0.4, 0.9);
    const rho = Vec3.init(0.8, 0.3, 0.1);
    for ([_]f64{ 0, 0.1, 0.6, 1 }) |roughness| {
        const alpha = @max(0.001, roughness * roughness);
        for ([_]f64{ 1e-7, 0.2, 1 }) |c| {
            // @notice 对称方向使 h=n，D=1/(pi*alpha²)，独立检查 1/4 雅可比与完整双瓣。
            const wo = direction(c, 0);
            const wi = Vec3.init(-wo.x, 0, c);
            const g_over_c = 2 / (c + @sqrt(c * c + alpha * alpha * (1 - c * c)));
            const d = 1 / (math.pi * alpha * alpha);
            const f = f0.add(white.sub(f0).scale(std.math.pow(f64, 1 - c, 5)));
            const q = @sin(std.math.asin(c) / 2);
            const budget = white.sub(f0).scale(1 - std.math.pow(f64, 1 - q, 5));
            const fs = f.scale(d * g_over_c * g_over_c / 4);
            const fd = rho.mul(budget).mul(budget).div(math.pi);
            const pure = bsdf.Surface{ .specular = f0, .roughness = roughness };
            const mixed = bsdf.Surface{ .diffuse = rho, .specular = f0, .roughness = roughness };
            for (0..3) |channel| {
                try testing.expectApproxEqRel(fs.at(channel), pure.eval(wo, normal, wi).at(channel), 1e-11);
                try testing.expectApproxEqRel(fs.add(fd).at(channel), mixed.eval(wo, normal, wi).at(channel), 1e-11);
            }
            try testing.expectApproxEqRel(d * g_over_c / 4, pure.pdf(wo, normal, wi), 1e-12);
            try testing.expectApproxEqRel(0.5 * (d * g_over_c / 4 + c / math.pi), mixed.pdf(wo, normal, wi), 1e-12);
        }
    }
}

test "BSDF normal-incidence VNDF accepted probability has closed form" {
    random.seed(43210);
    for ([_]f64{ 0, 0.1, 0.5, 0.8, 1 }) |roughness| {
        for ([_]bool{ false, true }) |mixed| {
            const surface = bsdf.Surface{ .specular = white, .diffuse = if (mixed) white else .{}, .roughness = roughness };
            const alpha = @max(0.001, roughness * roughness);
            // @method 法向 VNDF=D*h_z；有效反射要求 h_z>1/sqrt(2)，积分给 A_s=1/(1+alpha²)。
            const p = if (mixed) 0.5 else @as(f64, 1);
            const accepted_probability = 1 - p + p / (1 + alpha * alpha);
            const count = 32768;
            var accepted: usize = 0;
            for (0..count) |_| {
                if (surface.sample(normal, normal) != null) accepted += 1;
            }
            const tolerance = 6 * @sqrt(accepted_probability * (1 - accepted_probability) / count) + @as(f64, 1) / count;
            try testing.expectApproxEqAbs(accepted_probability, @as(f64, @floatFromInt(accepted)) / count, tolerance);
        }
    }
}

test "BSDF quadrature independently bounds each reciprocal diffuse and specular energy budget" {
    random.seed(1717);
    for ([_]Vec3{ .{ .x = 0, .y = 0.04, .z = 1 }, .{ .x = 0.9, .y = 0.5, .z = 0.01 } }) |f0| {
        for ([_]f64{ 0.5, 0.8, 1 }) |roughness| {
            for ([_]f64{ 0.05, 0.4, 1 }) |c| {
                const wo = direction(c, 0);
                const surface = bsdf.Surface{ .diffuse = white, .specular = f0, .roughness = roughness };
                const specular = bsdf.Surface{ .specular = f0, .roughness = roughness };
                const q = @sin(std.math.asin(c) / 2);
                const bound = f0.add(white.sub(f0).scale(std.math.pow(f64, 1 - q, 5)));
                var total: Vec3 = .{};
                var rs: Vec3 = .{};
                for (0..128) |zi| {
                    const z = (@as(f64, @floatFromInt(zi)) + 0.5) / 128;
                    for (0..256) |pi| {
                        const phi = (@as(f64, @floatFromInt(pi)) + 0.5) * 2 * math.pi / 256;
                        const wi = direction(z, phi);
                        const measure = z * 2 * math.pi / (128 * 256);
                        total = total.add(surface.eval(wo, normal, wi).scale(measure));
                        rs = rs.add(specular.eval(wo, normal, wi).scale(measure));
                    }
                }
                const rd = total.sub(rs);
                for (0..3) |channel| {
                    try testing.expect(rs.at(channel) >= 0 and rs.at(channel) <= bound.at(channel) + 0.002);
                    try testing.expect(rd.at(channel) >= -1e-12 and rd.at(channel) <= 1 - bound.at(channel) + 0.0001);
                    try testing.expect(total.at(channel) <= 1.002);
                }
                // @notice 另用独立方向求积核对采样估计，避免只验证使用同一 eval/pdf 的自洽恒等式。
                var sampled: Vec3 = .{};
                for (0..16384) |_| if (surface.sample(wo, normal)) |s| {
                    sampled = sampled.add(s.weight);
                };
                try expectColor(total, sampled.div(16384), 0.025);
            }
        }
    }
}

test "BSDF dielectric reversed refraction preserves Fresnel Snell and reciprocal radiance factors" {
    random.seed(764);
    for ([_]f64{ 1, 1.333, 1.5, 2.4 }) |ior| {
        for ([_]f64{ 0.01, 0.5, 1 }) |c| {
            const wo = direction(c, 0.3);
            var forward: ?bsdf.Sample = null;
            for (0..2048) |_| {
                const s = bsdf.sampleDielectric(wo, normal, ior, true).?;
                if (s.direction.z < 0) {
                    forward = s;
                    break;
                }
            }
            try testing.expect(forward != null);
            const entered = forward.?;
            var backward: ?bsdf.Sample = null;
            for (0..2048) |_| {
                const s = bsdf.sampleDielectric(entered.direction, normal.neg(), ior, false).?;
                if (s.direction.z > 0) {
                    backward = s;
                    break;
                }
            }
            try testing.expect(backward != null);
            const exited = backward.?;
            try expectColor(wo, exited.direction, 1e-11);
            try testing.expectApproxEqAbs(entered.pdf, exited.pdf, 1e-11);
            try testing.expectApproxEqAbs(@as(f64, 1), entered.eta * exited.eta, 1e-12);
            try expectColor(white, entered.weight.mul(exited.weight), 1e-12);
        }
    }
    const critical_cosine = @sqrt(1 - @as(f64, 1) / (1.5 * 1.5));
    try testing.expectEqual(@as(f64, 1), bsdf.fresnelDielectric(critical_cosine - 1e-8, 1.5));
    try testing.expect(bsdf.fresnelDielectric(critical_cosine + 1e-8, 1.5) < 1);
}

test "BSDF invalid directions and mutated material parameters fail closed" {
    const surface = bsdf.Surface{ .diffuse = white, .specular = white };
    for ([_]Vec3{ .{}, .{ .y = std.math.nan(f64) }, .{ .x = std.math.inf(f64) } }) |bad| {
        try expectColor(.{}, surface.eval(normal, normal, bad), 0);
        try testing.expectEqual(@as(f64, 0), surface.pdf(normal, normal, bad));
        try expectColor(.{}, surface.eval(normal, bad, normal), 0);
        try testing.expectEqual(@as(f64, 0), surface.pdf(normal, bad, normal));
        try testing.expect(surface.sample(normal, bad) == null);
        try testing.expect(bsdf.sampleDielectric(bad, normal, 1.5, true) == null);
        try testing.expect(bsdf.sampleDielectric(normal, bad, 1.5, true) == null);
    }
    try testing.expect(surface.sample(.{ .x = 1 }, normal) == null);
    try testing.expect(bsdf.sampleDielectric(normal, normal, 0, true) == null);
    try testing.expect(bsdf.sampleDielectric(normal.neg(), normal, 1.5, true) == null);
    var solid = texture.SolidColor{ .color_value = .{ .x = std.math.nan(f64) } };
    var tex = texture.Texture{ .solid = &solid };
    var lambert = material.Lambertian{ .albedo = &tex };
    var pbr = material.Pbr{ .base_color = white, .metallic = 0, .roughness = std.math.nan(f64) };
    var thin = material.Translucent{ .color = white, .transmission = 1.1 };
    var metal = material.Metal{ .albedo = white, .fuzz = std.math.nan(f64) };
    var mirror = material.Metal{ .albedo = .{ .x = 2 }, .fuzz = 0 };
    var glass = material.Dielectric{ .ir = std.math.inf(f64) };
    const ray = math.Ray{ .direction = normal.neg() };
    const rec = object.HitRecord{ .normal = normal, .front_face = true };
    for ([_]material.Material{ .{ .lambertian = &lambert }, .{ .pbr = &pbr }, .{ .translucent = &thin }, .{ .metal = &metal }, .{ .metal = &mirror }, .{ .dielectric = &glass } }) |m| {
        try expectColor(.{}, m.bsdfEval(ray, &rec, normal), 0);
        try testing.expectEqual(@as(f64, 0), m.bsdfPdf(ray, &rec, normal));
        try testing.expect(m.bsdfSample(ray, &rec) == null);
    }
}
