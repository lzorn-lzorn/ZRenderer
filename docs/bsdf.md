# 表面 BSDF：接口、推导与边界

## 固定积分契约

[材质接口](../src/material.zig) 提供：

- `Material.bsdfEval(self, r_in: Ray, rec: *const HitRecord, wi: Vec3) Color`
- `Material.bsdfPdf(self, r_in: Ray, rec: *const HitRecord, wi: Vec3) f64`
- `Material.bsdfSample(self, r_in: Ray, rec: *const HitRecord) ?bsdf.Sample`
- `Material.hasNonDelta(self) bool`
- `Material.interiorMedium(self) ?*const medium.Homogeneous`：查询合法 `Subsurface` 的借用内部介质；自由程由主积分器处理。

[独立数学核](../src/bsdf.zig) 仅依赖标准库、现有向量与随机数模块；不依赖几何或纹理。
`Sample` 字段为 `direction: math.Vec3`、`weight: math.Color`、`pdf: f64`、
`is_delta: bool`、`eta: f64 = 1`。

`direction` 是归一化的世界空间离开方向。定义
$\omega_o=-\operatorname{normalize}(r_{in}.direction)$，法线 $n$ 指向入射侧。
`wi` 同样从交点指向外部；薄层透射可以位于法线另一侧。
公开适配器会归一化有限非零输入；零向量、非有限向量、背向或严格切线入射不散射。
积分器仍应提供单位几何法线，并对透射使用绝对余弦。

连续事件满足

$$
W=\frac{f(\omega_o,\omega_i)|n\cdot\omega_i|}{p(\omega_i)}.
$$

`bsdfEval` **不包含余弦**；`bsdfPdf` 是**包含选瓣概率的完整球面立体角密度**。
延续路径只需乘 `Sample.weight`，不可再次除以 `pdf` 或重复乘余弦。
若从独立光源分布采样，则使用完整 `bsdfEval`、绝对余弦和该策略的密度；MIS 比较使用 `bsdfPdf`。

delta 事件没有普通立体角函数值：`bsdfEval` 和 `bsdfPdf` 均返回零。
delta 样本的 `pdf` 是**所选离散分支概率质量**，不是可与光源连续密度直接比较的量。
其 `weight` 已抵消分支概率；MIS 应将无法由连续光源策略命中的 delta 延续按单独事件处理。
纯 delta 材质的 `hasNonDelta` 为 `false`。

`eta` 为透射的 $\eta_i/\eta_t$，反射为 1。透射权重已经包含 $\eta^2$，不可再乘一次。
俄罗斯轮盘可单独跟踪其倒平方抵消折射对存活概率的影响，但不能改变真实路径权重。

## 构造器和参数

- `newPbr(alloc, params: Pbr) CreateError!*Material`
- `Pbr { base_color: Color, metallic: f64, roughness: f64, ior: f64 = 1.5 }`
- `newSilk(alloc, params: Silk) CreateError!*Material`
- `Silk { base_color: Color, roughness: f64, anisotropy: f64 = 0, ior: f64 = 1.5 }`
- `newTranslucent(alloc, color: Color, transmission: f64) CreateError!*Material`
- `newSubsurface(alloc, params: Subsurface) CreateError!*Material`
- `Subsurface { ior: f64 = 1.54, medium: medium.Homogeneous = .{} }`
- 原有 `newLambertian`、`newMetal`、`newDielectric`、`newIsotropic` 保留；返回错误集合现在包含 `InvalidParameter`。

反照率/F0 颜色必须为线性 RGB，每分量在 $[0,1]$；金属度、粗糙度、fuzz、透射比例也在 $[0,1]$。
所有数值必须有限，NaN、无穷、负值和越界值明确返回 `error.InvalidParameter`，不静默钳位。
IOR 的数值支持域为 $[10^{-6},10^6]$，覆盖常见介质并限制极端折射计算。
水可直接使用物理值 `newDielectric(alloc, 1.333)`，无需艺术性缩放。
该 IOR 只决定界面光学，不决定参考图的波形、布光、背景或曝光。
`Subsurface` 的 `sigma_a` 为有限非负 RGB 吸收、`sigma_s` 为有限非负标量散射率，单位均为逆米，
不是 $[0,1]$ 表面颜色；`g` 有限且 $|g|<0.99$。示例玉石 IOR=1.54 与介质系数均为美术选择，非实测参数。
常量/棋盘反照率及程序纹理频率在构造时校验；程序纹理和后续修改后的纹理颜色还在新接口求值时校验。
无效纹理颜色返回黑色/零密度/空样本，不能把 HDR 发光纹理当作反照率使用。

