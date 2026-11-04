const std = @import("std");
const math = @import("math.zig");
const Vec3 = math.Vec3;
const Point3 = math.Point3;

pub const default_seed: u64 = 0x1234_5678_9abc_def0;

// @notice 每个原生工作线程拥有独立伪随机数生成器，不共享可变状态，也不需要采样锁。
// @notice 线程局部存储本身不保证调度确定性；像素采样器按全局种子、像素及样本编号重置状态后才与任务调度无关。
threadlocal var prng = std.Random.DefaultPrng.init(default_seed);

// @brief 重置当前线程的伪随机数序列。
// @param value 本线程后续抽样的确定性种子。
pub fn seed(value: u64) void {
    prng = std.Random.DefaultPrng.init(value);
}

// @brief 返回 [0,1) 上的均匀伪随机数。
pub fn randomDouble() f64 {
    return prng.random().float(f64);
}

// @brief 将均匀样本线性映射到给定范围。
// @notice 调用者应提供有限且有序的端点；浮点舍入可能落到上端点。
pub fn randomDoubleRange(min: f64, max: f64) f64 {
    return min + (max - min) * randomDouble();
}

// @brief 独立抽取三个 [0,1) 分量。
pub fn randomVec() Vec3 {
    return Vec3.init(randomDouble(), randomDouble(), randomDouble());
}

// @brief 在给定范围内独立抽取三个分量。
pub fn randomVecRange(min: f64, max: f64) Vec3 {
    return Vec3.init(randomDoubleRange(min, max), randomDoubleRange(min, max), randomDoubleRange(min, max));
}

// @brief 将正八分体中的随机向量归一化。
// @notice 不是均匀球面采样；全零样本也未单独处理。
pub fn randomUnitVec() Vec3 {
    return randomVec().normalized();
}

// @brief 返回闭区间 [min,max] 内的均匀随机整数。
pub fn randomInt(min: i32, max: i32) i32 {
    return prng.random().intRangeAtMost(i32, min, max);
}

// @brief 通过立方体拒绝采样得到单位球内的均匀体积样本。
// @method **条件分布**：立方体密度为常数，限定 $\|\mathbf{p}\|^2<1$ 后球内仍为常数密度。
pub fn randomInUnitSphere() Point3 {
    var p: Point3 = undefined;
    while (true) {
        p = randomVecRange(-1.0, 1.0);
        if (p.lengthSquared() < 1.0) break;
    }
    return p;
}

// @brief 将球内样本径向归一化为均匀球面方向。
// @notice 零长度样本未作特殊处理。
pub fn randomUnitSphere() Vec3 {
    return randomInUnitSphere().normalized();
}

// @brief 将球内样本翻转到法线同侧，得到半球内体积样本。
// @notice 返回值并非单位方向，也不是余弦加权样本。
pub fn randomInHemisphere(normal: Vec3) Vec3 {
    const in_unit_sphere = randomInUnitSphere();
    if (in_unit_sphere.dot(normal) > 0.0)
        return in_unit_sphere
    else
        return in_unit_sphere.neg();
}

// @brief 拒绝采样得到 xy 平面单位圆盘内的均匀面积样本。
pub fn randomInUnitDisk() Vec3 {
    while (true) {
        const p = Vec3.init(randomDoubleRange(-1, 1), randomDoubleRange(-1, 1), 0);
        if (p.lengthSquared() < 1) return p;
    }
}

// @brief 返回局部正 z 半球上的余弦加权单位方向。
// @return 相对于立体角的密度为 $p(\omega)=\cos\theta/\pi$。
// @method **圆盘投影**：令 $r=\sqrt{u_2}$、$\phi=2\pi u_1$、$z=\sqrt{1-u_2}$；均匀圆盘面积投影满足 $dA=\cos\theta\,d\omega$。
pub fn randomCosineDirection() Vec3 {
    const r1 = randomDouble();
    const r2 = randomDouble();
    const z = @sqrt(1.0 - r2);
    const phi = 2.0 * math.pi * r1;
    const x = @cos(phi) * @sqrt(r2);
    const y = @sin(phi) * @sqrt(r2);
    return Vec3.init(x, y, z);
}

// @brief 均匀抽取从球外观察球体时所覆盖圆锥内的单位方向。
// @param radius 球体半径。
// @param distance_squared 观察点到球心的距离平方，须大于半径平方。
// @method **逆变换**：$c_{\max}=\sqrt{1-r^2/d^2}$，令 $z=1+u(c_{\max}-1)$ 且方位角均匀。
// @method 因 $d\omega=d\phi\,dz$，圆锥内密度为 $1/[2\pi(1-c_{\max})]$。
pub fn randomToSphere(radius: f64, distance_squared: f64) Vec3 {
    const r1 = randomDouble();
    const r2 = randomDouble();
    const z = 1.0 + r2 * (@sqrt(1.0 - radius * radius / distance_squared) - 1.0);
    const phi = 2.0 * math.pi * r1;
    const x = @cos(phi) * @sqrt(1.0 - z * z);
    const y = @sin(phi) * @sqrt(1.0 - z * z);
    return Vec3.init(x, y, z);
}
