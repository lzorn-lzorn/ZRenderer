// @brief 闭合电介质内部的均匀介质；提供吸收、散射自由程和 Henyey–Greenstein（HG）相函数。
// @notice 不依赖材质、求交器、随机数状态或 C 库；界面追踪与活动介质状态由积分器负责。
const std = @import("std");
const math = @import("math.zig");

// @brief RGB 吸收加标量散射的均匀介质；一个场景长度单位等于一米。
// @method **体积输运**：$\sigma_t=\sigma_a+\sigma_s$；采样密度 $q(d)=\sigma_s e^{-\sigma_s d}$，路径权重仅乘 $e^{-\sigma_a d}$。
// @notice 所有计算方法要求 valid() 为真；不支持嵌套介质、空间变化系数或波长相关散射率。
pub const Homogeneous = struct {
    sigma_a: math.Color = .{}, // @brief 线性 RGB 吸收系数，单位为逆米，各分量有限且非负。
    sigma_s: f64 = 0, // @brief 三通道共用的散射系数，单位为逆米，有限且非负。
    g: f64 = 0, // @brief HG 平均散射余弦，有限且严格满足 |g| < 0.99；正值表示前向散射。

    // @brief 检查全部介质系数，不修改或钳制无效材质参数。
    pub fn valid(self: Homogeneous) bool {
        return nonnegativeFinite(self.sigma_a.x) and
            nonnegativeFinite(self.sigma_a.y) and
            nonnegativeFinite(self.sigma_a.z) and
            nonnegativeFinite(self.sigma_s) and
            std.math.isFinite(self.g) and @abs(self.g) < 0.99;
    }

    // @brief 返回一段实际行程的逐通道连续吸收权重。
    // @param distance 非负米数，允许正无穷；零吸收通道在无限行程上仍返回一。
    // @method **Beer 定律**：$A_c(d)=\exp(-\sigma_{a,c}d)$，且 $A_c(d_1+d_2)=A_c(d_1)A_c(d_2)$。
    pub fn absorption(self: Homogeneous, distance: f64) math.Color {
        std.debug.assert(self.valid());
        std.debug.assert(distance >= 0);
        return .{
            .x = attenuation(self.sigma_a.x, distance),
            .y = attenuation(self.sigma_a.y, distance),
            .z = attenuation(self.sigma_a.z, distance),
        };
    }

    // @brief 返回没有任何碰撞的直线束透射率，不是已采样路径应再乘的权重。
    // @param distance 非负米数，允许正无穷。
    // @method $T_c(d)=\exp[-(\sigma_{a,c}+\sigma_s)d]=A_c(d)\exp(-\sigma_s d)$。
    // @notice 分开求指数避免两个有限系数相加溢出；事件和边界的散射生存概率已由自由程抽样承担。
    pub fn transmittance(self: Homogeneous, distance: f64) math.Color {
        return self.absorption(distance).scale(attenuation(self.sigma_s, distance));
    }

    // @brief 仅从散射指数分布抽样下一次体积散射的米制距离。
    // @param u 有限的 [0,1] 坐标；随机采样建议使用 [0,1)，保留一作为极限端点。
    // @return sigma_s 为零或 u 为一时返回正无穷；否则非负，极小散射率也可能使结果溢出为正无穷。
    // @method **逆累积分布**：$F(d)=1-e^{-\sigma_s d}$，$d=-\log(1-u)/\sigma_s$；log1p 保留极小 u 的精度。
    // @notice 禁止额外乘散射反照率或 exp(-sigma_s*d)，否则会重复计算已抽样的散射概率。
    pub fn sampleDistance(self: Homogeneous, u: f64) f64 {
        std.debug.assert(self.valid());
        std.debug.assert(u >= 0 and u <= 1);
        if (self.sigma_s == 0 or u == 1) return math.infinity;
        return -std.math.log1p(-u) / self.sigma_s;
    }

    // @brief 计算相对于立体角的 HG 相函数，单位为逆球面度，也是方向采样的概率密度。
    // @param cosine 入射传播方向与出射传播方向的点积，有限；钳制到 [-1,1] 以容忍舍入。
    // @method $p(c)=(1-g^2)/[4\pi(1+g^2-2gc)^{3/2}]$，且 $\int_{S^2}p\,d\omega=1$。
    // @notice 入射方向不是表面 BSDF 中朝外的方向；g > 0 的峰值位于 cosine = 1。
    pub fn phase(self: Homogeneous, cosine: f64) f64 {
        std.debug.assert(self.valid());
        std.debug.assert(std.math.isFinite(cosine));
        const c = math.clamp(cosine, -1, 1);
        const a = @abs(self.g);
        const aligned = if (self.g < 0) -c else c;
        // @method **稳定分母**：$1+g^2-2gc=(1-|g|)^2+2|g|(1-\operatorname{sgn}(g)c)$，避免前向峰值相消。
        const base = (1 - a) * (1 - a) + 2 * a * (1 - aligned);
        return ((1 - a) * (1 + a)) / (4 * math.pi * base * @sqrt(base));
    }

    // @brief 绕入射传播方向抽样 HG 方向；返回世界坐标单位向量，无内部随机状态。
    // @param forward 有限非零入射传播向量；内部先缩放再归一化，支持非单位方向。
    // @param u 有限的 [0,1] 余弦分位数，零为后向、一为前向。
    // @param v 有限的 [0,1] 方位角坐标；两端都对应零方位角。
    // @method **HG 逆变换**：令 $t=2u-1$，则 $c=t+g(1-t^2)(3+2gt-g^2)/[2(1+gt)^2]$。
    // @method 此式与 $[1+g^2-((1-g^2)/(1+gt))^2]/(2g)$ 等价，但没有除以 g 或相近数相减；g=0 精确退化为 c=t。
    // @method **方向重建**：$\phi=2\pi v$，$\omega=\sqrt{1-c^2}(\cos\phi\,\mathbf{u}+\sin\phi\,\mathbf{v})+c\,\mathbf{w}$。
    pub fn sampleDirection(self: Homogeneous, forward: math.Vec3, u: f64, v: f64) math.Vec3 {
        std.debug.assert(self.valid());
        std.debug.assert(u >= 0 and u <= 1 and v >= 0 and v <= 1);
        std.debug.assert(std.math.isFinite(forward.x) and std.math.isFinite(forward.y) and std.math.isFinite(forward.z));
        const scale = @max(@abs(forward.x), @max(@abs(forward.y), @abs(forward.z)));
        std.debug.assert(scale > 0);
        var basis: math.Onb = .{};
        // @notice 逐分量相除，不先计算倒数，避免极小输入向量的倒数溢出。
        basis.buildFromW(.{ .x = forward.x / scale, .y = forward.y / scale, .z = forward.z / scale });
        const t = 2 * u - 1;
        const denominator = 1 + self.g * t;
        const correction = self.g * (1 - t) * (1 + t) * (3 + 2 * self.g * t - self.g * self.g) / (2 * denominator * denominator);
        const cosine = math.clamp(t + correction, -1, 1);
        const sine = @sqrt(@max(0, (1 - cosine) * (1 + cosine)));
        const phi = 2 * math.pi * v;
        return basis.local3(sine * @cos(phi), sine * @sin(phi), cosine);
    }
};

// @brief 判断一个系数是否为有限非负数，拒绝 NaN 和正负无穷。
fn nonnegativeFinite(value: f64) bool {
    return std.math.isFinite(value) and value >= 0;
}

// @brief 计算单通道衰减，显式处理零系数和零距离以避免零乘无穷。
fn attenuation(rate: f64, distance: f64) f64 {
    if (rate == 0 or distance == 0) return 1;
    return @exp(-(rate * distance));
}
