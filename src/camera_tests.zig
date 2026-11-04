const std = @import("std");
const camera = @import("camera.zig");
const math = @import("math.zig");
const random = @import("random.zig");
const testing = std.testing;
const Args = camera.PhysicalCameraArgs;
const Vec3 = math.Vec3;

// @brief 按分量比较几何量，误差使用世界单位米。
fn expectVector(expected: Vec3, actual: Vec3, tolerance: f64) !void {
    try testing.expectApproxEqAbs(expected.x, actual.x, tolerance);
    try testing.expectApproxEqAbs(expected.y, actual.y, tolerance);
    try testing.expectApproxEqAbs(expected.z, actual.z, tolerance);
}

// @brief 将光线与相机轴向对焦平面求交，不假设光线方向长度。
fn intersectFocus(cam: camera.Camera, ray: math.Ray) Vec3 {
    const center = cam.origin.sub(cam.w.scale(cam.focus_distance));
    const distance = center.sub(ray.origin).dot(cam.w) / ray.direction.dot(cam.w);
    return ray.at(distance);
}

test "physical defaults are valid and reference exposure is exactly one" {
    const args: Args = .{};
    const cam = try args.build();
    try testing.expectEqual(@as(f64, 36), args.sensor_width_mm);
    try testing.expectEqual(@as(f64, 20.25), args.sensor_height_mm);
    try testing.expectEqual(@as(f64, 50), args.focal_length_mm);
    try testing.expectEqual(@as(f64, 8), args.f_number);
    try testing.expectEqual(@as(f64, 10), args.focus_distance);
    try testing.expectApproxEqAbs(@as(f64, 16.0 / 9.0), args.aspectRatio(), 1e-15);
    try testing.expectEqual(@as(f64, 1), cam.exposure_scale);
    try testing.expect(!cam.sensor_cos4_vignetting);
    for ([_]f64{ 0, 0.5, 1 }) |s| {
        try testing.expectEqual(@as(f64, 1), cam.sampleWeight(s, 0.25));
    }
    const ray = cam.getRaySampled(0.5, 0.5, 0.5, 0.5, 0);
    try expectVector(.{}, ray.origin, 0);
    try expectVector(.{ .z = -1 }, ray.direction, 1e-15);
}

test "aperture samples converge on the same off axis focal point in a rotated camera" {
    const args: Args = .{
        .lookfrom = .{ .x = 2, .y = 3, .z = 5 },
        .lookat = .{ .x = -1, .y = 1, .z = -2 },
        .vup = .{ .x = 0.1, .y = 1, .z = 0.2 },
        .focus_distance = 7,
        .f_number = 1.4,
    };
    const cam = try args.build();
    try testing.expectApproxEqAbs(@as(f64, 0), cam.u.dot(cam.v), 1e-14);
    try testing.expectApproxEqAbs(@as(f64, 0), cam.u.dot(cam.w), 1e-14);
    try testing.expectApproxEqAbs(@as(f64, 0), cam.v.dot(cam.w), 1e-14);
    try expectVector(cam.w, cam.u.cross(cam.v), 1e-14);
    for ([_][2]f64{ .{ 0, 0 }, .{ 0.19, 0.81 }, .{ 0.5, 0.5 }, .{ 1, 1 } }) |film| {
        const target = cam.origin.sub(cam.w.scale(args.focus_distance))
            .add(cam.horizontal.scale(film[0] - 0.5))
            .add(cam.vertical.scale(film[1] - 0.5));
        for ([_][2]f64{ .{ 0.5, 0.5 }, .{ 0, 0 }, .{ 1, 0.5 }, .{ 0.2, 0.9 } }) |lens| {
            const ray = cam.getRaySampled(film[0], film[1], lens[0], lens[1], 0.4);
            try testing.expectApproxEqAbs(@as(f64, 1), ray.direction.length(), 1e-14);
            try expectVector(target, intersectFocus(cam, ray), 1e-12);
            const offset = ray.origin.sub(cam.origin);
            try testing.expect(offset.length() <= cam.lens_radius + 1e-14);
            try testing.expectApproxEqAbs(@as(f64, 0), offset.dot(cam.w), 1e-14);
        }
    }
    const center = cam.getRaySampled(0.2, 0.7, 0.5, 0.5, 0.4);
    const edge = cam.getRaySampled(0.2, 0.7, 1, 0.5, 0.4);
    try testing.expect(center.origin.sub(edge.origin).length() > 0.01);
    try testing.expect(center.direction.sub(edge.direction).length() > 0.001);
}

