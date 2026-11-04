// @brief 均匀介质的独立解析与确定性分层测试；只导入纯 Zig 模块，不链接 C 库。
const std = @import("std");
const math = @import("math.zig");
const Homogeneous = @import("medium.zig").Homogeneous;
const testing = std.testing;

// @brief 逐通道比较颜色，不以亮度抵消通道误差。
fn expectColor(expected: math.Color, actual: math.Color, tolerance: f64) !void {
    for (0..3) |c| try testing.expectApproxEqAbs(expected.at(c), actual.at(c), tolerance);
}

// @brief 返回分层区间的中点，避免测试采样包含无限自由程的上端点。
fn midpoint(i: usize, n: usize) f64 {
    return (@as(f64, @floatFromInt(i)) + 0.5) / @as(f64, @floatFromInt(n));
}

test "medium validates every coefficient and strict anisotropy bounds" {
    try testing.expect((Homogeneous{}).valid());
    try testing.expect((Homogeneous{ .sigma_a = .{ .x = 1, .y = 2, .z = 3 }, .sigma_s = 4, .g = -0.989999 }).valid());
    for ([_]f64{ -1, math.infinity, -math.infinity, std.math.nan(f64) }) |bad| {
        try testing.expect(!(Homogeneous{ .sigma_s = bad }).valid());
        try testing.expect(!(Homogeneous{ .sigma_a = .{ .x = bad } }).valid());
        try testing.expect(!(Homogeneous{ .sigma_a = .{ .y = bad } }).valid());
        try testing.expect(!(Homogeneous{ .sigma_a = .{ .z = bad } }).valid());
    }
    for ([_]f64{ -1, -0.99, 0.99, 1, math.infinity, -math.infinity, std.math.nan(f64) }) |bad| {
        try testing.expect(!(Homogeneous{ .g = bad }).valid());
    }
}

test "Beer absorption is RGB thickness dependent and composes over segments" {
    const medium: Homogeneous = .{ .sigma_a = .{ .x = 0.2, .y = 1, .z = 4 }, .sigma_s = 3 };
    const a = medium.absorption(0.25);
    try expectColor(.{ .x = @exp(-0.05), .y = @exp(-0.25), .z = @exp(-1.0) }, a, 1e-14);
    try expectColor(a.mul(medium.absorption(0.75)), medium.absorption(1), 1e-14);
    try expectColor(medium.absorption(1).mul(medium.absorption(1)), medium.absorption(2), 1e-14);
    try expectColor(.{ .x = @exp(-1.6), .y = @exp(-2.0), .z = @exp(-3.5) }, medium.transmittance(0.5), 1e-14);
    try expectColor(medium.transmittance(0.2).mul(medium.transmittance(0.3)), medium.transmittance(0.5), 1e-14);
    try testing.expect(a.x > a.y and a.y > a.z);
}

test "vacuum and zero scattering preserve absorption without fictitious events" {
    const vacuum: Homogeneous = .{};
    const white: math.Color = .{ .x = 1, .y = 1, .z = 1 };
    for ([_]f64{ 0, 1, 1e300, math.infinity }) |distance| {
        try expectColor(white, vacuum.absorption(distance), 0);
        try expectColor(white, vacuum.transmittance(distance), 0);
    }
    const absorber: Homogeneous = .{ .sigma_a = .{ .x = 0, .y = 2, .z = 4 } };
    for ([_]f64{ 0, 0.25, 0.999, 1 }) |u| {
        try testing.expectEqual(math.infinity, vacuum.sampleDistance(u));
        try testing.expectEqual(math.infinity, absorber.sampleDistance(u));
    }
    try expectColor(absorber.absorption(2), absorber.transmittance(2), 0);
    try expectColor(.{ .x = 1 }, absorber.absorption(math.infinity), 0);
    const scatterer: Homogeneous = .{ .sigma_s = 2 };
    try expectColor(white, scatterer.absorption(3), 0);
    try expectColor(.{}, scatterer.transmittance(math.infinity), 0);
    try expectColor(white, absorber.transmittance(0), 0);
}

