const std = @import("std");
const math = @import("math.zig");
const random = @import("random.zig");
const texture = @import("texture.zig");
const pdf_mod = @import("pdf.zig");
const object = @import("object.zig");

const Color = math.Color;
const Ray = math.Ray;
const Point3 = math.Point3;
const Onb = math.Onb;
const Texture = texture.Texture;
const Pdf = pdf_mod.Pdf;
const HitRecord = object.HitRecord;
const Allocator = std.mem.Allocator;

/// Unified scattering output (mirrors the C++ scatter_record).
pub const ScatterRecord = struct {
    specular_ray: Ray = .{},
    is_specular: bool = false,
    attenuation: Color = .{},
    pdf: ?Pdf = null,
};

pub const Material = union(enum) {
    lambertian: *Lambertian,
    metal: *Metal,
    dielectric: *Dielectric,
    isotropic: *Isotropic,
    diffuse_light: *DiffuseLight,

    /// 4-argument scatter (the legacy path used by ray_color_with_*).
    pub fn scatter(self: Material, r_in: Ray, rec: *const HitRecord, attenuation: *Color, scattered: *Ray) bool {
        return switch (self) {
            .lambertian => |m| m.scatter(r_in, rec, attenuation, scattered),
            .metal => |m| m.scatter(r_in, rec, attenuation, scattered),
            .dielectric => |m| m.scatter(r_in, rec, attenuation, scattered),
            .isotropic => |m| m.scatter(r_in, rec, attenuation, scattered),
            .diffuse_light => |m| m.scatter(r_in, rec, attenuation, scattered),
        };
    }

    /// 5-argument scatter with an explicit pdf (only lambertian).
    pub fn scatterPdf(self: Material, r_in: Ray, rec: *const HitRecord, attenuation: *Color, scattered: *Ray, pdf: *f64) bool {
        return switch (self) {
            .lambertian => |m| m.scatterPdf(r_in, rec, attenuation, scattered, pdf),
            else => false,
        };
    }

    /// scatter into a ScatterRecord (the main path used by ray_color).
    pub fn scatterSrec(self: Material, r_in: Ray, rec: *const HitRecord, srec: *ScatterRecord) bool {
        return switch (self) {
            .lambertian => |m| m.scatterSrec(r_in, rec, srec),
            .metal => |m| m.scatterSrec(r_in, rec, srec),
            .dielectric => |m| m.scatterSrec(r_in, rec, srec),
            else => false,
        };
    }

    pub fn scatteringPdf(self: Material, r_in: Ray, rec: *const HitRecord, scattered: Ray) f64 {
        return switch (self) {
            .lambertian => |m| m.scatteringPdf(r_in, rec, scattered),
            else => 0.0,
        };
    }

    pub fn emitted3(self: Material, u: f64, v: f64, p: Point3) Color {
        return switch (self) {
            .diffuse_light => |m| m.emitted(u, v, p),
            else => Color.init(0, 0, 0),
        };
    }

    pub fn emitted5(self: Material, r_in: Ray, rec: *const HitRecord, u: f64, v: f64, p: Point3) Color {
        return switch (self) {
            .diffuse_light => |m| m.emittedV2(r_in, rec, u, v, p),
            else => Color.init(0, 0, 0),
        };
    }
};

pub fn newLambertian(alloc: Allocator, alb: *Texture) Allocator.Error!*Material {
    const m = try alloc.create(Lambertian);
    errdefer alloc.destroy(m);
    m.* = .{ .albedo = alb };
    const mat = try alloc.create(Material);
    mat.* = .{ .lambertian = m };
    return mat;
}

pub fn newMetal(alloc: Allocator, a: Color, f: f64) Allocator.Error!*Material {
    const m = try alloc.create(Metal);
    errdefer alloc.destroy(m);
    m.* = .{ .albedo = a, .fuzz = if (f < 1) f else 1 };
    const mat = try alloc.create(Material);
    mat.* = .{ .metal = m };
    return mat;
}

pub fn newDielectric(alloc: Allocator, ir: f64) Allocator.Error!*Material {
    const m = try alloc.create(Dielectric);
    errdefer alloc.destroy(m);
    m.* = .{ .ir = ir };
    const mat = try alloc.create(Material);
    mat.* = .{ .dielectric = m };
    return mat;
}

pub fn newIsotropic(alloc: Allocator, c: Color) Allocator.Error!*Material {
    const m = try alloc.create(Isotropic);
    errdefer alloc.destroy(m);
    const mat = try alloc.create(Material);
    errdefer alloc.destroy(mat);
    m.* = .{ .albedo = try texture.newSolid(alloc, c) };
    mat.* = .{ .isotropic = m };
    return mat;
}

