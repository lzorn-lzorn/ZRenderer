const std = @import("std");
const math = @import("math.zig");
const rng = @import("random.zig");
const material = @import("material.zig");
const mesh = @import("mesh.zig");
const texture = @import("texture.zig");

const Point3 = math.Point3;
const Vec3 = math.Vec3;
const Ray = math.Ray;
const Aabb = math.Aabb;
const Onb = math.Onb;
const Allocator = std.mem.Allocator;

// @brief 真实径向位移水球；保持 Object 入口并独立实现隐式曲面求交。
pub const WavySphere = @import("water.zig").WavySphere;

// @brief 保存射线命中的参数、位置、纹理坐标、朝向法线及借用材质。
pub const HitRecord = struct {
    front_face: bool = false,
    t: f64 = 0,
    u: f64 = 0,
    v: f64 = 0,
    p: Point3 = .{},
    normal: Vec3 = .{},
    material: ?*material.Material = null,
    // @brief 可选的形状级 alpha 掩码纹理；材质求值时据此计算不透明度。
    alpha: ?*texture.Texture = null,

    // @brief 根据入射方向记录正反面，并使保存的法线朝向入射侧。
    // @param outward_normal 几何体的外向单位法线。
    pub fn setFaceNormal(self: *HitRecord, r: Ray, outward_normal: Vec3) void {
        self.front_face = r.direction.dot(outward_normal) < 0;
        self.normal = if (self.front_face) outward_normal else outward_normal.neg();
    }
};

// @brief 对几何体、变换、介质和加速结构统一分派；各分支指针均为借用引用。
pub const Object = union(enum) {
    sphere: *Sphere,
    wavy_sphere: *WavySphere,
    capsule: *Capsule,
    xy_rect: *XyRect,
    xz_rect: *XzRect,
    yz_rect: *YzRect,
    group: *ObjectGroup,
    flip_face: *FlipFace,
    box: *Box,
    translate: *Translate,
    rotate_y: *RotateY,
    constant_medium: *ConstantMedium,
    bvh: *BvhNode,
    mesh: *mesh.TriangleMesh,
    instance: *Instance,

    // @brief 查询参数闭区间内的命中。
    // @param r 方向不要求归一化的射线。
    // @param t_min 允许的最小射线参数。
    // @param t_max 允许的最大射线参数。
    // @param rec 成功时写入命中记录；失败时内容不应使用。
    // @return 是否命中；介质分支包含随机自由程抽样。
    pub fn hit(self: Object, r: Ray, t_min: f64, t_max: f64, rec: *HitRecord) bool {
        return switch (self) {
            .sphere => |s| s.hit(r, t_min, t_max, rec),
            .wavy_sphere => |s| s.hit(r, t_min, t_max, rec),
            .capsule => |s| s.hit(r, t_min, t_max, rec),
            .xy_rect => |s| s.hit(r, t_min, t_max, rec),
            .xz_rect => |s| s.hit(r, t_min, t_max, rec),
            .yz_rect => |s| s.hit(r, t_min, t_max, rec),
            .group => |s| s.hit(r, t_min, t_max, rec),
            .flip_face => |s| s.hit(r, t_min, t_max, rec),
            .box => |s| s.hit(r, t_min, t_max, rec),
            .translate => |s| s.hit(r, t_min, t_max, rec),
            .rotate_y => |s| s.hit(r, t_min, t_max, rec),
            .constant_medium => |s| s.hit(r, t_min, t_max, rec),
            .bvh => |s| s.hit(r, t_min, t_max, rec),
            .mesh => |s| s.hit(r, t_min, t_max, rec),
            .instance => |s| s.hit(r, t_min, t_max, rec),
        };
    }

    // @brief 查询指定时间区间的包围盒。
    // @param out 成功时写入包围盒。
    // @return 是否存在有效包围盒；部分包装器使用预先缓存的时间范围。
    pub fn boundingBox(self: Object, t0: f64, t1: f64, out: *Aabb) bool {
        return switch (self) {
            .sphere => |s| s.boundingBox(t0, t1, out),
            .wavy_sphere => |s| s.boundingBox(t0, t1, out),
            .capsule => |s| s.boundingBox(t0, t1, out),
            .xy_rect => |s| s.boundingBox(t0, t1, out),
            .xz_rect => |s| s.boundingBox(t0, t1, out),
            .yz_rect => |s| s.boundingBox(t0, t1, out),
            .group => |s| s.boundingBox(t0, t1, out),
            .flip_face => |s| s.boundingBox(t0, t1, out),
            .box => |s| s.boundingBox(t0, t1, out),
            .translate => |s| s.boundingBox(t0, t1, out),
            .rotate_y => |s| s.boundingBox(t0, t1, out),
            .constant_medium => |s| s.boundingBox(t0, t1, out),
            .bvh => |s| s.boundingBox(t0, t1, out),
            .mesh => |s| s.boundingBox(t0, t1, out),
            .instance => |s| s.boundingBox(t0, t1, out),
        };
    }

    // @brief 兼容接口，返回 time=0 的立体角密度。
    pub fn pdfValue(self: Object, o: Point3, v: Vec3) f64 {
        return self.pdfValueAt(o, v, 0);
    }

    // @brief 返回指定路径时间的方向采样立体角密度。
    // @param o 世界空间观察点；v 为非零、可非单位的世界方向。
    // @param time 与后续求交射线使用相同的时间。
    // @return 不支持的分支或无效方向返回零。
    // @notice 支持球、三种矩形、组、翻面、平移及 y 旋转；水球、胶囊、盒、介质和 BVH 不支持光源采样。
    pub fn pdfValueAt(self: Object, o: Point3, v: Vec3, time: f64) f64 {
        return switch (self) {
            .sphere => |s| s.pdfValueAt(o, v, time),
            .wavy_sphere => 0.0,
            .xy_rect => |s| rectanglePdf(self, o, v, time, (s.x1 - s.x0) * (s.y1 - s.y0)),
            .xz_rect => |s| rectanglePdf(self, o, v, time, (s.x1 - s.x0) * (s.z1 - s.z0)),
            .yz_rect => |s| rectanglePdf(self, o, v, time, (s.y1 - s.y0) * (s.z1 - s.z0)),
            .group => |s| s.pdfValueAt(o, v, time),
            .flip_face => |s| s.ptr.pdfValueAt(o, v, time),
            .translate => |s| s.ptr.pdfValueAt(o.sub(s.offset), v, time),
            .rotate_y => |s| s.ptr.pdfValueAt(s.toLocal(o), s.toLocal(v), time),
            else => 0.0,
        };
    }

    // @brief 兼容接口，委托 time=0 的方向生成。
    pub fn random(self: Object, o: Point3) Vec3 {
        return self.randomAt(o, 0);
    }

    // @brief 从世界空间原点 o 抽取指定路径时间的光源方向。
    // @param time 与 pdfValueAt 及后续求交保持一致。
    // @return 方向不保证单位长度；水球返回零向量，其余不支持的分支保留占位方向 (1,0,0)。
    // @notice 对象组中的每个成员都必须支持采样；翻面不改变几何分布和 PDF。
    pub fn randomAt(self: Object, o: Point3, time: f64) Vec3 {
        return switch (self) {
            .sphere => |s| s.randomAt(o, time),
            .wavy_sphere => Vec3.init(0, 0, 0),
            .xy_rect => |s| Point3.init(rng.randomDoubleRange(s.x0, s.x1), rng.randomDoubleRange(s.y0, s.y1), s.k).sub(o),
            .xz_rect => |s| s.random(o),
            .yz_rect => |s| Point3.init(s.k, rng.randomDoubleRange(s.y0, s.y1), rng.randomDoubleRange(s.z0, s.z1)).sub(o),
            .group => |s| s.randomAt(o, time),
            .flip_face => |s| s.ptr.randomAt(o, time),
            .translate => |s| s.ptr.randomAt(o.sub(s.offset), time),
            .rotate_y => |s| s.toWorld(s.ptr.randomAt(s.toLocal(o), time)),
            else => Vec3.init(1, 0, 0),
        };
    }
};