直接构造 `bsdf.Surface` 也会在 `eval/pdf/sample` 入口校验颜色、粗糙度、透射比例与各向异性比例。
`specular != null` 时要求 `transmission == 0`；不支持同时使用微表面镜面与薄层漫透射。
非法闭包统一返回黑色、零密度和 `null`，不能让构造器外的直接初始化或参数修改绕过检查。
`fresnelSchlick` 是低层数学函数，要求合法 `F0` 和有限余弦；
`fresnelDielectric` 对非法 eta 或非有限余弦保守返回 1，但 `sampleDielectric` 会拒绝非法介质或方向。

工厂分两次分配参数对象和 `Material` 包装，第二次失败会释放第一次分配。
材质不拥有传入的 Lambertian 纹理；调用者维持纹理生命周期。
推荐沿用场景 arena。普通 allocator 下，需要分别释放包装和对应联合体指针；
`newIsotropic` 额外拥有其工厂创建的常量纹理及颜色对象。

## Lambertian 与薄片漫透射（非玉石模型）

Lambertian 为 $f=\rho/\pi$，采用余弦半球采样 $p=\cos\theta/\pi$，故每个样本权重恰为 $\rho$。

薄层模型的 `transmission` 为 $t$：

$$
f(\omega_o,\omega_i)=\frac{\rho}{\pi}
\begin{cases}1-t,&n\cdot\omega_i>0,\\t,&n\cdot\omega_i<0.\end{cases}
$$

以 $1-t$ 和 $t$ 选择反射/透射余弦半球，密度分别为
$(1-t)|\cos\theta|/\pi$ 和 $t|\cos\theta|/\pi$。
分支概率与物理系数抵消，所以包括纯透射端点在内，每个有效样本权重都是 $\rho$。
双半球积分为 $\rho\le1$；交换两条方向并把法线朝向新的入射侧后，函数不变。
这是局部、互易、能量有界的漫 BTDF：**不是 BSSRDF，不模拟内部路径、厚度或空间扩散**。
该薄层模型不折射，`eta=1`。
`newTranslucent` 保留给薄片；当前示例玉石使用下面的抛光界面与体积随机游走，不使用此模型。

## GGX、Smith 与 VNDF

粗糙金属的 `albedo` 是 Schlick $F_0$。
PBR 的 $F_0$ 和漫反射预算颜色分别为

$$
F_0=(1-m)\left(\frac{ior-1}{ior+1}\right)^2+m\,base\_color,
\qquad \rho_d=(1-m)base\_color.
$$

取 $\alpha=\max(0.001,roughness^2)$，$h=\operatorname{normalize}(\omega_o+\omega_i)$，
$c_o=n\cdot\omega_o$，$c_i=n\cdot\omega_i$。以下反射公式只在 $c_o,c_i>0$ 使用。

### 从微表面斜率推导 D

设 $s=(h_x/h_z,h_y/h_z)$ 是各向同性微表面的斜率。GGX 的二维斜率概率密度为

$$
P_{22}(s)=\frac{\alpha^2}{\pi(\alpha^2+|s|^2)^2},\qquad
\int_{\mathbb R^2}P_{22}(s)\,d^2s
=\int_0^\infty\frac{2\alpha^2r}{(\alpha^2+r^2)^2}\,dr=1.
$$

从斜率到单位法线的立体角雅可比满足 $d^2s=d\omega_h/h_z^3$。
法线分布函数 D 使用**投影面积归一化**，不是普通立体角概率密度：
$D(h)h_z\,d\omega_h=P_{22}(s)\,d^2s$。
因此 $D(h)=P_{22}(s)/h_z^4$，化简得到下面的切向分量形式。

