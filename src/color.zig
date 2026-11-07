const std = @import("std");
const math = @import("math.zig");
const random = @import("random.zig");
const object = @import("object.zig");
const light = @import("light.zig");
const medium_mod = @import("medium.zig");

const Color = math.Color;
const Ray = math.Ray;
const HitRecord = object.HitRecord;

// @brief 将线性 RGB 平均值编码为显示字节：先 ACES 色调映射，再做 gamma 2.2。
// @param samples_per_pixel 实际累积样本数；out 至少包含三个字节。
// @notice 色调映射把高动态范围平滑压到 [0,1]，避免高光被硬裁成纯白。
pub fn writeColor(out: []u8, pixel: Color, samples_per_pixel: i32) void {
    std.debug.assert(samples_per_pixel > 0 and out.len >= 3);
    const scale = 1.0 / @as(f64, @floatFromInt(samples_per_pixel));
    for (0..3) |i| {
        const linear = pixel.at(i) * scale;
        const safe = if (std.math.isNan(linear) or linear < 0) 0 else linear;
        const tonemapped = acesFilm(safe);
        const encoded = if (tonemapped <= 0) 0 else math.pow(tonemapped, 1.0 / 2.2);
        out[i] = @intFromFloat(256 * math.clamp(encoded, 0, 0.999));
    }
}

// @brief ACES 电影色调映射（Stephen Hill 拟合曲线），把线性 HDR 平滑映射到 [0,1]。
// @notice 高光按渐近线滚向 1.0 而不是硬裁，保留亮部层次。
pub fn acesFilm(x: f64) f64 {
    if (!std.math.isFinite(x)) return if (x < 0) 0 else 1;
    const a = 2.51;
    const b = 0.03;
    const c = 2.43;
    const d = 0.59;
    const e = 0.14;
    const num = x * (a * x + b);
    const den = x * (c * x + d) + e;
    return math.clamp(num / den, 0.0, 1.0);
}

// @brief 沿几何法线偏移射线起点，偏移方向由目标方向所在半球确定。
// @param normal 当前仅支持几何法线；加入法线贴图后不能用着色法线代替。
// @notice 相对误差项加小绝对下限改善米尺度细毛与大球共存；不是逐次运算的严格误差界。
pub fn spawnRay(p: math.Point3, normal: math.Vec3, direction: math.Vec3, time: f64) Ray {
    const magnitude = @max(@abs(p.x), @max(@abs(p.y), @abs(p.z)));
    const offset = @max(1e-8, 32 * math.epsilon * magnitude);
    const side: f64 = if (normal.dot(direction) >= 0) 1 else -1;
    return Ray.init(p.add(normal.scale(side * offset)), direction, time);
}

// @brief 显式光照连接；连续方向取首个可见表面的发光，delta 使用有限区间遮挡检测。
// @method $\widehat L_{NEE}=f_s(\omega_o,\omega_i)L_i|n\cdot\omega_i|w_L/p_L$。
// @method 连续 $w_L=p_L^2/(p_L^2+p_B^2)$；delta 方向不能由连续 BSDF 命中，因此 $w_L=1$。
// @notice 玻璃也遮挡这条直线阴影连接；穿过折射界面的光须由路径追踪采样。
fn directLighting(incoming: Ray, rec: *const HitRecord, world: *object.BvhNode, lights: light.Sampler) Color {
    const sample = lights.sample(rec.p, incoming.time) orelse return .{};
    const mat = rec.material.?;
    const f = mat.bsdfEval(incoming, rec, sample.direction);
    const cosine = @abs(rec.normal.dot(sample.direction));
    if (cosine == 0 or (f.x == 0 and f.y == 0 and f.z == 0)) return .{};
    const shadow = spawnRay(rec.p, rec.normal, sample.direction, incoming.time);
    var hit: HitRecord = .{};
    var incident: Color = .{};
    if (sample.is_delta) {
        const offset_along_ray = shadow.origin.sub(rec.p).dot(sample.direction);
        const max_t = sample.distance - offset_along_ray - 1e-8;
        if (max_t <= 0 or world.hit(shadow, 0, max_t, &hit)) return .{};
        incident = sample.radiance;
    } else if (world.hit(shadow, 0, math.infinity, &hit)) {
        incident = hit.material.?.emitted5(shadow, &hit, hit.u, hit.v, hit.p);
    } else {
        incident = lights.radiance(sample.direction);
    }
    const weight = if (sample.is_delta) 1 else light.powerHeuristic(sample.pdf, mat.bsdfPdf(incoming, rec, sample.direction));
    return f.mul(incident).scale(cosine * weight / sample.pdf);
}

// @brief 相机主射线首个表面交点的降噪辅助数据（G-buffer）。
pub const PrimaryHit = struct {
    albedo: Color = .{},
    normal: math.Vec3 = .{},
    depth: f64 = 0,
    hit: bool = false,
};

