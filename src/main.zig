const std = @import("std");
const math = @import("math.zig");
const camera = @import("camera.zig");
const render = @import("render.zig");
const sampling = @import("sampling.zig");
const scene_mod = @import("scene.zig");

const Point3 = math.Point3;
const Vec3 = math.Vec3;
const Color = math.Color;

// @brief 命令行参数；不改变用户原先设置的 8640 默认宽度，预览时应显式降低分辨率。
pub const Options = struct {
    thread_count: usize = 0,
    help: bool = false,
    image_width: i32 = 8640,
    samples: i32 = 100,
    min_samples: u32 = 16,
    min_bounce: i32 = 5,
    adaptive: bool = true,
    sampler: sampling.Sampler = .sobol,
    relative_error: f64 = 0.05,
    absolute_error: f64 = 0.002,
    output: [:0]const u8 = "random_scene.png",
    focal_length_mm: f64 = 50,
    f_number: f64 = 8,
    focus_distance: f64 = 13.3,
    shutter_seconds: f64 = 1.0 / 125.0,
    iso: f64 = 100,
    exposure_compensation: f64 = 0,
    fur_strands: usize = 1800,

    // @brief 解析并验证数值；物理相机还会校验对焦距离与焦距之间的关系。
    // @param args 不包含可执行文件路径的参数切片。
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
            } else if (std.mem.eql(u8, args[i], "--no-adaptive")) {
                options.adaptive = false;
            } else if (std.mem.eql(u8, args[i], "--focal-length") or std.mem.eql(u8, args[i], "--f-number") or
                std.mem.eql(u8, args[i], "--focus-distance") or std.mem.eql(u8, args[i], "--shutter") or
                std.mem.eql(u8, args[i], "--iso") or std.mem.eql(u8, args[i], "--exposure") or std.mem.eql(u8, args[i], "--fur-strands"))
            {
                const flag = args[i];
                i += 1;
                if (i == args.len) return error.MissingOptionValue;
                if (std.mem.eql(u8, flag, "--fur-strands")) {
                    options.fur_strands = std.fmt.parseInt(usize, args[i], 10) catch return error.InvalidFurCount;
                    if (options.fur_strands > 100000) return error.InvalidFurCount;
                } else {
                    const value = std.fmt.parseFloat(f64, args[i]) catch return error.InvalidCameraParameter;
                    if (!std.math.isFinite(value) or (value <= 0 and !std.mem.eql(u8, flag, "--exposure"))) return error.InvalidCameraParameter;
                    if (std.mem.eql(u8, flag, "--focal-length")) {
                        options.focal_length_mm = value;
                    } else if (std.mem.eql(u8, flag, "--f-number")) {
                        options.f_number = value;
                    } else if (std.mem.eql(u8, flag, "--focus-distance")) {
                        options.focus_distance = value;
                    } else if (std.mem.eql(u8, flag, "--shutter")) {
                        if (value > 1) return error.ShutterOutsideSceneInterval;
                        options.shutter_seconds = value;
                    } else if (std.mem.eql(u8, flag, "--iso")) {
                        options.iso = value;
                    } else {
                        options.exposure_compensation = value;
                    }
                }
            } else if (std.mem.eql(u8, args[i], "--width") or std.mem.eql(u8, args[i], "--samples") or
                std.mem.eql(u8, args[i], "--min-samples") or std.mem.eql(u8, args[i], "--rr-depth") or
                std.mem.eql(u8, args[i], "--relative-error") or std.mem.eql(u8, args[i], "--absolute-error") or
                std.mem.eql(u8, args[i], "--sampler") or std.mem.eql(u8, args[i], "--output"))
            {
                const flag = args[i];
                i += 1;
                if (i == args.len) return error.MissingOptionValue;
                const value = args[i];
                if (std.mem.eql(u8, flag, "--width")) {
                    options.image_width = std.fmt.parseInt(i32, value, 10) catch return error.InvalidWidth;
                    if (options.image_width < 4) return error.InvalidWidth;
                } else if (std.mem.eql(u8, flag, "--samples")) {
                    options.samples = std.fmt.parseInt(i32, value, 10) catch return error.InvalidSamples;
                    if (options.samples <= 0) return error.InvalidSamples;
                } else if (std.mem.eql(u8, flag, "--min-samples")) {
                    options.min_samples = std.fmt.parseInt(u32, value, 10) catch return error.InvalidSamples;
                    if (options.min_samples == 0) return error.InvalidSamples;
                } else if (std.mem.eql(u8, flag, "--rr-depth")) {
                    options.min_bounce = std.fmt.parseInt(i32, value, 10) catch return error.InvalidDepth;
                    if (options.min_bounce < 0) return error.InvalidDepth;
                } else if (std.mem.eql(u8, flag, "--sampler")) {
                    options.sampler = std.meta.stringToEnum(sampling.Sampler, value) orelse return error.InvalidSampler;
                } else if (std.mem.eql(u8, flag, "--output")) {
                    if (value.len == 0) return error.InvalidOutput;
                    options.output = value;
                } else {
                    const tolerance = std.fmt.parseFloat(f64, value) catch return error.InvalidTolerance;
                    if (!std.math.isFinite(tolerance) or tolerance < 0) return error.InvalidTolerance;
                    if (std.mem.eql(u8, flag, "--relative-error")) options.relative_error = tolerance else options.absolute_error = tolerance;
                }
            } else {
                return error.UnknownArgument;
            }
        }
        return options;
    }
};

