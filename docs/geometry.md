# 胶囊几何与带时间光源采样

实现见 [object.zig](../src/object.zig)，独立回归见 [geometry_tests.zig](../src/geometry_tests.zig)。

## 接口与所有权

- `Capsule { start: Point3, end: Point3, radius: f64, material: *Material }` 是静态闭合图元；`Object.capsule` 同时参与 `hit` 和 `boundingBox` 分派。
- `newCapsule(alloc, start, end, radius, mat) !*Object` 验证端点有限、轴线长度有限且非零、半径有限且严格为正。无效参数返回 `error.InvalidCapsule`，且不进行分配。
- 工厂分别分配胶囊和 `Object` 包装。第二次分配失败会释放第一次分配，错误为 `error.OutOfMemory`。材质始终借用，不转移所有权。
- 成功后可由场景区域分配器统一释放；使用普通分配器时，先销毁 `obj.capsule`，再销毁 `obj`，不要销毁借用材质。
- 直接初始化 `Capsule` 必须遵守同样的几何约束。算法使用 `f64`；有限输入不代表任意极端坐标、半径的中间乘积都可表示。场景尺度应保证半径平方、相对坐标及交点可表示。

### 毛束不是毛发散射模型

每段胶囊是真实、可遮挡、可投影且有曲面法线的几何体，不是 billboard 或透明贴片。场景可以将约 2000 条毛束的分段胶囊加入现有 BVH；这里不生成场景，不改变 BVH 构建和排序算法。

材质仍由现有表面 BSDF（双向散射分布函数）处理。使用各向同性表面 BSDF **不等于实现毛发散射**：本改动不模拟纤维切向各向异性、内部折射、纵向/方位散射瓣或毛发多重散射。胶囊也没有专用光源采样器。

## 解析胶囊求交

设轴线端点为 $A,B$，半径为 $r>0$：

$$
L=\|B-A\|,\qquad \mathbf w=(B-A)/L.
$$

胶囊是到线段 $AB$ 的距离不超过 $r$ 的点集。其**边界**由有限圆柱侧面及两端外半球组成，不是整个圆柱面与两个完整球面的简单并集；后者会引入胶囊内部的错误交点。

### 1. 射线参数与方向缩放

调用者给出的射线为 $\mathbf p(t)=\mathbf o+t\mathbf v$，不要求 $\mathbf v$ 为单位向量。内部先以最大绝对分量 $m$ 缩放，再归一化为 $\mathbf d$，使用距离参数 $s$：

$$
\mathbf d=\frac{\mathbf v/m}{\|\mathbf v/m\|},\qquad
t=\frac{s/\|\mathbf v/m\|}{m}.
$$

这样不必直接计算可能上溢/下溢的 $\mathbf v\cdot\mathbf v$。零或非有限方向不命中；查询区间为闭区间 $[t_{\min},t_{\max}]$，允许负参数，且仅接受有限根。

### 2. 有限圆柱侧面

令 $\mathbf q=\mathbf o-A$，分离轴向和径向分量：

$$
q_\parallel=\mathbf q\cdot\mathbf w,\quad
d_\parallel=\mathbf d\cdot\mathbf w,\quad
\mathbf q_\perp=\mathbf q-q_\parallel\mathbf w,\quad
\mathbf d_\perp=\mathbf d-d_\parallel\mathbf w.
$$

侧面满足

$$
\|\mathbf q_\perp+s\mathbf d_\perp\|^2=r^2
\quad\Longrightarrow\quad
a s^2+2h s+c=0,
$$

其中 $a=\|\mathbf d_\perp\|^2$，$h=\mathbf q_\perp\cdot\mathbf d_\perp$，$c=\|\mathbf q_\perp\|^2-r^2$。每个根必须进一步满足

$$0\le q_\parallel+s d_\parallel\le L.$$

严格轴平行时径向方向为零，不产生独立侧面根，交点由端帽处理。不以固定 epsilon 将近平行方向当成平行，以免漏掉长毛束上的有效交点。恰与侧面母线重合的射线，约定返回满足查询范围的端帽接缝根，而不枚举连续重合区间。

### 3. 外半球端帽

分别对以 $A$、$B$ 为球心、半径 $r$ 的球求两个根，但只保留：

