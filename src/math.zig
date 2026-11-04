const std = @import("std");

pub const epsilon: f64 = 2.220446049250313e-16; // @brief 双精度机器精度，对应 C++ 的 std::numeric_limits<double>::epsilon()。
pub const infinity: f64 = std.math.inf(f64);
pub const pi: f64 = std.math.pi;

// @brief 三分量双精度向量；也作为点和颜色使用，与 C++ 版本的别名一致。
pub const Vec3 = struct {
    x: f64 = 0,
    y: f64 = 0,
    z: f64 = 0,

    // @brief 按分量构造向量。
    pub fn init(x: f64, y: f64, z: f64) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    // @brief 按下标读取分量。
    // @param i 分量下标，只允许 0、1、2。
    // @notice 越界进入不可达分支；安全检查开启时触发崩溃，对应 C++ 版本的抛错意图。
    pub fn at(self: Vec3, i: usize) f64 {
        return switch (i) {
            0 => self.x,
            1 => self.y,
            2 => self.z,
            else => unreachable,
        };
    }

    // @brief 逐分量相加。
    pub fn add(self: Vec3, o: Vec3) Vec3 {
        return .{ .x = self.x + o.x, .y = self.y + o.y, .z = self.z + o.z };
    }
    // @brief 逐分量相减。
    pub fn sub(self: Vec3, o: Vec3) Vec3 {
        return .{ .x = self.x - o.x, .y = self.y - o.y, .z = self.z - o.z };
    }
    // @brief 逐分量相乘，不是点积。
    pub fn mul(self: Vec3, o: Vec3) Vec3 {
        return .{ .x = self.x * o.x, .y = self.y * o.y, .z = self.z * o.z };
    }
    // @brief 将所有分量乘以标量。
    pub fn scale(self: Vec3, t: f64) Vec3 {
        return .{ .x = self.x * t, .y = self.y * t, .z = self.z * t };
    }
    // @brief 将所有分量除以非零标量。
    pub fn div(self: Vec3, t: f64) Vec3 {
        return self.scale(1.0 / t);
    }
    // @brief 各分量加上同一标量。
    pub fn addScalar(self: Vec3, t: f64) Vec3 {
        return .{ .x = self.x + t, .y = self.y + t, .z = self.z + t };
    }
    // @brief 各分量减去同一标量。
    pub fn subScalar(self: Vec3, t: f64) Vec3 {
        return .{ .x = self.x - t, .y = self.y - t, .z = self.z - t };
    }
    // @brief 返回反向向量。
    pub fn neg(self: Vec3) Vec3 {
        return .{ .x = -self.x, .y = -self.y, .z = -self.z };
    }
    // @brief 返回欧氏点积。
    pub fn dot(self: Vec3, o: Vec3) f64 {
        return self.x * o.x + self.y * o.y + self.z * o.z;
    }
    // @brief 返回遵循右手定则的叉积。
    pub fn cross(self: Vec3, o: Vec3) Vec3 {
        return .{
            .x = self.y * o.z - self.z * o.y,
            .y = self.z * o.x - self.x * o.z,
            .z = self.x * o.y - self.y * o.x,
        };
    }
    // @brief 返回长度平方，避免开方。
    pub fn lengthSquared(self: Vec3) f64 {
        return self.x * self.x + self.y * self.y + self.z * self.z;
    }
    // @brief 返回欧氏长度。
    pub fn length(self: Vec3) f64 {
        return @sqrt(self.lengthSquared());
    }
    // @brief 保持方向并归一化。
    // @notice 输入须具有有限的非零长度；不处理零向量。
    pub fn normalized(self: Vec3) Vec3 {
        return self.div(self.length());
    }
    // @brief 判断各分量绝对值是否均小于机器精度。
    pub fn nearZero(self: Vec3) bool {
        return @abs(self.x) < epsilon and @abs(self.y) < epsilon and @abs(self.z) < epsilon;
    }
};

pub const Point3 = Vec3;
pub const Color = Vec3;

// @brief 将数值限制在给定闭区间内。
// @notice 调用者保证 min 不大于 max；NaN 会原样返回。
pub fn clamp(v: f64, min: f64, max: f64) f64 {
    if (v < min) return min;
    if (v > max) return max;
    return v;
}

// @brief 将角度制转换为弧度制。
pub fn degreesToRadians(deg: f64) f64 {
    return deg * pi / 180.0;
}

