const std = @import("std");
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

/// Iterative path integration. `depth` is the number of scattering events before
/// roulette starts, NOT a hard path-length cap. `rr` caps survival probability.
/// Only surviving roulette events divide throughput by their probability.
pub fn rayColor(r: Ray, background: Color, world: *object.BvhNode, lights: ?*object.Object, depth: i32, rr: f64) Color {
    std.debug.assert(rr > 0 and rr < 1);
    var ray = r;
    var radiance = Color.init(0, 0, 0);
    var throughput = Color.init(1, 1, 1);
    var remaining = @max(depth, 0);

    while (true) {
        var rec: HitRecord = .{};
        if (!world.hit(ray, 0.001, math.infinity, &rec)) {
            return radiance.add(throughput.mul(background));
        }
        const mat = rec.material.?;
        radiance = radiance.add(throughput.mul(mat.emitted5(ray, &rec, rec.u, rec.v, rec.p)));
        var srec: ScatterRecord = .{};
        if (!mat.scatterSrec(ray, &rec, &srec)) return radiance;

        if (srec.is_specular) {
            throughput = throughput.mul(srec.attenuation);
            ray = srec.specular_ray;
        } else {
            var bsdf_pdf = srec.pdf orelse return radiance;
            var scattered: Ray = undefined;
            var weight: f64 = 1;
            if (lights) |light_obj| {
                var light_pdf = Pdf{ .hittable = .{ .ptr = light_obj, .o = rec.p } };
                const mix = Pdf{ .mixture = .{ .p0 = &light_pdf, .p1 = &bsdf_pdf } };
                const direction = mix.generate();
                scattered = Ray.init(rec.p, direction, ray.time);
                const pdf_value = mix.value(direction);
                if (!(pdf_value > 0) or !std.math.isFinite(pdf_value)) return radiance;
                weight = mat.scatteringPdf(ray, &rec, scattered) / pdf_value;
            } else {
                const direction = bsdf_pdf.generate();
                scattered = Ray.init(rec.p, direction, ray.time);
                // Lambertian f*cos and cosine sampling both contain cos/pi.
                if (mat.* != .lambertian or bsdf_pdf != .cosine) {
                    const pdf_value = bsdf_pdf.value(direction);
                    if (!(pdf_value > 0) or !std.math.isFinite(pdf_value)) return radiance;
                    weight = mat.scatteringPdf(ray, &rec, scattered) / pdf_value;
                }
            }
            if (!(weight > 0) or !std.math.isFinite(weight)) return radiance;
            throughput = throughput.mul(srec.attenuation).scale(weight);
            ray = scattered;
        }

        if (!std.math.isFinite(throughput.x) or !std.math.isFinite(throughput.y) or !std.math.isFinite(throughput.z)) return radiance;
        const contribution = @max(throughput.x, @max(throughput.y, throughput.z));
        if (contribution <= 0) return radiance;
        if (remaining > 0) remaining -= 1;
        if (remaining == 0) {
            const survival = @min(rr, @max(0.05, contribution));
            if (random.randomDouble() >= survival) return radiance;
            throughput = throughput.scale(1.0 / survival);
        }
    }
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
