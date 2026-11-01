const std = @import("std");

pub const epsilon: f64 = 2.220446049250313e-16; // std::numeric_limits<double>::epsilon()
pub const infinity: f64 = std.math.inf(f64);
pub const pi: f64 = std.math.pi;

/// 3-component double vector; also used as point3 and color (matching the C++ aliases).
pub const Vec3 = struct {
    x: f64 = 0,
    y: f64 = 0,
    z: f64 = 0,

    pub fn init(x: f64, y: f64, z: f64) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    /// Index access (0,1,2); panics out of range, mirroring the C++ throw.
    pub fn at(self: Vec3, i: usize) f64 {
        return switch (i) {
            0 => self.x,
            1 => self.y,
            2 => self.z,
            else => unreachable,
        };
    }

    pub fn add(self: Vec3, o: Vec3) Vec3 {
        return .{ .x = self.x + o.x, .y = self.y + o.y, .z = self.z + o.z };
    }
    pub fn sub(self: Vec3, o: Vec3) Vec3 {
        return .{ .x = self.x - o.x, .y = self.y - o.y, .z = self.z - o.z };
    }
    /// Element-wise multiply (vec * vec).
    pub fn mul(self: Vec3, o: Vec3) Vec3 {
        return .{ .x = self.x * o.x, .y = self.y * o.y, .z = self.z * o.z };
    }
    /// Scalar multiply (vec * t).
    pub fn scale(self: Vec3, t: f64) Vec3 {
        return .{ .x = self.x * t, .y = self.y * t, .z = self.z * t };
    }
    pub fn div(self: Vec3, t: f64) Vec3 {
        return self.scale(1.0 / t);
    }
    pub fn addScalar(self: Vec3, t: f64) Vec3 {
        return .{ .x = self.x + t, .y = self.y + t, .z = self.z + t };
    }
    pub fn subScalar(self: Vec3, t: f64) Vec3 {
        return .{ .x = self.x - t, .y = self.y - t, .z = self.z - t };
    }
    pub fn neg(self: Vec3) Vec3 {
        return .{ .x = -self.x, .y = -self.y, .z = -self.z };
    }
    pub fn dot(self: Vec3, o: Vec3) f64 {
        return self.x * o.x + self.y * o.y + self.z * o.z;
    }
    pub fn cross(self: Vec3, o: Vec3) Vec3 {
        return .{
            .x = self.y * o.z - self.z * o.y,
            .y = self.z * o.x - self.x * o.z,
            .z = self.x * o.y - self.y * o.x,
        };
    }
    pub fn lengthSquared(self: Vec3) f64 {
        return self.x * self.x + self.y * self.y + self.z * self.z;
    }
    pub fn length(self: Vec3) f64 {
        return @sqrt(self.lengthSquared());
    }
    pub fn normalized(self: Vec3) Vec3 {
        return self.div(self.length());
    }
    pub fn nearZero(self: Vec3) bool {
        return @abs(self.x) < epsilon and @abs(self.y) < epsilon and @abs(self.z) < epsilon;
    }
};

pub const Point3 = Vec3;
pub const Color = Vec3;

pub fn clamp(v: f64, min: f64, max: f64) f64 {
    if (v < min) return min;
    if (v > max) return max;
    return v;
}

pub fn degreesToRadians(deg: f64) f64 {
    return deg * pi / 180.0;
}

/// Floating point power via exp/log (avoids std.math.pow signature churn).
pub fn pow(base: f64, exp: f64) f64 {
    return @exp(exp * @log(base));
}

pub const Ray = struct {
    origin: Point3 = .{},
    direction: Vec3 = .{},
    time: f64 = 0,

    pub fn init(origin: Point3, direction: Vec3, time: f64) Ray {
        return .{ .origin = origin, .direction = direction, .time = time };
    }
    pub fn at(self: Ray, t: f64) Point3 {
        return self.origin.add(self.direction.scale(t));
    }
};

pub fn reflect(v: Vec3, n: Vec3) Vec3 {
    return v.sub(n.scale(2.0 * v.dot(n)));
}

pub fn refract(uv: Vec3, n: Vec3, etai_over_etat: f64) Vec3 {
    const cos_theta = @min(uv.neg().dot(n), 1.0);
    const r_out_perp = uv.add(n.scale(cos_theta)).scale(etai_over_etat);
    const r_out_parallel = n.scale(-@sqrt(@abs(1.0 - r_out_perp.lengthSquared())));
    return r_out_perp.add(r_out_parallel);
}

pub const Aabb = struct {
    min: Point3 = .{},
    max: Point3 = .{},

    pub fn init(min: Point3, max: Point3) Aabb {
        return .{ .min = min, .max = max };
    }

    pub fn hit(self: Aabb, r: Ray, tmin: f64, tmax: f64) bool {
        var t_min = tmin;
        var t_max = tmax;
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            const inv_dir = 1.0 / r.direction.at(i);
            var a = (self.min.at(i) - r.origin.at(i)) * inv_dir;
            var b = (self.max.at(i) - r.origin.at(i)) * inv_dir;
            if (inv_dir < 0) {
                const tmp = a;
                a = b;
                b = tmp;
            }
            t_min = @max(t_min, a);
            t_max = @min(t_max, b);
            if (t_max <= t_min) return false;
        }
        return true;
    }
};

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

/// Orthonormal basis.
pub const Onb = struct {
    axis: [3]Vec3 = .{ .{}, .{}, .{} },

    pub fn u(self: Onb) Vec3 {
        return self.axis[0];
    }
    pub fn v(self: Onb) Vec3 {
        return self.axis[1];
    }
    pub fn w(self: Onb) Vec3 {
        return self.axis[2];
    }
    pub fn local3(self: Onb, a: f64, b: f64, c: f64) Vec3 {
        return self.u().scale(a).add(self.v().scale(b)).add(self.w().scale(c));
    }
    pub fn local(self: Onb, a: Vec3) Vec3 {
        return self.u().scale(a.x).add(self.v().scale(a.y)).add(self.w().scale(a.z));
    }
    pub fn buildFromW(self: *Onb, n: Vec3) void {
        self.axis[2] = n.normalized();
        const a = if (@abs(self.w().x) > 0.9) Vec3.init(0, 1, 0) else Vec3.init(1, 0, 0);
        self.axis[1] = self.w().cross(a).normalized();
        self.axis[0] = self.w().cross(self.v());
    }
};