// @brief 通过指数与对数计算浮点幂，避免 std.math.pow 接口变动。
// @notice 常规实数计算要求 base 为正；不补充零底数或负底数的特殊分支。
pub fn pow(base: f64, exp: f64) f64 {
    return @exp(exp * @log(base));
}

// @brief 带时间的参数化射线；方向不要求单位长度。
// @method **参数化**：$\mathbf{p}(t)=\mathbf{o}+t\mathbf{d}$，故 t 仅在方向为单位向量时等于距离。
pub const Ray = struct {
    origin: Point3 = .{},
    direction: Vec3 = .{},
    time: f64 = 0,

    // @brief 构造指定原点、方向和快门时间的射线。
    pub fn init(origin: Point3, direction: Vec3, time: f64) Ray {
        return .{ .origin = origin, .direction = direction, .time = time };
    }
    // @brief 返回参数 t 对应的空间位置。
    pub fn at(self: Ray, t: f64) Point3 {
        return self.origin.add(self.direction.scale(t));
    }
};

// @brief 计算镜面反射方向。
// @param n 单位法线。
// @method **法向分解**：保持切向分量并反转法向分量，$\mathbf{r}=\mathbf{v}-2(\mathbf{v}\cdot\mathbf{n})\mathbf{n}$。
pub fn reflect(v: Vec3, n: Vec3) Vec3 {
    return v.sub(n.scale(2.0 * v.dot(n)));
}

// @brief 根据斯涅尔定律构造折射方向。
// @param uv 单位入射方向。
// @param n 朝向入射侧的单位法线。
// @param etai_over_etat 入射介质与透射介质的折射率之比。
// @method **切向分解**：$c=\min(-\mathbf{u}\cdot\mathbf{n},1)$，$\mathbf{r}_{\perp}=\eta(\mathbf{u}+c\mathbf{n})$。
// @method 由单位长度约束得 $\mathbf{r}_{\parallel}=-\sqrt{|1-\|\mathbf{r}_{\perp}\|^2|}\mathbf{n}$，二者相加得到结果。
// @notice 调用者须先排除全内反射；绝对值仅缓解舍入误差，不替代物理条件检查。
pub fn refract(uv: Vec3, n: Vec3, etai_over_etat: f64) Vec3 {
    const cos_theta = @min(uv.neg().dot(n), 1.0);
    const r_out_perp = uv.add(n.scale(cos_theta)).scale(etai_over_etat);
    const r_out_parallel = n.scale(-@sqrt(@abs(1.0 - r_out_perp.lengthSquared())));
    return r_out_perp.add(r_out_parallel);
}

// @brief 在一次包围体层次结构（BVH）遍历中复用射线及方向倒数。
// @notice 变换后的射线必须重新建立查询，不能复用原坐标系的缓存。
pub const AabbRay = struct {
    ray: Ray,
    inverse_direction: Vec3,

    // @brief 预计算方向倒数；零方向以零占位，由求交函数单独处理。
    pub fn init(ray: Ray) AabbRay {
        return .{
            .ray = ray,
            .inverse_direction = .{
                .x = if (ray.direction.x == 0) 0 else 1.0 / ray.direction.x,
                .y = if (ray.direction.y == 0) 0 else 1.0 / ray.direction.y,
                .z = if (ray.direction.z == 0) 0 else 1.0 / ray.direction.z,
            },
        };
    }
};