### Smith 遮蔽与完整镜面项

Smith 的 GGX 单方向遮蔽为

$$
\Lambda(c)=\frac{\sqrt{1+\alpha^2\tan^2\theta}-1}{2},\qquad
G_1(c)=\frac1{1+\Lambda(c)}.
$$

代入 $\tan^2\theta=(1-c^2)/c^2$ 并把 c 移入根号，得到稳定形式：

$$
D(h)=\frac{\alpha^2}{\pi[\sin^2\theta_h+\alpha^2\cos^2\theta_h]^2},\qquad
\frac{G_1(c)}{c}=\frac{2}{c+\sqrt{\alpha^2+(1-\alpha^2)c^2}},
$$

$$
F(x)=F_0+(1-F_0)(1-x)^5,\qquad
f_s=\frac{D(h)F(\omega_o\cdot h)G_1(c_o)G_1(c_i)}{4c_oc_i}.
$$

实现直接计算 $G_1/c$ 的有限形式，并用半向量的切向分量计算 $D$，避免掠射除零和锐利峰的相消。
其中 $\lim_{c\to0^+}G_1(c)/c=2/\alpha$，法向处该比值为 1。
此模型使用分离 Smith 遮蔽函数 $G_2=G_1(c_o)G_1(c_i)$，不是高度相关 Smith；不含多次微表面散射。

### 可见法线采样与反射方向的雅可比

Heitz VNDF（可见法线分布）方法包含三个步骤：

1. 把视线拉伸为 $v_h=\operatorname{normalize}(\alpha\omega_{ox},\alpha\omega_{oy},c_o)$，在该空间采样单位粗糙度分布。
2. 在垂直 $v_h$ 的基底中用 $r=\sqrt{u_1},\phi=2\pi u_2$ 均匀取圆盘点 $(x,y)$。
	令 $s=(1+v_{hz})/2$，用 $y\leftarrow(1-s)\sqrt{1-x^2}+sy$ 处理可见投影区域，再沿 $v_h$ 提升到单位球面 $n_h$。
3. 返回 $h=\operatorname{normalize}(\alpha n_{hx},\alpha n_{hy},\max(0,n_{hz}))$。

微表面对观察方向的投影面积与 $D(h)\max(0,\omega_o\cdot h)$ 成正比；
Smith 的归一化给出 $G_1(c_o)/c_o$，因此得到

$$
p_h(h\mid\omega_o)=\frac{D(h)G_1(c_o)\max(0,\omega_o\cdot h)}{c_o},\quad h_z\ge0,
\qquad p_s(\omega_i)=\frac{D(h)G_1(c_o)}{4c_o}.
$$

第一项对可见微法线归一化为 1。为了得到第二项，以固定的 $\omega_o$ 为极轴：
反射关系 $\omega_i=2(\omega_o\cdot h)h-\omega_o$ 给出 $\theta_i=2\theta_h$，方位角相同，所以

$$
\frac{d\omega_i}{d\omega_h}
=\frac{\sin(2\theta_h)\,2d\theta_h\,d\phi}{\sin\theta_h\,d\theta_h\,d\phi}
=4|\omega_o\cdot h|,
\qquad p_s=p_h\left|\frac{d\omega_h}{d\omega_i}\right|.
$$

恰好消去 $p_h$ 中的 $|\omega_o\cdot h|$；不能漏掉 1/4，也不可使用普通 NDF 密度 $D(h)h_z$ 替代 VNDF 密度。
纯金属只采样 VNDF；同时存在漫反射预算时，以 $s=0.5$ 混合 VNDF 与余弦半球：

$$
p=s\,p_s+(1-s)\frac{c_i}{\pi}.
$$

该概率只控制估计方差，不是 BSDF 的物理系数。无论选中了哪个瓣，样本权重都使用完整 $f_s+f_d$ 和完整 $p$。
无镜面时 $s=0$；纯镜面预算时 $s=1$。薄层的上下半球密度另按 t、1-t 分支，不能混入 GGX。