// @brief 几何体分配辅助函数。

// @brief 分配带材质的运动球体及其对象包装。
// @param cen0 起始球心；cen1 为结束球心，t0/t1 为对应时间。
// @param r 球体半径。
// @param m 借用材质指针。
// @return 新对象或分配错误；成功分配由调用者的场景生命周期管理。
pub fn newSphere(alloc: Allocator, cen0: Point3, cen1: Point3, t0: f64, t1: f64, r: f64, m: *material.Material) Allocator.Error!*Object {
    const s = try alloc.create(Sphere);
    errdefer alloc.destroy(s);
    s.* = Sphere.init(cen0, cen1, t0, t1, r, m);
    const o = try alloc.create(Object);
    o.* = .{ .sphere = s };
    return o;
}

// @brief 分配静态真实位移水球及对象包装；不创建或修改材质。
// @param alloc 场景分配器；center 为有限世界球心，radius 为有限正半径。
// @param amplitude 半径比例，范围 [0,0.1]，建议 0.035。
// @param frequency 无量纲角频率，范围 [0,40]，建议 14；mat 为借用材质。
// @return 新对象或 InvalidWavySphere/OutOfMemory；两次分配均保证失败清理。
// @notice 可直接使用普通 dielectric(1.333)；水球不支持光源方向采样。
pub fn newWavySphere(alloc: Allocator, center: Point3, radius: f64, amplitude: f64, frequency: f64, mat: *material.Material) !*Object {
    const value = try WavySphere.init(center, radius, amplitude, frequency, mat);
    const sphere = try alloc.create(WavySphere);
    errdefer alloc.destroy(sphere);
    sphere.* = value;
    const obj = try alloc.create(Object);
    obj.* = .{ .wavy_sphere = sphere };
    return obj;
}

// @brief 分配有限圆柱和两个半球端帽组成的静态胶囊，用作细杆/纤维段几何。
// @param start 轴线起点；end 为不同于起点的有限终点。
// @param radius 有限且严格为正的半径；mat 为借用表面材质。
// @return 对象或 InvalidCapsule/OutOfMemory；失败自动清理，成功由场景分配器管理。
// @notice 这不是毛发散射模型；普通表面 BSDF 不描述纤维内部散射。
pub fn newCapsule(alloc: Allocator, start: Point3, end: Point3, radius: f64, mat: *material.Material) !*Object {
    const length = vectorLength(end.sub(start));
    if (!finiteVector(start) or !finiteVector(end) or !std.math.isFinite(radius) or radius <= 0 or
        !std.math.isFinite(length) or length <= 0) return error.InvalidCapsule;
    const capsule = try alloc.create(Capsule);
    errdefer alloc.destroy(capsule);
    capsule.* = .{ .start = start, .end = end, .radius = radius, .material = mat };
    const obj = try alloc.create(Object);
    obj.* = .{ .capsule = capsule };
    return obj;
}

// @brief 分配 z=k 平面上的 xy 矩形及对象包装，边界按各轴给定。
// @return 新对象或分配错误；材质 m 为借用引用。
pub fn newXyRect(alloc: Allocator, x0: f64, x1: f64, y0: f64, y1: f64, k: f64, m: *material.Material) Allocator.Error!*Object {
    const s = try alloc.create(XyRect);
    errdefer alloc.destroy(s);
    s.* = .{ .x0 = x0, .x1 = x1, .y0 = y0, .y1 = y1, .k = k, .material = m };
    const o = try alloc.create(Object);
    o.* = .{ .xy_rect = s };
    return o;
}

// @brief 分配 y=k 平面上的 xz 矩形及对象包装，边界按各轴给定。
// @return 新对象或分配错误；材质 m 为借用引用。
pub fn newXzRect(alloc: Allocator, x0: f64, x1: f64, z0: f64, z1: f64, k: f64, m: *material.Material) Allocator.Error!*Object {
    const s = try alloc.create(XzRect);
    errdefer alloc.destroy(s);
    s.* = .{ .x0 = x0, .x1 = x1, .z0 = z0, .z1 = z1, .k = k, .material = m };
    const o = try alloc.create(Object);
    o.* = .{ .xz_rect = s };
    return o;
}

// @brief 分配 x=k 平面上的 yz 矩形及对象包装，边界按各轴给定。
// @return 新对象或分配错误；材质 m 为借用引用。
pub fn newYzRect(alloc: Allocator, y0: f64, y1: f64, z0: f64, z1: f64, k: f64, m: *material.Material) Allocator.Error!*Object {
    const s = try alloc.create(YzRect);
    errdefer alloc.destroy(s);
    s.* = .{ .y0 = y0, .y1 = y1, .z0 = z0, .z1 = z1, .k = k, .material = m };
    const o = try alloc.create(Object);
    o.* = .{ .yz_rect = s };
    return o;
}

fn wrapBvh(alloc: Allocator, node: *BvhNode) Allocator.Error!*Object {
    const o = try alloc.create(Object);
    o.* = .{ .bvh = node };
    return o;
}

// @brief 分配三角形网格对象包装；网格所有权仍由调用方/场景分配器管理。
// @return 新对象或分配错误。
pub fn buildMesh(alloc: Allocator, m: *mesh.TriangleMesh) Allocator.Error!*Object {
    const o = try alloc.create(Object);
    o.* = .{ .mesh = m };
    return o;
}

// @brief 分配仿射变换实例包装；借用被包装对象并缓存对象到世界的变换。
// @return 新对象或分配错误。
// @notice 实例不支持光源方向采样，PDF 为零、生成方向为占位；主要用于共享网格的重复摆放。
pub fn buildInstance(alloc: Allocator, ptr: *Object, transform: math.Transform) Allocator.Error!*Object {
    const inst = try alloc.create(Instance);
    errdefer alloc.destroy(inst);
    inst.* = .{ .ptr = ptr, .transform = transform };
    const o = try alloc.create(Object);
    o.* = .{ .instance = inst };
    return o;
}

// @brief 对象组。

