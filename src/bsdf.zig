const std = @import("std");
const math = @import("math.zig");
const random = @import("random.zig");
const Vec3 = math.Vec3;
const Color = math.Color;
const white = Color.init(1, 1, 1);

// @brief 积分器唯一的散射样本契约。
// @param direction 归一化世界方向；pdf 为立体角密度，delta 时为离散分支概率。
// @param weight 连续事件为 f*abs(n·wi)/pdf；delta 已消去分支概率，不得再次除以 pdf。
// @param eta 透射的 eta_i/eta_t；反射恒为 1。
pub const Sample = struct {
    direction: Vec3,
    weight: Color,
    pdf: f64,
    is_delta: bool,
    eta: f64 = 1,
};

// @brief 显式拒绝 NaN、无穷和越界颜色，不把非法参数静默截断。
pub fn validColor(c: Color) bool {
    return validUnit(c.x) and validUnit(c.y) and validUnit(c.z);
}

// @brief 判断标量是否有限且处于闭区间 [0,1]。
pub fn validUnit(x: f64) bool {
    return std.math.isFinite(x) and x >= 0 and x <= 1;
}

// @brief 校验折射率或相对折射率的数值支持域 [1e-6,1e6]。
// @notice 有限计算域覆盖常见物理介质，避免 eta 平方溢出。
pub fn validIor(x: f64) bool {
    return std.math.isFinite(x) and x >= 1e-6 and x <= 1e6;
}

// @brief 缩放后归一化，兼容巨大或极小有限向量；零向量无定义。
pub fn unit(v: Vec3) ?Vec3 {
    if (!std.math.isFinite(v.x) or !std.math.isFinite(v.y) or !std.math.isFinite(v.z)) return null;
    const scale = @max(@abs(v.x), @max(@abs(v.y), @abs(v.z)));
    if (scale == 0) return null;
    const w = Vec3.init(v.x / scale, v.y / scale, v.z / scale);
    return w.scale(1 / @sqrt(w.lengthSquared()));
}

fn pow5(x: f64) f64 {
    const x2 = x * x;
    return x2 * x2 * x;
}

// @brief Schlick 彩色菲涅耳；仅用于不透射的微表面。
// @notice 调用方保证 F0 在 [0,1] 且 cosine 有限；Surface 会先校验颜色和方向。
// @method $F(c)=F_0+(1-F_0)(1-c)^5$，逐通道插值法向反射率与掠射极限 1。
pub fn fresnelSchlick(f0: Color, cosine: f64) Color {
    return f0.add(white.sub(f0).scale(pow5(1 - math.clamp(cosine, 0, 1))));
}

// @brief 非偏振介电质精确菲涅耳，eta 为入射/透射折射率。
// @return 全反射返回 1；相同介质返回 0。
// @notice 非法 eta 或非有限 cosine 保守返回 1；有限 cosine 钳位到 [0,1]。
// @method **Snell 与偏振平均：** $\sin\theta_t=\eta\sin\theta_o$，所以 $c_t=\sqrt{1-\eta^2(1-c_o^2)}$。
// @method $$r_s=\frac{\eta c_o-c_t}{\eta c_o+c_t},\quad r_p=\frac{c_o-\eta c_t}{c_o+\eta c_t},\quad F=\frac{r_s^2+r_p^2}{2}.$$
// @method 两个振幅符号约定不影响平方；根号非正时按全反射处理。eta=1 必须先返回 0，避免切线 0/0。
pub fn fresnelDielectric(cosine: f64, eta: f64) f64 {
    if (!validIor(eta) or !std.math.isFinite(cosine)) return 1;
    if (eta == 1) return 0;
    const c = math.clamp(cosine, 0, 1);
    const sin2_t = eta * eta * @max(0, (1 - c) * (1 + c));
    if (sin2_t >= 1) return 1;
    const ct = @sqrt(1 - sin2_t);
    return fresnelFromCosines(c, ct, eta);
}