**null 事件：**某些可见微法线会把反射方向送到下半球。此时返回 `null`，贡献为零，路径结束。
不可重采样，不可把有效方向密度条件归一化。正确归一化是
$\int_{\Omega^+}p\,d\omega+P(null)=1$。
例如 $\alpha=1$ 且法向观察的纯 GGX，方向密度为 $1/(4\pi)$，有效半球概率为 $1/2$。

更一般地，法向观察时 $p_h=D(h)h_z$，有效反射要求 $h_z>1/\sqrt2$，故

$$
A_s=\int_{1/\sqrt2}^1\frac{2\alpha^2z}{[1-(1-\alpha^2)z^2]^2}\,dz
=\frac1{1+\alpha^2},\qquad
P(null)=s(1-A_s).
$$

把 null 作为离散原子，估计量的期望为

$$
\mathbb E[W L_i]=\int_{\Omega}p(\omega_i)\frac{f|c_i|}{p(\omega_i)}L_i\,d\omega_i
+P(null)\,0=\int_{\Omega}f|c_i|L_i\,d\omega_i.
$$

若重试直到成功，却仍使用未条件化密度，就会把结果放大为原来的 $1/P(accepted)$。

### 各向异性 GGX（丝绸/缎面）

丝绸的纤维沿切向对齐，使切向(u)与副切向(v)具有不同粗糙度。取 $\alpha=\max(0.001,roughness^2)$、
$aspect=\sqrt{1-0.9\,anisotropy}$，则

$$
\alpha_u=\max(0.001,\alpha\cdot aspect),\qquad
\alpha_v=\max(0.001,\alpha/ aspect).
$$

切向(u)为平滑的纤维方向，$anisotropy$ 越大高光越沿副切向(v)拉长。各向异性 NDF、Smith 遮蔽与 VNDF 采样分别是

$$
D(h)=\frac{1}{\pi\alpha_u\alpha_v\left(\frac{h_u^2}{\alpha_u^2}+\frac{h_v^2}{\alpha_v^2}+h_z^2\right)^2},\qquad
\frac{G_1(v)}{v_z}=\frac{2}{v_z+\sqrt{v_z^2+\alpha_u^2v_u^2+\alpha_v^2v_v^2}},
$$

$$
v_h=\operatorname{normalize}(\alpha_u\omega_{ou},\alpha_v\omega_{ov},c_o),\qquad
h=\operatorname{normalize}(\alpha_u n_{hu},\alpha_v n_{hv},\max(0,n_{hz})).
$$

反射雅可比 $1/(4|\omega_o\cdot h|)$ 与漫反射 Fresnel 上界证明均与各向同性相同，因此互易性与能量预算不变。
`anisotropy=0` 时严格退化为各向同性 GGX。切向由几何法线经 `Onb.buildFromW` 确定性导出，不依赖 UV 切线。

## PBR 漫反射预算的互易性和能量证明

简单把完整 Lambertian 加在 GGX 上可能超过白炉能量；只乘依赖出射方向的系数又会破坏互易性。
这里采用显式、保守、双方向对称的 Fresnel 上界。

将 $\omega_o$ 分解为法向分量 $c_o$ 和长度为 $\sqrt{1-c_o^2}$ 的切向分量。
对任意 $c_i\ge0$，由切向 Cauchy–Schwarz 不等式：

$$
\omega_o\cdot\omega_i
\ge c_oc_i-\sqrt{1-c_o^2}\sqrt{1-c_i^2}
\ge-\sqrt{1-c_o^2}.
$$

等号在反方位的水平切线方向达到。由于
$\omega_o\cdot h=\sqrt{(1+\omega_o\cdot\omega_i)/2}$，因此
$\omega_o\cdot h\ge q(c_o)$，其中

$$
q(c)=\sqrt{\frac{1-\sqrt{1-c^2}}{2}}
=\frac{c}{\sqrt{2(1+\sqrt{1-c^2})}},\qquad B(c)=F(q(c)).
$$

有理化形式避免掠射时 $1-\sqrt{1-c^2}$ 的相消。
Schlick 的导数为 $F'(x)=-5(1-F_0)(1-x)^4\le0$，
故每个颜色通道 $F(\omega_o\cdot h)\le B(c_o)$。
取