pub const Lambertian = struct {
    albedo: *Texture,

    pub fn scatter(self: Lambertian, r_in: Ray, rec: *const HitRecord, attenuation: *Color, scattered: *Ray) bool {
        var scatter_direction = rec.normal.add(random.randomUnitSphere());
        if (scatter_direction.nearZero()) scatter_direction = rec.normal;
        scattered.* = Ray.init(rec.p, scatter_direction, r_in.time);
        attenuation.* = self.albedo.value(rec.u, rec.v, rec.p);
        return true;
    }

    pub fn scatterPdf(self: Lambertian, r_in: Ray, rec: *const HitRecord, attenuation: *Color, scattered: *Ray, pdf: *f64) bool {
        var uvw: Onb = .{};
        uvw.buildFromW(rec.normal);
        const direction = uvw.local(random.randomCosineDirection());
        scattered.* = Ray.init(rec.p, direction.normalized(), r_in.time);
        attenuation.* = self.albedo.value(rec.u, rec.v, rec.p);
        pdf.* = uvw.w().dot(scattered.direction) / math.pi;
        return true;
    }

    pub fn scatterSrec(self: Lambertian, r_in: Ray, rec: *const HitRecord, srec: *ScatterRecord) bool {
        _ = r_in;
        srec.is_specular = false;
        srec.attenuation = self.albedo.value(rec.u, rec.v, rec.p);
        srec.pdf = Pdf{ .cosine = pdf_mod.CosinePdf.init(rec.normal) };
        return true;
    }

    pub fn scatteringPdf(self: Lambertian, r_in: Ray, rec: *const HitRecord, scattered: Ray) f64 {
        _ = self;
        _ = r_in;
        const cosine = rec.normal.dot(scattered.direction.normalized());
        return if (cosine < 0) 0.0 else cosine / math.pi;
    }
};

pub const Metal = struct {
    albedo: Color,
    fuzz: f64,

    pub fn scatter(self: Metal, r_in: Ray, rec: *const HitRecord, attenuation: *Color, scattered: *Ray) bool {
        const reflected = math.reflect(r_in.direction.normalized(), rec.normal);
        scattered.* = Ray.init(rec.p, reflected, r_in.time);
        attenuation.* = self.albedo;
        return scattered.direction.dot(rec.normal) > 0;
    }

    pub fn scatterSrec(self: Metal, r_in: Ray, rec: *const HitRecord, srec: *ScatterRecord) bool {
        const reflected = math.reflect(r_in.direction.normalized(), rec.normal);
        srec.specular_ray = Ray.init(rec.p, reflected.add(random.randomInUnitSphere().scale(self.fuzz)), r_in.time);
        srec.attenuation = self.albedo;
        srec.is_specular = true;
        srec.pdf = null;
        return true;
    }
};

pub const Dielectric = struct {
    ir: f64,

    pub fn scatter(self: Dielectric, r_in: Ray, rec: *const HitRecord, attenuation: *Color, scattered: *Ray) bool {
        attenuation.* = Color.init(1, 1, 1);
        const refraction_ratio = if (rec.front_face) (1.0 / self.ir) else self.ir;
        const unit_direction = r_in.direction.normalized();
        const cos_theta = @min(unit_direction.neg().dot(rec.normal), 1.0);
        const sin_theta = @sqrt(1.0 - cos_theta * cos_theta);
        const cannot_refract = refraction_ratio * sin_theta > 1.0;
        const direction = if (cannot_refract or reflectance(cos_theta, refraction_ratio) > random.randomDouble())
            math.reflect(unit_direction, rec.normal)
        else
            math.refract(unit_direction, rec.normal, refraction_ratio);
        scattered.* = Ray.init(rec.p, direction, r_in.time);
        return true;
    }

    pub fn scatterSrec(self: Dielectric, r_in: Ray, rec: *const HitRecord, srec: *ScatterRecord) bool {
        srec.is_specular = true;
        srec.pdf = null;
        srec.attenuation = Color.init(1, 1, 1);
        const refraction_ratio = if (rec.front_face) (1.0 / self.ir) else self.ir;
        const unit_direction = r_in.direction.normalized();
        const cos_theta = @min(unit_direction.neg().dot(rec.normal), 1.0);
        const sin_theta = @sqrt(1.0 - cos_theta * cos_theta);
        const cannot_refract = refraction_ratio * sin_theta > 1.0;
        const direction = if (cannot_refract or reflectance(cos_theta, refraction_ratio) > random.randomDouble())
            math.reflect(unit_direction, rec.normal)
        else
            math.refract(unit_direction, rec.normal, refraction_ratio);
        srec.specular_ray = Ray.init(rec.p, direction, r_in.time);
        return true;
    }

    fn reflectance(cosine: f64, ref_idx: f64) f64 {
        const r0 = (1 - ref_idx) / (1 + ref_idx);
        const r0sq = r0 * r0;
        return r0sq + (1 - r0sq) * math.pow(1.0 - cosine, 5.0);
    }
};

pub const Isotropic = struct {
    albedo: *Texture,

    pub fn scatter(self: Isotropic, r_in: Ray, rec: *const HitRecord, attenuation: *Color, scattered: *Ray) bool {
        scattered.* = Ray.init(rec.p, random.randomInUnitSphere(), r_in.time);
        attenuation.* = self.albedo.value(rec.u, rec.v, rec.p);
        return true;
    }
};

pub const DiffuseLight = struct {
    emit: *Texture,

    pub fn scatter(self: DiffuseLight, r_in: Ray, rec: *const HitRecord, attenuation: *Color, scattered: *Ray) bool {
        _ = self;
        _ = r_in;
        _ = rec;
        _ = attenuation;
        _ = scattered;
        return false;
    }

    pub fn emitted(self: DiffuseLight, u: f64, v: f64, p: Point3) Color {
        return self.emit.value(u, v, p);
    }

    pub fn emittedV2(self: DiffuseLight, r_in: Ray, rec: *const HitRecord, u: f64, v: f64, p: Point3) Color {
        _ = r_in;
        return if (rec.front_face) self.emit.value(u, v, p) else Color.init(0, 0, 0);
    }
};