// @brief 已知两侧余弦时求偏振平均；调用方先处理全反射与相同介质。
fn fresnelFromCosines(c: f64, ct: f64, eta: f64) f64 {
    const rs = (eta * c - ct) / (eta * c + ct);
    const rp = (c - eta * ct) / (c + eta * ct);
    return math.clamp(0.5 * (rs * rs + rp * rp), 0, 1);
}

// @brief 平滑介电质的 delta 采样；法线朝向 wo，外部介质假定为空气。
// @notice 辐亮度透射权重为 eta²，已用 Fresnel 分支概率抵消反射/透射系数。
// @method **方向：** $\omega_t=\eta(-\omega_o+c_o n)-c_t n$；反射为 $-\omega_o+2c_o n$。
// @method 用 $\eta[(\omega_o\times n)\times n]$ 求透射切向量，再由其模长求 $c_t$；避免 $c_o$ 舍入到 1 后丢失小角度。
// @method **辐亮度测度：** 折射的展度 $n^2|\cos\theta|\,dA\,d\omega$ 守恒，无损传播保持 $L/n^2$。
// @method 从 wo 侧反向追踪到 wi 侧，$L_o=(1-F)(n_o/n_t)^2L_t$；此处 $\eta=n_o/n_t$，不是正向光传播的倒数约定。
// @method $$f_t=\frac{(1-F)\eta^2\delta_\Omega(\omega_i-\omega_t)}{|n\cdot\omega_i|},\quad W_t=\frac{(1-F)\eta^2}{P(t)}=\eta^2,\quad W_r=\frac{F}{P(r)}=1.$$
// @method 因 $P(r)=F,P(t)=1-F$，pdf 是离散质量；不能与连续立体角密度直接做 MIS，也不能再次除概率。
// @method 高折射率内部向外追踪可有 $W_t>1$，这是测度转换，不是反射炉能量超标；逆向透射的 eta 乘积为 1。
pub fn sampleDielectric(wo_in: Vec3, n_in: Vec3, ior: f64, front_face: bool) ?Sample {
    if (!validIor(ior)) return null;
    const wo = unit(wo_in) orelse return null;
    const n = unit(n_in) orelse return null;
    const c = math.clamp(wo.dot(n), 0, 1);
    if (wo.dot(n) <= 0) return null;
    const eta = if (front_face) 1 / ior else ior;
    if (eta == 1) return .{ .direction = wo.neg(), .weight = white, .pdf = 1, .is_delta = true };
    const tangent = wo.cross(n).cross(n).scale(eta);
    const sin2_t = tangent.lengthSquared();
    const ct = @sqrt(@max(0, 1 - sin2_t));
    const f = if (sin2_t >= 1) 1 else fresnelFromCosines(c, ct, eta);
    if (random.randomDouble() < f or f == 1) return .{
        .direction = unit(math.reflect(wo.neg(), n)) orelse return null,
        .weight = white,
        .pdf = f,
        .is_delta = true,
    };
    const transmitted = tangent.sub(n.scale(ct));
    return .{
        .direction = unit(transmitted) orelse return null,
        .weight = white.scale(eta * eta),
        .pdf = 1 - f,
        .is_delta = true,
        .eta = eta,
    };
}

// @brief 各向异性 GGX 法线分布；使用切向平方避免锐利峰处的相消。
// @method **从斜率到法线：** 令 $s=(h_x/h_z,h_y/h_z)$，各向异性 GGX 斜率密度正比于 $1/[\alpha_x\alpha_y(1+s_x^2/\alpha_x^2+s_y^2/\alpha_y^2)^2]$。
// @method $d^2s=d\omega_h/h_z^3$，投影法线概率 $P_{22}d^2s=D(h)h_zd\omega_h$，故 $D=P_{22}/h_z^4$。
// @method $$D(h)=\frac{1}{\pi\alpha_x\alpha_y\left(\frac{h_x^2}{\alpha_x^2}+\frac{h_y^2}{\alpha_y^2}+h_z^2\right)^2},\qquad\int_{\Omega^+}D(h)h_z\,d\omega_h=1.$$
// @method D 本身不是立体角 PDF；以 $h_x^2+h_y^2$ 代替 $1-h_z^2$ 可保留极尖峰附近的小切向分量；$\alpha_x=\alpha_y$ 时退化为各向同性。
fn distribution(h: Vec3, alpha_x: f64, alpha_y: f64) f64 {
    const ax2 = alpha_x * alpha_x;
    const ay2 = alpha_y * alpha_y;
    const d = h.x * h.x / ax2 + h.y * h.y / ay2 + h.z * h.z;
    return 1 / (math.pi * alpha_x * alpha_y * d * d);
}

