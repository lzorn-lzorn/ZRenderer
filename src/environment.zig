const std = @import("std");
const math = @import("math.zig");

const Allocator = std.mem.Allocator;
const Vec3 = math.Vec3;
const Color = math.Color;

// @brief 环境方向样本：世界空间方向与其立体角概率密度。
pub const Sample = struct { direction: Vec3, pdf: f64 };

// @brief 等距柱状投影 HDR 环境贴图，带亮度重要性采样与可选旋转。
// @notice 像素与 CDF 缓冲均由场景分配器管理；贴图按纬度正弦加权采样。
pub const EnvironmentMap = struct {
    width: usize,
    height: usize,
    pixels: []Color,
    rotation: math.Transform = math.Transform.identity(),
    scale: f64 = 1,
    marginal_cdf: []f64, // 长度 height+1，随 v 的累积分布
    conditional_cdf: []f64, // 长度 (width+1)*height，随 u 的累积分布
    total_weight: f64,

    // @brief 由等距柱状像素建立环境贴图，预计算亮度 CDF。
    // @param rotation 应用于采样与查询方向的旋转（如 PBRT Rotate）；scale 为辐亮度缩放。
    pub fn build(alloc: Allocator, pixels: []Color, width: usize, height: usize, rotation: math.Transform, scale: f64) Allocator.Error!*EnvironmentMap {
        const self = try alloc.create(EnvironmentMap);
        self.* = .{
            .width = width,
            .height = height,
            .pixels = pixels,
            .rotation = rotation,
            .scale = scale,
            .marginal_cdf = try alloc.alloc(f64, height + 1),
            .conditional_cdf = try alloc.alloc(f64, (width + 1) * height),
            .total_weight = 0,
        };
        buildCdf(self);
        return self;
    }

    // @brief 用亮度乘纬度正弦构造边缘与条件 CDF。
    fn buildCdf(self: *EnvironmentMap) void {
        var conditional: []f64 = self.conditional_cdf;
        self.marginal_cdf[0] = 0;
        var total: f64 = 0;
        var v: usize = 0;
        while (v < self.height) : (v += 1) {
            const theta = math.pi * (@as(f64, @floatFromInt(v)) + 0.5) / @as(f64, @floatFromInt(self.height));
            const sin_theta = @sin(theta);
            const row_cdf = conditional[v * (self.width + 1) ..][0 .. self.width + 1];
            row_cdf[0] = 0;
            var u: usize = 0;
            while (u < self.width) : (u += 1) {
                const lum = luminance(self.pixels[v * self.width + u]);
                const weight = lum * sin_theta;
                row_cdf[u + 1] = row_cdf[u] + weight;
            }
            const row_total = row_cdf[self.width];
            total += row_total;
            self.marginal_cdf[v + 1] = total;
            if (row_total > 0) {
                for (row_cdf) |*c| c.* /= row_total;
            }
        }
        self.total_weight = total;
        if (total > 0) {
            for (self.marginal_cdf) |*c| c.* /= total;
        }
    }

    // @brief 按方向查询辐射亮度；方向须为非零向量，贴图坐标按钳位取样。
    pub fn radiance(self: *const EnvironmentMap, direction: Vec3) Color {
        const local = self.rotation.toObjectVector(direction);
        const uv = directionToUv(local);
        return self.lookup(uv.u, uv.v).scale(self.scale);
    }

    // @brief 采样方向及其立体角密度；u1、u2 为 [0,1] 均匀样本。
    pub fn sampleDirection(self: *const EnvironmentMap, u_a: f64, u_b: f64) Sample {
        const v_float = invertCdf(self.marginal_cdf, u_a);
        const v = @min(@as(usize, @intFromFloat(v_float * @as(f64, @floatFromInt(self.height)))), self.height - 1);
        const row_cdf = self.conditional_cdf[v * (self.width + 1) ..][0 .. self.width + 1];
        const u_float = invertCdf(row_cdf, u_b);
        const u = @min(@as(usize, @intFromFloat(u_float * @as(f64, @floatFromInt(self.width)))), self.width - 1);
        const cu = @as(f64, @floatFromInt(u)) / @as(f64, @floatFromInt(self.width));
        const cv = @as(f64, @floatFromInt(v)) / @as(f64, @floatFromInt(self.height));
        const direction = self.rotation.applyVector(uvToDirection(cu, cv));
        const theta = math.pi * (cv + 0.5 / @as(f64, @floatFromInt(self.height)));
        const sin_theta = @max(@sin(theta), 1e-6);
        const density = luminance(self.pixels[v * self.width + u]) / (2.0 * math.pi * math.pi * self.total_weight * sin_theta);
        return .{ .direction = direction, .pdf = if (std.math.isFinite(density) and density > 0) density else 0 };
    }

    // @brief 返回查询方向的立体角密度，与 sampleDirection 一致。
    pub fn pdf(self: *const EnvironmentMap, direction: Vec3) f64 {
        const local = self.rotation.toObjectVector(direction);
        const uv = directionToUv(local);
        const u = @min(@as(usize, @intFromFloat(uv.u * @as(f64, @floatFromInt(self.width)))), self.width - 1);
        const v = @min(@as(usize, @intFromFloat(uv.v * @as(f64, @floatFromInt(self.height)))), self.height - 1);
        const theta = math.pi * (@as(f64, @floatFromInt(v)) + 0.5) / @as(f64, @floatFromInt(self.height));
        const sin_theta = @max(@sin(theta), 1e-6);
        const density = luminance(self.pixels[v * self.width + u]) / (2.0 * math.pi * math.pi * self.total_weight * sin_theta);
        return if (std.math.isFinite(density) and density > 0) density else 0;
    }

    fn lookup(self: *const EnvironmentMap, u: f64, v: f64) Color {
        const x = u * @as(f64, @floatFromInt(self.width)) - 0.5;
        const y = v * @as(f64, @floatFromInt(self.height)) - 0.5;
        const xi: i64 = @intFromFloat(@floor(x));
        const yi: i64 = @intFromFloat(@floor(y));
        const xf = x - @as(f64, @floatFromInt(xi));
        const yf = y - @as(f64, @floatFromInt(yi));
        const width_i: i64 = @intCast(self.width);
        const x0: usize = @intCast(@mod(xi, width_i));
        const x1: usize = @intCast(@mod(xi + 1, width_i));
        const y0: usize = @intCast(@min(@max(yi, 0), @as(i64, @intCast(self.height - 1))));
        const y1: usize = @intCast(@min(@max(yi + 1, 0), @as(i64, @intCast(self.height - 1))));
        const c00 = self.pixels[y0 * self.width + x0];
        const c10 = self.pixels[y0 * self.width + x1];
        const c01 = self.pixels[y1 * self.width + x0];
        const c11 = self.pixels[y1 * self.width + x1];
        const a = c00.scale((1 - xf) * (1 - yf)).add(c10.scale(xf * (1 - yf)));
        const b = c01.scale((1 - xf) * yf).add(c11.scale(xf * yf));
        return a.add(b);
    }
};