// @brief 由最小、最大角点表示的轴对齐包围盒。
pub const Aabb = struct {
    min: Point3 = .{},
    max: Point3 = .{},

    // @brief 构造包围盒；调用者保证每轴最小值不大于最大值。
    pub fn init(min: Point3, max: Point3) Aabb {
        return .{ .min = min, .max = max };
    }

    // @brief 判断射线在给定闭区间内是否与包围盒相交。
    pub fn hit(self: Aabb, r: Ray, tmin: f64, tmax: f64) bool {
        return self.interval(r, tmin, tmax) != null;
    }

    // @brief 射线进入和离开包围盒的闭区间端点。
    pub const Interval = struct { entry: f64, exit: f64 };

    // @brief 建立临时倒数缓存并求交。
    // @return 裁剪后的参数闭区间；无交集时为 null。
    pub fn interval(self: Aabb, r: Ray, tmin: f64, tmax: f64) ?Interval {
        return self.intervalCached(AabbRay.init(r), tmin, tmax);
    }

    // @brief 用缓存倒数执行平行平面夹层求交，保留擦边和恰在 tmax 的命中。
    // @param query 与当前坐标系一致的射线缓存。
    // @param tmin 查询参数下界。
    // @param tmax 查询参数上界。
    // @return 三轴夹层与查询区间的交集；空交集返回 null。
    // @method **夹层法**：每轴求 $a_i=(b_{\min,i}-o_i)/d_i$、$b_i=(b_{\max,i}-o_i)/d_i$，按方向交换端点。
    // @method 逐轴更新 $t_{\rm enter}=\max(t_{\min},a_x,a_y,a_z)$、$t_{\rm exit}=\min(t_{\max},b_x,b_y,b_z)$。
    // @method 仅当 $t_{\rm exit}<t_{\rm enter}$ 时拒绝；等号表示闭区间擦边命中。
    // @method 若 $d_i=0$，原点在夹层外则拒绝，否则该轴不限制参数区间。
    pub fn intervalCached(self: Aabb, query: AabbRay, tmin: f64, tmax: f64) ?Interval {
        var t_min = tmin;
        var t_max = tmax;
        if (t_max < t_min) return null;
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            const origin = query.ray.origin.at(i);
            const direction = query.ray.direction.at(i);
            // @notice 同时覆盖负零，避免在盒面计算零乘无穷大。
            if (direction == 0) {
                if (origin < self.min.at(i) or origin > self.max.at(i)) return null;
                continue;
            }
            const inv_dir = query.inverse_direction.at(i);
            // @notice 极小非零方向的倒数可能溢出，此时改用直接除法。
            var a = if (std.math.isFinite(inv_dir)) (self.min.at(i) - origin) * inv_dir else (self.min.at(i) - origin) / direction;
            var b = if (std.math.isFinite(inv_dir)) (self.max.at(i) - origin) * inv_dir else (self.max.at(i) - origin) / direction;
            if (direction < 0) {
                const tmp = a;
                a = b;
                b = tmp;
            }
            t_min = @max(t_min, a);
            t_max = @min(t_max, b);
            if (t_max < t_min) return null;
        }
        return .{ .entry = t_min, .exit = t_max };
    }
};

// @brief 返回同时包住两个输入盒的最小轴对齐包围盒。
pub fn surroundingBox(box0: Aabb, box1: Aabb) Aabb {
    const small = Point3.init(
        @min(box0.min.x, box1.min.x),
        @min(box0.min.y, box1.min.y),
        @min(box0.min.z, box1.min.z),
    );
    const big = Point3.init(
        @max(box0.max.x, box1.max.x),
        @max(box0.max.y, box1.max.y),
        @max(box0.max.z, box1.max.z),
    );
    return Aabb.init(small, big);
}

// @brief 用于局部方向采样的正交单位基。
pub const Onb = struct {
    axis: [3]Vec3 = .{ .{}, .{}, .{} },

    // @brief 返回第一条基轴。
    pub fn u(self: Onb) Vec3 {
        return self.axis[0];
    }
    // @brief 返回第二条基轴。
    pub fn v(self: Onb) Vec3 {
        return self.axis[1];
    }
    // @brief 返回采样主轴。
    pub fn w(self: Onb) Vec3 {
        return self.axis[2];
    }
    // @brief 将三个局部坐标转换为世界方向。
    pub fn local3(self: Onb, a: f64, b: f64, c: f64) Vec3 {
        return self.u().scale(a).add(self.v().scale(b)).add(self.w().scale(c));
    }
    // @brief 将局部向量按基轴线性组合到世界坐标系。
    pub fn local(self: Onb, a: Vec3) Vec3 {
        return self.u().scale(a.x).add(self.v().scale(a.y)).add(self.w().scale(a.z));
    }
    // @brief 以非零向量 n 为主轴建立正交单位基。
    // @method **构造**：归一化得 $\mathbf{w}$，选择不近似平行的辅助轴 $\mathbf{a}$。
    // @method 令 $\mathbf{v}=\operatorname{normalize}(\mathbf{w}\times\mathbf{a})$、$\mathbf{u}=\mathbf{w}\times\mathbf{v}$，用于保持立体角的方向变换。
    pub fn buildFromW(self: *Onb, n: Vec3) void {
        self.axis[2] = n.normalized();
        const a = if (@abs(self.w().x) > 0.9) Vec3.init(0, 1, 0) else Vec3.init(1, 0, 0);
        self.axis[1] = self.w().cross(a).normalized();
        self.axis[0] = self.w().cross(self.v());
    }
};
