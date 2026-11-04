const std = @import("std");
const sampling = @import("sampling.zig");
const camera = @import("camera.zig");
const math = @import("math.zig");
const testing = std.testing;

test "Sobol starts with known Gray-code points" {
    const first = [_]u32{ 0, 0x80000000, 0xc0000000, 0x40000000 };
    const second = [_]u32{ 0, 0x80000000, 0x40000000, 0xc0000000 };
    for (0..4) |i| {
        try testing.expectEqual(first[i], sampling.sobolBits(@intCast(i), 0));
        try testing.expectEqual(second[i], sampling.sobolBits(@intCast(i), 1));
    }
}

test "every shifted Sobol replica stratifies each camera dimension" {
    const sampler = sampling.PixelSampler.init(42, 3, .sobol);
    for (0..sampling.replicas) |replica| {
        var seen: [sampling.dimensions][64]bool = @splat(@splat(false));
        var film_cells: [64]bool = @splat(false);
        for (0..64) |index| {
            const point = sampler.startSample(@intCast(index * sampling.replicas + replica));
            for (point, 0..) |value, dimension| {
                try testing.expect(value > 0 and value < 1);
                const cell: usize = @intFromFloat(value * 64);
                try testing.expect(!seen[dimension][cell]);
                seen[dimension][cell] = true;
            }
            const x: usize = @intFromFloat(point[0] * 8);
            const y: usize = @intFromFloat(point[1] * 8);
            try testing.expect(!film_cells[y * 8 + x]);
            film_cells[y * 8 + x] = true;
        }
    }
}

test "Sobol sampler is reproducible and pixel-decorrelated" {
    const a = sampling.PixelSampler.init(42, 123, .sobol);
    const b = sampling.PixelSampler.init(42, 123, .sobol);
    const c = sampling.PixelSampler.init(42, 124, .sobol);
    const d = sampling.PixelSampler.init(43, 123, .sobol);
    const pa = a.startSample(19);
    const pb = b.startSample(19);
    const pc = c.startSample(19);
    const pd = d.startSample(19);
    try testing.expectEqualSlices(f64, &pa, &pb);
    try testing.expect(!std.mem.eql(f64, &pa, &pc));
    try testing.expect(!std.mem.eql(f64, &pa, &pd));
    const cached = a.startSampleWithPoint(19, sampling.sobolPoint(19 / sampling.replicas));
    try testing.expectEqualSlices(f64, &pa, &cached);
}

test "randomized Sobol improves a smooth integral at a fixed sample budget" {
    var random_mse: f64 = 0;
    var sobol_mse: f64 = 0;
    for (0..64) |pixel| {
        for ([_]sampling.Sampler{ .random, .sobol }) |mode| {
            const sampler = sampling.PixelSampler.init(99, @intCast(pixel), mode);
            var sum: f64 = 0;
            for (0..128) |i| {
                const point = sampler.startSample(@intCast(i));
                sum += point[0] + point[1];
            }
            const error_value = sum / 128 - 1; // Integral of x+y over [0,1]^2.
            if (mode == .sobol) sobol_mse += error_value * error_value else random_mse += error_value * error_value;
        }
    }
    try testing.expect(sobol_mse < random_mse);
}

test "adaptive estimator requires two balanced stable checks" {
    var estimate: sampling.Estimate = .{};
    for (0..32) |i| {
        estimate.add(.{ .x = 0.25, .y = 0.5, .z = 1 });
        const stop = estimate.converged(16, 0, 0);
        try testing.expectEqual(i == 31, stop);
    }
}

test "adaptive estimator detects between-replica variation in any RGB channel" {
    var estimate: sampling.Estimate = .{};
    for (0..128) |i| {
        const value: math.Color = if (i % sampling.replicas < 4) .{ .x = 1 } else .{ .z = 1 };
        estimate.add(value);
        try testing.expect(!estimate.converged(16, 0.002, 0.05));
    }
    estimate.add(.{ .x = std.math.nan(f64) });
    try testing.expect(!estimate.converged(16, 1, 1));
}

test "concentric disk mapping stays finite and has uniform-area second moment" {
    const center = camera.concentricDisk(0.5, 0.5);
    try testing.expectEqual(@as(f64, 0), center.lengthSquared());
    var radius_squared_sum: f64 = 0;
    for (0..64) |i| {
        for (0..64) |j| {
            const p = camera.concentricDisk((@as(f64, @floatFromInt(i)) + 0.5) / 64, (@as(f64, @floatFromInt(j)) + 0.5) / 64);
            try testing.expect(std.math.isFinite(p.x) and std.math.isFinite(p.y));
            try testing.expect(p.lengthSquared() <= 1);
            radius_squared_sum += p.lengthSquared();
        }
    }
    try testing.expectApproxEqAbs(@as(f64, 0.5), radius_squared_sum / (64 * 64), 0.001);
}