// @brief 稳定计算各向异性 Smith 单方向遮蔽除以余弦 G1(v)/(n·v)，避免掠射方向的 0/0。
// @param v 切向基下的单位方向，v.z=n·v>0；alpha_x/y 沿两条切向轴。
// @method **Smith 单方向遮蔽：** $\Lambda(v)=[\sqrt{1+(\alpha_x^2v_x^2+\alpha_y^2v_y^2)/v_z^2}-1]/2$，$G_1=1/(1+\Lambda)$。
// @method 将 v_z 移入根号得到无需先计算无穷 Lambda 的稳定形式：
// @method $$\frac{G_1(v)}{v_z}=\frac{2}{v_z+\sqrt{v_z^2+\alpha_x^2v_x^2+\alpha_y^2v_y^2}},\quad\lim_{v_z\to0^+}\frac{G_1(v)}{v_z}\le\frac2{\min(\alpha_x,\alpha_y)}.$$
// @method $\alpha_x=\alpha_y=\alpha$ 时退化为 $2/(c+\sqrt{\alpha^2+(1-\alpha^2)c^2})$；双方向采用分离式 $G_2=G_1(v_o)G_1(v_i)$，非高度相关 Smith。
fn g1OverCos(v: Vec3, alpha_x: f64, alpha_y: f64) f64 {
    const c = v.z;
    return 2 / (c + @sqrt(c * c + alpha_x * alpha_x * v.x * v.x + alpha_y * alpha_y * v.y * v.y));
}

fn local(frame: math.Onb, v: Vec3) Vec3 {
    return .{ .x = v.dot(frame.u()), .y = v.dot(frame.v()), .z = v.dot(frame.w()) };
}

// @brief Heitz 可见法线采样（各向异性）：分别以 alpha_x/y 拉伸视线、投影圆盘、再反向拉伸。
// @notice 不重采样落到下半球的反射；其概率质量必须作为 null 事件保留。
// @method **VNDF（可见法线分布）：** $v_h=\operatorname{normalize}(\alpha_x\omega_{ox},\alpha_y\omega_{oy},c_o)$ 把各向异性 GGX 化为单位粗糙度。
// @method 围绕 vh 建立切向基，以 $r=\sqrt{u_1},\phi=2\pi u_2$ 均匀采样投影圆盘 $(x,y)$。
// @method 可见半球投影的裁剪由 $s=(1+v_{hz})/2$ 与 $y\leftarrow(1-s)\sqrt{1-x^2}+sy$ 实现，再提升到球面 nh。
// @method 反向映射 $h=\operatorname{normalize}(\alpha_x n_{hx},\alpha_y n_{hy},\max(0,n_{hz}))$，所得密度为
// @method $$p_h(h\mid\omega_o)=\frac{D(h)G_1(c_o)\max(0,\omega_o\cdot h)}{c_o},\quad h_z\ge0.$$
// @method 这是投影到观察方向的微表面积，经 G1 归一化；并非 $D(h)h_z$ 的普通法线采样。$\alpha_x=\alpha_y$ 时退化为各向同性。
fn sampleVisibleNormal(wo: Vec3, alpha_x: f64, alpha_y: f64) Vec3 {
    const vh = Vec3.init(alpha_x * wo.x, alpha_y * wo.y, wo.z).normalized();
    const lensq = vh.x * vh.x + vh.y * vh.y;
    const t1 = if (lensq > 0) Vec3.init(-vh.y, vh.x, 0).scale(1 / @sqrt(lensq)) else Vec3.init(1, 0, 0);
    const t2 = vh.cross(t1);
    const r = @sqrt(random.randomDouble());
    const phi = 2 * math.pi * random.randomDouble();
    const x = r * @cos(phi);
    var y = r * @sin(phi);
    const s = 0.5 * (1 + vh.z);
    y = (1 - s) * @sqrt(@max(0, 1 - x * x)) + s * y;
    const nh = t1.scale(x).add(t2.scale(y)).add(vh.scale(@sqrt(@max(0, 1 - x * x - y * y))));
    return Vec3.init(alpha_x * nh.x, alpha_y * nh.y, @max(0, nh.z)).normalized();
}