// @brief 等距柱状投影：uvToDirection 与 directionToUv 互为逆映射。
fn uvToDirection(u: f64, v: f64) Vec3 {
    const phi = 2.0 * math.pi * u - math.pi;
    const theta = math.pi * v;
    const sin_theta = @sin(theta);
    return Vec3.init(sin_theta * @cos(phi), @cos(theta), sin_theta * @sin(phi));
}

const Uv = struct { u: f64, v: f64 };

fn directionToUv(d: Vec3) Uv {
    const theta = std.math.acos(math.clamp(d.y, -1.0, 1.0));
    const phi = std.math.atan2(d.z, d.x);
    return .{ .u = (phi + math.pi) / (2.0 * math.pi), .v = theta / math.pi };
}

fn luminance(c: Color) f64 {
    return @max(c.x, @max(c.y, c.z));
}

// @brief 在单调递增的 CDF 中二分查找，返回 [0,1] 归一化位置。
fn invertCdf(cdf: []const f64, sample: f64) f64 {
    var low: usize = 0;
    var high: usize = cdf.len - 1;
    while (high - low > 1) {
        const mid = (low + high) / 2;
        if (cdf[mid] <= sample) low = mid else high = mid;
    }
    if (high >= cdf.len) return 1.0;
    const span = cdf[high] - cdf[low];
    const frac = if (span > 0) (sample - cdf[low]) / span else 0.0;
    return (@as(f64, @floatFromInt(low)) + frac) / @as(f64, @floatFromInt(cdf.len - 1));
}