test "f number sets aperture radius in meters without changing focus geometry" {
    const wide = try (Args{ .f_number = 2 }).build();
    const narrow = try (Args{ .f_number = 4 }).build();
    try testing.expectApproxEqAbs(@as(f64, 0.0125), wide.lens_radius, 1e-15);
    try testing.expectApproxEqAbs(wide.lens_radius / 2, narrow.lens_radius, 1e-15);
    try expectVector(wide.horizontal, narrow.horizontal, 0);
    const edge = wide.getRaySampled(0.5, 0.5, 1, 0.5, 0.5);
    try testing.expectApproxEqAbs(wide.lens_radius, edge.origin.sub(wide.origin).length(), 1e-15);
}

test "sensor mapping follows finite conjugate lens equation and field of view" {
    // @notice 物距选为二倍焦距，使忽略像距变化的近似实现产生明显误差。
    const args: Args = .{ .focus_distance = 0.1 };
    const cam = try args.build();
    const focal = args.focal_length_mm / 1000;
    const image_distance = focal * args.focus_distance / (args.focus_distance - focal);
    const width = (args.sensor_width_mm / 1000) * args.focus_distance / image_distance;
    const height = (args.sensor_height_mm / 1000) * args.focus_distance / image_distance;
    try testing.expectApproxEqAbs(@as(f64, 0.1), image_distance, 1e-15);
    try testing.expectApproxEqAbs(width, cam.horizontal.length(), 1e-15);
    try testing.expectApproxEqAbs(height, cam.vertical.length(), 1e-15);
    try testing.expectApproxEqAbs(args.aspectRatio(), cam.horizontal.length() / cam.vertical.length(), 1e-15);
    const edge = cam.getRaySampled(1, 0.5, 0.5, 0.5, 0.5);
    const actual_fov = 2 * std.math.acos(-edge.direction.dot(cam.w));
    const expected_fov = 2 * std.math.atan((args.sensor_width_mm / 1000) / (2 * image_distance));
    try testing.expectApproxEqAbs(expected_fov, actual_fov, 1e-14);
    try expectVector(cam.lower_left_corner, intersectFocus(cam, cam.getRaySampled(0, 0, 0.5, 0.5, 0.5)), 1e-14);
}

test "physical shutter interpolation is uniform bounded and includes sample endpoints" {
    const cam = try (Args{ .shutter_open = -0.03, .shutter_close = 0.01 }).build();
    try testing.expectEqual(cam.time0, cam.getRaySampled(0.5, 0.5, 0.5, 0.5, 0).time);
    try testing.expectEqual(cam.time1, cam.getRaySampled(0.5, 0.5, 0.5, 0.5, 1).time);
    var sum: f64 = 0;
    for (0..1024) |i| {
        const shutter = (@as(f64, @floatFromInt(i)) + 0.5) / 1024;
        const ray = cam.getRaySampled(0.2, 0.9, 0.1, 0.7, shutter);
        try testing.expect(ray.time >= cam.time0 and ray.time <= cam.time1);
        try testing.expectApproxEqAbs(cam.time0 + (cam.time1 - cam.time0) * shutter, ray.time, 1e-15);
        sum += ray.time;
    }
    try testing.expectApproxEqAbs((cam.time0 + cam.time1) / 2, sum / 1024, 1e-14);
    random.seed(47);
    for (0..128) |_| {
        const ray = cam.getRay(0.3, 0.6);
        try testing.expect(ray.time >= cam.time0 and ray.time < cam.time1);
        try testing.expectApproxEqAbs(@as(f64, 1), ray.direction.length(), 1e-14);
    }
}

