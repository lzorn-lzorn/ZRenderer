const std = @import("std");
const math = @import("math.zig");
const random = @import("random.zig");
const camera = @import("camera.zig");
const object = @import("object.zig");
const color_mod = @import("color.zig");
const stb = @import("stb.zig");

const Color = math.Color;
const Camera = camera.Camera;
const Allocator = std.mem.Allocator;

pub const Scene = struct {
    alloc: Allocator,
    name: []const u8 = "",
    world: object.ObjectGroup,
    light: ?*object.Object = null,
    bvh: *object.BvhNode = undefined,

    pub fn init(alloc: Allocator, name: []const u8) Scene {
        return .{ .alloc = alloc, .name = name, .world = object.ObjectGroup.init(alloc) };
    }

    pub fn addObject(self: *Scene, obj: *object.Object) !void {
        try self.world.add(obj);
    }

    pub fn buildBvh(self: *Scene) void {
        self.bvh = object.BvhNode.init(self.alloc, self.world.list.items, 0, self.world.list.items.len, 0, 1);
    }
};

pub const Clock = struct {
    start_time: i128 = 0,
    end_time: i128 = 0,
    is_running: bool = false,

    pub fn start(self: *Clock) void {
        self.start_time = std.time.nanoTimestamp();
        self.is_running = true;
    }

    pub fn stop(self: *Clock) void {
        self.end_time = std.time.nanoTimestamp();
        self.is_running = false;
    }

    pub fn elapsedSeconds(self: Clock) f64 {
        const ns = if (self.is_running) std.time.nanoTimestamp() - self.start_time else self.end_time - self.start_time;
        return @as(f64, @floatFromInt(ns)) / 1e9;
    }
};

pub const RenderParams = struct {
    cam: Camera,
    background: Color,
    image_width: i32,
    image_height: i32,
    samples_per_pixel: i32,
    min_bounce: i32,
    rr: f64,
    channel: i32,
};

pub fn renderImage(
    alloc: Allocator,
    params: RenderParams,
    world: *object.BvhNode,
    lights: ?*object.Object,
    out_filename: [*:0]const u8,
) !void {
    const w = params.image_width;
    const h = params.image_height;
    const data = try alloc.alloc(u8, @intCast(w * h * params.channel));

    var j: i32 = h - 1;
    while (j >= 0) : (j -= 1) {
        std.debug.print("\rScanlines remaining: {d} ", .{j});
        var i: i32 = 0;
        while (i < w) : (i += 1) {
            var pixel_color = Color.init(0, 0, 0);
            var s: i32 = 0;
            while (s < params.samples_per_pixel) : (s += 1) {
                const u = (@as(f64, @floatFromInt(i)) + random.randomDouble()) / @as(f64, @floatFromInt(w - 1));
                const v = (@as(f64, @floatFromInt(j)) + random.randomDouble()) / @as(f64, @floatFromInt(h - 1));
                const r = params.cam.getRay(u, v);
                pixel_color = pixel_color.add(color_mod.rayColor(r, params.background, world, lights, params.min_bounce, params.rr));
            }
            const idx: usize = @intCast((j * w + i) * params.channel);
            color_mod.writeColor(data[idx..], pixel_color, params.samples_per_pixel);
        }
    }
    std.debug.print("\n", .{});

    const ok = stb.stbi_write_png(out_filename, w, h, params.channel, data.ptr, 0);
    if (ok == 0) {
        std.debug.print("stbi_write_png failed\n", .{});
        return error.WriteFailed;
    }
}
