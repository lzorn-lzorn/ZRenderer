//! Camera-domain randomized quasi-Monte Carlo and adaptive error estimation.
//! Eight independent digital shifts let us estimate error BETWEEN randomized
//! replicas, rather than incorrectly treating correlated Sobol points as IID.
const std = @import("std");
const math = @import("math.zig");
const random = @import("random.zig");
const Color = math.Color;

pub const Sampler = enum { random, sobol };
pub const replicas: u32 = 8;
pub const dimensions = 5; // film x/y, lens x/y, shutter time
pub const SobolPoint = [dimensions]u32;

pub fn hash(value: u64) u64 {
    var z = value +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

// Primitive polynomial coefficients and initial odd direction numerators for
// Sobol dimensions 2..5. Dimension 1 uses powers of two directly.
const Polynomial = struct { degree: usize, a: u32, m: [3]u32 };
const polynomials = [_]Polynomial{
    .{ .degree = 1, .a = 0, .m = .{ 1, 0, 0 } },
    .{ .degree = 2, .a = 1, .m = .{ 1, 3, 0 } },
    .{ .degree = 3, .a = 1, .m = .{ 1, 3, 1 } },
    .{ .degree = 3, .a = 2, .m = .{ 1, 1, 1 } },
};

const directions = makeDirections();

fn makeDirections() [dimensions][32]u32 {
    @setEvalBranchQuota(10000);
    var table: [dimensions][32]u32 = undefined;
    for (0..32) |i| table[0][i] = @as(u32, 1) << @as(u5, @intCast(31 - i));
    for (polynomials, 1..) |p, d| {
        for (0..p.degree) |i| table[d][i] = p.m[i] << @as(u5, @intCast(31 - i));
        for (p.degree..32) |i| {
            var v = table[d][i - p.degree] ^ (table[d][i - p.degree] >> @as(u5, @intCast(p.degree)));
            for (1..p.degree) |k| {
                if (((p.a >> @as(u5, @intCast(p.degree - 1 - k))) & 1) != 0) v ^= table[d][i - k];
            }
            table[d][i] = v;
        }
    }
    return table;
}

/// Unscrambled, Gray-code ordered Sobol coordinate, represented in 32 bits.
pub fn sobolBits(index: u32, dimension: usize) u32 {
    std.debug.assert(dimension < dimensions);
    var gray = index ^ (index >> 1);
    var result: u32 = 0;
    while (gray != 0) {
        result ^= directions[dimension][@ctz(gray)];
        gray &= gray - 1;
    }
    return result;
}

pub fn sobolPoint(index: u32) SobolPoint {
    var result: SobolPoint = undefined;
    for (&result, 0..) |*value, d| value.* = sobolBits(index, d);
    return result;
}

pub const PixelSampler = struct {
    mode: Sampler,
    pixel_seed: u64,
    shifts: [replicas][dimensions]u32,

    pub fn init(seed: u64, pixel_index: u64, mode: Sampler) PixelSampler {
        var self: PixelSampler = .{ .mode = mode, .pixel_seed = hash(seed ^ hash(pixel_index)), .shifts = undefined };
        for (0..replicas) |r| {
            const replica_seed = hash(self.pixel_seed ^ hash(@intCast(r)));
            for (0..dimensions) |d| self.shifts[r][d] = @truncate(hash(replica_seed ^ hash(@intCast(d))));
        }
        return self;
    }

    /// Resets the thread-local path RNG too. Rejection sampling / variable path
    /// lengths never change the fixed camera dimensions or another pixel.
    pub fn startSample(self: *const PixelSampler, sample: u32) [dimensions]f64 {
        return self.startSampleWithPoint(sample, if (self.mode == .sobol) sobolPoint(sample / replicas) else @splat(0));
    }

    /// Renderer supplies a shared precomputed point; digital shifts remain
    /// pixel/replica-specific. This avoids repeating Gray-code work per pixel.
    pub fn startSampleWithPoint(self: *const PixelSampler, sample: u32, point: SobolPoint) [dimensions]f64 {
        random.seed(hash(self.pixel_seed ^ (0xd1b54a32d192ed03 *% (@as(u64, sample) + 1))));
        var result: [dimensions]f64 = undefined;
        for (&result, 0..) |*value, d| {
            value.* = switch (self.mode) {
                .random => random.randomDouble(),
                .sobol => (@as(f64, @floatFromInt(point[d] ^ self.shifts[sample % replicas][d])) + 0.5) / 4294967296.0,
            };
        }
        return result;
    }
};

/// Constant per-worker storage, not a full-frame variance buffer.
pub const Estimate = struct {
    sum: Color = .{},
    replica_sums: [replicas]Color = @splat(.{}),
    count: u32 = 0,
    stable_checks: u8 = 0,
    finite: bool = true,

    pub fn add(self: *Estimate, value: Color) void {
        self.finite = self.finite and std.math.isFinite(value.x) and std.math.isFinite(value.y) and std.math.isFinite(value.z);
        const r = self.count % replicas;
        self.replica_sums[r] = self.replica_sums[r].add(value);
        self.sum = self.sum.add(value);
        self.count += 1;
    }

    /// Check only complete power-of-two replica blocks (16,32,64,... total).
    /// The 2.5 factor is a conservative heuristic, NOT a guaranteed CI under
    /// repeated stopping tests. Rare paths and optional stopping can cause bias.
    pub fn converged(self: *Estimate, min_samples: u32, absolute: f64, relative: f64) bool {
        if (!self.finite or self.count < @max(min_samples, 2 * replicas) or self.count % replicas != 0) return false;
        const n = self.count / replicas;
        if ((n & (n - 1)) != 0) return false;
        const mean = self.sum.div(@floatFromInt(self.count));
        var m2: Color = .{};
        for (self.replica_sums) |sum| {
            const delta = sum.div(@floatFromInt(n)).sub(mean);
            m2 = m2.add(delta.mul(delta));
        }
        for (0..3) |channel| {
            const se = @sqrt(m2.at(channel) / @as(f64, replicas * (replicas - 1)));
            if (2.5 * se > absolute + relative * @abs(mean.at(channel))) {
                self.stable_checks = 0;
                return false;
            }
        }
        self.stable_checks +|= 1;
        return self.stable_checks >= 2;
    }
};