test "photographic exposure ratios shutter aperture ISO and signed EV" {
    const cases = [_]struct { args: Args, expected: f64 }{
        .{ .args = .{ .shutter_close = 2.0 / 125.0 }, .expected = 2 },
        .{ .args = .{ .shutter_close = 0.5 / 125.0 }, .expected = 0.5 },
        .{ .args = .{ .f_number = 4 }, .expected = 4 },
        .{ .args = .{ .f_number = 16 }, .expected = 0.25 },
        .{ .args = .{ .iso = 200 }, .expected = 2 },
        .{ .args = .{ .iso = 50 }, .expected = 0.5 },
        .{ .args = .{ .exposure_compensation = 1 }, .expected = 2 },
        .{ .args = .{ .exposure_compensation = -1 }, .expected = 0.5 },
        .{ .args = .{ .exposure_compensation = 0.5 }, .expected = @sqrt(2.0) },
        .{ .args = .{ .shutter_close = 2.0 / 125.0, .f_number = 4, .iso = 200, .exposure_compensation = -2 }, .expected = 4 },
    };
    for (cases) |case| {
        const cam = try case.args.build();
        try testing.expectApproxEqRel(case.expected, cam.exposure_scale, 1e-13);
        try testing.expectEqual(cam.exposure_scale, cam.sampleWeight(0, 0));
    }
}

test "sensor cos fourth weighting is centered symmetric and uses image distance" {
    const args: Args = .{ .focus_distance = 0.1, .sensor_cos4_vignetting = true, .exposure_compensation = 1 };
    const cam = try args.build();
    try testing.expectApproxEqAbs(cam.exposure_scale, cam.sampleWeight(0.5, 0.5), 1e-14);
    const image_distance = 0.1;
    const sx = args.sensor_width_mm / 2000;
    const sy = args.sensor_height_mm / 2000;
    const factor = 1 + (sx * sx + sy * sy) / (image_distance * image_distance);
    const corner = cam.sampleWeight(0, 0);
    try testing.expectApproxEqAbs(cam.exposure_scale / (factor * factor), corner, 1e-14);
    try testing.expect(corner < cam.sampleWeight(0, 0.5));
    try testing.expect(cam.sampleWeight(0, 0.5) < cam.sampleWeight(0.5, 0.5));
    try testing.expectApproxEqAbs(corner, cam.sampleWeight(1, 1), 1e-14);
    try testing.expectApproxEqAbs(corner, cam.sampleWeight(0, 1), 1e-14);
    var rotated_args = args;
    rotated_args.lookfrom = .{ .x = 2, .y = 3, .z = 4 };
    rotated_args.lookat = .{ .x = -2, .y = -1, .z = -3 };
    const rotated = try rotated_args.build();
    try testing.expectApproxEqAbs(corner, rotated.sampleWeight(0, 0), 1e-14);
}

test "every physical numeric parameter rejects NaN and both infinities" {
    inline for (.{
        "sensor_width_mm",
        "sensor_height_mm",
        "focal_length_mm",
        "f_number",
        "focus_distance",
        "shutter_open",
        "shutter_close",
        "iso",
        "exposure_compensation",
    }) |field| {
        for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |invalid| {
            var args: Args = .{};
            @field(args, field) = invalid;
            try testing.expectError(error.NonFiniteParameter, args.build());
        }
    }
    inline for (.{ "lookfrom", "lookat", "vup" }) |field| {
        inline for (.{ "x", "y", "z" }) |component| {
            for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |invalid| {
                var args: Args = .{};
                @field(@field(args, field), component) = invalid;
                try testing.expectError(error.NonFiniteParameter, args.build());
            }
        }
    }
}

