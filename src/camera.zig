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
        const rd = random.randomInUnitDisk().scale(self.lens_radius);
        const offset = self.u.scale(rd.x).add(self.v.scale(rd.y));
        return Ray.init(
            self.origin.add(offset),
            self.lower_left_corner
                .add(self.horizontal.scale(s))
                .add(self.vertical.scale(t))
                .sub(self.origin)
                .sub(offset),
            random.randomDoubleRange(self.time0, self.time1),
        );
    }
};

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
