const std = @import("std");
const math = @import("math.zig");
const random = @import("random.zig");
const camera = @import("camera.zig");
const material = @import("material.zig");
const texture = @import("texture.zig");
const object = @import("object.zig");
const render = @import("render.zig");

const Point3 = math.Point3;
const Vec3 = math.Vec3;
const Color = math.Color;

pub const Options = struct {
    thread_count: usize = 0,
    help: bool = false,

    pub fn parse(args: []const [:0]const u8) !Options {
        var options = Options{};
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
                options.help = true;
            } else if (std.mem.eql(u8, args[i], "--threads")) {
                i += 1;
                if (i == args.len) return error.MissingThreadCount;
                options.thread_count = std.fmt.parseInt(usize, args[i], 10) catch return error.InvalidThreadCount;
            } else {
                return error.UnknownArgument;
            }
        }
        return options;
    }
};

const usage = "Usage: zrenderer [--threads N] [--help]\n" ++
    "  --threads 0  Auto-select CPU workers (default)\n" ++
    "  --threads 1  Render on a single thread\n";

fn loadRandomScene(alloc: std.mem.Allocator) !*render.Scene {
    std.debug.print("Loading random scene...\n", .{});
    const scene = try alloc.create(render.Scene);
    scene.* = render.Scene.init(alloc, "random_scene");

    const checker = try texture.newCheckerColors(alloc, Color.init(0.2, 0.3, 0.1), Color.init(0.9, 0.9, 0.9));
    const ground_material = try material.newLambertian(alloc, checker);
    try scene.addObject(try object.newSphere(alloc, Point3.init(0, -1000, 0), Point3.init(0, -1000, 0), 0.0, 1.0, 1000.0, ground_material));

    var a: i32 = -11;
    while (a < 11) : (a += 1) {
        var b: i32 = -11;
        while (b < 11) : (b += 1) {
            const choose_mat = random.randomDouble();
            const center = Point3.init(
                @as(f64, @floatFromInt(a)) + 0.9 * random.randomDouble(),
                0.2,
                @as(f64, @floatFromInt(b)) + 0.9 * random.randomDouble(),
            );

            if (center.sub(Point3.init(4, 0.2, 0)).length() > 0.9) {
                if (choose_mat < 0.8) {
                    // diffuse
                    const albedo = random.randomVec().mul(random.randomVec());
                    const sphere_material = try material.newLambertian(alloc, try texture.newSolid(alloc, albedo));
                    const center2 = center.add(Vec3.init(0, random.randomDoubleRange(0, 0.5), 0));
                    try scene.addObject(try object.newSphere(alloc, center, center2, 0.0, 1.0, 0.2, sphere_material));
                } else if (choose_mat < 0.9) {
                    // metal
                    const albedo = random.randomVecRange(0.5, 1.0);
                    const fuzz = random.randomDoubleRange(0, 0.5);
                    const sphere_material = try material.newMetal(alloc, albedo, fuzz);
                    try scene.addObject(try object.newSphere(alloc, center, center, 0.0, 1.0, 0.2, sphere_material));
                } else {
                    // glass
                    const sphere_material = try material.newDielectric(alloc, 1.5);
                    try scene.addObject(try object.newSphere(alloc, center, center, 0.0, 1.0, 0.2, sphere_material));
                }
            }
        }
    }
    try scene.buildBvh();
    return scene;
}

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena_state.allocator();
    defer arena_state.deinit();

    const argv = try init.minimal.args.toSlice(alloc);
    const options = Options.parse(argv[1..]) catch |err| {
        std.debug.print("Invalid arguments: {s}\n{s}", .{ @errorName(err), usage });
        return err;
    };
    if (options.help) {
        std.debug.print("{s}", .{usage});
        return;
    }

    var timer = render.Clock{ .io = init.io };
    timer.start();

    const scene = try loadRandomScene(alloc);
    std.debug.print("Scene loaded.\n", .{});

    const args = camera.CameraArgs{
        .lookfrom = Point3.init(13, 2, 3),
        .lookat = Point3.init(0, 0, 0),
        .vup = Vec3.init(0, 1, 0),
        .vfov = 20.0,
        .aperture = 0.1,
        .aspect_ratio = 16.0 / 9.0,
    };
    const cam = args.build();

    const image_width: i32 = 8640;
    const image_height: i32 = @intFromFloat(@as(f64, @floatFromInt(image_width)) / args.aspect_ratio);

    const params = render.RenderParams{
        .cam = cam,
        .background = Color.init(0.7, 0.8, 1.0),
        .image_width = image_width,
        .image_height = image_height,
        .samples_per_pixel = 100,
        .min_bounce = 100,
        .rr = 0.9,
        .channel = 3,
        .thread_count = options.thread_count,
    };

    std.debug.print("Render set done.\n", .{});
    try render.renderImage(alloc, params, scene.bvh, scene.light, "random_scene.png");
    std.debug.print("Rendering done.\n", .{});

    timer.stop();
    const secs = timer.elapsedSeconds();
    const minutes: i64 = @intFromFloat(secs / 60.0);
    const seconds: i64 = @intFromFloat(@mod(secs, 60.0));
    std.debug.print("\nDone. Elapsed time: {d} minutes and {d} seconds.\n", .{ minutes, seconds });
}
