const std = @import("std");
const math = @import("math.zig");
const Vec3 = math.Vec3;
const Point3 = math.Point3;

var prng = std.Random.DefaultPrng.init(0x1234_5678_9abc_def0);
var rnd = prng.random();

pub fn randomDouble() f64 {
    return rnd.float(f64);
}

pub fn randomDoubleRange(min: f64, max: f64) f64 {
    return min + (max - min) * randomDouble();
}

pub fn randomVec() Vec3 {
    return Vec3.init(randomDouble(), randomDouble(), randomDouble());
}

pub fn randomVecRange(min: f64, max: f64) Vec3 {
    return Vec3.init(randomDoubleRange(min, max), randomDoubleRange(min, max), randomDoubleRange(min, max));
}

pub fn randomUnitVec() Vec3 {
    return randomVec().normalized();
}

pub fn randomInt(min: i32, max: i32) i32 {
    return @intFromFloat(randomDoubleRange(@floatFromInt(min), @floatFromInt(max) + 1.0));
}

pub fn randomInUnitSphere() Point3 {
    var p: Point3 = undefined;
    while (true) {
        p = randomVecRange(-1.0, 1.0);
        if (p.lengthSquared() < 1.0) break;
    }
    return p;
}

pub fn randomUnitSphere() Vec3 {
    return randomInUnitSphere().normalized();
}

pub fn randomInHemisphere(normal: Vec3) Vec3 {
    const in_unit_sphere = randomInUnitSphere();
    if (in_unit_sphere.dot(normal) > 0.0)
        return in_unit_sphere
    else
        return in_unit_sphere.neg();
}

pub fn randomInUnitDisk() Vec3 {
    while (true) {
        const p = Vec3.init(randomDoubleRange(-1, 1), randomDoubleRange(-1, 1), 0);
        if (p.lengthSquared() < 1) return p;
    }
}

/// Random direction with a cos(theta)/pi distribution.
pub fn randomCosineDirection() Vec3 {
    const r1 = randomDouble();
    const r2 = randomDouble();
    const z = @sqrt(1.0 - r2);
    const phi = 2.0 * math.pi * r1;
    const x = @cos(phi) * @sqrt(r2);
    const y = @sin(phi) * @sqrt(r2);
    return Vec3.init(x, y, z);
}

pub fn randomToSphere(radius: f64, distance_squared: f64) Vec3 {
    const r1 = randomDouble();
    const r2 = randomDouble();
    const z = 1.0 + r2 * (@sqrt(1.0 - radius * radius / distance_squared) - 1.0);
    const phi = 2.0 * math.pi * r1;
    const x = @cos(phi) * @sqrt(1.0 - z * z);
    const y = @sin(phi) * @sqrt(1.0 - z * z);
    return Vec3.init(x, y, z);
}