// @brief 所有上半球 wi 对应的 Fresnel 上界；用于保守且互易的漫反射预算。
// @method **几何下界：** 固定 $c_o=n\cdot\omega_o>0$，任何上半球 wi 满足 $\omega_o\cdot\omega_i\ge-\sqrt{1-c_o^2}$。
// @method 最小值出现在反方位的切线方向；又 $\omega_o\cdot h=\sqrt{(1+\omega_o\cdot\omega_i)/2}$，于是
// @method $$\omega_o\cdot h\ge q(c_o),\quad q(c)=\sqrt{\frac{1-\sqrt{1-c^2}}2}=\frac{c}{\sqrt{2(1+\sqrt{1-c^2})}}.$$
// @method 最后一式有理化消去掠射相消。Schlick 在 [0,1] 单调不增，故逐通道 $F(\omega_o\cdot h)\le B(c_o)=F(q(c_o))$。
// @method **能量预算：** 用 $f_d=\rho_d[1-B(c_o)][1-B(c_i)]/\pi$，双边乘积保证互易，不是 glTF 精确模型。
// @method VNDF 的有效样本满足 $f_sc_i/p_s=F G_1(c_i)\le B(c_o)$；包含 null 后 $R_s=\int_{\Omega^+}f_sc_i\,d\omega_i\le B(c_o)$。
// @method 又 $\int_{\Omega^+}c_i/\pi\,d\omega_i=1$ 且 $\rho_d,1-B(c_i)\in[0,1]$，故 $R_d\le1-B(c_o)$，逐通道 $R_s+R_d\le1$。
// @method 这是保守上界而非能量补偿：双边预算及缺失的微表面多次反射都会使白炉变暗。
fn fresnelBound(f0: Color, cosine: f64) Color {
    const c = math.clamp(cosine, 0, 1);
    const q = c / @sqrt(2 * (1 + @sqrt(@max(0, 1 - c * c))));
    return fresnelSchlick(f0, q);
}

