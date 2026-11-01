const std = @import("std");
const math = @import("math.zig");
const noise_mod = @import("noise.zig");
const stb = @import("stb.zig");

const Color = math.Color;
const Point3 = math.Point3;
const Allocator = std.mem.Allocator;

pub const Texture = union(enum) {
    solid: *SolidColor,
    checker: *CheckerTexture,
    perlin: *PerlinNoiseTexture,
    image: *ImageTexture,

    pub fn value(self: Texture, u: f64, v: f64, p: Point3) Color {
        return switch (self) {
            .solid => |t| t.value(u, v, p),
            .checker => |t| t.value(u, v, p),
            .perlin => |t| t.value(u, v, p),
            .image => |t| t.value(u, v, p),
        };
    }
};

pub fn newSolid(alloc: Allocator, c: Color) *Texture {
    const s = alloc.create(SolidColor);
    s.* = .{ .color_value = c };
    const t = alloc.create(Texture);
    t.* = .{ .solid = s };
    return t;
}

pub fn newCheckerColors(alloc: Allocator, c1: Color, c2: Color) *Texture {
    const ch = alloc.create(CheckerTexture);
    ch.* = .{ .even = newSolid(alloc, c1), .odd = newSolid(alloc, c2) };
    const t = alloc.create(Texture);
    t.* = .{ .checker = ch };
    return t;
}

pub const SolidColor = struct {
    color_value: Color = .{},

    pub fn value(self: SolidColor, u: f64, v: f64, p: Point3) Color {
        _ = u;
        _ = v;
        _ = p;
        return self.color_value;
    }
};

pub const CheckerTexture = struct {
    even: *Texture,
    odd: *Texture,

    pub fn value(self: CheckerTexture, u: f64, v: f64, p: Point3) Color {
        const sines = @sin(10.0 * p.x) * @sin(10.0 * p.y) * @sin(10.0 * p.z);
        if (sines < 0) return self.odd.value(u, v, p);
        return self.even.value(u, v, p);
    }
};

pub const PerlinNoiseTexture = struct {
    noise: noise_mod.Perlin,
    scale: f64,

    pub fn init(sc: f64) PerlinNoiseTexture {
        return .{ .noise = noise_mod.Perlin.init(), .scale = sc };
    }

    pub fn value(self: PerlinNoiseTexture, u: f64, v: f64, p: Point3) Color {
        _ = u;
        _ = v;
        return Color.init(1, 1, 1).scale(0.5 * (1.0 + @sin(self.scale * p.z + 10.0 * self.noise.turb(p, 7))));
    }
};

pub const ImageTexture = struct {
    data: ?[*]u8 = null,
    width: i32 = 0,
    height: i32 = 0,
    bytes_per_scanline: i32 = 0,
    bytes_per_pixel: i32 = 3,

    pub fn init(filename: [*:0]const u8) ImageTexture {
        var self = ImageTexture{};
        var comp: c_int = self.bytes_per_pixel;
        self.data = stb.stbi_load(filename, &self.width, &self.height, &comp, self.bytes_per_pixel);
        if (self.data == null) {
            std.debug.print("ERROR: Could not load texture image file '{s}'.\n", .{filename});
            self.width = 0;
            self.height = 0;
        }
        self.bytes_per_scanline = self.bytes_per_pixel * self.width;
        return self;
    }

    pub fn value(self: ImageTexture, u_in: f64, v_in: f64, p: Point3) Color {
        _ = p;
        if (self.data == null) return Color.init(0, 1, 1);

        const u = math.clamp(u_in, 0.0, 1.0);
        const v = 1.0 - math.clamp(v_in, 0.0, 1.0);

        var i: i32 = @intFromFloat(u * @as(f64, @floatFromInt(self.width)));
        var j: i32 = @intFromFloat(v * @as(f64, @floatFromInt(self.height)));
        if (i >= self.width) i = self.width - 1;
        if (j >= self.height) j = self.height - 1;

        const color_scale = 1.0 / 255.0;
        const offset: usize = @intCast(j * self.bytes_per_scanline + i * self.bytes_per_pixel);
        const pixel = self.data.? + offset;
        return Color.init(
            color_scale * @as(f64, @floatFromInt(pixel[0])),
            color_scale * @as(f64, @floatFromInt(pixel[1])),
            color_scale * @as(f64, @floatFromInt(pixel[2])),
        );
    }
};