// @brief 保存借用对象指针的动态列表，支持最近命中及等权方向混合。
pub const ObjectGroup = struct {
    alloc: Allocator,
    list: std.ArrayList(*Object),

    // @brief 建立空列表，后续容量使用 alloc 分配。
    pub fn init(alloc: Allocator) ObjectGroup {
        return .{ .alloc = alloc, .list = .empty };
    }

    // @brief 追加借用对象；扩容失败时返回分配错误。
    pub fn add(self: *ObjectGroup, obj: *Object) !void {
        try self.list.append(self.alloc, obj);
    }

    // @brief 清空列表但保留容量，不销毁对象。
    pub fn clear(self: *ObjectGroup) void {
        self.list.clearRetainingCapacity();
    }

    // @brief 线性遍历并逐步收紧上界，成功时将最近命中写入 rec。
    pub fn hit(self: ObjectGroup, r: Ray, t_min: f64, t_max: f64, rec: *HitRecord) bool {
        var temp_rec: HitRecord = .{};
        var hit_anything = false;
        var closest_so_far = t_max;
        for (self.list.items) |obj| {
            if (obj.hit(r, t_min, closest_so_far, &temp_rec)) {
                hit_anything = true;
                closest_so_far = temp_rec.t;
                rec.* = temp_rec;
            }
        }
        return hit_anything;
    }

    // @brief 合并各对象在指定时间范围的包围盒；空组或缺失包围盒时失败。
    pub fn boundingBox(self: ObjectGroup, t0: f64, t1: f64, out: *Aabb) bool {
        if (self.list.items.len == 0) return false;
        var temp_box: Aabb = undefined;
        var is_first = true;
        for (self.list.items) |obj| {
            if (!obj.boundingBox(t0, t1, &temp_box)) return false;
            out.* = if (is_first) temp_box else math.surroundingBox(out.*, temp_box);
            is_first = false;
        }
        return true;
    }

    // @brief 返回各成员立体角密度的等权平均；空组返回零。
    // @method **等权混合**：$p(\omega)=\sum_{j=1}^{N}p_j(\omega)/N$，与均匀选择成员一致。
    pub fn pdfValue(self: ObjectGroup, o: Point3, v: Vec3) f64 {
        return self.pdfValueAt(o, v, 0);
    }

    // @brief 在相同路径时间求各成员 PDF 的等权平均；空组返回零。
    pub fn pdfValueAt(self: ObjectGroup, o: Point3, v: Vec3, time: f64) f64 {
        const n = self.list.items.len;
        if (n == 0) return 0.0;
        const weight = 1.0 / @as(f64, @floatFromInt(n));
        var sum: f64 = 0.0;
        for (self.list.items) |obj| {
            sum += weight * obj.pdfValueAt(o, v, time);
        }
        return sum;
    }

    // @brief 均匀选择成员并采样方向；空组返回占位方向。
    // @notice 用作有效分布时，每个成员都必须支持配对的方向生成和密度求值。
    pub fn random(self: ObjectGroup, o: Point3) Vec3 {
        return self.randomAt(o, 0);
    }

    // @brief 均匀选择成员，将路径时间原样传入其方向生成器。
    pub fn randomAt(self: ObjectGroup, o: Point3, time: f64) Vec3 {
        const n = self.list.items.len;
        if (n == 0) return Vec3.init(1, 0, 0);
        const idx: usize = @intCast(rng.randomInt(0, @intCast(n - 1)));
        return self.list.items[idx].randomAt(o, time);
    }
};

// @brief 正反面翻转包装。

// @brief 仅翻转命中记录中的正反面标志，保留已朝向入射侧的法线。
pub const FlipFace = struct {
    ptr: *Object,

    // @brief 委托求交，成功后翻转 front_face。
    pub fn hit(self: FlipFace, r: Ray, t_min: f64, t_max: f64, rec: *HitRecord) bool {
        if (!self.ptr.hit(r, t_min, t_max, rec)) return false;
        rec.front_face = !rec.front_face;
        return true;
    }

    // @brief 直接返回被包装对象的包围盒。
    pub fn boundingBox(self: FlipFace, t0: f64, t1: f64, out: *Aabb) bool {
        return self.ptr.boundingBox(t0, t1, out);
    }
};

// @brief 检查向量分量，避免无效输入传播为伪命中。
fn finiteVector(v: Vec3) bool {
    return std.math.isFinite(v.x) and std.math.isFinite(v.y) and std.math.isFinite(v.z);
}

fn maxComponent(v: Vec3) f64 {
    return @max(@abs(v.x), @max(@abs(v.y), @abs(v.z)));
}

// @brief 先按最大分量缩放，避免长度平方无谓上溢或下溢。
fn vectorLength(v: Vec3) f64 {
    const scale = maxComponent(v);
    if (scale == 0) return 0;
    return Vec3.init(v.x / scale, v.y / scale, v.z / scale).length() * scale;
}

fn unitDirection(v: Vec3) ?Vec3 {
    if (!finiteVector(v)) return null;
    const scale = maxComponent(v);
    if (scale == 0) return null;
    return Vec3.init(v.x / scale, v.y / scale, v.z / scale).normalized();
}

// @brief 求解径向方程的两个有序根；零方向和真正的负判别式无根。
// @method **稳定根**：$at^2+2ht+c=0$，$q=-h-\operatorname{sign}(h)\sqrt{\Delta}$，根为 $q/a,c/q$。
// @method 用最近距离计算 $\Delta=a(r^2-\|\mathbf{o}\times\mathbf{d}\|^2/a)$，避免远处射线的 $h^2-ac$ 消减。
// @notice 只将半径尺度内数个 ulp 的负差判为切线；不使用会吞掉近平行射线的方向阈值。
fn radialRoots(origin: Vec3, direction: Vec3, radius: f64) ?[2]f64 {
    const scale = maxComponent(direction);
    if (scale == 0 or !std.math.isFinite(scale)) return null;
    const d = Vec3.init(direction.x / scale, direction.y / scale, direction.z / scale);
    const a = d.lengthSquared();
    const h = origin.dot(d);
    const distance2 = origin.cross(d).lengthSquared() / a;
    const radius2 = radius * radius;
    var gap = radius2 - distance2;
    if (!std.math.isFinite(gap) or gap < -8 * math.epsilon * @max(radius2, distance2)) return null;
    gap = @max(0, gap);
    const root_delta = @sqrt(a) * @sqrt(gap);
    if (root_delta == 0) return .{ (-h / a) / scale, (-h / a) / scale };
    const q = if (h >= 0) -h - root_delta else -h + root_delta;
    const length = vectorLength(origin);
    const c = (length - radius) * (length + radius);
    const first = (q / a) / scale;
    // @notice 两项量级分离时直接相减更准确；仅在可能发生消减时使用韦达乘积根。
    const second = if (root_delta < 0.5 * @abs(h))
        ((if (h >= 0) -h + root_delta else -h - root_delta) / a) / scale
    else
        (c / q) / scale;
    return .{ @min(first, second), @max(first, second) };
}