// @brief 统一 BSDF、下一事件估计和 MIS 的非递归路径积分器。
// @param depth 开始俄罗斯轮盘的散射次数，不是最大反弹数；rr 为存活概率上限。
// @param lights 恒定环境、面光源以及可选点光源/方向光的只读集合。
pub fn rayColorLit(r: Ray, world: *object.BvhNode, lights: light.Sampler, depth: i32, rr: f64) Color {
    return rayColorLitInner(r, world, lights, depth, rr, null);
}

// @brief 与 rayColorLit 相同，但可选输出主射线首个表面交点的 albedo/normal/depth。
// @param primary 非空时写入首个命中；供降噪器的联合双边滤波使用。
pub fn rayColorLitPrimary(r: Ray, world: *object.BvhNode, lights: light.Sampler, depth: i32, rr: f64, primary: ?*PrimaryHit) Color {
    return rayColorLitInner(r, world, lights, depth, rr, primary);
}

// @method 路径通量 $\beta\leftarrow\beta f_s|n\cdot\omega|/p_B$，delta 使用其离散权重。
// @method BSDF 路径命中光源时乘 $w_B=p_B^2/(p_B^2+p_L^2)$，与上一顶点 NEE 的 $w_L$ 互补。
// @method 相机直接可见发光和 delta 链后的发光权重为一；直接光照在轮盘之前累积。
// @method 透射样本含 $\eta^2$；轮盘使用 $\beta/\prod\eta^2$，避免误杀进入玻璃的路径。
// @method 存活概率 $q=\min(rr,\max(0.05,\max_c\beta_c\,\eta_{scale}))$，仅存活路径除以 $q$。
// @method **内部随机游走**：$D\sim\mathrm{Exp}(\sigma_s)$，只乘 $\exp(-\sigma_a\min(D,L))$；散射概率已包含在自由程分布中。
// @method 若 $D<L$，在实际内部位置按 HG 相函数采样，$p_{HG}/q_{HG}=1$；不附加表面余弦或重复乘散射消光。
// @notice 支持分离闭合抛光物体的均匀体散射及相机初始位于其内部；不支持重叠/嵌套介质或介质内嵌物体。
// @notice 体积顶点不做穿折射界面的 NEE；必须随机游走至边界离开，因此不对体积方向应用未配对的光源 MIS。
fn rayColorLitInner(r: Ray, world: *object.BvhNode, lights: light.Sampler, depth: i32, rr: f64, primary: ?*PrimaryHit) Color {
    std.debug.assert(rr > 0 and rr < 1);
    var ray = r;
    var radiance: Color = .{};
    var throughput = Color.init(1, 1, 1);
    var remaining: i32 = @max(depth, 0);
    var previous_uses_mis = false;
    var previous_pdf: f64 = 0;
    var previous_origin = r.origin;
    var eta_scale: f64 = 1;
    var active_medium: ?*const medium_mod.Homogeneous = null;
    var first_segment = true;

    while (true) {
        var rec: HitRecord = .{};
        const found = world.hit(ray, 0, math.infinity, &rec);
        // @notice 首个交点用于降噪 G-buffer；只记录第一次命中的表面属性。
        if (first_segment and found) {
            if (primary) |out| {
                const direction_length = ray.direction.length();
                out.* = .{
                    .albedo = rec.material.?.albedo(&rec),
                    .normal = rec.normal,
                    .depth = rec.t * direction_length,
                    .hit = true,
                };
            }
        }
        // @notice 闭合且无嵌入几何时，第一交点背面意味着相机初始处于该介质内部。
        if (first_segment and found and !rec.front_face) active_medium = rec.material.?.interiorMedium();
        first_segment = false;
        if (active_medium) |medium| {
            // @notice 有界介质内必须存在出口；无出口属于无效/不受支持的几何，不能直接泄露环境光。
            if (!found) return radiance;
            const direction_length = ray.direction.length();
            if (!std.math.isFinite(direction_length) or direction_length <= 0) return radiance;
            const surface_distance = rec.t * direction_length;
            const distance = if (medium.sigma_s == 0) math.infinity else medium.sampleDistance(random.randomDouble());
            throughput = throughput.mul(medium.absorption(@min(distance, surface_distance)));
            if (distance < surface_distance) {
                const position = ray.at(distance / direction_length);
                const direction = medium.sampleDirection(ray.direction, random.randomDouble(), random.randomDouble());
                // @notice 无表面就没有法线偏移；此连续相函数没有配对 NEE，使用权重一而非套用表面 MIS。
                previous_uses_mis = false;
                previous_pdf = 0;
                previous_origin = position;
                ray = Ray.init(position, direction, ray.time);
                if (!continuePath(&throughput, &remaining, eta_scale, rr)) return radiance;
                continue;
            }
        }
        const emitted = if (found) rec.material.?.emitted5(ray, &rec, rec.u, rec.v, rec.p) else lights.radiance(ray.direction);
        const emission_weight = if (!previous_uses_mis) 1 else light.powerHeuristic(previous_pdf, lights.pdf(previous_origin, ray.direction, ray.time));
        radiance = radiance.add(throughput.mul(emitted).scale(emission_weight));
        if (!found) return radiance;
        const mat = rec.material.?;
        if (mat.hasNonDelta()) radiance = radiance.add(throughput.mul(directLighting(ray, &rec, world, lights)));
        const scatter = mat.bsdfSample(ray, &rec) orelse return radiance;
        throughput = throughput.mul(scatter.weight);
        // @notice 通过几何半球判断跨界，不能用 eta!=1：折射率匹配时仍须进入或离开吸收介质。
        if (mat.interiorMedium()) |medium| {
            if (scatter.direction.dot(rec.normal) < 0) active_medium = if (rec.front_face) medium else null;
        }
        previous_uses_mis = !scatter.is_delta;
        previous_pdf = scatter.pdf;
        previous_origin = rec.p;
        ray = spawnRay(rec.p, rec.normal, scatter.direction, ray.time);
        eta_scale /= scatter.eta * scatter.eta;
        if (!continuePath(&throughput, &remaining, eta_scale, rr)) return radiance;
    }
}

