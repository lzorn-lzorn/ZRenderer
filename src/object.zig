const std = @import("std");
const math = @import("math.zig");
const random = @import("random.zig");
const material = @import("material.zig");
const texture = @import("texture.zig");

const Point3 = math.Point3;
const Vec3 = math.Vec3;
const Ray = math.Ray;
const Aabb = math.Aabb;
const Onb = math.Onb;
const Allocator = std.mem.Allocator;

pub const HitRecord = struct {
    front_face: bool = false,
    t: f64 = 0,
    u: f64 = 0,
    v: f64 = 0,
    p: Point3 = .{},
    normal: Vec3 = .{},
    material: ?*material.Material = null,

    pub fn setFaceNormal(self: *HitRecord, r: Ray, outward_normal: Vec3) void {
        self.front_face = r.direction.dot(outward_normal) < 0;
        self.normal = if (self.front_face) outward_normal else outward_normal.neg();
    }
};

pub const Object = union(enum) {
    sphere: *Sphere,
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

    pub fn hit(self: Object, r: Ray, t_min: f64, t_max: f64, rec: *HitRecord) bool {
        return switch (self) {
            .sphere => |s| s.hit(r, t_min, t_max, rec),
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
        };
    }

    pub fn boundingBox(self: Object, t0: f64, t1: f64, out: *Aabb) bool {
        return switch (self) {
            .sphere => |s| s.boundingBox(t0, t1, out),
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
        };
    }

    pub fn pdfValue(self: Object, o: Point3, v: Vec3) f64 {
        return switch (self) {
            .sphere => |s| s.pdfValue(o, v),
            .xz_rect => |s| s.pdfValue(o, v),
            .group => |s| s.pdfValue(o, v),
            else => 0.0,
        };
    }

    pub fn random(self: Object, o: Point3) Vec3 {
        return switch (self) {
            .sphere => |s| s.random(o),
            .xz_rect => |s| s.random(o),
            .group => |s| s.random(o),
            else => Vec3.init(1, 0, 0),
        };
    }
};

// ---------------------------------------------------------------- helpers

pub fn newSphere(alloc: Allocator, cen0: Point3, cen1: Point3, t0: f64, t1: f64, r: f64, m: *material.Material) *Object {
    const s = alloc.create(Sphere);
    s.* = Sphere.init(cen0, cen1, t0, t1, r, m);
    const o = alloc.create(Object);
    o.* = .{ .sphere = s };
    return o;
}

pub fn newXyRect(alloc: Allocator, x0: f64, x1: f64, y0: f64, y1: f64, k: f64, m: *material.Material) *Object {
    const s = alloc.create(XyRect);
    s.* = .{ .x0 = x0, .x1 = x1, .y0 = y0, .y1 = y1, .k = k, .material = m };
    const o = alloc.create(Object);
    o.* = .{ .xy_rect = s };
    return o;
}

pub fn newXzRect(alloc: Allocator, x0: f64, x1: f64, z0: f64, z1: f64, k: f64, m: *material.Material) *Object {
    const s = alloc.create(XzRect);
    s.* = .{ .x0 = x0, .x1 = x1, .z0 = z0, .z1 = z1, .k = k, .material = m };
    const o = alloc.create(Object);
    o.* = .{ .xz_rect = s };
    return o;
}

pub fn newYzRect(alloc: Allocator, y0: f64, y1: f64, z0: f64, z1: f64, k: f64, m: *material.Material) *Object {
    const s = alloc.create(YzRect);
    s.* = .{ .y0 = y0, .y1 = y1, .z0 = z0, .z1 = z1, .k = k, .material = m };
    const o = alloc.create(Object);
    o.* = .{ .yz_rect = s };
    return o;
}

fn wrapBvh(alloc: Allocator, node: *BvhNode) *Object {
    const o = alloc.create(Object);
    o.* = .{ .bvh = node };
    return o;
}

// ---------------------------------------------------------------- group

pub const ObjectGroup = struct {
    alloc: Allocator,
    list: std.ArrayList(*Object),

    pub fn init(alloc: Allocator) ObjectGroup {
        return .{ .alloc = alloc, .list = std.ArrayList(*Object).init(alloc) };
    }

    pub fn add(self: *ObjectGroup, obj: *Object) !void {
        try self.list.append(obj);
    }

    pub fn clear(self: *ObjectGroup) void {
        self.list.clearRetainingCapacity();
    }

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

    pub fn pdfValue(self: ObjectGroup, o: Point3, v: Vec3) f64 {
        const n = self.list.items.len;
        if (n == 0) return 0.0;
        const weight = 1.0 / @as(f64, @floatFromInt(n));
        var sum: f64 = 0.0;
        for (self.list.items) |obj| {
            sum += weight * obj.pdfValue(o, v);
        }
        return sum;
    }

    pub fn random(self: ObjectGroup, o: Point3) Vec3 {
        const n = self.list.items.len;
        if (n == 0) return Vec3.init(1, 0, 0);
        const idx: usize = @intCast(random.randomInt(0, @intCast(n - 1)));
        return self.list.items[idx].random(o);
    }
};