// @brief 静态胶囊：有限圆柱侧面加两端外半球；材质指针为借用引用。
// @notice 直接初始化时也须满足 newCapsule 的有限、正半径和非退化轴线约束。
pub const Capsule = struct {
    start: Point3,
    end: Point3,
    radius: f64,
    material: *material.Material,

    // @brief 返回闭区间内最近表面命中，支持非单位方向、切线、轴平行和内部出射。
    // @param r 世界空间射线；零方向不命中。
    // @param rec 保存面向入射侧的单位法线；front_face 标识几何外侧。
    // @return 是否命中；UV 的 v 是沿完整胶囊长度的归一化位置，u 固定为零。
    // @method **轴向分解**：$\mathbf{w}=(B-A)/L$，$\mathbf{o}_\perp=\mathbf{o}-A-\mathbf{w}[(\mathbf{o}-A)\cdot\mathbf{w}]$。
    // @method 对 $\|\mathbf{o}_\perp+s\mathbf{d}_\perp\|^2=r^2$ 求根，仅保留 $0\le(\mathbf{p}-A)\cdot\mathbf{w}\le L$。
    // @method 两球根分别只保留 $(\mathbf{p}-A)\cdot\mathbf{w}\le0$ 和 $(\mathbf{p}-B)\cdot\mathbf{w}\ge0$，避免命中内部球面。
    pub fn hit(self: Capsule, r: Ray, t_min: f64, t_max: f64, rec: *HitRecord) bool {
        if (t_min > t_max or std.math.isNan(t_min) or std.math.isNan(t_max) or !finiteVector(r.origin)) return false;
        const d = unitDirection(r.direction) orelse return false;
        const direction_scale = maxComponent(r.direction);
        const scaled_length = Vec3.init(r.direction.x / direction_scale, r.direction.y / direction_scale, r.direction.z / direction_scale).length();
        const length = vectorLength(self.end.sub(self.start));
        if (!(length > 0) or !std.math.isFinite(length) or !(self.radius > 0) or !std.math.isFinite(self.radius)) return false;
        const axis = self.end.sub(self.start).div(length);
        const offset = r.origin.sub(self.start);
        const axial_origin = offset.dot(axis);
        const axial_direction = d.dot(axis);
        const perpendicular_origin = offset.sub(axis.scale(axial_origin));
        const perpendicular_direction = d.sub(axis.scale(axial_direction));
        var closest = t_max;
        var found = false;
        // @notice 每个表面都检查两个根：近根可能在区间外或属于被裁去的内半球。
        if (radialRoots(perpendicular_origin, perpendicular_direction, self.radius)) |roots| {
            for (roots) |s| {
                const t = (s / scaled_length) / direction_scale;
                const axial = @mulAdd(f64, s, axial_direction, axial_origin);
                if (!std.math.isFinite(t) or t < t_min or t > closest or axial < 0 or axial > length) continue;
                const normal = unitDirection(perpendicular_origin.add(perpendicular_direction.scale(s))) orelse continue;
                self.record(r, t, axial, length, normal, rec);
                closest = t;
                found = true;
            }
        }
        for ([_]Point3{ self.start, self.end }, 0..) |center_point, cap| {
            const cap_origin = r.origin.sub(center_point);
            if (radialRoots(cap_origin, d, self.radius)) |roots| {
                for (roots) |s| {
                    const t = (s / scaled_length) / direction_scale;
                    const local = cap_origin.add(d.scale(s));
                    const axial = local.dot(axis);
                    if (!std.math.isFinite(t) or t < t_min or t > closest) continue;
                    if ((cap == 0 and axial > 0) or (cap == 1 and axial < 0)) continue;
                    const normal = unitDirection(local) orelse continue;
                    self.record(r, t, axial + (if (cap == 0) @as(f64, 0) else length), length, normal, rec);
                    closest = t;
                    found = true;
                }
            }
        }
        return found;
    }

    fn record(self: Capsule, r: Ray, t: f64, axial: f64, length: f64, outward: Vec3, rec: *HitRecord) void {
        rec.* = .{ .t = t, .p = r.at(t), .u = 0, .v = math.clamp((axial + self.radius) / (length + 2 * self.radius), 0, 1), .material = self.material };
        rec.setFaceNormal(r, outward);
    }

    // @brief 返回端点逐分量最小/最大值向外扩张 radius 的精确静态包围盒。
    // @param t0 时间区间起点；t1 为终点，静态图元均忽略。
    pub fn boundingBox(self: Capsule, t0: f64, t1: f64, out: *Aabb) bool {
        _ = t0;
        _ = t1;
        out.* = Aabb.init(
            Point3.init(@min(self.start.x, self.end.x), @min(self.start.y, self.end.y), @min(self.start.z, self.end.z)).subScalar(self.radius),
            Point3.init(@max(self.start.x, self.end.x), @max(self.start.y, self.end.y), @max(self.start.z, self.end.z)).addScalar(self.radius),
        );
        return true;
    }
};

// @brief 矩形面积采样的立体角密度，先归一化方向使判定不依赖方向长度。
// @method **测度变换**：$d\omega=|\cos\theta|dA/d^2$，故 $p_\omega=d^2/(A|\cos\theta|)$。
// @notice 排除零方向、非正面积、共面/平行射线及零距离；不使用固定参数 epsilon。
fn rectanglePdf(obj: Object, origin: Point3, v: Vec3, time: f64, area: f64) f64 {
    const direction = unitDirection(v) orelse return 0;
    if (!finiteVector(origin) or !(area > 0) or !std.math.isFinite(area)) return 0;
    var rec: HitRecord = .{};
    if (!obj.hit(Ray.init(origin, direction, time), 0, math.infinity, &rec) or !(rec.t > 0)) return 0;
    const cosine = @abs(direction.dot(rec.normal));
    if (!(cosine > 0)) return 0;
    const result = rec.t * rec.t / (cosine * area);
    return if (std.math.isFinite(result)) result else 0;
}

// @brief 球体。

