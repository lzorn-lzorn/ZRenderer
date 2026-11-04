const std = @import("std");
const math = @import("math.zig");
const material = @import("material.zig");
const HitRecord = @import("object.zig").HitRecord;
const Vec3 = math.Vec3;
const Point3 = math.Point3;
const Ray = math.Ray;

// @brief 固定方向、权重、频率比例及相位；不读取随机状态或时间。
const Wave = struct { direction: Vec3, weight: f64, scale: f64, phase: f64 };
const waves = [_]Wave{
    .{ .direction = .{ .x = 1, .y = 0, .z = 0 }, .weight = 0.32, .scale = 1, .phase = 0.3 },
    .{ .direction = .{ .x = 0, .y = 0.6, .z = 0.8 }, .weight = 0.27, .scale = 0.73, .phase = 1.7 },
    .{ .direction = .{ .x = -0.8, .y = 0.6, .z = 0 }, .weight = 0.23, .scale = 0.47, .phase = 2.8 },
    .{ .direction = .{ .x = 0.36, .y = -0.48, .z = 0.8 }, .weight = 0.18, .scale = 1.31, .phase = 4.1 },
};

// @brief 静态星形水球；真实表面、几何法线和 UV 使用同一径向波场。
// @method **曲面**：$F(q)=\rho-1-aW(n)$，$q=(p-c)/R,\rho=|q|,n=q/\rho$。
// @method $W(n)=\sum_i w_i\sin(k_i d_i\cdot n+\phi_i)$，$k_i=f s_i,\sum_i w_i=1$。
// @notice 因而 $R(1-a)\le|p-c|\le R(1+a)$，无缝、封闭且不会产生多层径向边界。
// @notice 使用 init 验证参数，不应直接改写成员；材质借用，求交不分配内存。
pub const WavySphere = struct {
    center: Point3,
    radius: f64,
    amplitude: f64,
    frequency: f64,
    material: *material.Material,

    // @brief 每次查询的硬上限；正常射线远低于此值，耗尽时不伪造交点。
    pub const max_nodes = 32768;
    pub const max_depth = 64;
    // @notice 世界位置细分目标 1e-12，远小于父级 spawnRay 的 1e-8 偏移。
    pub const point_tolerance: f64 = 1e-12;
    const roundoff: f64 = 16 * std.math.floatEps(f64);

    // @brief 验证有限球心、正半径、振幅比例与频率，建立水球值。
    // @param amplitude 范围 [0,0.1]；frequency 范围 [0,40]；mat 为借用指针。
    // @return 水球值或 InvalidWavySphere，不发生分配。
    pub fn init(center: Point3, radius: f64, amplitude: f64, frequency: f64, mat: *material.Material) !WavySphere {
        if (!finite(center) or !std.math.isFinite(radius) or radius <= 0 or
            !std.math.isFinite(amplitude) or amplitude < 0 or amplitude > 0.1 or
            !std.math.isFinite(frequency) or frequency < 0 or frequency > 40)
            return error.InvalidWavySphere;
        const extent = radius * (1 + amplitude + 64 * std.math.floatEps(f64));
        if (!std.math.isFinite(extent) or !finite(center.addScalar(extent)) or !finite(center.subScalar(extent)))
            return error.InvalidWavySphere;
        return .{ .center = center, .radius = radius, .amplitude = amplitude, .frequency = frequency, .material = mat };
    }

    const Field = struct { value: f64, gradient: Vec3 };

    // @brief 同时计算无量纲隐式值和关于 q 的解析梯度。
    // @method **真法线**：$g=\sum_i w_i k_i\cos(k_i d_i\cdot n+\phi_i)d_i$，$\nabla_q F=n-a(g-n(n\cdot g))/\rho$。
    // @notice 梯度径向分量恒为 1，不会在表面退化；球心仅返回内部占位值，不用于法线。
    fn field(self: WavySphere, q: Vec3) Field {
        const rho = q.length();
        if (rho == 0) return .{ .value = -1, .gradient = .{} };
        const n = q.div(rho);
        var w: f64 = 0;
        var g: Vec3 = .{};
        for (waves) |wave| {
            const k = self.frequency * wave.scale;
            const phase = k * wave.direction.dot(n) + wave.phase;
            w += wave.weight * @sin(phase);
            g = g.add(wave.direction.scale(wave.weight * k * @cos(phase)));
        }
        return .{ .value = rho - 1 - self.amplitude * w, .gradient = n.sub(g.sub(n.scale(n.dot(g))).scale(self.amplitude / rho)) };
    }

    // @brief 世界空间隐式值（长度单位），用于诊断与有限差分验证；不是精确有符号距离。
    // @param p 世界空间点；球心处为内部占位值。
    // @return 负值在水球内，正值在外，零值是真实表面。
    pub fn implicitValue(self: WavySphere, p: Point3) f64 {
        return self.radius * self.field(p.sub(self.center).div(self.radius)).value;
    }

    // @brief 返回真实表面的解析外向单位几何法线，而不是 bump 法线。
    // @param p 非球心的表面点。
    // @return 归一化解析梯度。
    pub fn outwardNormal(self: WavySphere, p: Point3) Vec3 {
        return self.field(p.sub(self.center).div(self.radius)).gradient.normalized();
    }

    // @brief 由单位方向直接得到真实径向表面点，供检查轮廓和测试使用。
    // @param direction 任意非零有限方向。
    // @return 对应方向上的唯一表面点。
    pub fn surfacePoint(self: WavySphere, direction: Vec3) Point3 {
        const n = direction.normalized();
        return self.center.add(n.scale(self.radius * (1 - self.field(n).value)));
    }

    // @brief 全局二阶导数界；仅用于不穿越内球的射线区间。
    // @method $\|D^2F\|\le H=1/r_-+a\sum_i w_i(k_i^2+6|k_i|)/r_-^2$，$r_-=1-a$。
    // @method 由 $\|Dn\|\le1/\rho,\|D^2n\|\le6/\rho^2$ 和链式法则得到保守界。
    fn hessianBound(self: WavySphere) f64 {
        const inner = 1 - self.amplitude;
        var bound: f64 = 0;
        for (waves) |wave| {
            const k = self.frequency * wave.scale;
            bound += wave.weight * (k * k + 6 * k);
        }
        return (1 / inner + self.amplitude * bound / (inner * inner)) * (1 + 64 * std.math.floatEps(f64));
    }

    const Interval = struct { lo: f64, hi: f64, depth: usize = 0 };

    // @brief 统一无量纲区间容差，保持普通尺度下的世界误差远小于 1e-8。
    fn parameterTolerance(self: WavySphere) f64 {
        return @max(32 * std.math.floatEps(f64), point_tolerance / @max(1, self.radius));
    }

    // @brief 接受数值上恰在闭区间端点的穿越根；同时约束残差及牛顿位置误差，不能只按近表面距离命中。
    fn endpointRoot(self: WavySphere, sample: Field, d: Vec3) bool {
        if (sample.value == 0) return true;
        const slope = @abs(sample.gradient.dot(d));
        return @abs(sample.value) <= roundoff and @abs(sample.value) <= slope * self.parameterTolerance();
    }

    // @brief 用二阶泰勒包络从近到远隔离根；禁止以粗糙的距离阈值直接宣告命中。
    // @method **排除证书**：区间中点 m、半宽 h 满足 $|F(m)|>|F'(m)|h+Hh^2/2+\epsilon_f$ 时无根。
    // @method 剩余区间按左、右次序二分；小区间内细化符号根，切点则细化 $F'=0$ 并验证 $|F|\le\epsilon_f$。
    // @notice 固定栈 65 个区间，最多 32768 个节点、64 层；预算耗尽返回 null，不返回未收敛伪根。
    fn search(self: WavySphere, foot: Vec3, d: Vec3, interval: Interval, budget: *usize) ?f64 {
        var stack: [max_depth + 1]Interval = undefined;
        stack[0] = interval;
        var count: usize = 1;
        const hessian = self.hessianBound();
        const tolerance = self.parameterTolerance();
        while (count > 0 and budget.* > 0) {
            budget.* -= 1;
            count -= 1;
            const current = stack[count];
            const mid = current.lo + (current.hi - current.lo) * 0.5;
            const half = (current.hi - current.lo) * 0.5;
            const sample = self.field(foot.add(d.scale(mid)));
            const derivative = sample.gradient.dot(d);
            if (@abs(sample.value) > @abs(derivative) * half + 0.5 * hessian * half * half + roundoff) continue;
            // @method 若 $|F'(m)|>Hh$，整段严格单调；同号端点立即排除，避免切点附近舍入带的指数细分。
            if (@abs(derivative) > hessian * half) {
                const left = self.field(foot.add(d.scale(current.lo)));
                const right = self.field(foot.add(d.scale(current.hi)));
                if (self.endpointRoot(left, d)) return current.lo;
                if (self.endpointRoot(right, d)) return current.hi;
                if ((left.value < 0) == (right.value < 0)) continue;
            }
            if (current.hi - current.lo <= tolerance or mid == current.lo or mid == current.hi) {
                if (self.refine(foot, d, current.lo, current.hi)) |root| return root;
                continue;
            }
            if (current.depth == max_depth) return null;
            stack[count] = .{ .lo = mid, .hi = current.hi, .depth = current.depth + 1 };
            stack[count + 1] = .{ .lo = current.lo, .hi = mid, .depth = current.depth + 1 };
            count += 2;
        }
        return null;
    }

    // @brief 在已隔离的极小区间内细化穿越根或驻点；两端同号且无驻点时拒绝近表面伪命中。
    fn refine(self: WavySphere, foot: Vec3, d: Vec3, lower: f64, upper: f64) ?f64 {
        var lo = lower;
        var hi = upper;
        const left = self.field(foot.add(d.scale(lo)));
        const right = self.field(foot.add(d.scale(hi)));
        if (self.endpointRoot(left, d)) return lo;
        if (self.endpointRoot(right, d)) return hi;
        const crossing = (left.value < 0) != (right.value < 0);
        const left_derivative = left.gradient.dot(d);
        const right_derivative = right.gradient.dot(d);
        if (!crossing and (left_derivative < 0) == (right_derivative < 0) and left_derivative != 0 and right_derivative != 0) return null;
        for (0..48) |_| {
            const mid = lo + (hi - lo) * 0.5;
            if (mid == lo or mid == hi) break;
            const value = self.field(foot.add(d.scale(mid)));
            const before = if (crossing) (value.value < 0) == (left.value < 0) else (value.gradient.dot(d) < 0) == (left_derivative < 0);
            if (before) lo = mid else hi = mid;
        }
        const root = lo + (hi - lo) * 0.5;
        return if (crossing or @abs(self.field(foot.add(d.scale(root))).value) <= roundoff) root else null;
    }

    // @brief 查询闭区间内最近命中；射线允许来自内外部，方向无需归一化，时间不影响静态波场。
    // @param r 有限原点与非零有限方向；t_min/t_max 可为无穷但不能为 NaN。
    // @param rec 成功写入真实位置、UV、借用材质以及朝向入射侧的解析几何法线。
    // @return 是否存在已收敛交点；非法射线或预算耗尽返回 false。
    // @method **球壳裁剪**：在单位方向上以最近点为参数原点，先裁剪外球，再跳过严格位于内球的区间。
    // @notice 不使用固定 t epsilon；只在距离坐标求根，再换回原射线参数，避免方向缩放改变精度。
    pub fn hit(self: WavySphere, r: Ray, t_min: f64, t_max: f64, rec: *HitRecord) bool {
        if (!finite(r.origin) or !finite(r.direction) or std.math.isNan(t_min) or std.math.isNan(t_max) or t_min > t_max) return false;
        const scale = @max(@abs(r.direction.x), @max(@abs(r.direction.y), @abs(r.direction.z)));
        if (scale == 0) return false;
        const scaled = r.direction.div(scale);
        const length = scaled.length();
        const d = scaled.div(length);
        const origin = r.origin.sub(self.center).div(self.radius);
        if (!finite(origin)) return false;
        const b = origin.dot(d);
        const foot = d.cross(origin.cross(d));
        const distance2 = foot.lengthSquared();
        const outer = 1 + self.amplitude + 64 * std.math.floatEps(f64);
        const gap = outer * outer - distance2;
        if (!(gap >= 0)) return false;
        const extent = @sqrt(gap);
        const lo = @max(-extent, (t_min * scale / self.radius) * length + b);
        const hi = @min(extent, (t_max * scale / self.radius) * length + b);
        if (lo > hi) return false;
        var root: ?f64 = null;
        if (self.amplitude == 0) {
            // @notice 零振幅采用精确球二次根，包括真正切线；不将负判别式钳为零。
            const sphere_gap = 1 - distance2;
            if (sphere_gap < 0) return false;
            const delta = @sqrt(sphere_gap);
            for ([_]f64{ -delta, delta }) |candidate| {
                if (candidate >= lo and candidate <= hi) {
                    root = candidate;
                    break;
                }
            }
        } else {
            var budget: usize = max_nodes;
            const inner_gap = (1 - self.amplitude) * (1 - self.amplitude) - distance2;
            if (inner_gap > 0) {
                const cut = @sqrt(inner_gap);
                if (lo <= -cut) root = self.search(foot, d, .{ .lo = lo, .hi = @min(hi, -cut) }, &budget);
                if (root == null and hi >= cut and budget > 0) root = self.search(foot, d, .{ .lo = @max(lo, cut), .hi = hi }, &budget);
            } else {
                root = self.search(foot, d, .{ .lo = lo, .hi = hi }, &budget);
            }
        }
        const x = root orelse return false;
        const raw_t = (((x - b) * self.radius) / length) / scale;
        if (!std.math.isFinite(raw_t)) return false;
        const t = math.clamp(raw_t, t_min, t_max);
        // @notice 参数坐标转换可使闭区间端点越界数个 ulp；仅允许位置容差内的舍入回夹。
        if (@abs(((t - raw_t) * scale / self.radius) * length) > self.parameterTolerance()) return false;
        const q = foot.add(d.scale(x));
        const n = q.normalized();
        rec.* = .{
            .t = t,
            .p = self.center.add(q.scale(self.radius)),
            .u = (std.math.atan2(-n.z, n.x) + math.pi) / (2 * math.pi),
            .v = std.math.acos(math.clamp(-n.y, -1, 1)) / math.pi,
            .material = self.material,
        };
        rec.setFaceNormal(r, self.field(q).gradient.normalized());
        return true;
    }

    // @brief 返回带舍入余量的保守静态外 AABB；覆盖全部波峰且适合现有 BVH。
    // @param t0/t1 被忽略，水球不随时间移动。
    // @return 始终成功（前提是由 init 构造）。
    pub fn boundingBox(self: WavySphere, t0: f64, t1: f64, out: *math.Aabb) bool {
        _ = t0;
        _ = t1;
        const extent = self.radius * (1 + self.amplitude + 64 * std.math.floatEps(f64));
        out.* = math.Aabb.init(self.center.subScalar(extent), self.center.addScalar(extent));
        return true;
    }
};

// @brief 检查所有分量，拒绝 NaN/无穷传播。
fn finite(v: Vec3) bool {
    return std.math.isFinite(v.x) and std.math.isFinite(v.y) and std.math.isFinite(v.z);
}