// @brief 表面与体积事件共享通量检查和俄罗斯轮盘；无硬性最大反弹数。
// @method $q=\min(rr,\max(0.05,\max_c\beta_c\eta_{scale}))$；存活后 $\beta\leftarrow\beta/q$。
fn continuePath(throughput: *Color, remaining: *i32, eta_scale: f64, rr: f64) bool {
    if (!light.validRadiance(throughput.*)) return false;
    const contribution = @max(throughput.x, @max(throughput.y, throughput.z));
    if (contribution <= 0) return false;
    if (remaining.* > 0) remaining.* -= 1;
    if (remaining.* == 0) {
        const survival = @min(rr, @max(0.05, contribution * eta_scale));
        if (random.randomDouble() >= survival) return false;
        throughput.* = throughput.scale(1 / survival);
    }
    return true;
}

// @brief 保留原主入口，将旧形状光源和背景适配到统一 NEE/MIS 积分器。
// @notice 默认不额外采样恒定环境；环境仍通过 BSDF 路径可见。
pub fn rayColor(r: Ray, background: Color, world: *object.BvhNode, lights: ?*object.Object, depth: i32, rr: f64) Color {
    return rayColorLit(r, world, .{ .area = lights, .background = background }, depth, rr);
}

// @brief 历史渐变天空接口，仅用于兼容；新场景应使用 rayColorLit。
// @notice 旧递归路径不包含新 PBR 闭包或 NEE，不能作为新模型的参考积分器。
pub fn rayColorWithBvh(r: Ray, world: *object.BvhNode, depth: i32, rr: f64) Color {
    var rec: HitRecord = .{};
    if (world.hit(r, 0.001, math.infinity, &rec)) {
        if (random.randomDouble() >= rr) return Color.init(0, 0, 0);
        var scattered: Ray = undefined;
        var attenuation: Color = undefined;
        if (rec.material.?.scatter(r, &rec, &attenuation, &scattered)) {
            return attenuation.mul(rayColorWithBvh(scattered, world, depth - 1, rr)).scale(1.0 / rr);
        }
        return Color.init(0, 0, 0);
    }
    const unit_direction = r.direction.normalized();
    const t = 0.5 * (unit_direction.y + 1.0);
    return Color.init(1, 1, 1).scale(1.0 - t).add(Color.init(0.5, 0.7, 1.0).scale(t));
}

// @brief 历史背景接口委托统一实现，避免重复维护错误的轮盘补偿。
pub fn rayColorWithBackground(r: Ray, background: Color, world: *object.BvhNode, depth: i32, rr: f64) Color {
    return rayColor(r, background, world, null, depth, rr);
}

// @brief 无 BVH 的历史递归参考路径，不支持新 PBR 闭包。
// @notice 轮盘只补偿存活的后续散射，不缩放当前表面发光；生产路径使用 rayColorLit。
pub fn rayColorWithoutBvh(r: Ray, background: Color, world: object.ObjectGroup, depth: i32, rr: f64) Color {
    var rec: HitRecord = .{};
    if (!world.hit(r, 0.001, math.infinity, &rec)) return background;

    var scattered: Ray = undefined;
    var attenuation: Color = undefined;
    const emitted = rec.material.?.emitted3(rec.u, rec.v, rec.p);
    if (!rec.material.?.scatter(r, &rec, &attenuation, &scattered)) return emitted;
    const survival: f64 = if (depth <= 0) rr else 1;
    if (random.randomDouble() >= survival) return emitted;
    return emitted.add(attenuation.mul(rayColorWithoutBvh(scattered, background, world, depth - 1, rr)).scale(1 / survival));
}