// @brief 在两个时刻之间线性移动的球体。
pub const Sphere = struct {
    center0: Point3 = .{},
    center1: Point3 = .{},
    radius: f64 = 0,
    time0: f64 = 0,
    time1: f64 = 0,
    material: *material.Material,

    // @brief 保存端点球心、对应时间、半径及借用材质。
    pub fn init(cen0: Point3, cen1: Point3, t0: f64, t1: f64, r: f64, m: *material.Material) Sphere {
        return .{ .center0 = cen0, .center1 = cen1, .time0 = t0, .time1 = t1, .radius = r, .material = m };
    }

    // @brief 求时间对应球体在参数闭区间内的最近交点。
    // @method **二次方程**：令 $\mathbf{q}=\mathbf{o}-\mathbf{c}(time)$，代入球面得 $at^2+2ht+c=0$。
    // @method 其中 $a=\mathbf{d}\cdot\mathbf{d}$、$h=\mathbf{q}\cdot\mathbf{d}$、$c=\mathbf{q}\cdot\mathbf{q}-r^2$；依次检查根 $(-h\mp\sqrt{h^2-ac})/a$。
    pub fn hit(self: Sphere, r: Ray, t_min: f64, t_max: f64, rec: *HitRecord) bool {
        const oc = r.origin.sub(self.center(r.time));
        const a = r.direction.lengthSquared();
        const half_b = oc.dot(r.direction);
        const c = oc.lengthSquared() - self.radius * self.radius;

        const discriminant = half_b * half_b - a * c;
        if (discriminant < 0) return false;
        const sqrtd = @sqrt(discriminant);
        const inv_a = 1.0 / a;

        var root = (-half_b - sqrtd) * inv_a;
        if (root < t_min or t_max < root) {
            root = (-half_b + sqrtd) * inv_a;
            if (root < t_min or t_max < root) return false;
        }

        rec.t = root;
        rec.p = r.at(rec.t);
        const outward_normal = rec.p.sub(self.center(r.time)).scale(1.0 / self.radius);
        rec.setFaceNormal(r, outward_normal);
        getSphereUv(outward_normal, &rec.u, &rec.v);
        rec.material = self.material;
        return true;
    }

    // @brief 兼容接口，委托 time=0 的球体方向密度。
    pub fn pdfValue(self: Sphere, o: Point3, v: Vec3) f64 {
        return self.pdfValueAt(o, v, 0);
    }

    // @brief 按 center(time) 返回球外圆锥或球内均匀球面的立体角密度。
    // @param v 可非单位的非零方向；无效输入或圆锥外方向返回零。
    // @method **球面帽**：$x=r^2/d^2$，$1-\cos\theta_{max}=x/(1+\sqrt{1-x})$，$p=1/[2\pi(1-\cos\theta_{max})]$。
    // @method 球内每个方向均有出口，故 $p=1/(4\pi)$；球面上采用朝球心的半球。
    pub fn pdfValueAt(self: Sphere, o: Point3, v: Vec3, time: f64) f64 {
        const unit = unitDirection(v) orelse return 0;
        const direction = self.center(time).sub(o);
        const distance = vectorLength(direction);
        if (!finiteVector(direction) or !std.math.isFinite(distance) or !std.math.isFinite(self.radius) or self.radius <= 0) return 0;
        if (distance < self.radius) return 1.0 / (4.0 * math.pi);
        const axis = unitDirection(direction) orelse return 0;
        if (unit.dot(axis) < 0) return 0;
        const ratio = self.radius / distance;
        const x = ratio * ratio;
        // @notice 用正弦平方判断小圆锥，避免 cos(theta) 舍入为 1 后丢失角度分辨率。
        if (unit.cross(axis).lengthSquared() > x * (1.0 + 16.0 * math.epsilon)) return 0;
        const one_minus_cos = x / (1.0 + @sqrt(@max(0, 1.0 - x)));
        const density = 1.0 / (2.0 * math.pi * one_minus_cos);
        return if (std.math.isFinite(density)) density else 0;
    }

    // @brief 兼容接口，委托 time=0 的方向生成。
    pub fn random(self: Sphere, o: Point3) Vec3 {
        return self.randomAt(o, 0);
    }

    // @brief 在指定时间的可见圆锥内均匀抽样；球内使用整个单位球面。
    // @param o 世界空间观察点；time 为当前路径时间。
    // @return 单位方向；无效几何返回占位方向。
    // @method **逆变换**：球内 $z=1-2u$；球外 $\delta=u(1-\cos\theta_{max})$、$z=1-\delta$、$\sin\theta=\sqrt{\delta(2-\delta)}$。
    pub fn randomAt(self: Sphere, o: Point3, time: f64) Vec3 {
        const direction = self.center(time).sub(o);
        const distance = vectorLength(direction);
        if (!finiteVector(direction) or !std.math.isFinite(distance) or !std.math.isFinite(self.radius) or self.radius <= 0) return Vec3.init(1, 0, 0);
        const phi = 2.0 * math.pi * rng.randomDouble();
        if (distance < self.radius) {
            const z = 1.0 - 2.0 * rng.randomDouble();
            const radial = @sqrt(@max(0, (1.0 - z) * (1.0 + z)));
            return Vec3.init(radial * @cos(phi), radial * @sin(phi), z);
        }
        const ratio = self.radius / distance;
        const x = ratio * ratio;
        const delta = rng.randomDouble() * (x / (1.0 + @sqrt(@max(0, 1.0 - x))));
        const radial = @sqrt(delta * (2.0 - delta));
        var uvw: Onb = .{};
        uvw.buildFromW(unitDirection(direction) orelse return Vec3.init(1, 0, 0));
        return uvw.local(Vec3.init(radial * @cos(phi), radial * @sin(phi), 1.0 - delta));
    }

    // @brief 对球心作线性时间插值，范围外会外推。
    // @notice 零时间跨度视为静止在 center0，避免任意路径时间下除以零。
    pub fn center(self: Sphere, time: f64) Point3 {
        const time_diff = time - self.time0;
        if (time_diff == 0 or self.time1 == self.time0) return self.center0;
        const inv_time_diff = 1.0 / (self.time1 - self.time0);
        return self.center0.add(self.center1.sub(self.center0).scale(time_diff * inv_time_diff));
    }

    // @brief 合并查询时间两端的球体包围盒，覆盖线性运动轨迹。
    pub fn boundingBox(self: Sphere, time0: f64, time1: f64, out: *Aabb) bool {
        const r = Vec3.init(self.radius, self.radius, self.radius);
        const box0 = Aabb.init(self.center(time0).sub(r), self.center(time0).add(r));
        const box1 = Aabb.init(self.center(time1).sub(r), self.center(time1).add(r));
        out.* = math.surroundingBox(box0, box1);
        return true;
    }

    fn getSphereUv(p: Point3, u: *f64, v: *f64) void {
        const theta = std.math.acos(-p.y);
        const phi = std.math.atan2(-p.z, p.x) + math.pi;
        u.* = phi * 0.5 / math.pi;
        v.* = theta / math.pi;
    }
};

// @brief 轴对齐矩形。

// @brief 位于 z=k 平面的矩形，几何法线朝正 z。
pub const XyRect = struct {
    x0: f64 = 0,
    x1: f64 = 0,
    y0: f64 = 0,
    y1: f64 = 0,
    k: f64 = 0,
    material: *material.Material,

    // @brief 与矩形平面求交并检查 xy 边界，成功时写入纹理坐标及命中记录。
    pub fn hit(self: XyRect, r: Ray, t_min: f64, t_max: f64, rec: *HitRecord) bool {
        if (r.direction.z == 0) return false;
        const t = (self.k - r.origin.z) / r.direction.z;
        if (!std.math.isFinite(t) or t < t_min or t > t_max) return false;
        const x = r.origin.x + t * r.direction.x;
        const y = r.origin.y + t * r.direction.y;
        if (x < self.x0 or x > self.x1 or y < self.y0 or y > self.y1) return false;
        rec.u = (x - self.x0) / (self.x1 - self.x0);
        rec.v = (y - self.y0) / (self.y1 - self.y0);
        rec.t = t;
        rec.setFaceNormal(r, Vec3.init(0, 0, 1));
        rec.material = self.material;
        rec.p = r.at(t);
        return true;
    }

    // @brief 返回沿 z 扩展微小厚度的静态包围盒，忽略时间参数。
    pub fn boundingBox(self: XyRect, t0: f64, t1: f64, out: *Aabb) bool {
        _ = t0;
        _ = t1;
        out.* = Aabb.init(Point3.init(self.x0, self.y0, self.k - 0.0001), Point3.init(self.x1, self.y1, self.k + 0.0001));
        return true;
    }
};