test "scattering free flight matches exponential CDF and mean independently of absorption" {
    const medium: Homogeneous = .{ .sigma_s = 2.5 };
    const absorbing: Homogeneous = .{ .sigma_s = 2.5, .sigma_a = .{ .x = 50, .y = 1, .z = 9 } };
    const n = 65536;
    const cutoff: f64 = 0.4;
    var total: f64 = 0;
    var below: usize = 0;
    for (0..n) |i| {
        const u = midpoint(i, n);
        const distance = medium.sampleDistance(u);
        total += distance;
        if (distance < cutoff) below += 1;
        try testing.expectEqual(distance, absorbing.sampleDistance(u));
        try testing.expectApproxEqAbs(u, 1 - @exp(-medium.sigma_s * distance), 2e-15);
    }
    // @method $E[D]=1/\sigma_s$，$P(D<L)=1-e^{-\sigma_s L}$；中点求积尾部误差随样本数降低。
    try testing.expectApproxEqAbs(1 / medium.sigma_s, total / n, 1e-5);
    try testing.expectApproxEqAbs(1 - @exp(-medium.sigma_s * cutoff), @as(f64, @floatFromInt(below)) / n, @as(f64, 1) / n);
}

test "free flight endpoints tiny uniforms and extreme finite rates do not produce NaN" {
    const medium: Homogeneous = .{ .sigma_s = 2 };
    try testing.expectEqual(@as(f64, 0), medium.sampleDistance(0));
    try testing.expectEqual(math.infinity, medium.sampleDistance(1));
    try testing.expectApproxEqRel(@as(f64, 5e-301), medium.sampleDistance(1e-300), 1e-14);
    const last: f64 = 1 - 0x1p-53;
    try testing.expect(std.math.isFinite(medium.sampleDistance(last)));
    var previous: f64 = 0;
    for ([_]f64{ 0, 1e-16, 0.1, 0.5, 0.9, last, 1 }) |u| {
        const distance = medium.sampleDistance(u);
        try testing.expect(distance >= previous);
        previous = distance;
    }
    for ([_]f64{ 1e-300, 1e300, std.math.floatMax(f64) }) |rate| {
        const extreme: Homogeneous = .{ .sigma_s = rate, .sigma_a = .{ .x = rate, .y = rate, .z = rate } };
        try testing.expect(extreme.valid());
        try testing.expect(std.math.isFinite(extreme.sampleDistance(0.5)));
        try expectColor(.{ .x = 1, .y = 1, .z = 1 }, extreme.transmittance(0), 0);
        try expectColor(.{}, extreme.transmittance(math.infinity), 0);
        for ([_]f64{ 1e-300, 1, 1e300 }) |distance| {
            const a = extreme.absorption(distance);
            const t = extreme.transmittance(distance);
            for (0..3) |c| {
                try testing.expect(std.math.isFinite(a.at(c)) and a.at(c) >= 0 and a.at(c) <= 1);
                try testing.expect(std.math.isFinite(t.at(c)) and t.at(c) >= 0 and t.at(c) <= a.at(c));
            }
        }
    }
    const tiny: Homogeneous = .{ .sigma_s = 0x1p-1074 };
    try testing.expectEqual(math.infinity, tiny.sampleDistance(0.5));
    // @notice 有限系数之和可能溢出，但很短路段的真实光学厚度仍有限。
    const huge: Homogeneous = .{ .sigma_s = 1e308, .sigma_a = .{ .x = 1e308 } };
    try expectColor(.{ .x = @exp(-2.0), .y = @exp(-1.0), .z = @exp(-1.0) }, huge.transmittance(1e-308), 2e-15);
}

test "HG phase has travel-direction convention and isotropic limit" {
    const isotropic: Homogeneous = .{};
    const forward: Homogeneous = .{ .g = 0.8 };
    const backward: Homogeneous = .{ .g = -0.8 };
    for ([_]f64{ -1, -0.5, 0, 0.3, 1 }) |cosine| {
        try testing.expectApproxEqAbs(1 / (4 * math.pi), isotropic.phase(cosine), 1e-15);
        try testing.expectApproxEqAbs(forward.phase(cosine), backward.phase(-cosine), 1e-14);
        const base = 1 + forward.g * forward.g - 2 * forward.g * cosine;
        const reference = (1 - forward.g * forward.g) / (4 * math.pi * base * @sqrt(base));
        try testing.expectApproxEqRel(reference, forward.phase(cosine), 1e-13);
    }
    try testing.expect(forward.phase(1) > forward.phase(0));
    try testing.expect(forward.phase(0) > forward.phase(-1));
    try testing.expectEqual(forward.phase(1), forward.phase(1 + 1e-15));
    try testing.expectEqual(forward.phase(-1), forward.phase(-1 - 1e-15));
}