$$
f_d=\frac{\rho_d}{\pi}[1-B(c_o)][1-B(c_i)].
$$

$f_s$ 和 $f_d$ 都在交换 $\omega_o,\omega_i$ 时不变。
对有效 VNDF 方向，$f_sc_i/p_s=F\,G_1(c_i)$。因为 $G_1\le1$，且有效方向的概率质量至多为 1：

$$
R_s=\int_{\Omega^+}f_sc_i\,d\omega_i
=\int_{\Omega^+}p_s F G_1(c_i)\,d\omega_i
\le B(c_o)\int_{\Omega^+}p_s\,d\omega_i\le B(c_o).
$$

又因 $0\le\rho_d\le1$、$0\le1-B(c_i)\le1$，以及余弦半球积分为 $\pi$：

$$
R_d=\rho_d[1-B(c_o)]\int_{\Omega^+}[1-B(c_i)]\frac{c_i}{\pi}\,d\omega_i
\le1-B(c_o).
$$

逐通道得到

$$
0\le R_s+R_d\le1.
$$

这是有证明的保守模型，**不是精确 glTF BSDF，也不等同于精确分层介质**：双边预算会进一步损失能量。
单次 GGX 还会丢失微表面间多次反射能量，因此白材质可能变暗；不应通过无条件归一化掩盖此损失。
例如白金属 $F_0=1,\alpha=1,c_o=1$ 的反照率为 $1-\ln2\approx0.30685$。
没有实现多次散射能量补偿、粗糙介电透射、sheen 纤维散射瓣或纤维内部折射；各向异性 GGX 已用于丝绸/缎面材质。
PBR 是不透明模型，即使 `metallic=0` 也不会折射。
PBR 的零粗糙度保留有限 GGX 峰；严格 delta 镜面请使用 `newMetal(..., 0)`，其权重刻意保持常量 albedo，兼容原解析镜面测试。

## 平滑介电体

平滑介电质采用精确非偏振 Fresnel，不使用 Schlick 近似。外部介质假定为空气，
进入时 $\eta=1/ior$，离开时 $\eta=ior$；没有嵌套介质栈。

$$
c_t=\sqrt{1-\eta^2(1-c_o^2)},\quad
F=\frac12\left[\left(\frac{\eta c_o-c_t}{\eta c_o+c_t}\right)^2+
\left(\frac{c_o-\eta c_t}{c_o+\eta c_t}\right)^2\right].
$$

若 $\eta^2(1-c_o^2)\ge1$，全反射；相同折射率直接延续，不制造掠射伪反射。
采样器实际用切向量
$t=\eta[(\omega_o\times n)\times n]$，由 $|t|^2$ 判定全反射并计算
$c_t=\sqrt{1-|t|^2}$，最后 $\omega_t=t-c_tn$。
与仅由 $1-c_o^2$ 求角度相比，这可以保留接近法向的小切向量：例如支持域内 $ior=10^6$、
$\sin\theta_o=10^{-8}$ 时，虽然双精度 $c_o$ 可能已经舍入为 1，折射后的正弦仍为 $0.01$。
独立的标量 `fresnelDielectric(cosine, eta)` 无法恢复调用方已舍去的角度信息；
采样器直接用稳定计算的两侧余弦求精确偏振平均。

### 为什么辐亮度路径权重是 eta²

Snell 映射给出 $n_o\sin\theta_o=n_t\sin\theta_t$，求微分可得

$$
n_o^2c_o\,d\omega_o=n_t^2c_t\,d\omega_t.
$$

这是光学展度守恒。结合通量测度 $d\Phi=L|\cos\theta|\,dA\,d\omega$，
无损折射保持 $L/n^2$。在此接口中，路径从 wo 侧**反向追踪**到 wi 侧，
计算回到 wo 侧的辐亮度：$L_o=(1-F)(n_o/n_t)^2L_t$。
所以取 $\eta=n_o/n_t$，而不是把正向光传播的介质比混用到反向路径权重。

写成相对于立体角 Dirac 测度的透射 BSDF：

$$
f_t(\omega_o,\omega_i)=\frac{(1-F)\eta^2\delta_\Omega(\omega_i-\omega_t)}{|n\cdot\omega_i|}.
$$