// @brief 位于 y=k 平面的矩形，支持均匀面积采样及立体角密度求值。
pub const XzRect = struct {
    x0: f64 = 0,
    x1: f64 = 0,
    z0: f64 = 0,
    z1: f64 = 0,
    k: f64 = 0,
    material: *material.Material,

    // @brief 与矩形平面求交并检查 xz 边界，成功时写入命中记录。
    pub fn hit(self: XzRect, r: Ray, t_min: f64, t_max: f64, rec: *HitRecord) bool {
        if (r.direction.y == 0) return false;
        const t = (self.k - r.origin.y) / r.direction.y;
        if (!std.math.isFinite(t) or t < t_min or t > t_max) return false;
        const x = r.origin.x + t * r.direction.x;
        const z = r.origin.z + t * r.direction.z;
        if (x < self.x0 or x > self.x1 or z < self.z0 or z > self.z1) return false;
        rec.u = (x - self.x0) / (self.x1 - self.x0);
        rec.v = (z - self.z0) / (self.z1 - self.z0);
        rec.t = t;
        rec.setFaceNormal(r, Vec3.init(0, 1, 0));
        rec.material = self.material;
        rec.p = r.at(t);
        return true;
    }

    // @brief 返回沿 y 扩展微小厚度的静态包围盒，忽略时间参数。
    pub fn boundingBox(self: XzRect, t0: f64, t1: f64, out: *Aabb) bool {
        _ = t0;
        _ = t1;
        out.* = Aabb.init(Point3.init(self.x0, self.k - 0.0001, self.z0), Point3.init(self.x1, self.k + 0.0001, self.z1));
        return true;
    }

    // @brief 将矩形均匀面积密度转换为从 origin 观察的立体角密度。
    // @param v 非零观察方向，不要求归一化。
    // @method **测度变换**：$d\omega=|\cos\theta|\,dA/d^2$，因此 $p_\omega=p_A d^2/|\cos\theta|=d^2/(A|\cos\theta|)$。
    // @method 非单位射线方向下，距离平方为 $d^2=t^2\|\mathbf{v}\|^2$；不能直接使用 t²。
    // @notice 非正面积、零方向、平行或共面射线返回零；求值与 Object.pdfValueAt 一致。
    pub fn pdfValue(self: XzRect, origin: Point3, v: Vec3) f64 {
        var rect = self;
        return rectanglePdf(.{ .xz_rect = &rect }, origin, v, 0, (self.x1 - self.x0) * (self.z1 - self.z0));
    }

    // @brief 在矩形上均匀抽取面积点，返回该点减 origin 的非单位方向。
    pub fn random(self: XzRect, origin: Point3) Vec3 {
        const random_point = Point3.init(rng.randomDoubleRange(self.x0, self.x1), self.k, rng.randomDoubleRange(self.z0, self.z1));
        return random_point.sub(origin);
    }
};

// @brief 位于 x=k 平面的矩形，几何法线朝正 x。
pub const YzRect = struct {
    y0: f64 = 0,
    y1: f64 = 0,
    z0: f64 = 0,
    z1: f64 = 0,
    k: f64 = 0,
    material: *material.Material,

    // @brief 与矩形平面求交并检查 yz 边界，成功时写入命中记录。
    pub fn hit(self: YzRect, r: Ray, t_min: f64, t_max: f64, rec: *HitRecord) bool {
        if (r.direction.x == 0) return false;
        const t = (self.k - r.origin.x) / r.direction.x;
        if (!std.math.isFinite(t) or t < t_min or t > t_max) return false;
        const y = r.origin.y + t * r.direction.y;
        const z = r.origin.z + t * r.direction.z;
        if (y < self.y0 or y > self.y1 or z < self.z0 or z > self.z1) return false;
        rec.u = (y - self.y0) / (self.y1 - self.y0);
        rec.v = (z - self.z0) / (self.z1 - self.z0);
        rec.t = t;
        rec.setFaceNormal(r, Vec3.init(1, 0, 0));
        rec.material = self.material;
        rec.p = r.at(t);
        return true;
    }

    // @brief 返回沿 x 扩展微小厚度的静态包围盒，忽略时间参数。
    pub fn boundingBox(self: YzRect, t0: f64, t1: f64, out: *Aabb) bool {
        _ = t0;
        _ = t1;
        out.* = Aabb.init(Point3.init(self.k - 0.0001, self.y0, self.z0), Point3.init(self.k + 0.0001, self.y1, self.z1));
        return true;
    }
};

// @brief 六面长方体。

// @brief 由六个矩形组成的轴对齐长方体。
pub const Box = struct {
    box_min: Point3 = .{},
    box_max: Point3 = .{},
    sides: ObjectGroup,

    // @brief 从最小、最大角点分配六个共享材质的面。
    // @notice 成功及部分构造资源由场景分配器生命周期管理，通常使用区域分配器。
    pub fn init(alloc: Allocator, p0: Point3, p1: Point3, m: *material.Material) !Box {
        var self = Box{ .box_min = p0, .box_max = p1, .sides = ObjectGroup.init(alloc) };
        try self.sides.add(try newXyRect(alloc, p0.x, p1.x, p0.y, p1.y, p1.z, m));
        try self.sides.add(try newXyRect(alloc, p0.x, p1.x, p0.y, p1.y, p0.z, m));
        try self.sides.add(try newXzRect(alloc, p0.x, p1.x, p0.z, p1.z, p1.y, m));
        try self.sides.add(try newXzRect(alloc, p0.x, p1.x, p0.z, p1.z, p0.y, m));
        try self.sides.add(try newYzRect(alloc, p0.y, p1.y, p0.z, p1.z, p1.x, m));
        try self.sides.add(try newYzRect(alloc, p0.y, p1.y, p0.z, p1.z, p0.x, m));
        return self;
    }

    // @brief 委托六面对象组返回最近命中。
    pub fn hit(self: Box, r: Ray, t_min: f64, t_max: f64, rec: *HitRecord) bool {
        return self.sides.hit(r, t_min, t_max, rec);
    }

    // @brief 返回长方体自身的静态包围盒。
    pub fn boundingBox(self: Box, t0: f64, t1: f64, out: *Aabb) bool {
        _ = t0;
        _ = t1;
        out.* = Aabb.init(self.box_min, self.box_max);
        return true;
    }
};

// @brief 几何变换包装。

// @brief 借用对象并施加固定平移。
pub const Translate = struct {
    ptr: *Object,
    offset: Vec3,

    // @brief 将射线平移到对象空间求交，再平移命中位置；法线和正反面保持不变。
    pub fn hit(self: Translate, r: Ray, t_min: f64, t_max: f64, rec: *HitRecord) bool {
        const moved_r = Ray.init(r.origin.sub(self.offset), r.direction, r.time);
        if (!self.ptr.hit(moved_r, t_min, t_max, rec)) return false;
        rec.p = rec.p.add(self.offset);
        return true;
    }

    // @brief 平移被包装对象在指定时间区间的包围盒。
    pub fn boundingBox(self: Translate, t0: f64, t1: f64, out: *Aabb) bool {
        if (!self.ptr.boundingBox(t0, t1, out)) return false;
        out.* = Aabb.init(out.min.add(self.offset), out.max.add(self.offset));
        return true;
    }
};