test "HG phase integrates to one and first cosine moment equals g" {
    const n = 65536;
    for ([_]f64{ -0.989999, -0.8, -0.1, -1e-12, 0, 1e-12, 0.1, 0.8, 0.989999 }) |g| {
        const medium: Homogeneous = .{ .g = g };
        var mass: f64 = 0;
        var moment: f64 = 0;
        for (0..n) |i| {
            const theta = math.pi * midpoint(i, n);
            const cosine = @cos(theta);
            // @method 独立球面积分：$2\pi\int_0^\pi p(\cos\theta)\sin\theta\,d\theta$；不使用方向采样器。
            const weight = medium.phase(cosine) * @sin(theta) * (2 * math.pi * math.pi / n);
            mass += weight;
            moment += cosine * weight;
        }
        try testing.expectApproxEqAbs(@as(f64, 1), mass, 2e-6);
        try testing.expectApproxEqAbs(g, moment, 2e-6);
    }
}

test "HG sampled cosine mean equals g and directions are normalized" {
    const axis = (math.Vec3{ .x = 1, .y = 2, .z = -3 }).normalized();
    const n = 65536;
    for ([_]f64{ -0.989999, -0.7, -1e-12, 0, 1e-12, 0.7, 0.989999 }) |g| {
        const medium: Homogeneous = .{ .g = g };
        var sum: f64 = 0;
        for (0..n) |i| {
            const direction = medium.sampleDirection(axis, midpoint(i, n), midpoint((i * 4051) % n, n));
            sum += axis.dot(direction);
            try testing.expectApproxEqAbs(@as(f64, 1), direction.lengthSquared(), 2e-14);
            try testing.expect(std.math.isFinite(medium.phase(axis.dot(direction))));
        }
        try testing.expectApproxEqAbs(g, sum / n, 1e-6);
    }
}

test "HG inverse CDF agrees with analytic angular CDF" {
    for ([_]f64{ -0.98, -0.5, 0.2, 0.9, 0.98 }) |g| {
        const medium: Homogeneous = .{ .g = g };
        for (0..2048) |i| {
            const u = midpoint(i, 2048);
            const direction = medium.sampleDirection(.{ .z = 1 }, u, 0.37);
            // @method $F(c)=(1-g^2)[(1+g^2-2gc)^{-1/2}-(1+g)^{-1}]/(2g)$；独立检验分位数。
            const cdf = (1 - g * g) / (2 * g) * (1 / @sqrt(1 + g * g - 2 * g * direction.z) - 1 / (1 + g));
            try testing.expectApproxEqAbs(u, cdf, 2e-11);
        }
    }
}

test "HG isotropic sampling has uniform azimuth and spherical second moments" {
    const medium: Homogeneous = .{};
    const n = 256;
    var mean: math.Vec3 = .{};
    var second: math.Vec3 = .{};
    for (0..n) |i| {
        for (0..128) |j| {
            const direction = medium.sampleDirection(.{ .z = 1 }, midpoint(i, n), midpoint(j, 128));
            mean = mean.add(direction);
            second = second.add(direction.mul(direction));
        }
    }
    try expectColor(.{}, mean.div(n * 128), 1e-14);
    // @method 均匀球面满足 $E[\omega_i]=0$、$E[\omega_i^2]=1/3$，用于检查方位角与局部基底。
    try expectColor(.{ .x = @as(f64, 1) / 3, .y = @as(f64, 1) / 3, .z = @as(f64, 1) / 3 }, second.div(n * 128), 1e-5);
}

