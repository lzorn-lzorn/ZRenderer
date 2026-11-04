const std = @import("std");
const math = @import("math.zig");
const bsdf = @import("bsdf.zig");
const random = @import("random.zig");
const object = @import("object.zig");
const Vec3 = math.Vec3;
const Color = math.Color;

// @brief 点光源的 RGB 辐射强度；场景距离采用米，照度随距离平方衰减。
pub const PointLight = struct { position: Vec3, intensity: Color };

// @brief 理想无限远光源；direction 表示光传播方向，radiance 表示垂直入射辐照度系数。
// @notice delta 光源不具备普通立体角辐亮度密度；字段为积分后的方向分布权重。
pub const DistantLight = struct { direction: Vec3, radiance: Color };

// @brief 光源样本；连续方向需沿阴影射线求可见辐亮度，delta 样本直接给出能量。
// @param pdf 已包含选光概率；连续样本为立体角密度，delta 为离散概率。
// @param distance 点光源的距离；方向光和连续方向使用无穷远。
pub const Sample = struct {
    direction: Vec3,
    pdf: f64,
    is_delta: bool = false,
    radiance: Color = .{},
    distance: f64 = math.infinity,
};

// @brief 不拥有内存的只读光源集合，可在线程间共享。
// @param area 可采样形状或组，应同时包含于 world；运动求值与光线使用相同时间。
// @param sample_environment 是否为非黑恒定环境增加均匀球面提议；关闭不影响环境可见性。
// @notice 面光源采用方向空间估计：先选方向，再评价该方向上首个可见表面的发光或环境。
pub const Sampler = struct {
    area: ?*object.Object = null,
    background: Color = .{},
    sample_environment: bool = false,
    points: []const PointLight = &.{},
    distant: []const DistantLight = &.{},

    // @brief 检查有限非负光强与有效方向；渲染开始前调用，工作线程不重复验证。
    pub fn valid(self: Sampler) bool {
        if (!validRadiance(self.background)) return false;
        for (self.points) |p| {
            if (!finiteVector(p.position) or !validRadiance(p.intensity)) return false;
        }
        for (self.distant) |d| {
            if (bsdf.unit(d.direction) == null or !validRadiance(d.radiance)) return false;
        }
        return true;
    }

    fn environmentEnabled(self: Sampler) bool {
        return self.sample_environment and (self.background.x > 0 or self.background.y > 0 or self.background.z > 0);
    }

    // @brief 形状组、环境各占一个候选，每个 delta 光源各占一个候选。
    pub fn count(self: Sampler) usize {
        return @as(usize, @intFromBool(self.area != null)) + @as(usize, @intFromBool(self.environmentEnabled())) + self.points.len + self.distant.len;
    }

    // @brief 返回完整连续方向密度；delta 的离散质量不加入方向密度，但计入选光分母。
    // @method 若候选数为 $K$，则 $p_L(\omega)=\frac1K[p_A(\omega)+\mathbf1_E/(4\pi)]$。
    // @method 形状组内部还包含自己的选形状概率；与 BSDF 比较时必须使用完整 $p_L$。
    pub fn pdf(self: Sampler, origin: Vec3, direction: Vec3, time: f64) f64 {
        const n = self.count();
        if (n == 0 or bsdf.unit(direction) == null) return 0;
        var density: f64 = if (self.environmentEnabled()) 1 / (4 * math.pi) else 0;
        if (self.area) |area| density += area.pdfValueAt(origin, direction, time);
        return density / @as(f64, @floatFromInt(n));
    }

    // @brief 等概率选光并返回一个样本；无效或零距离样本保留为零贡献，不重新抽样。
    // @method 点光源使用 $L=I/r^2$，估计量为 $fL|n\cdot\omega|/p_{select}$。
    // @notice 连续样本的辐亮度在积分器中求值，因此自动处理遮挡、背面发光和重叠方向。
    pub fn sample(self: Sampler, origin: Vec3, time: f64) ?Sample {
        const n = self.count();
        if (n == 0) return null;
        var index: usize = @min(n - 1, @as(usize, @intFromFloat(random.randomDouble() * @as(f64, @floatFromInt(n)))));
        const selection = 1 / @as(f64, @floatFromInt(n));
        if (self.area) |area| {
            if (index == 0) {
                const wi = bsdf.unit(area.randomAt(origin, time)) orelse return null;
                const density = self.pdf(origin, wi, time);
                if (!(density > 0) or !std.math.isFinite(density)) return null;
                return .{ .direction = wi, .pdf = density };
            }
            index -= 1;
        }
        if (self.environmentEnabled()) {
            if (index == 0) {
                const z = 1 - 2 * random.randomDouble();
                const phi = 2 * math.pi * random.randomDouble();
                const r = @sqrt(@max(0, 1 - z * z));
                const wi = Vec3.init(r * @cos(phi), r * @sin(phi), z);
                return .{ .direction = wi, .pdf = self.pdf(origin, wi, time) };
            }
            index -= 1;
        }
        if (index < self.points.len) {
            const point = self.points[index];
            const delta = point.position.sub(origin);
            const wi = bsdf.unit(delta) orelse return null;
            // @notice 先缩放再求范数，避免可表示的大距离因平方和溢出而被错误拒绝。
            const scale = @max(@abs(delta.x), @max(@abs(delta.y), @abs(delta.z)));
            const scaled = Vec3.init(delta.x / scale, delta.y / scale, delta.z / scale);
            const distance = scale * @sqrt(scaled.lengthSquared());
            if (!(distance > 0) or !std.math.isFinite(distance)) return null;
            const intensity = point.intensity.scale(1 / distance).scale(1 / distance);
            if (!validRadiance(intensity)) return null;
            return .{ .direction = wi, .pdf = selection, .is_delta = true, .radiance = intensity, .distance = distance };
        }
        const distant = self.distant[index - self.points.len];
        return .{ .direction = (bsdf.unit(distant.direction) orelse return null).neg(), .pdf = selection, .is_delta = true, .radiance = distant.radiance };
    }
};

// @brief 幂启发式 MIS；使用缩放后的比值避免直接平方大 PDF 导致溢出。
// @method 每种策略各一个样本，$w_a=p_a^2/(p_a^2+p_b^2)$，同一方向的两权重和为一。
// @notice 不将 delta 离散概率与连续方向 PDF 比较；delta 样本权重在调用处直接设为一。
pub fn powerHeuristic(a: f64, b: f64) f64 {
    if (!(a > 0)) return 0;
    if (!(b > 0)) return 1;
    const scale = @max(a, b);
    const x = a / scale;
    const y = b / scale;
    return x * x / (x * x + y * y);
}

// @brief 检查任意非负 HDR RGB，允许大于一但不允许负数、NaN 或无穷。
pub fn validRadiance(c: Color) bool {
    return finiteVector(c) and c.x >= 0 and c.y >= 0 and c.z >= 0;
}

fn finiteVector(v: Vec3) bool {
    return std.math.isFinite(v.x) and std.math.isFinite(v.y) and std.math.isFinite(v.z);
}