// @brief 绕 y 轴旋转的借用对象包装，缓存正余弦及包围盒。
pub const RotateY = struct {
    ptr: *Object,
    sin_theta: f64,
    cos_theta: f64,
    hasbox: bool,
    bbox: Aabb,

    // @brief 旋转原包围盒八个顶点，构造轴对齐外包盒。
    // @param angle 角度制旋转量。
    // @notice alloc 当前不使用；包围盒固定按时间 [0,1] 预计算。
    pub fn init(alloc: Allocator, p: *Object, angle: f64) RotateY {
        _ = alloc;
        const radians = math.degreesToRadians(angle);
        var self = RotateY{
            .ptr = p,
            .sin_theta = @sin(radians),
            .cos_theta = @cos(radians),
            .hasbox = false,
            .bbox = .{},
        };
        self.hasbox = p.boundingBox(0, 1, &self.bbox);

        var min = Point3.init(math.infinity, math.infinity, math.infinity);
        var max = Point3.init(-math.infinity, -math.infinity, -math.infinity);
        var i: i32 = 0;
        while (i < 2) : (i += 1) {
            var j: i32 = 0;
            while (j < 2) : (j += 1) {
                var k: i32 = 0;
                while (k < 2) : (k += 1) {
                    const x = @as(f64, @floatFromInt(i)) * self.bbox.max.x + @as(f64, @floatFromInt(1 - i)) * self.bbox.min.x;
                    const y = @as(f64, @floatFromInt(j)) * self.bbox.max.y + @as(f64, @floatFromInt(1 - j)) * self.bbox.min.y;
                    const z = @as(f64, @floatFromInt(k)) * self.bbox.max.z + @as(f64, @floatFromInt(1 - k)) * self.bbox.min.z;

                    const newx = self.cos_theta * x + self.sin_theta * z;
                    const newz = -self.sin_theta * x + self.cos_theta * z;

                    const tester = Vec3.init(newx, y, newz);
                    min = Point3.init(@min(min.x, tester.x), @min(min.y, tester.y), @min(min.z, tester.z));
                    max = Point3.init(@max(max.x, tester.x), @max(max.y, tester.y), @max(max.z, tester.z));
                }
            }
        }
        self.bbox = Aabb.init(min, max);
        return self;
    }

    fn toLocal(self: RotateY, v: Vec3) Vec3 {
        return Vec3.init(self.cos_theta * v.x - self.sin_theta * v.z, v.y, self.sin_theta * v.x + self.cos_theta * v.z);
    }

    fn toWorld(self: RotateY, v: Vec3) Vec3 {
        return Vec3.init(self.cos_theta * v.x + self.sin_theta * v.z, v.y, -self.sin_theta * v.x + self.cos_theta * v.z);
    }

    // @brief 逆旋转射线后求交，再正旋转位置和已朝向入射侧的法线，保留 front_face。
    // @method **正交不变性**：$(R\mathbf{d})\cdot(R\mathbf{n})=\mathbf{d}\cdot\mathbf{n}$，无需重新定向，更不能混用局部射线和世界法线。
    pub fn hit(self: RotateY, r: Ray, t_min: f64, t_max: f64, rec: *HitRecord) bool {
        const rotated_r = Ray.init(self.toLocal(r.origin), self.toLocal(r.direction), r.time);
        if (!self.ptr.hit(rotated_r, t_min, t_max, rec)) return false;
        rec.p = self.toWorld(rec.p);
        rec.normal = self.toWorld(rec.normal);
        return true;
    }

    // @brief 返回构造时缓存的包围盒及有效标志，不重新计算时间范围。
    pub fn boundingBox(self: RotateY, t0: f64, t1: f64, out: *Aabb) bool {
        _ = t0;
        _ = t1;
        out.* = self.bbox;
        return self.hasbox;
    }
};

// @brief 通用仿射变换实例：把世界射线逆变换到对象空间求交，再正变换位置与法线。
// @notice 非均匀缩放下法线使用逆转置变换，front_face 保持不变。
// @method **参数保持**：$\mathbf o'\mathbf +t\mathbf d'=A^{-1}(\mathbf o+t\mathbf d)+\mathbf b^{-1}$，参数 t 不变。
// @method **法线方向**：$(A^{-T}\mathbf n)\cdot(A\mathbf d)=\mathbf n\cdot\mathbf d$，因此入射侧与正面标志不被破坏。
pub const Instance = struct {
    ptr: *Object,
    transform: math.Transform,

    // @brief 逆变换射线求交，再正变换命中位置与法线。
    pub fn hit(self: Instance, r: Ray, t_min: f64, t_max: f64, rec: *HitRecord) bool {
        const local = self.transform.toObjectRay(r);
        if (!self.ptr.hit(local, t_min, t_max, rec)) return false;
        rec.p = self.transform.applyPoint(rec.p);
        rec.normal = self.transform.applyNormal(rec.normal);
        return true;
    }

    // @brief 变换被包装对象的包围盒八个顶点，构造轴对齐外包盒。
    pub fn boundingBox(self: Instance, t0: f64, t1: f64, out: *Aabb) bool {
        var box: Aabb = undefined;
        if (!self.ptr.boundingBox(t0, t1, &box)) return false;
        out.* = transformAabb(self.transform, box);
        return true;
    }
};

// @brief 变换包围盒八个角点后取逐分量极值，得到世界空间轴对齐外包盒。
fn transformAabb(transform: math.Transform, box: Aabb) Aabb {
    var min = Point3.init(math.infinity, math.infinity, math.infinity);
    var max = Point3.init(-math.infinity, -math.infinity, -math.infinity);
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        var j: usize = 0;
        while (j < 2) : (j += 1) {
            var k: usize = 0;
            while (k < 2) : (k += 1) {
                const corner = Point3.init(
                    if (i == 0) box.min.x else box.max.x,
                    if (j == 0) box.min.y else box.max.y,
                    if (k == 0) box.min.z else box.max.z,
                );
                const transformed = transform.applyPoint(corner);
                min = Point3.init(@min(min.x, transformed.x), @min(min.y, transformed.y), @min(min.z, transformed.z));
                max = Point3.init(@max(max.x, transformed.x), @max(max.y, transformed.y), @max(max.z, transformed.z));
            }
        }
    }
    return Aabb.init(min, max);
}

// @brief 均匀参与介质。

// @brief 在封闭边界内按固定密度抽取散射事件。
pub const ConstantMedium = struct {
    boundary: *Object,
    phase_function: *material.Material,
    neg_inv_density: f64,

    // @brief 保存借用边界和相函数材质，预计算负密度倒数。
    // @param d 正的介质密度。
    pub fn init(b: *Object, d: f64, a: *material.Material) ConstantMedium {
        return .{ .boundary = b, .neg_inv_density = -1.0 / d, .phase_function = a };
    }

    // @brief 在边界内抽取指数自由程，若落在有效区段内则记录介质命中。
    // @method **逆累积分布**：自由程 $s=-\ln U/\rho$，将几何区间长度换算为 $(t_2-t_1)\|\mathbf{d}\|$ 后比较。
    // @notice 介质命中会消耗随机数；保存的法线和正面标志只是相函数所需的占位值。
    pub fn hit(self: ConstantMedium, r: Ray, t_min: f64, t_max: f64, rec: *HitRecord) bool {
        var rec1: HitRecord = .{};
        var rec2: HitRecord = .{};

        if (!self.boundary.hit(r, -math.infinity, math.infinity, &rec1)) return false;
        if (!self.boundary.hit(r, rec1.t + 0.0001, math.infinity, &rec2)) return false;

        if (rec1.t < t_min) rec1.t = t_min;
        if (rec2.t > t_max) rec2.t = t_max;

        if (rec1.t >= rec2.t) return false;
        if (rec1.t < 0) rec1.t = 0;

        const ray_length = r.direction.length();
        const distance_inside_boundary = (rec2.t - rec1.t) * ray_length;
        const hit_distance = self.neg_inv_density * @log(rng.randomDouble());

        if (hit_distance > distance_inside_boundary) return false;

        rec.t = rec1.t + hit_distance / ray_length;
        rec.p = r.at(rec.t);

        rec.normal = Vec3.init(1, 0, 0);
        rec.front_face = true;
        rec.material = self.phase_function;

        return true;
    }

    // @brief 使用介质边界的包围盒。
    pub fn boundingBox(self: ConstantMedium, t0: f64, t1: f64, out: *Aabb) bool {
        return self.boundary.boundingBox(t0, t1, out);
    }
};

// @brief 包围体层次结构。