test "HG finite extremes endpoints and near-zero g remain stable on arbitrary axes" {
    const axes = [_]math.Vec3{
        .{ .x = 1 },
        .{ .y = -1 },
        .{ .z = 1 },
        .{ .z = -1 },
        .{ .x = 1, .y = -2, .z = 3 },
        .{ .x = 1e300, .y = -1e300, .z = 1e300 },
        .{ .x = 1e-300, .y = 1e-300 },
        .{ .z = 0x1p-1074 },
    };
    for (axes) |axis| {
        for ([_]f64{ -0.989999999999, -1e-8, -1e-16, 0, 1e-16, 1e-8, 0.989999999999 }) |g| {
            const medium: Homogeneous = .{ .g = g };
            for ([_]f64{ 0, 1e-16, 0.25, 0.5, 0.75, 1 - 0x1p-53, 1 }) |u| {
                for ([_]f64{ 0, 0.37, 1 }) |v| {
                    const direction = medium.sampleDirection(axis, u, v);
                    try testing.expect(std.math.isFinite(direction.x) and std.math.isFinite(direction.y) and std.math.isFinite(direction.z));
                    try testing.expectApproxEqAbs(@as(f64, 1), direction.lengthSquared(), 2e-14);
                }
                const direction = medium.sampleDirection(.{ .z = 1 }, u, 0.5);
                if (u == 0 or u == 1) try testing.expectEqual(2 * u - 1, direction.z);
                if (@abs(g) <= 1e-8) try testing.expectApproxEqAbs(2 * u - 1, direction.z, 2e-8);
                if (g == 0) try testing.expectEqual(2 * u - 1, direction.z);
                try testing.expect(std.math.isFinite(medium.phase(direction.z)) and medium.phase(direction.z) > 0);
            }
        }
    }
    // @method 在 u=1/2 处，$c=g(3-g^2)/2$；防止把小而非零的 g 直接切换成各向同性近似。
    for ([_]f64{ -1e-12, 1e-12 }) |g| {
        const medium: Homogeneous = .{ .g = g };
        try testing.expectApproxEqRel(g * (3 - g * g) / 2, medium.sampleDirection(.{ .z = 1 }, 0.5, 0).z, 1e-14);
    }
}

test "RGB absorption-only free-flight weights match analytic event and boundary expectations" {
    const medium: Homogeneous = .{ .sigma_s = 2, .sigma_a = .{ .x = 0, .y = 0.8, .z = 4 } };
    const limit: f64 = 0.7;
    const n = 131072;
    var unbounded: math.Color = .{};
    var events: math.Color = .{};
    var boundary: math.Color = .{};
    for (0..n) |i| {
        const distance = medium.sampleDistance(midpoint(i, n));
        unbounded = unbounded.add(medium.absorption(distance));
        if (distance < limit) {
            events = events.add(medium.absorption(distance));
        } else {
            boundary = boundary.add(medium.absorption(limit));
        }
    }
    for (0..3) |c| {
        const extinction = medium.sigma_s + medium.sigma_a.at(c);
        const ratio = medium.sigma_s / extinction;
        const ballistic = @exp(-extinction * limit);
        // @method 无限段 $E[A_c(D)]=\sigma_s/(\sigma_s+\sigma_{a,c})$；此比值是期望值，不是单条路径要再乘的反照率。
        try testing.expectApproxEqAbs(ratio, unbounded.at(c) / n, 2e-6);
        // @method 截断段：$E[1_{D<L}A_c(D)]=\sigma_s(1-e^{-\sigma_{t,c}L})/\sigma_{t,c}$，$E[1_{D\ge L}A_c(L)]=e^{-\sigma_{t,c}L}$。
        try testing.expectApproxEqAbs(ratio * (1 - ballistic), events.at(c) / n, @as(f64, 2) / n);
        try testing.expectApproxEqAbs(ballistic, boundary.at(c) / n, @as(f64, 2) / n);
        try testing.expectApproxEqAbs(ratio * (1 - ballistic) + ballistic, (events.at(c) + boundary.at(c)) / n, @as(f64, 2) / n);
    }
    try testing.expectApproxEqAbs(@as(f64, 1), (events.x + boundary.x) / n, 1e-14);
}
