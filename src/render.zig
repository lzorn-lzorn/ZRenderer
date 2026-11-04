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

    pub fn buildBvh(self: *Scene) object.BvhNode.BuildError!void {
        self.bvh = try object.BvhNode.init(self.alloc, self.world.list.items, 0, self.world.list.items.len, 0, 1);
    }
};

pub const Clock = struct {
    io: std.Io,
    start_time: i128 = 0,
    end_time: i128 = 0,
    is_running: bool = false,

    pub fn start(self: *Clock) void {
        self.start_time = std.Io.Clock.awake.now(self.io).toNanoseconds();
        self.is_running = true;
    }

    pub fn stop(self: *Clock) void {
        self.end_time = std.Io.Clock.awake.now(self.io).toNanoseconds();
        self.is_running = false;
    }

    pub fn elapsedSeconds(self: Clock) f64 {
        const ns = if (self.is_running) std.Io.Clock.awake.now(self.io).toNanoseconds() - self.start_time else self.end_time - self.start_time;
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
    show_progress: bool = true,
    /// Zero selects the available logical CPU count; one renders on the caller.
    thread_count: usize = 0,
    rows_per_task: usize = 8,
    seed: u64 = random.default_seed,
};

/// Returns top-to-bottom RGB pixels. The caller owns the returned allocation.
/// The scene, materials and textures must remain read-only until this returns.
pub fn renderPixels(
    alloc: Allocator,
    params: RenderParams,
    world: *object.BvhNode,
    lights: ?*object.Object,
) ![]u8 {
    if (params.image_width < 2 or params.image_height < 2 or
        params.samples_per_pixel <= 0 or params.channel != 3 or
        params.rows_per_task == 0 or params.min_bounce < 0 or
        !std.math.isFinite(params.rr) or params.rr <= 0 or params.rr >= 1)
        return error.InvalidRenderParams;

    const w: usize = @intCast(params.image_width);
    const h: usize = @intCast(params.image_height);
    const stride = try std.math.mul(usize, w, 3);
    if (stride > std.math.maxInt(c_int)) return error.InvalidRenderParams;
    const data = try alloc.alloc(u8, try std.math.mul(usize, stride, h));
    errdefer alloc.free(data);

    const rows_per_task = @min(params.rows_per_task, h);
    const task_count = (h - 1) / rows_per_task + 1;
    const requested = if (params.thread_count == 0) std.Thread.getCpuCount() catch 1 else params.thread_count;
    const worker_count = if (@import("builtin").single_threaded) 1 else @min(@max(requested, 1), task_count);
    var work = RenderWork{
        .params = params,
        .world = world,
        .lights = lights,
        .data = data,
        .width = w,
        .height = h,
        .rows_per_task = rows_per_task,
    };

    if (params.show_progress) std.debug.print("Rendering with {d} worker(s)...\n", .{worker_count});

    if (worker_count == 1) {
        work.run(true);
    } else if (!@import("builtin").single_threaded) {
        // All allocations happen on the caller; workers never use the arena.
        const threads = try alloc.alloc(std.Thread, worker_count - 1);
        defer alloc.free(threads);
        var started: usize = 0;
        // Join before releasing either the work context or its pixel buffer.
        defer for (threads[0..started]) |thread| thread.join();
        errdefer work.cancelled.store(true, .monotonic);
        for (threads) |*thread| {
            thread.* = try std.Thread.spawn(.{}, RenderWork.run, .{ &work, false });
            started += 1;
        }
        work.run(true);
    }

    if (params.show_progress) std.debug.print("\rRendering: 100% ({d}/{d} rows)\n", .{ h, h });
    return data;
}

const RenderWork = struct {
    params: RenderParams,
    world: *object.BvhNode,
    lights: ?*object.Object,
    data: []u8,
    width: usize,
    height: usize,
    rows_per_task: usize,
    next_row: std.atomic.Value(usize) = .init(0),
    completed_rows: std.atomic.Value(usize) = .init(0),
    cancelled: std.atomic.Value(bool) = .init(false),

    fn run(self: *RenderWork, report_progress: bool) void {
        var last_percent: usize = 0;
        while (!self.cancelled.load(.monotonic)) {
            const first = self.next_row.fetchAdd(self.rows_per_task, .monotonic);
            if (first >= self.height) break;
            const end = @min(first + self.rows_per_task, self.height);
            for (first..end) |row| self.renderRow(row);
            const done = self.completed_rows.fetchAdd(end - first, .monotonic) + end - first;
            // Only the caller prints, at most once per percentage point.
            const percent = done * 100 / self.height;
            if (report_progress and self.params.show_progress and percent > last_percent and percent < 100) {
                std.debug.print("\rRendering: {d}% ({d}/{d} rows)", .{ percent, done, self.height });
                last_percent = percent;
            }
        }
    }

    fn renderRow(self: *const RenderWork, row: usize) void {
        const params = self.params;
        // Scheduling and worker count must not change the sample sequence.
        random.seed(params.seed +% @as(u64, @intCast(row)));
        // Camera v points upwards; PNG rows start at the top of the image.
        const j = self.height - 1 - row;
        for (0..self.width) |i| {
            var pixel_color = Color.init(0, 0, 0);
            var s: i32 = 0;
            while (s < params.samples_per_pixel) : (s += 1) {
                const u = (@as(f64, @floatFromInt(i)) + random.randomDouble()) / @as(f64, @floatFromInt(self.width - 1));
                const v = (@as(f64, @floatFromInt(j)) + random.randomDouble()) / @as(f64, @floatFromInt(self.height - 1));
                const r = params.cam.getRay(u, v);
                pixel_color = pixel_color.add(color_mod.rayColor(r, params.background, self.world, self.lights, params.min_bounce, params.rr));
            }
            const idx = (row * self.width + i) * 3;
            color_mod.writeColor(self.data[idx..][0..3], pixel_color, params.samples_per_pixel);
        }
    }
};

pub fn renderImage(
    alloc: Allocator,
    params: RenderParams,
    world: *object.BvhNode,
    lights: ?*object.Object,
    out_filename: [*:0]const u8,
) !void {
    const data = try renderPixels(alloc, params, world, lights);
    defer alloc.free(data);

    // All workers have joined: encode exactly once, without intermediate files.
    const ok = stb.stbi_write_png(out_filename, params.image_width, params.image_height, params.channel, data.ptr, 0);
    if (ok == 0) {
        std.debug.print("stbi_write_png failed\n", .{});
        return error.WriteFailed;
    }
}
