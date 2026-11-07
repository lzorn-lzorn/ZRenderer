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

// @brief 多尺度 à-trous 小波降噪参数（OIDN 同款核心结构）。
pub const AtrousOptions = struct {
    scales: u32 = 5,
    sigma_albedo: f64 = 0.1,
    sigma_normal: f64 = 0.1,
    sigma_depth: f64 = 0.1,
    // @brief 相对亮度引导阈值；0 关闭（噪声图上的亮度引导不可靠，默认关闭）。
    sigma_luminance: f64 = 0.0,
};

// @brief 多尺度 à-trous 小波降噪：去火点 + 反照率/光照分离 + 5x5 孔洞核逐尺度扩大。
// @param image 线性 RGB；guides 为噪声无关的反照率/法线/深度。
// @notice 只平滑 illumination=radiance/albedo，重建时乘回 albedo，从而保留纹理细节。
// @notice 反照率过低（金属/介电/天空）时退化为直接平滑辐亮度。
// @notice 天空（未命中）像素只用空间核平滑；天空与表面交界不混合。
pub fn denoiseAtrous(
    alloc: Allocator,
    image: []Color,
    guides: []const Guide,
    width: usize,
    height: usize,
    options: AtrousOptions,
) Allocator.Error!void {
    if (width == 0 or height == 0 or options.scales == 0) return;
    try fireflyClamp(alloc, image, width, height);
    const w: isize = @intCast(width);
    const h: isize = @intCast(height);

    // 分离光照：illumination = radiance / albedo，金属/天空等低反照率像素退化为 radiance。
    const illum = try alloc.alloc(Color, image.len);
    defer alloc.free(illum);
    separateIllumination(image, guides, illum);

    // 预滤波亮度引导（可选）：5x5 盒式模糊把方差降低约 25 倍，避免亮度引导被噪声主导。
    const guide_lum: ?[]f64 = if (options.sigma_luminance > 0) blk: {
        const gl = try alloc.alloc(f64, image.len);
        var y: usize = 0;
        while (y < height) : (y += 1) {
            var x: usize = 0;
            while (x < width) : (x += 1) {
                var sum: f64 = 0;
                var count: usize = 0;
                var dy: isize = -2;
                while (dy <= 2) : (dy += 1) {
                    const ny = @as(isize, @intCast(y)) + dy;
                    if (ny < 0 or ny >= h) continue;
                    var dx: isize = -2;
                    while (dx <= 2) : (dx += 1) {
                        const nx = @as(isize, @intCast(x)) + dx;
                        if (nx < 0 or nx >= w) continue;
                        sum += luminance(illum[@intCast(ny * w + nx)]);
                        count += 1;
                    }
                }
                gl[y * width + x] = sum / @as(f64, @floatFromInt(count));
            }
        }
        break :blk gl;
    } else null;
    defer if (guide_lum) |gl| alloc.free(gl);

    // 多尺度 à-trous 平滑光照。
    try atrousPass(alloc, illum, guides, width, height, options, guide_lum);

    // 重建辐亮度：radiance = 平滑后的 illumination × albedo。
    reconstructRadiance(illum, guides, image);
}

// @brief 在光照（或辐亮度）缓冲上执行多尺度 à-trous 卷积；guide_lum 可选。
fn atrousPass(
    alloc: Allocator,
    buf: []Color,
    guides: []const Guide,
    width: usize,
    height: usize,
    options: AtrousOptions,
    guide_lum: ?[]const f64,
) Allocator.Error!void {
    const w: isize = @intCast(width);
    const h: isize = @intCast(height);
    const tmp = try alloc.alloc(Color, buf.len);
    defer alloc.free(tmp);
    const kernel = [5]f64{ 1.0 / 16.0, 4.0 / 16.0, 6.0 / 16.0, 4.0 / 16.0, 1.0 / 16.0 };
    var scale: u32 = 0;
    while (scale < options.scales) : (scale += 1) {
        const step: isize = @as(isize, 1) << @intCast(scale);
        @memcpy(tmp, buf);
        var y: usize = 0;
        while (y < height) : (y += 1) {
            var x: usize = 0;
            while (x < width) : (x += 1) {
                const idx = y * width + x;
                const center = tmp[idx];
                const gc = guides[idx];
                var sum = Color{};
                var weight_sum: f64 = 0;
                var ky: usize = 0;
                while (ky < 5) : (ky += 1) {
                    const ny = @as(isize, @intCast(y)) + (@as(isize, @intCast(ky)) - 2) * step;
                    if (ny < 0 or ny >= h) continue;
                    var kx: usize = 0;
                    while (kx < 5) : (kx += 1) {
                        const nx = @as(isize, @intCast(x)) + (@as(isize, @intCast(kx)) - 2) * step;
                        if (nx < 0 or nx >= w) continue;
                        const ni: usize = @intCast(ny * w + nx);
                        const gi = guides[ni];
                        var weight = kernel[ky] * kernel[kx];
                        if (gc.hit and gi.hit) {
                            weight *= gaussian(albedoDiff(gc.albedo, gi.albedo), options.sigma_albedo);
                            weight *= gaussian(1.0 - math.clamp(gc.normal.dot(gi.normal), -1.0, 1.0), options.sigma_normal);
                            weight *= gaussian(relativeDepthDiff(gc.depth, gi.depth), options.sigma_depth);
                            if (guide_lum) |gl| {
                                if (options.sigma_luminance > 0) weight *= gaussian(relativeDiff(gl[idx], gl[ni]), options.sigma_luminance);
                            }
                        } else if (gc.hit != gi.hit) {
                            continue;
                        }
                        sum = sum.add(tmp[ni].scale(weight));
                        weight_sum += weight;
                    }
                }
                buf[idx] = if (weight_sum > 0) sum.scale(1.0 / weight_sum) else center;
            }
        }
    }
}