test "nonpositive dimensions aperture ISO focus and invalid shutter order are rejected" {
    inline for (.{ "sensor_width_mm", "sensor_height_mm", "focal_length_mm", "f_number", "focus_distance", "iso" }) |field| {
        for ([_]f64{ 0, -1 }) |invalid| {
            var args: Args = .{};
            @field(args, field) = invalid;
            try testing.expectError(error.InvalidParameter, args.build());
        }
    }
    try testing.expectError(error.InvalidParameter, (Args{ .focus_distance = 0.05 }).build());
    try testing.expectError(error.InvalidParameter, (Args{ .focus_distance = 0.04 }).build());
    try testing.expectError(error.InvalidParameter, (Args{ .shutter_close = 0 }).build());
    try testing.expectError(error.InvalidParameter, (Args{ .shutter_open = 1 }).build());
}

test "degenerate and numerically parallel viewing bases are rejected" {
    try testing.expectError(error.InvalidBasis, (Args{ .lookat = .{} }).build());
    try testing.expectError(error.InvalidBasis, (Args{ .vup = .{} }).build());
    try testing.expectError(error.InvalidBasis, (Args{ .vup = .{ .z = 1 } }).build());
    try testing.expectError(error.InvalidBasis, (Args{ .vup = .{ .z = -1 } }).build());
    try testing.expectError(error.InvalidBasis, (Args{ .vup = .{ .y = 1e-14, .z = 1 } }).build());
    try testing.expectError(error.InvalidBasis, (Args{ .lookfrom = .{ .z = 1.7e308 }, .lookat = .{ .z = -1.7e308 } }).build());
}

test "finite inputs causing derived geometry overflow or underflow are rejected" {
    try testing.expectError(error.InvalidGeometry, (Args{ .sensor_width_mm = 1e308, .focus_distance = 1000 }).build());
    try testing.expectError(error.InvalidGeometry, (Args{ .sensor_height_mm = 1e308, .focus_distance = 1000 }).build());
    try testing.expectError(error.InvalidGeometry, (Args{ .sensor_width_mm = 1e308, .sensor_height_mm = 1e-200 }).build());
    try testing.expectError(error.InvalidGeometry, (Args{ .sensor_width_mm = 1e-200, .sensor_height_mm = 1e308 }).build());
    const subnormal: f64 = @bitCast(@as(u64, 1));
    try testing.expectError(error.InvalidGeometry, (Args{ .sensor_width_mm = subnormal }).build());
    try testing.expectError(error.InvalidGeometry, (Args{ .focal_length_mm = subnormal }).build());
    try testing.expectError(error.InvalidGeometry, (Args{ .f_number = subnormal }).build());
    try testing.expectError(error.InvalidGeometry, (Args{
        .lookfrom = .{ .x = 1.7e308 },
        .lookat = .{ .x = 1.7e308, .z = -1 },
        .focus_distance = 1e308,
    }).build());
}

test "exposure overflow underflow and overflowing shutter duration are rejected" {
    try testing.expectError(error.InvalidExposure, (Args{ .exposure_compensation = 1024 }).build());
    try testing.expectError(error.InvalidExposure, (Args{ .exposure_compensation = -1075 }).build());
    try testing.expectError(error.InvalidExposure, (Args{ .exposure_compensation = 1e308 }).build());
    try testing.expectError(error.InvalidExposure, (Args{ .exposure_compensation = -1e308 }).build());
    try testing.expectError(error.InvalidExposure, (Args{ .shutter_open = -1.7e308, .shutter_close = 1.7e308 }).build());
    try testing.expectError(error.InvalidExposure, (Args{ .iso = 1e308, .exposure_compensation = 100 }).build());
    try testing.expectError(error.InvalidExposure, (Args{ .iso = 1e-300, .exposure_compensation = -100 }).build());
}