$$
(\mathbf p-A)\cdot\mathbf w\le0 \quad\text{（起点帽）},\qquad
(\mathbf p-B)\cdot\mathbf w\ge0 \quad\text{（终点帽）}.
$$

两根都要检查：近根可能不在查询区间内，也可能属于被裁去的内部半球。圆柱和两端帽的全部有效候选中取最小 $t$。这同时覆盖内部出射、端帽交点、接缝和切线。

### 4. 稳定二次根

通用径向求根器先缩放方向分量。对一般径向原点 $\mathbf q$ 和方向 $\mathbf d$，通过射线到球心/轴心的最近距离计算判别式：

$$
\rho^2=\frac{\|\mathbf q\times\mathbf d\|^2}{a},\qquad
\Delta=a(r^2-\rho^2).
$$

它避免直接计算 $h^2-ac$ 时，远距离大数相减吞掉半径信息。负差只有在 $8\epsilon\max(r^2,\rho^2)$ 的舍入量级以内才作为切线处理；真正的负判别式返回无根。这是浮点容差，而非无限精度几何保证。

根计算使用

$$
q_*=-h-\operatorname{sign}(h)\sqrt\Delta,\qquad
s_0=q_*/a,\quad s_1=c/q_*,
$$

并排序；$h=0$ 时符号选择正号。切线直接返回重复根 $-h/a$，避免 $0/0$。$c$ 用 $(\|\mathbf q\|-r)(\|\mathbf q\|+r)$ 计算。当 $\sqrt\Delta<|h|/2$、直接求另一根没有严重消减时，使用直接公式，避免韦达乘积增加额外舍入。

### 5. 法线、UV 与包围盒

圆柱外向法线来自径向向量，端帽外向法线来自交点减球心，两者均归一化。遵循现有 `HitRecord` 约定：

- `front_face` 表示入射方向与几何外向法线的点积严格小于零。
- `normal` 是面向入射侧的单位法线；内部出射时它与几何外向法线相反。
- 精确切线点积为零，`front_face=false`。
- `u=0`；`v=clamp((axial+r)/(L+2r),0,1)` 是贯穿两端帽的简单纵向坐标，不是完整圆周 UV 展开。

精确轴对齐包围盒为

$$
\mathbf b_{\min}=\min(A,B)-(r,r,r),\qquad
\mathbf b_{\max}=\max(A,B)+(r,r,r).
$$

这里的最小/最大是逐分量操作。静态胶囊忽略时间，交换端点不改变几何与包围盒，只反转纵向坐标。

## 带时间的光源采样 API

- `Object.pdfValueAt(o, v, time)` 返回相对于立体角的密度；`v` 可非单位。
- `Object.randomAt(o, time)` 返回配对采样方向，不保证单位长度。
- 旧 `pdfValue(o,v)` 与 `random(o)` 严格委托 `time=0`，不是球体的 `time0`。`Sphere`、`ObjectGroup` 的旧接口也遵守此约定。
- 调用方应让生成、密度求值和实际光线求交使用同一个路径时间。无需在本改动中修改主 `LightSampler`。

| 对象 | 支持方式 |
| --- | --- |
| `sphere` | 使用 `center(time)`，球外圆锥、球内整个球面 |
| `xy_rect` / `xz_rect` / `yz_rect` | 均匀面积采样，转换为立体角 PDF |
| `group` | 均匀选择成员，成员 PDF 等权求和；逐层传播时间 |
| `flip_face` | 分布和 PDF 原样委托；发光面的朝向仍由材质判定 |
| `translate` | 观察点减偏移量，方向不平移 |
| `rotate_y` | 观察点和查询方向逆旋转；生成方向正旋转 |
| `capsule` / `box` / `constant_medium` / `bvh` | **不支持光源采样**，PDF 为零，生成器返回占位方向 `(1,0,0)` |

空组同样返回零 PDF 和占位方向。光源组中的每个成员必须支持完整的生成/PDF 配对；不要把不支持的图元混入组后当作归一化分布。BVH 仍然可用于这些光源的几何求交，但不能直接代替可采样的光源组。

### 球体：时间、内部与小圆锥