// ---------------------------------------------------------------- flip_face

pub const FlipFace = struct {
    ptr: *Object,

    pub fn hit(self: FlipFace, r: Ray, t_min: f64, t_max: f64, rec: *HitRecord) bool {
        if (!self.ptr.hit(r, t_min, t_max, rec)) return false;
        rec.front_face = !rec.front_face;
        return true;
    }

    pub fn boundingBox(self: FlipFace, t0: f64, t1: f64, out: *Aabb) bool {
        return self.ptr.boundingBox(t0, t1, out);
    }
};

// ---------------------------------------------------------------- sphere

pub const Sphere = struct {
    center0: Point3 = .{},
    center1: Point3 = .{},
    radius: f64 = 0,
    time0: f64 = 0,
    time1: f64 = 0,
    material: *material.Material,

    pub fn init(cen0: Point3, cen1: Point3, t0: f64, t1: f64, r: f64, m: *material.Material) Sphere {
        return .{ .center0 = cen0, .center1 = cen1, .time0 = t0, .time1 = t1, .radius = r, .material = m };
    }

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

    pub fn pdfValue(self: Sphere, o: Point3, v: Vec3) f64 {
        var rec: HitRecord = .{};
        if (!self.hit(Ray.init(o, v), 0.001, math.infinity, &rec)) return 0;
        const cos_theta_max = @sqrt(1.0 - self.radius * self.radius / self.center0.sub(o).lengthSquared());
        const solid_angle = 2.0 * math.pi * (1.0 - cos_theta_max);
        return 1.0 / solid_angle;
    }

    pub fn random(self: Sphere, o: Point3) Vec3 {
        const direction = self.center0.sub(o);
        const distance_squared = direction.lengthSquared();
        var uvw: Onb = .{};
        uvw.buildFromW(direction);
        return uvw.local(random.randomToSphere(self.radius, distance_squared));
    }

    pub fn center(self: Sphere, time: f64) Point3 {
        const time_diff = time - self.time0;
        if (time_diff == 0) return self.center0;
        const inv_time_diff = 1.0 / (self.time1 - self.time0);
        return self.center0.add(self.center1.sub(self.center0).scale(time_diff * inv_time_diff));
    }

    pub fn boundingBox(self: Sphere, time0: f64, time1: f64, out: *Aabb) bool {
        const r = Vec3.init(self.radius, self.radius, self.radius);
        const box0 = Aabb.init(self.center(time0).sub(r), self.center(time0).add(r));
        const box1 = Aabb.init(self.center(time1).sub(r), self.center(time1).add(r));
        out.* = math.surroundingBox(box0, box1);
        return true;
    }

    fn getSphereUv(p: Point3, u: *f64, v: *f64) void {
        const theta = @acos(-p.y);
        const phi = @atan2(-p.z, p.x) + math.pi;
        u.* = phi * 0.5 / math.pi;
        v.* = theta / math.pi;
    }
};

// ---------------------------------------------------------------- rects

