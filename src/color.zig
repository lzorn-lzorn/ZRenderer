const math = @import("math.zig");
const random = @import("random.zig");
const material = @import("material.zig");
const object = @import("object.zig");
const pdf_mod = @import("pdf.zig");

const Color = math.Color;
const Ray = math.Ray;
const HitRecord = object.HitRecord;
const ScatterRecord = material.ScatterRecord;
const Pdf = pdf_mod.Pdf;

/// Writes an [0,1] color into `out[0..3]` as 8-bit RGB, applying the
/// 1/samples-per-pixel scale and gamma correction (gamma = 2.2).
pub fn writeColor(out: []u8, pixel: Color, samples_per_pixel: i32) void {
    var r = pixel.x;
    var g = pixel.y;
    var b = pixel.z;

    // Clamp NaN to black (the C++ checks r != r).
    if (r != r) r = 0.0;
    if (g != g) g = 0.0;
    if (b != b) b = 0.0;

    const scale = 1.0 / @as(f64, @floatFromInt(samples_per_pixel));
    const inv_gamma = 1.0 / 2.2;
    r = math.pow(scale * r, inv_gamma);
    g = math.pow(scale * g, inv_gamma);
    b = math.pow(scale * b, inv_gamma);

    out[0] = @intFromFloat(256.0 * math.clamp(r, 0.0, 0.999));
    out[1] = @intFromFloat(256.0 * math.clamp(g, 0.0, 0.999));
    out[2] = @intFromFloat(256.0 * math.clamp(b, 0.0, 0.999));
}

/// The main path tracer: importance-samples the light (when present) and the
/// material's scattering pdf, mixed 50/50.
pub fn rayColor(r: Ray, background: Color, world: *object.BvhNode, lights: ?*object.Object, depth: i32, rr: f64) Color {
    var rec: HitRecord = .{};

    if (depth < 0 and random.randomDouble() >= rr) return Color.init(0, 0, 0);
    if (!world.hit(r, 0.001, math.infinity, &rec)) return background;

    var srec: ScatterRecord = .{};
    const emitted = rec.material.?.emitted5(r, &rec, rec.u, rec.v, rec.p);
    if (!rec.material.?.scatterSrec(r, &rec, &srec)) return emitted;

    if (srec.is_specular) {
        return srec.attenuation.mul(rayColor(srec.specular_ray, background, world, lights, depth - 1, rr)).scale(1.0 / rr);
    }

    var scattered: Ray = undefined;
    var pdf_val: f64 = undefined;
    if (lights) |light_obj| {
        var light_pdf = Pdf{ .hittable = .{ .ptr = light_obj, .o = rec.p } };
        var cos_pdf = srec.pdf.?;
        var mix = Pdf{ .mixture = .{ .p0 = &light_pdf, .p1 = &cos_pdf } };
        const dir = mix.generate();
        scattered = Ray.init(rec.p, dir, r.time);
        pdf_val = mix.value(dir);
    } else {
        const cos_pdf = srec.pdf.?;
        const dir = cos_pdf.generate();
        scattered = Ray.init(rec.p, dir, r.time);
        pdf_val = cos_pdf.value(dir);
    }

    const scattered_color = rayColor(scattered, background, world, lights, depth - 1, rr);
    const scattering_pdf = rec.material.?.scatteringPdf(r, &rec, scattered);
    return emitted.add(srec.attenuation.mul(scattered_color).scale(scattering_pdf / (pdf_val * rr)));
}

/// Legacy path: gradient background, no light sampling.
pub fn rayColorWithBvh(r: Ray, world: *object.BvhNode, depth: i32, rr: f64) Color {
    var rec: HitRecord = .{};
    if (world.hit(r, 0.001, math.infinity, &rec)) {
        if (random.randomDouble() >= rr) return Color.init(0, 0, 0);
        var scattered: Ray = undefined;
        var attenuation: Color = undefined;
        if (rec.material.?.scatter(r, &rec, &attenuation, &scattered)) {
            return attenuation.mul(rayColorWithBvh(scattered, world, depth - 1, rr)).scale(1.0 / rr);
        }
        return Color.init(0, 0, 0);
    }
    const unit_direction = r.direction.normalized();
    const t = 0.5 * (unit_direction.y + 1.0);
    return Color.init(1, 1, 1).scale(1.0 - t).add(Color.init(0.5, 0.7, 1.0).scale(t));
}

pub fn rayColorWithBackground(r: Ray, background: Color, world: *object.BvhNode, depth: i32, rr: f64) Color {
    var rec: HitRecord = .{};
    if (depth <= 0 and random.randomDouble() >= rr) return Color.init(0, 0, 0);
    if (!world.hit(r, 0.001, math.infinity, &rec)) return background;

    var scattered: Ray = undefined;
    var attenuation: Color = undefined;
    const emitted = rec.material.?.emitted3(rec.u, rec.v, rec.p);
    if (!rec.material.?.scatter(r, &rec, &attenuation, &scattered)) return emitted;
    return emitted.add(attenuation.mul(rayColorWithBackground(scattered, background, world, depth - 1, rr)).scale(1.0 / rr));
}

pub fn rayColorWithoutBvh(r: Ray, background: Color, world: object.ObjectGroup, depth: i32, rr: f64) Color {
    var rec: HitRecord = .{};
    if (depth < 0 and random.randomDouble() >= rr) return Color.init(0, 0, 0);
    if (!world.hit(r, 0.001, math.infinity, &rec)) return background;

    var scattered: Ray = undefined;
    var attenuation: Color = undefined;
    const emitted = rec.material.?.emitted3(rec.u, rec.v, rec.p);
    if (!rec.material.?.scatter(r, &rec, &attenuation, &scattered)) return emitted;
    return emitted.add(attenuation.mul(rayColorWithoutBvh(scattered, background, world, depth - 1, rr)).scale(1.0 / rr));
}