按 $F$ 反射、按 $1-F$ 透射，delta 权重分别为
$F/F=1$ 和 $(1-F)\eta^2/(1-F)=\eta^2$。
因此离开高 IOR 介质时权重可大于 1，这是辐亮度测度转换，不是能量错误；透射白炉不能使用反射表面的同一数值上界。
反转同一非全反射路径并翻转法线，两次 Fresnel 分支概率相同、方向相互还原，
eta 和辐亮度权重的乘积分别为 1；不能把带不同介质测度的 delta 写成普通连续 BSDF 的数值互易比较。

## 抛光边界与真实随机游走 SSS

`Subsurface` 通过同一个 `sampleDielectric` 处理界面，其 `bsdfEval/pdf` 为零、`hasNonDelta=false`，
只表示**表面是 delta**，不表示内部没有散射。`Material.interiorMedium()` 将内部介质交给
[主积分器](../src/color.zig)，当前已经接入场景和主程序，不是等待集成的独立模块。

内部在不同空间位置按 $D\sim\mathrm{Exp}(\sigma_s)$ 及 HG 相函数随机游走，
逐段乘 $e^{-\sigma_a d}$，有真实的吸收、厚度依赖和空间扩散；它不是薄层 BTDF，
也没有另行使用解析 BSSRDF 或扩散近似。方向密度是球面相函数，不能乘表面余弦。
边界折射进入/离开时切换活动介质；反射/全反射不切换，IOR=1 也仍需切换介质。

`sigma_s=0` 时仅有 Beer 吸收；`sigma_a=(0,0,0)` 且 `sigma_s=0` 时为清澈电介质，
保留 IOR 对应的反射/折射，不会退化成漫反射或不透明体。
只支持外部空气中的分离闭合物体，不支持嵌套、相交或内部嵌入其他物体。
没有体积 NEE、跨折射界面连接和专用焦散求解；参数、光学厚度与权重证明见 [次表面散射](subsurface.md)。

## 兼容性、相函数与验证

旧 `scatter`、`scatterPdf`、`scatterSrec`、`scatteringPdf` 和发光接口仍可调用。
旧介电接口也使用新的精确 Fresnel 与 eta²；旧金属散射入口保留历史镜面/随机 fuzz 行为，**不是 GGX**。
PBR、薄层和 `Subsurface` 只在新 BSDF 接口工作，旧散射接口返回 `false`；体积状态还需 `rayColorLit`。
`DiffuseLight` 不散射。`Isotropic` 是不带表面余弦的体相函数，不能冒充表面 BSDF：
新接口明确返回黑色、零密度、`null`，`hasNonDelta=false`；其旧体散射方法保留。
新体积路径已通过 `medium.Homogeneous` 的 HG 契约直接接入积分器，不借用旧 `Isotropic` 表面接口。

[测试集](../tests/bsdf_tests.zig) 覆盖世界空间 sample/eval/pdf 一致性、掠射有限值、反射白炉、
互易性、VNDF 经验分箱与包含 null 的归一化、漫反射/漫透射端点和概率抵消、
各向异性丝绸 sample/eval/pdf 一致性与零各向异性退化为电介质 PBR、
镜面常量权重、精确 Fresnel、水的进入/离开 eta²、Snell 与全反射、非法参数和逐次分配失败。
另有独立解析的 GGX 双瓣 f/pdf、多个粗糙度的法向接受率、逐通道镜面/漫反射预算求积、
跨界面往返折射、极高 IOR 的小角度回归、直接构造闭包与后续参数修改的非法输入检查。
测试已由 [主测试根](../tests/tests.zig) 导入；当前通过状态以本轮实际测试输出为准。
统计测试固定随机种子；白炉采样与数值求积留有统计/离散化容差，数学能量保证来自上面的证明。
粗糙度下限的尖峰由解析检查和 VNDF 采样覆盖，不依赖均匀角度网格解析该尖峰。
可独立执行 `zig build test -Dtest-filter=BSDF`，并加 `-Doptimize=ReleaseSafe` 或 `-Doptimize=ReleaseFast`。