// @brief 缓存左右子包围盒的二叉加速节点；叶子借用输入对象。
pub const BvhNode = struct {
    // @notice 相同左右指针明确表示单对象叶子，只求交一次，避免重复介质抽样。
    left: *Object,
    right: *Object,
    box: Aabb,
    left_box: Aabb,
    right_box: Aabb,

    pub const BuildError = Allocator.Error || error{ InvalidObjectRange, MissingBoundingBox };

    // @brief 为对象切片的指定子区间建立确定性 BVH，不改动调用者顺序。
    // @param start 构建区间起点，包含该元素。
    // @param end 构建区间终点，不包含该元素；区间不得为空。
    // @param time0 包围盒运动时间起点，time1 为终点。
    // @return 根节点；无效区间、缺失包围盒或分配失败时返回对应错误。
    // @method **中位划分**：以包围盒质心 $\mathbf{c}=(\mathbf{b}_{\min}+\mathbf{b}_{\max})/2$ 的最长分布轴排序，再按数量二分。
    // @method 相同跨度优先 x、再 y；稳定排序保留相同质心顺序，构建不依赖随机数状态。
    pub fn init(alloc: Allocator, src_objects: []const *Object, start: usize, end: usize, time0: f64, time1: f64) BuildError!*BvhNode {
        if (start >= end or end > src_objects.len) return error.InvalidObjectRange;
        // @notice 排序或分配树节点前，先缓存并验证所有包围盒。
        // @notice 仅排序临时数组；调用者的对象顺序保持不变。
        const entries = try alloc.alloc(BuildEntry, end - start);
        defer alloc.free(entries);
        for (src_objects[start..end], entries) |obj, *entry| {
            var bounds: Aabb = undefined;
            if (!obj.boundingBox(time0, time1, &bounds)) return error.MissingBoundingBox;
            entry.* = .{ .object = obj, .box = bounds };
        }
        return build(alloc, entries);
    }

    const BuildEntry = struct {
        object: *Object,
        box: Aabb,

        fn centroid(self: BuildEntry) Point3 {
            return self.box.min.scale(0.5).add(self.box.max.scale(0.5));
        }
    };

    fn build(alloc: Allocator, entries: []BuildEntry) Allocator.Error!*BvhNode {
        const node = try alloc.create(BvhNode);
        errdefer alloc.destroy(node);

        var centroid_bounds = Aabb.init(entries[0].centroid(), entries[0].centroid());
        for (entries[1..]) |entry| {
            centroid_bounds = math.surroundingBox(centroid_bounds, Aabb.init(entry.centroid(), entry.centroid()));
        }
        const extent = centroid_bounds.max.sub(centroid_bounds.min);
        var axis: usize = 0;
        if (extent.y > extent.x) axis = 1;
        if (extent.z > extent.at(axis)) axis = 2;
        // @method 稳定、确定性的中位划分；跨度相等时优先 x，其次 y。
        sortEntries(entries, axis);

        if (entries.len <= 2) {
            node.left = entries[0].object;
            node.right = entries[entries.len - 1].object;
            node.left_box = entries[0].box;
            node.right_box = entries[entries.len - 1].box;
        } else {
            const mid = entries.len / 2;
            const left = try build(alloc, entries[0..mid]);
            errdefer destroyBuilt(alloc, left, mid);
            node.left = try wrapBvh(alloc, left);
            errdefer alloc.destroy(node.left);
            const right = try build(alloc, entries[mid..]);
            errdefer destroyBuilt(alloc, right, entries.len - mid);
            node.right = try wrapBvh(alloc, right);
            node.left_box = left.box;
            node.right_box = right.box;
        }
        node.box = math.surroundingBox(node.left_box, node.right_box);
        return node;
    }

    // @notice 仅用于失败清理：count 区分自有子树和借用输入对象，后者本身也可能是 BVH。
    // @notice 成功构建的资源仍由区域分配器统一管理。
    fn destroyBuilt(alloc: Allocator, node: *BvhNode, count: usize) void {
        if (count > 2) {
            destroyBuilt(alloc, node.left.bvh, count / 2);
            destroyBuilt(alloc, node.right.bvh, count - count / 2);
            alloc.destroy(node.left);
            alloc.destroy(node.right);
        }
        alloc.destroy(node);
    }

    const SortContext = struct { axis: usize };

    // @brief 使用模式击破快速排序按质心坐标划分，使中位分割在大量对象时保持 $O(n\log n)$。
    // @notice 比较仅依赖质心在选定轴上的坐标，结果是确定性的；不稳定排序只改变相同质心的相对顺序。
    fn sortEntries(entries: []BuildEntry, axis: usize) void {
        const Sorter = struct {
            fn lessThan(ctx: SortContext, a: BuildEntry, b: BuildEntry) bool {
                return a.centroid().at(ctx.axis) < b.centroid().at(ctx.axis);
            }
        };
        std.sort.pdq(BuildEntry, entries, SortContext{ .axis = axis }, Sorter.lessThan);
    }

    // @brief 先检查根包围盒，再按近侧优先顺序查询最近命中。
    // @param rec 成功时写入最近交点；查询范围为 [t_min,t_max]。
    // @return 是否有对象命中。
    pub fn hit(self: *const BvhNode, r: Ray, t_min: f64, t_max: f64, rec: *HitRecord) bool {
        const query = math.AabbRay.init(r);
        if (self.box.intervalCached(query, t_min, t_max) == null) return false;
        return self.hitInside(query, t_min, t_max, rec);
    }

    // @brief 调用者已检查当前节点盒，沿 BVH 边下降时复用方向倒数，不重复检查同一盒。
    // @method **近侧优先**：比较左右包围盒入口参数，先访问较小者；若命中于 $t_*$，远侧查询上界收紧到 $t_*$。
    // @method 远侧入口满足 $t_{\rm far}>t_*$ 时不可能有更近交点，可剪枝；等号仍须查询以保持闭区间语义。
    fn hitInside(self: *const BvhNode, query: math.AabbRay, t_min: f64, t_max: f64, rec: *HitRecord) bool {
        if (self.left == self.right) return hitChild(self.left, query, t_min, t_max, rec);

        const left_interval = self.left_box.intervalCached(query, t_min, t_max);
        const right_interval = self.right_box.intervalCached(query, t_min, t_max);
        if (left_interval == null) {
            return right_interval != null and hitChild(self.right, query, t_min, t_max, rec);
        }
        if (right_interval == null) return hitChild(self.left, query, t_min, t_max, rec);

        const right_first = right_interval.?.entry < left_interval.?.entry;
        const near = if (right_first) self.right else self.left;
        const far = if (right_first) self.left else self.right;
        const far_entry = if (right_first) left_interval.?.entry else right_interval.?.entry;
        const hit_near = hitChild(near, query, t_min, t_max, rec);
        const closest = if (hit_near) rec.t else t_max;
        // @notice 相等仍可命中，因为图元求交区间也包含端点。
        if (far_entry > closest) return hit_near;
        const hit_far = hitChild(far, query, t_min, closest, rec);
        return hit_near or hit_far;
    }

    fn hitChild(child: *Object, query: math.AabbRay, t_min: f64, t_max: f64, rec: *HitRecord) bool {
        return switch (child.*) {
            .bvh => |node| node.hitInside(query, t_min, t_max, rec),
            else => child.hit(query.ray, t_min, t_max, rec),
        };
    }

    // @brief 返回构建时缓存的总包围盒，忽略当前时间参数。
    // @notice 查询射线时间应处于构建所覆盖的运动时间范围。
    pub fn boundingBox(self: *const BvhNode, t0: f64, t1: f64, out: *Aabb) bool {
        _ = t0;
        _ = t1;
        out.* = self.box;
        return true;
    }
};