// @brief 把辐亮度拆成 illumination=radiance/albedo；低反照率像素退化为 radiance。
fn separateIllumination(image: []const Color, guides: []const Guide, out: []Color) void {
    for (image, 0..) |c, i| {
        const g = guides[i];
        if (g.hit and albedoLuma(g.albedo) > 0.01) {
            out[i] = Color.init(
                c.x / (g.albedo.x + 1e-6),
                c.y / (g.albedo.y + 1e-6),
                c.z / (g.albedo.z + 1e-6),
            );
        } else {
            out[i] = c;
        }
    }
}

// @brief 重建 radiance=illumination*albedo；低反照率像素保持 illumination。
fn reconstructRadiance(illum: []const Color, guides: []const Guide, out: []Color) void {
    for (illum, 0..) |il, i| {
        const g = guides[i];
        if (g.hit and albedoLuma(g.albedo) > 0.01) {
            out[i] = Color.init(il.x * g.albedo.x, il.y * g.albedo.y, il.z * g.albedo.z);
        } else {
            out[i] = il;
        }
    }
}

fn albedoLuma(albedo: Color) f64 {
    return 0.2126 * albedo.x + 0.7152 * albedo.y + 0.0722 * albedo.z;
}

// @brief 3x3 中值参考 + 火焰点截断：只把超出局部中值 factor 倍的像素截断，普通像素保持不变。
// @notice 比全量中值替换更保守，去掉孤立亮斑的同时不拉低整体亮度。
fn fireflyClamp(alloc: Allocator, image: []Color, width: usize, height: usize) Allocator.Error!void {
    const factor: f64 = 4.0;
    const buf = try alloc.alloc(Color, image.len);
    defer alloc.free(buf);
    const w: isize = @intCast(width);
    const h: isize = @intCast(height);
    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            var rs: [9]f64 = undefined;
            var gs: [9]f64 = undefined;
            var bs: [9]f64 = undefined;
            var count: usize = 0;
            var dy: isize = -1;
            while (dy <= 1) : (dy += 1) {
                const ny = @as(isize, @intCast(y)) + dy;
                if (ny < 0 or ny >= h) continue;
                var dx: isize = -1;
                while (dx <= 1) : (dx += 1) {
                    const nx = @as(isize, @intCast(x)) + dx;
                    if (nx < 0 or nx >= w) continue;
                    const c = image[@intCast(ny * w + nx)];
                    rs[count] = c.x;
                    gs[count] = c.y;
                    bs[count] = c.z;
                    count += 1;
                }
            }
            sortF64(rs[0..count]);
            sortF64(gs[0..count]);
            sortF64(bs[0..count]);
            const mid = count / 2;
            const c = image[y * width + x];
            buf[y * width + x] = Color.init(
                @min(c.x, rs[mid] * factor),
                @min(c.y, gs[mid] * factor),
                @min(c.z, bs[mid] * factor),
            );
        }
    }
    @memcpy(image, buf);
}

fn luminance(c: Color) f64 {
    return 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z;
}

fn relativeDiff(a: f64, b: f64) f64 {
    const denom = @max(@max(a, b), 1e-6);
    return @abs(a - b) / denom;
}

// @brief 小规模插入排序，用于 3x3 中值滤波取中间值。
fn sortF64(values: []f64) void {
    var i: usize = 1;
    while (i < values.len) : (i += 1) {
        const key = values[i];
        var j = i;
        while (j > 0 and values[j - 1] > key) : (j -= 1) values[j] = values[j - 1];
        values[j] = key;
    }
}
