const math = @import("math.zig");
const random = @import("random.zig");
const object = @import("object.zig");

const Vec3 = math.Vec3;
const Point3 = math.Point3;
const Onb = math.Onb;

pub const Pdf = union(enum) {
    cosine: CosinePdf,
    hittable: HittablePdf,
    mixture: MixturePdf,

    pub fn value(self: Pdf, direction: Vec3) f64 {
        return switch (self) {
            .cosine => |p| p.value(direction),
            .hittable => |p| p.value(direction),
            .mixture => |p| p.value(direction),
        };
    }

    pub fn generate(self: Pdf) Vec3 {
        return switch (self) {
            .cosine => |p| p.generate(),
            .hittable => |p| p.generate(),
            .mixture => |p| p.generate(),
        };
    }
};

pub const CosinePdf = struct {
    uvw: Onb = .{},

    pub fn init(w: Vec3) CosinePdf {
        var self: CosinePdf = .{};
        self.uvw.buildFromW(w);
        return self;
    }

    pub fn value(self: CosinePdf, direction: Vec3) f64 {
        const cosine = direction.normalized().dot(self.uvw.w());
        return if (cosine <= 0) 0.0 else cosine / math.pi;
    }

    pub fn generate(self: CosinePdf) Vec3 {
        return self.uvw.local(random.randomCosineDirection());
    }
};

pub const HittablePdf = struct {
    ptr: *object.Object,
    o: Point3,

    pub fn value(self: HittablePdf, direction: Vec3) f64 {
        return self.ptr.pdfValue(self.o, direction);
    }

    pub fn generate(self: HittablePdf) Vec3 {
        return self.ptr.random(self.o);
    }
};

pub const MixturePdf = struct {
    p0: *Pdf,
    p1: *Pdf,

    pub fn value(self: MixturePdf, direction: Vec3) f64 {
        return 0.5 * self.p0.value(direction) + 0.5 * self.p1.value(direction);
    }

    pub fn generate(self: MixturePdf) Vec3 {
        return if (random.randomDouble() < 0.5) self.p0.generate() else self.p1.generate();
    }
};