test "stable basis and exposure computations accept representable extreme inputs" {
    const huge_up = try (Args{ .vup = .{ .y = 1e300 } }).build();
    const tiny_up = try (Args{ .vup = .{ .y = 1e-300 } }).build();
    try expectVector(huge_up.u, tiny_up.u, 1e-15);
    // @notice 光圈数平方会溢出，但最终曝光与镜头半径可表示，不应因中间量而拒绝。
    const cam = try (Args{ .f_number = 1e200, .iso = 1e300 }).build();
    try testing.expectApproxEqRel(@as(f64, 6.4e-101), cam.exposure_scale, 1e-12);
    const far = try (Args{ .focus_distance = 1e200 }).build();
    const ray = far.getRaySampled(1, 1, 1, 1, 1);
    try testing.expectApproxEqAbs(@as(f64, 1), ray.direction.length(), 1e-14);
    // @notice 使用相对焦平面向量，世界坐标不能分辨的小横向位移仍保留在方向中。
    const translated = try (Args{ .lookfrom = .{ .x = 1e100 }, .lookat = .{ .x = 1e100, .z = -1 } }).build();
    const reference = try (Args{}).build();
    try expectVector(reference.getRaySampled(1, 1, 0.5, 0.5, 0).direction, translated.getRaySampled(1, 1, 0.5, 0.5, 0).direction, 1e-14);
}

test "legacy defaults tags constructors and unnormalized sampled rays remain compatible" {
    const defaults: camera.CameraArgs = .{};
    try expectVector(.{}, defaults.lookfrom, 0);
    try expectVector(.{}, defaults.lookat, 0);
    try expectVector(.{}, defaults.vup, 0);
    try testing.expectEqual(@as(f64, 40), defaults.vfov);
    try testing.expectEqual(@as(f64, 16.0 / 9.0), defaults.aspect_ratio);
    try testing.expectEqual(@as(f64, 0), defaults.aperture);
    try testing.expectEqual(@as(f64, 10), defaults.focus_dist);
    try testing.expectEqual(@as(f64, 0), defaults.time0);
    try testing.expectEqual(@as(f64, 0), defaults.time1);
    const tag: camera.Tag = .time_range;
    try testing.expectEqual(camera.Tag.time_range, tag);
    const args: camera.CameraArgs = .{
        .lookfrom = .{ .z = 3 },
        .lookat = .{},
        .vup = .{ .y = 1 },
        .vfov = 60,
        .aspect_ratio = 2,
        .aperture = 0.4,
        .focus_dist = 5,
        .time0 = 2,
        .time1 = 4,
    };
    const built = args.build();
    const direct = camera.Camera.init(args.lookfrom, args.lookat, args.vup, args.vfov, args.aspect_ratio, args.aperture, args.focus_dist, args.time0, args.time1);
    try testing.expectEqualDeep(direct, built);
    try testing.expectEqual(@as(f64, 1), built.exposure_scale);
    try testing.expectEqual(@as(f64, 1), built.sampleWeight(0, 0));
    try testing.expectEqual(@as(f64, 0.2), built.lens_radius);
    const center = built.getRaySampled(0.5, 0.5, 0.5, 0.5, 0.25);
    try expectVector(args.lookfrom, center.origin, 0);
    try expectVector(.{ .z = -5 }, center.direction, 1e-14);
    try testing.expectEqual(@as(f64, 2.5), center.time);
    const edge = built.getRaySampled(0.3, 0.7, 1, 0.5, 0.75);
    const offset = built.u.scale(0.2);
    try expectVector(built.origin.add(offset), edge.origin, 1e-14);
    try expectVector(built.lower_left_corner.add(built.horizontal.scale(0.3)).add(built.vertical.scale(0.7)).sub(built.origin).sub(offset), edge.direction, 0);
    try testing.expectEqual(@as(f64, 3.5), edge.time);
    random.seed(91);
    const generated = built.getRay(0.3, 0.7);
    random.seed(91);
    const lens_x = random.randomDouble();
    const lens_y = random.randomDouble();
    const shutter = random.randomDouble();
    try testing.expectEqualDeep(built.getRaySampled(0.3, 0.7, lens_x, lens_y, shutter), generated);
    const literal: camera.Camera = .{};
    try testing.expectEqual(@as(f64, 1), literal.sampleWeight(0.5, 0.5));
}
