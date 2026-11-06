const std = @import("std");
const math = @import("math.zig");

const Allocator = std.mem.Allocator;
const Color = math.Color;
const Vec3 = math.Vec3;

// @brief 降噪辅助数据：主射线首个交点的反照率、法线与距离，供联合双边滤波引导。
pub const Guide = struct {
    albedo: Color = .{},
    normal: Vec3 = .{},
    depth: f64 = 0,
    hit: bool = false,
};

// @brief 联合双边滤波参数；半径与各标准差越大越平滑，但更易丢失细节。
pub const Options = struct {
    radius: i32 = 3,
    sigma_space: f64 = 2.5,
    sigma_albedo: f64 = 0.1,
    sigma_normal: f64 = 0.1,
    sigma_depth: f64 = 0.1,
    // @brief 颜色引导标准差；设为 0 时关闭（避免噪声自引导，默认只靠 G-buffer）。
    sigma_color: f64 = 0.0,
    iterations: u32 = 2,
};

// @brief 用 G-buffer 引导的联合双边滤波平滑线性 RGB 图像，原地替换。
// @param image 线性 RGB，长度 width*height；guides 与之等长。
// @notice 反照率/法线/深度差异大的邻居权重趋零，因此不会跨几何与纹理边界模糊。
// @notice 天空（未命中）像素只用空间核平滑；天空与表面交界几乎不混合。
pub fn denoiseJointBilateral(
    alloc: Allocator,
    image: []Color,
    guides: []const Guide,
    width: usize,
    height: usize,
    options: Options,
) Allocator.Error!void {
    if (options.radius <= 0 or width == 0 or height == 0) return;
    const radius: usize = @intCast(options.radius);
    var tmp = try alloc.alloc(Color, image.len);
    defer alloc.free(tmp);
    var iteration: u32 = 0;
    while (iteration < @max(1, options.iterations)) : (iteration += 1) {
        @memcpy(tmp, image);
        var y: usize = 0;
        while (y < height) : (y += 1) {
            var x: usize = 0;
            while (x < width) : (x += 1) {
                const idx = y * width + x;
                const center = tmp[idx];
                const gc = guides[idx];
                var sum = Color{};
                var weight_sum: f64 = 0;
                const y0 = if (y >= radius) y - radius else 0;
                const y1 = @min(y + radius, height - 1);
                const x0 = if (x >= radius) x - radius else 0;
                const x1 = @min(x + radius, width - 1);
                var ny = y0;
                while (ny <= y1) : (ny += 1) {
                    var nx = x0;
                    while (nx <= x1) : (nx += 1) {
                        const nidx = ny * width + nx;
                        const gi = guides[nidx];
                        const dx = @as(f64, @floatFromInt(@as(i64, @intCast(nx)) - @as(i64, @intCast(x))));
                        const dy = @as(f64, @floatFromInt(@as(i64, @intCast(ny)) - @as(i64, @intCast(y))));
                        var weight = @exp(-(dx * dx + dy * dy) / (2.0 * options.sigma_space * options.sigma_space));
                        if (gc.hit and gi.hit) {
                            weight *= gaussian(albedoDiff(gc.albedo, gi.albedo), options.sigma_albedo);
                            weight *= gaussian(1.0 - math.clamp(gc.normal.dot(gi.normal), -1.0, 1.0), options.sigma_normal);
                            weight *= gaussian(relativeDepthDiff(gc.depth, gi.depth), options.sigma_depth);
                            if (options.sigma_color > 0) weight *= gaussian(colorDiff(center, tmp[nidx]), options.sigma_color);
                        } else if (gc.hit != gi.hit) {
                            // 天空与表面交界：完全不混合，避免把 HDR 天空渗入几何导致过曝。
                            continue;
                        }
                        sum = sum.add(tmp[nidx].scale(weight));
                        weight_sum += weight;
                    }
                }
                image[idx] = if (weight_sum > 0) sum.scale(1.0 / weight_sum) else center;
            }
        }
    }
}

fn gaussian(diff: f64, sigma: f64) f64 {
    if (sigma <= 0) return 1;
    return @exp(-(diff * diff) / (2.0 * sigma * sigma));
}

fn albedoDiff(a: Color, b: Color) f64 {
    return @max(@abs(a.x - b.x), @max(@abs(a.y - b.y), @abs(a.z - b.z)));
}

fn colorDiff(a: Color, b: Color) f64 {
    return @max(@abs(a.x - b.x), @max(@abs(a.y - b.y), @abs(a.z - b.z)));
}

fn relativeDepthDiff(a: f64, b: f64) f64 {
    const denom = @max(@max(a, b), 1e-6);
    return @abs(a - b) / denom;
}