球心按给定时间线性插值，区间外会外推；零时间跨度按静止在 `center0` 处理。令 $d=\|\mathbf c(time)-\mathbf o\|$。

球外 $d\ge r$ 时，均匀采样可见圆锥：

$$
x=(r/d)^2,\qquad
1-\cos\theta_{\max}=\frac{x}{1+\sqrt{1-x}},\qquad
p_\omega=\frac1{2\pi(1-\cos\theta_{\max})}.
$$

有理化公式避免远处小球的 $1-\sqrt{1-x}$ 消减为零。采样使用均匀方位角和 $\delta=u(1-\cos\theta_{\max})$，由 $z=1-\delta$、$\sin\theta=\sqrt{\delta(2-\delta)}$ 构造局部方向；即使 $z$ 舍入到 1，也尽量保留径向角度。PDF 用正弦平方判断圆锥支持域，且排除背向方向。

球内 $d<r$ 时，每个方向都有表面出口，因此使用整个单位球面：

$$z=1-2u,\quad\phi=2\pi v,\qquad p_\omega=\frac1{4\pi}.$$

球面上 $d=r$ 约定采样朝球心的半球，密度为 $1/(2\pi)$，不采样朝外的零距离交点。零/非有限查询方向返回零。光源几何采样不决定单面发光是否有效，后者仍由发光材质按 `front_face` 判定。

### 矩形：面积到立体角的转换

面积为 $A$ 的矩形上均匀取点 $\mathbf x$，生成非单位方向 $\mathbf v=\mathbf x-\mathbf o$。令 $d=\|\mathbf x-\mathbf o\|$，$\theta$ 为几何法线与观察方向的夹角：

$$
d\omega=\frac{|\cos\theta|}{d^2}\,dA,\qquad
p_\omega=p_A\frac{d^2}{|\cos\theta|}
=\frac{d^2}{A|\cos\theta|}.
$$

如果直接使用非单位射线参数，必须用 $d^2=t^2\|\mathbf v\|^2$，不能只用 $t^2$。实现先稳定归一化方向再求交，因此所得参数就是距离，不受输入方向大小影响；不使用旧的固定参数下界 `0.001`。平行、共面、零方向、非正面积和零距离返回零 PDF。矩形边界须有限且有序。

### 刚体变换与法线修复

平移不改变方向；旋转保持立体角，因此两个变换都不需要 PDF 的额外雅可比因子。`flip_face` 只翻转正反面标志，不改变已经面向入射侧的法线，也不改变双侧的几何方向分布。

旧平移实现会把已经面向入射侧的 `normal` 再当作外向法线，使内部出射被误判为正面。现在只平移交点。旧旋转实现用局部射线与世界法线再次定向，混用了坐标系。现在正旋转交点及保存的法线，保留子对象的 `front_face`：

$$ (R\mathbf d)\cdot(R\mathbf n)=\mathbf d\cdot\mathbf n. $$

`RotateY` 的缓存包围盒仍按构造时 `[0,1]` 计算，BVH 包围盒仍按其构建时间范围缓存；这一既有约束未改动。若场景使用其他快门范围，集成方须确保加速结构的包围盒覆盖实际运动。

## 验证范围

独立测试链接现有 stb C 实现与 libc，不要求主测试根导入新增文件：

- 已知圆柱、上下端帽、偏心轴平行、内部出口、切线、接缝、未命中与闭区间最近根。
- 非轴对齐线段、交换端点、单位法线、UV 范围、精确包围盒及现有 BVH 遍历。
- 方向缩放 `1e-200` 到 `1e200`、距离 `1e8`、近表面根、长段近平行射线。
- 参数校验先于分配，以及两个分配点的全部 OOM 清理路径。
- 移动球的多个时间点、球内均匀方向的矩、零快门跨度、球面半球及远距离小圆锥。
- 三种矩形的解析 PDF、极端方向缩放、共面/平行拒绝和近距离光源。
- 内外命中的平移/旋转/翻面组合回归，变换光源、组的时间传播、旧接口的时间零兼容性及显式不支持的采样分支。

统计测试使用固定种子和宽于抽样噪声的容差；不承诺不同 Zig 版本之间随机序列或浮点结果逐位一致。