const math = @import("math.zig");
const random = @import("random.zig");

const Vec3 = math.Vec3;
const Point3 = math.Point3;
const Ray = math.Ray;

pub const Camera = struct {
    origin: Point3 = .{},
    lower_left_corner: Point3 = .{},
    horizontal: Vec3 = .{},
    vertical: Vec3 = .{},
    u: Vec3 = .{},
    v: Vec3 = .{},
    w: Vec3 = .{},
    lens_radius: f64 = 0,
    time0: f64 = 0,
    time1: f64 = 0,

    pub fn init(
        lookfrom: Point3,
        lookat: Point3,
        vup: Vec3,
        vfov: f64,
        aspect_ratio: f64,
        aperture: f64,
        focus_dist: f64,
        time0: f64,
        time1: f64,
    ) Camera {
        const theta = math.degreesToRadians(vfov);
        const h = @tan(theta / 2.0);
        const viewport_height = 2.0 * h;
        const viewport_width = aspect_ratio * viewport_height;

        const w = lookfrom.sub(lookat).normalized();
        const u = vup.cross(w).normalized();
        const v = w.cross(u);

        return .{
            .origin = lookfrom,
            .horizontal = u.scale(focus_dist * viewport_width),
            .vertical = v.scale(focus_dist * viewport_height),
            .lower_left_corner = lookfrom
                .sub(u.scale(focus_dist * viewport_width * 0.5))
                .sub(v.scale(focus_dist * viewport_height * 0.5))
                .sub(w.scale(focus_dist)),
            .u = u,
            .v = v,
            .w = w,
            .lens_radius = aperture * 0.5,
            .time0 = time0,
            .time1 = time1,
        };
    }

    pub fn getRay(self: Camera, s: f64, t: f64) Ray {
        const lens_x = random.randomDouble();
        const lens_y = random.randomDouble();
        const shutter = random.randomDouble();
        return self.getRaySampled(s, t, lens_x, lens_y, shutter);
    }

    /// Fixed sample dimensions: concentric disk mapping avoids rejection loops
    /// which would otherwise consume a varying number of Sobol coordinates.
    pub fn getRaySampled(self: Camera, s: f64, t: f64, lens_x: f64, lens_y: f64, shutter: f64) Ray {
        const rd = concentricDisk(lens_x, lens_y).scale(self.lens_radius);
        const offset = self.u.scale(rd.x).add(self.v.scale(rd.y));
        return Ray.init(
            self.origin.add(offset),
            self.lower_left_corner
                .add(self.horizontal.scale(s))
                .add(self.vertical.scale(t))
                .sub(self.origin)
                .sub(offset),
            self.time0 + (self.time1 - self.time0) * shutter,
        );
    }
};

pub fn concentricDisk(x: f64, y: f64) Vec3 {
    const sx = 2 * x - 1;
    const sy = 2 * y - 1;
    if (sx == 0 and sy == 0) return .{};
    const use_x = @abs(sx) > @abs(sy);
    const radius = if (use_x) sx else sy;
    const theta = if (use_x) (math.pi / 4) * (sy / sx) else (math.pi / 2) - (math.pi / 4) * (sx / sy);
    return .{ .x = radius * @cos(theta), .y = radius * @sin(theta) };
}

pub const CameraArgs = struct {
    lookfrom: Point3 = .{},
    lookat: Point3 = .{},
    vup: Vec3 = .{},
    vfov: f64 = 40.0,
    aspect_ratio: f64 = 16.0 / 9.0,
    aperture: f64 = 0.0,
    focus_dist: f64 = 10.0,
    time0: f64 = 0,
    time1: f64 = 0,

    pub fn build(self: CameraArgs) Camera {
        return Camera.init(
            self.lookfrom,
            self.lookat,
            self.vup,
            self.vfov,
            self.aspect_ratio,
            self.aperture,
            self.focus_dist,
            self.time0,
            self.time1,
        );
    }
};

pub const Tag = enum {
    lookfrom,
    lookat,
    vup,
    vfov,
    aspect_ratio,
    aperture,
    focus_dist,
    time_range,
};