const usage = "Usage: zrenderer [options]\n" ++
    "  --threads 0  Auto-select CPU workers (default)\n" ++
    "  --threads 1  Render on a single thread\n" ++
    "  --width N    Image width, 16:9 aspect ratio (default 8640)\n" ++
    "  --samples N  Maximum samples per pixel (default 100)\n" ++
    "  --min-samples N  Earliest adaptive check (default 16)\n" ++
    "  --rr-depth N    Start roulette after N scatters (default 5)\n" ++
    "  --sampler sobol|random  Camera sampler (default sobol)\n" ++
    "  --no-adaptive  Always use exactly --samples samples\n" ++
    "  --relative-error E  Relative error tolerance (default 0.05)\n" ++
    "  --absolute-error E  Linear RGB absolute tolerance (default 0.002)\n" ++
    "  --output FILE   PNG path; parent directory must exist\n" ++
    "  --focal-length MM  Physical focal length (default 50)\n" ++
    "  --f-number N       Lens f-number (default 8)\n" ++
    "  --focus-distance M Focus plane distance (default 13.3)\n" ++
    "  --shutter SECONDS  Exposure duration, (0,1] (default 0.008)\n" ++
    "  --iso N            Relative sensor gain (default 100)\n" ++
    "  --exposure EV      Exposure compensation (default 0)\n" ++
    "  --fur-strands N    Hero fur strand count, 0 disables (default 1800)\n";

// @brief 解析参数、建立物理相机与场景、执行并行渲染并写出 PNG。
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

    // @notice 参数解析已将快门限制在当前场景 BVH 的 [0,1] 秒运动区间内。
    const args = camera.PhysicalCameraArgs{
        .lookfrom = Point3.init(13, 2, 3),
        .lookat = Point3.init(0, 0.65, 0),
        .vup = Vec3.init(0, 1, 0),
        .focal_length_mm = options.focal_length_mm,
        .f_number = options.f_number,
        .focus_distance = options.focus_distance,
        .shutter_close = options.shutter_seconds,
        .iso = options.iso,
        .exposure_compensation = options.exposure_compensation,
    };
    const cam = try args.build();
    std.debug.print("Loading PBR scene...\n", .{});
    const scene = try scene_mod.loadRandomScene(alloc, .{ .fur_strands = options.fur_strands });
    std.debug.print("Scene loaded: {d} objects; {d} hero fur strands.\n", .{ scene.world.list.items.len, options.fur_strands });

    const image_width = options.image_width;
    const image_height: i32 = @intFromFloat(@as(f64, @floatFromInt(image_width)) / args.aspectRatio());

    const params = render.RenderParams{
        .cam = cam,
        .background = Color.init(0.3, 0.4, 0.6),
        .sample_environment = true,
        .image_width = image_width,
        .image_height = image_height,
        .samples_per_pixel = options.samples,
        .min_bounce = options.min_bounce,
        .rr = 0.9,
        .channel = 3,
        .thread_count = options.thread_count,
        .sampler = options.sampler,
        .adaptive = options.adaptive,
        .min_samples = options.min_samples,
        .relative_error = options.relative_error,
        .absolute_error = options.absolute_error,
    };

    std.debug.print("Render set done.\n", .{});
    try render.renderImage(alloc, params, scene.bvh, scene.light, options.output);
    std.debug.print("Rendering done.\n", .{});

    timer.stop();
    const secs = timer.elapsedSeconds();
    const minutes: i64 = @intFromFloat(secs / 60.0);
    const seconds: i64 = @intFromFloat(@mod(secs, 60.0));
    std.debug.print("\nDone. Elapsed time: {d} minutes and {d} seconds.\n", .{ minutes, seconds });
}