// @brief 连续表面闭包：漫反射/薄层漫透射，或互易漫反射加 GGX。
// @param diffuse 线性反照率；specular 非空时表示 GGX F0。
// @param roughness 感知粗糙度，alpha=max(0.001,roughness²)，零值仍为连续分布。
// @notice specular 非空时 transmission 必须为零；直接构造的非法参数同样返回黑色/零密度/null。
pub const Surface = struct {
    diffuse: Color = .{},
    specular: ?Color = null,
    roughness: f64 = 0.5,
    transmission: f64 = 0,
    anisotropy: f64 = 0,
    // @brief 不透明度：1 为完全不透明；小于 1 时以 1-opacity 概率直线穿过（alpha 混合）。
    opacity: f64 = 1,

    fn valid(self: Surface) bool {
        return validColor(self.diffuse) and validUnit(self.roughness) and validUnit(self.transmission) and validUnit(self.anisotropy) and validUnit(self.opacity) and
            (if (self.specular) |f0| validColor(f0) and self.transmission == 0 else true);
    }

    // @brief 各向异性 GGX 沿切向(u)/副切向(v)的粗糙度 alpha；anisotropy=0 时二者相等。
    // @method 采用 Principled 的 aspect 映射：$\alpha_x=\alpha\sqrt{1-0.9a}$、$\alpha_y=\alpha/\sqrt{1-0.9a}$，$\alpha=\max(0.001,roughness^2)$。
    // @method 切向(u)为平滑的纤维方向，anisotropy 越大高光越沿副切向(v)拉长。
    fn alphas(self: Surface) struct { x: f64, y: f64 } {
        const a = @max(0.001, self.roughness * self.roughness);
        const aspect = @sqrt(@max(0.001, 1 - 0.9 * self.anisotropy));
        return .{ .x = @max(0.001, a * aspect), .y = @max(0.001, a / aspect) };
    }

    fn specProbability(self: Surface) f64 {
        if (self.specular == null) return 0;
        if (self.diffuse.x == 0 and self.diffuse.y == 0 and self.diffuse.z == 0) return 1;
        return 0.5;
    }

    // @brief 双方向均从交点向外；返回 BSDF，不包含余弦或采样概率。
    // @return 无效方向、背面入射或不支持的半球返回黑色。
    // @method **完整连续 BSDF：** 上半球 $f=f_d+f_s$，$f_s=D(h)F(\omega_o\cdot h)[G_1(c_o)/c_o][G_1(c_i)/c_i]/4$。
    // @method 无镜面时 $f_d=\rho(1-t)/\pi$，下半球 $f=\rho t/\pi$；有镜面时 t=0，漫反射还需乘双边 $[1-B]$ 预算。
    // @method h 与 D 在交换 wo、wi 时不变，F 的两个点积相等，G 与漫反射预算对称，因此反射严格互易。
    pub fn eval(self: Surface, wo_in: Vec3, n_in: Vec3, wi_in: Vec3) Color {
        if (!self.valid()) return .{};
        const wo = unit(wo_in) orelse return .{};
        const wi = unit(wi_in) orelse return .{};
        const n = unit(n_in) orelse return .{};
        const co = wo.dot(n);
        const ci = wi.dot(n);
        if (co <= 0 or ci == 0) return .{};
        if (ci < 0) return if (self.specular == null) self.diffuse.scale(self.transmission / math.pi).scale(self.opacity) else .{};
        var diffuse = self.diffuse.scale((1 - self.transmission) / math.pi);
        const f0 = self.specular orelse return diffuse.scale(self.opacity);
        diffuse = diffuse.mul(white.sub(fresnelBound(f0, co))).mul(white.sub(fresnelBound(f0, ci)));
        const h = unit(wo.add(wi)) orelse return diffuse.scale(self.opacity);
        var frame: math.Onb = .{};
        frame.buildFromW(n);
        const a = self.alphas();
        const wo_l = local(frame, wo);
        const wi_l = local(frame, wi);
        const spec = fresnelSchlick(f0, wo.dot(h)).scale(distribution(local(frame, h), a.x, a.y) * g1OverCos(wo_l, a.x, a.y) * g1OverCos(wi_l, a.x, a.y) / 4);
        return diffuse.add(spec).scale(self.opacity);
    }

    // @brief 完整混合密度，包含选瓣概率；上半球积分可小于 1，余量是 null 概率。
    // @method **反射雅可比：** 以 wo 为极轴，反射角 $\theta_i=2\theta_h$、方位不变，$d\omega_i/d\omega_h=2\sin(2\theta_h)/\sin\theta_h=4|\omega_o\cdot h|$。
    // @method 因此 $p_s(\omega_i)=p_h(h)/(4|\omega_o\cdot h|)=D(h)G_1(c_o)/(4c_o)$，不可误乘 $h_z$ 或漏掉 1/4。
    // @method 令选镜面概率 s 为纯镜面 1、混合 1/2、无镜面 0；物理系数不随 s 改变。
    // @method $$p(\omega_i)=\begin{cases}s p_s+(1-s)(1-t)c_i/\pi,&c_i>0,\\t|c_i|/\pi,&c_i<0\text{ 且无镜面},\\0,&\text{其他}.\end{cases}$$
    // @method 只在有效半球返回密度；完整概率空间是方向加 null 原子，$P(\varnothing)=s[1-\int_{\Omega^+}p_s\,d\omega_i]$。
    // @method 例如 alpha=1、法向 wo 时 $p_s=1/(4\pi)$，纯镜面的接受率恰为 1/2；不能归一化为 1。
    pub fn pdf(self: Surface, wo_in: Vec3, n_in: Vec3, wi_in: Vec3) f64 {
        if (!self.valid()) return 0;
        const wo = unit(wo_in) orelse return 0;
        const wi = unit(wi_in) orelse return 0;
        const n = unit(n_in) orelse return 0;
        const co = wo.dot(n);
        const ci = wi.dot(n);
        if (co <= 0 or ci == 0) return 0;
        if (ci < 0) return if (self.specular == null) self.transmission * -ci / math.pi * self.opacity else 0;
        const p = self.specProbability();
        const diffuse = (1 - p) * (1 - self.transmission) * ci / math.pi;
        if (p == 0) return diffuse * self.opacity;
        const h = unit(wo.add(wi)) orelse return diffuse * self.opacity;
        var frame: math.Onb = .{};
        frame.buildFromW(n);
        const a = self.alphas();
        return (diffuse + p * distribution(local(frame, h), a.x, a.y) * g1OverCos(local(frame, wo), a.x, a.y) / 4) * self.opacity;
    }

    // @brief 返回世界空间样本；权重使用完整 eval/pdf，而非仅被选中的瓣。
    // @notice null 是零贡献事件，积分器应终止路径，不能重试或对 pdf 重新归一化。
    // @method **混合估计量：** 先按 s 选 VNDF 或余弦瓣；取样后不再保留瓣标签，统一返回 $W=f|c_i|/p$。
    // @method $$\mathbb E[W L_i]=\int_{\Omega}p(\omega_i)\frac{f|c_i|}{p(\omega_i)}L_i\,d\omega_i+P(\varnothing)\,0=\int_{\Omega}f|c_i|L_i\,d\omega_i.$$
    // @method 薄层余弦瓣的 t 或 1-t 同时出现在 f 和 p 中，因此每次有效采样 W=rho；黑色样本也保留其正常概率。
    pub fn sample(self: Surface, wo_in: Vec3, n_in: Vec3) ?Sample {
        if (!self.valid()) return null;
        const wo = unit(wo_in) orelse return null;
        const n = unit(n_in) orelse return null;
        if (wo.dot(n) <= 0) return null;
        // @brief alpha 混合：以 1-opacity 概率直线穿过表面，不改变方向与通量。
        if (self.opacity < 1 and random.randomDouble() >= self.opacity) {
            return .{ .direction = wo.neg(), .weight = white, .pdf = 1 - self.opacity, .is_delta = true };
        }
        var frame: math.Onb = .{};
        frame.buildFromW(n);
        var wi: Vec3 = undefined;
        if (random.randomDouble() < self.specProbability()) {
            const a = self.alphas();
            const h = frame.local(sampleVisibleNormal(local(frame, wo), a.x, a.y));
            wi = unit(math.reflect(wo.neg(), h)) orelse return null;
            if (wi.dot(n) <= 0) return null;
        } else {
            wi = frame.local(random.randomCosineDirection());
            if (self.transmission > 0 and random.randomDouble() < self.transmission) wi = wi.neg();
            wi = unit(wi) orelse return null;
        }
        const density = self.pdf(wo, n, wi);
        if (!(density > 0) or !std.math.isFinite(density)) return null;
        const weight = self.eval(wo, n, wi).scale(@abs(n.dot(wi)) / density);
        if (!std.math.isFinite(weight.x) or !std.math.isFinite(weight.y) or !std.math.isFinite(weight.z)) return null;
        return .{ .direction = wi, .weight = weight, .pdf = density, .is_delta = false };
    }
};