pub const XyRect = struct {
    x0: f64 = 0,
    x1: f64 = 0,
    y0: f64 = 0,
    y1: f64 = 0,
    k: f64 = 0,
    material: *material.Material,

    pub fn hit(self: XyRect, r: Ray, t_min: f64, t_max: f64, rec: *HitRecord) bool {
        const t = (self.k - r.origin.z) / r.direction.z;
        if (t < t_min or t > t_max) return false;
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

    pub fn boundingBox(self: XyRect, t0: f64, t1: f64, out: *Aabb) bool {
        _ = t0;
        _ = t1;
        out.* = Aabb.init(Point3.init(self.x0, self.y0, self.k - 0.0001), Point3.init(self.x1, self.y1, self.k + 0.0001));
        return true;
    }
};

pub const XzRect = struct {
    x0: f64 = 0,
    x1: f64 = 0,
    z0: f64 = 0,
    z1: f64 = 0,
    k: f64 = 0,
    material: *material.Material,

    pub fn hit(self: XzRect, r: Ray, t_min: f64, t_max: f64, rec: *HitRecord) bool {
        const t = (self.k - r.origin.y) / r.direction.y;
        if (t < t_min or t > t_max) return false;
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

    pub fn boundingBox(self: XzRect, t0: f64, t1: f64, out: *Aabb) bool {
        _ = t0;
        _ = t1;
        out.* = Aabb.init(Point3.init(self.x0, self.k - 0.0001, self.z0), Point3.init(self.x1, self.k + 0.0001, self.z1));
        return true;
    }

    pub fn pdfValue(self: XzRect, origin: Point3, v: Vec3) f64 {
        var rec: HitRecord = .{};
        if (!self.hit(Ray.init(origin, v), 0.001, math.infinity, &rec)) return 0;
        const area = (self.x1 - self.x0) * (self.z1 - self.z0);
        const distance_squared = rec.t * rec.t * v.lengthSquared();
        const cosine = @abs(v.dot(rec.normal) / v.length());
        return distance_squared / (cosine * area);
    }

    pub fn random(self: XzRect, origin: Point3) Vec3 {
        const random_point = Point3.init(random.randomDoubleRange(self.x0, self.x1), self.k, random.randomDoubleRange(self.z0, self.z1));
        return random_point.sub(origin);
    }
};

pub const YzRect = struct {
    y0: f64 = 0,
    y1: f64 = 0,
    z0: f64 = 0,
    z1: f64 = 0,
    k: f64 = 0,
    material: *material.Material,

    pub fn hit(self: YzRect, r: Ray, t_min: f64, t_max: f64, rec: *HitRecord) bool {
        const t = (self.k - r.origin.x) / r.direction.x;
        if (t < t_min or t > t_max) return false;
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

    pub fn boundingBox(self: YzRect, t0: f64, t1: f64, out: *Aabb) bool {
        _ = t0;
        _ = t1;
        out.* = Aabb.init(Point3.init(self.k - 0.0001, self.y0, self.z0), Point3.init(self.k + 0.0001, self.y1, self.z1));
        return true;
    }
};

// ---------------------------------------------------------------- box

pub const Box = struct {
    box_min: Point3 = .{},
    box_max: Point3 = .{},
    sides: ObjectGroup,

    pub fn init(alloc: Allocator, p0: Point3, p1: Point3, m: *material.Material) !Box {
        var self = Box{ .box_min = p0, .box_max = p1, .sides = ObjectGroup.init(alloc) };
        try self.sides.add(newXyRect(alloc, p0.x, p1.x, p0.y, p1.y, p1.z, m));
        try self.sides.add(newXyRect(alloc, p0.x, p1.x, p0.y, p1.y, p0.z, m));
        try self.sides.add(newXzRect(alloc, p0.x, p1.x, p0.z, p1.z, p1.y, m));
        try self.sides.add(newXzRect(alloc, p0.x, p1.x, p0.z, p1.z, p0.y, m));
        try self.sides.add(newYzRect(alloc, p0.y, p1.y, p0.z, p1.z, p1.x, m));
        try self.sides.add(newYzRect(alloc, p0.y, p1.y, p0.z, p1.z, p0.x, m));
        return self;
    }

    pub fn hit(self: Box, r: Ray, t_min: f64, t_max: f64, rec: *HitRecord) bool {
        return self.sides.hit(r, t_min, t_max, rec);
    }

    pub fn boundingBox(self: Box, t0: f64, t1: f64, out: *Aabb) bool {
        _ = t0;
        _ = t1;
        out.* = Aabb.init(self.box_min, self.box_max);
        return true;
    }
};

// ---------------------------------------------------------------- transform

pub const Translate = struct {
    ptr: *Object,
    offset: Vec3,

    pub fn hit(self: Translate, r: Ray, t_min: f64, t_max: f64, rec: *HitRecord) bool {
        const moved_r = Ray.init(r.origin.sub(self.offset), r.direction, r.time);
        if (!self.ptr.hit(moved_r, t_min, t_max, rec)) return false;
        rec.p = rec.p.add(self.offset);
        rec.setFaceNormal(moved_r, rec.normal);
        return true;
    }

    pub fn boundingBox(self: Translate, t0: f64, t1: f64, out: *Aabb) bool {
        if (!self.ptr.boundingBox(t0, t1, out)) return false;
        out.* = Aabb.init(out.min.add(self.offset), out.max.add(self.offset));
        return true;
    }
};

pub const RotateY = struct {
    ptr: *Object,
    sin_theta: f64,
    cos_theta: f64,
    hasbox: bool,
    bbox: Aabb,

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

    pub fn hit(self: RotateY, r: Ray, t_min: f64, t_max: f64, rec: *HitRecord) bool {
        const origin = Point3.init(
            self.cos_theta * r.origin.x - self.sin_theta * r.origin.z,
            r.origin.y,
            self.sin_theta * r.origin.x + self.cos_theta * r.origin.z,
        );
        const direction = Vec3.init(
            self.cos_theta * r.direction.x - self.sin_theta * r.direction.z,
            r.direction.y,
            self.sin_theta * r.direction.x + self.cos_theta * r.direction.z,
        );
        const rotated_r = Ray.init(origin, direction, r.time);

        if (!self.ptr.hit(rotated_r, t_min, t_max, rec)) return false;

        const p = Point3.init(
            self.cos_theta * rec.p.x + self.sin_theta * rec.p.z,
            rec.p.y,
            -self.sin_theta * rec.p.x + self.cos_theta * rec.p.z,
        );
        const normal = Vec3.init(
            self.cos_theta * rec.normal.x + self.sin_theta * rec.normal.z,
            rec.normal.y,
            -self.sin_theta * rec.normal.x + self.cos_theta * rec.normal.z,
        );
        rec.p = p;
        rec.setFaceNormal(rotated_r, normal);
        return true;
    }

    pub fn boundingBox(self: RotateY, t0: f64, t1: f64, out: *Aabb) bool {
        _ = t0;
        _ = t1;
        out.* = self.bbox;
        return self.hasbox;
    }
};

// ---------------------------------------------------------------- constant medium

pub const ConstantMedium = struct {
    boundary: *Object,
    phase_function: *material.Material,
    neg_inv_density: f64,

    pub fn init(b: *Object, d: f64, a: *material.Material) ConstantMedium {
        return .{ .boundary = b, .neg_inv_density = -1.0 / d, .phase_function = a };
    }

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
        const hit_distance = self.neg_inv_density * @log(random.randomDouble());

        if (hit_distance > distance_inside_boundary) return false;

        rec.t = rec1.t + hit_distance / ray_length;
        rec.p = r.at(rec.t);

        rec.normal = Vec3.init(1, 0, 0);
        rec.front_face = true;
        rec.material = self.phase_function;

        return true;
    }

    pub fn boundingBox(self: ConstantMedium, t0: f64, t1: f64, out: *Aabb) bool {
        return self.boundary.boundingBox(t0, t1, out);
    }
};

// ---------------------------------------------------------------- BVH

pub const BvhNode = struct {
    left: *Object,
    right: *Object,
    box: Aabb,

    pub fn init(alloc: Allocator, src_objects: []const *Object, start: usize, end: usize, time0: f64, time1: f64) *BvhNode {
        const node = alloc.create(BvhNode);

        // Do not mutate the caller's object list: work on a copy.
        const objects = alloc.alloc(*Object, src_objects.len);
        @memcpy(objects, src_objects);

        const axis: u8 = @intCast(random.randomInt(0, 2));
        const object_span = end - start;

        if (object_span == 1) {
            node.left = objects[start];
            node.right = objects[start];
        } else if (object_span == 2) {
            if (boxCompare(objects[start], objects[start + 1], axis)) {
                node.left = objects[start];
                node.right = objects[start + 1];
            } else {
                node.left = objects[start + 1];
                node.right = objects[start];
            }
        } else {
            sortObjects(objects, start, end, axis);
            const mid = start + object_span / 2;
            node.left = wrapBvh(alloc, init(alloc, objects, start, mid, time0, time1));
            node.right = wrapBvh(alloc, init(alloc, objects, mid, end, time0, time1));
        }

        var box_left: Aabb = undefined;
        var box_right: Aabb = undefined;
        if (!node.left.boundingBox(time0, time1, &box_left) or !node.right.boundingBox(time0, time1, &box_right)) {
            std.debug.print("No bounding box in bvh_node constructor.\n", .{});
        }
        node.box = math.surroundingBox(box_left, box_right);
        return node;
    }

    pub fn hit(self: BvhNode, r: Ray, t_min: f64, t_max: f64, rec: *HitRecord) bool {
        if (!self.box.hit(r, t_min, t_max)) return false;
        const hit_left = self.left.hit(r, t_min, t_max, rec);
        const hit_right = self.right.hit(r, t_min, if (hit_left) rec.t else t_max, rec);
        return hit_left or hit_right;
    }

    pub fn boundingBox(self: BvhNode, t0: f64, t1: f64, out: *Aabb) bool {
        _ = t0;
        _ = t1;
        out.* = self.box;
        return true;
    }
};

fn boxCompare(a: *Object, b: *Object, axis: u8) bool {
    var box_a: Aabb = undefined;
    var box_b: Aabb = undefined;
    if (!a.boundingBox(0, 0, &box_a) or !b.boundingBox(0, 0, &box_b)) {
        std.debug.print("No bounding box in bvh_node constructor.\n", .{});
    }
    return box_a.min.at(axis) < box_b.min.at(axis);
}

/// Stable insertion sort over [start, end) by the chosen axis (small lists; the
/// per-level cost is negligible and this avoids std.sort API churn).
fn sortObjects(objects: []*Object, start: usize, end: usize, axis: u8) void {
    var i = start + 1;
    while (i < end) : (i += 1) {
        const key = objects[i];
        var j = i;
        while (j > start and boxCompare(key, objects[j - 1], axis)) : (j -= 1) {
            objects[j] = objects[j - 1];
        }
        objects[j] = key;
    }
}
