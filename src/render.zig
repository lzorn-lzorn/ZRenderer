const std = @import("std");
const math = @import("math.zig");
const random = @import("random.zig");
const camera = @import("camera.zig");
const object = @import("object.zig");
const color_mod = @import("color.zig");
const stb = @import("stb.zig");
const sampling = @import("sampling.zig");
const light = @import("light.zig");
const texture = @import("texture.zig");
const environment = @import("environment.zig");
const denoise = @import("denoise.zig");

const Color = math.Color;
const Camera = camera.Camera;
const Allocator = std.mem.Allocator;

// @brief 管理场景对象列表、可选采样光源和构建后的加速结构。
// @notice 对象和材质由场景分配器生命周期管理；渲染前必须建立 BVH。
pub const Scene = struct {
    alloc: Allocator,
    name: []const u8 = "",
    world: object.ObjectGroup,
    light: ?*object.Object = null,
    bvh: *object.BvhNode = undefined,
    images: std.ArrayList(*texture.ImageTexture) = .empty,

    // @brief 创建空场景，借用名称切片并保存分配器。
    pub fn init(alloc: Allocator, name: []const u8) Scene {
        return .{
            .alloc = alloc,
            .name = name,
            .world = object.ObjectGroup.init(alloc),
            .images = .empty,
        };
    }

    // @brief 追加借用对象；列表扩容失败时返回错误。
    pub fn addObject(self: *Scene, obj: *object.Object) !void {
        try self.world.add(obj);
    }

    // @brief 登记一张由 stb 分配的图像纹理，供 deinit 统一释放像素缓冲。
    // @notice 图像纹理包装本身仍由场景分配器管理，此处只释放内部像素缓冲。
    pub fn addImage(self: *Scene, image: *texture.ImageTexture) !void {
        try self.images.append(self.alloc, image);
    }

    // @brief 为非空场景建立覆盖时间 [0,1] 的 BVH。
    // @return 无效对象范围、缺失包围盒或分配失败时返回错误。
    pub fn buildBvh(self: *Scene) object.BvhNode.BuildError!void {
        self.bvh = try object.BvhNode.init(self.alloc, self.world.list.items, 0, self.world.list.items.len, 0, 1);
    }

    // @brief 释放所有登记的 stb 图像像素缓冲；几何、材质和包装仍由场景分配器统一回收。
    // @notice 在场景分配器销毁前调用；重复调用安全（deinit 会重置各图像）。
    pub fn deinit(self: *Scene) void {
        for (self.images.items) |image| image.deinit();
        self.images.deinit(self.alloc);
    }
};

// @brief 使用清醒时间时钟统计经过时间。
pub const Clock = struct {
    io: std.Io,
    start_time: i128 = 0,
    end_time: i128 = 0,
    is_running: bool = false,

    // @brief 重设起点并开始计时。
    pub fn start(self: *Clock) void {
        self.start_time = std.Io.Clock.awake.now(self.io).toNanoseconds();
        self.is_running = true;
    }

    // @brief 记录终点并停止计时。
    pub fn stop(self: *Clock) void {
        self.end_time = std.Io.Clock.awake.now(self.io).toNanoseconds();
        self.is_running = false;
    }

    // @brief 返回已开始的计时区间秒数；运行中使用当前时间作为终点。
    pub fn elapsedSeconds(self: Clock) f64 {
        const ns = if (self.is_running) std.Io.Clock.awake.now(self.io).toNanoseconds() - self.start_time else self.end_time - self.start_time;
        return @as(f64, @floatFromInt(ns)) / 1e9;
    }
};

// @brief 渲染结束后汇总的样本总数和提前停止像素数。
pub const RenderStats = struct {
    total_samples: u64 = 0,
    early_stopped_pixels: u64 = 0,
};

// @brief 相机、积分器、线程调度和采样停止设置。
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
    // @notice 零表示使用可用逻辑处理器数；一表示仅在调用线程渲染。
    thread_count: usize = 0,
    rows_per_task: usize = 8,
    seed: u64 = random.default_seed,
    sampler: sampling.Sampler = .sobol,
    adaptive: bool = true,
    min_samples: u32 = 16,
    absolute_error: f64 = 0.002,
    // @brief 可选独立光源与恒定/贴图环境重要性采样；切片在所有工作线程退出前保持有效。
    point_lights: []const light.PointLight = &.{},
    distant_lights: []const light.DistantLight = &.{},
    environment: ?*const environment.EnvironmentMap = null,
    sample_environment: bool = false,
    relative_error: f64 = 0.05,
    // @brief 线性域 G-buffer 引导的联合双边降噪；需主射线首个命中数据.
    denoise: bool = false,
    denoise_options: denoise.Options = .{},
    // @notice 可选的调用者自有统计输出，仅在全部工作线程汇合后写入。
    stats: ?*RenderStats = null,
};

// @brief 渲染为自上而下、紧密排列的 RGB 字节缓冲。
// @param alloc 在调用线程上分配输出及工作资源的分配器。
// @param params 渲染设置；宽高至少为二，仅支持三个颜色通道。
// @param world 已建立的只读 BVH，其时间范围须覆盖相机快门。
// @param lights 可选的方向采样几何体，须支持有效的生成及密度求值。
// @return 调用者负责释放的像素缓冲；参数、分配或线程创建失败时返回错误。
// @notice 返回前，场景、材质和纹理必须保持只读且存活。
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

    if (params.min_samples == 0 or !std.math.isFinite(params.absolute_error) or
        !std.math.isFinite(params.relative_error) or params.absolute_error < 0 or params.relative_error < 0)
        return error.InvalidRenderParams;

    if (!(light.Sampler{ .area = lights, .background = params.background, .environment = params.environment, .points = params.point_lights, .distant = params.distant_lights }).valid() or
        !std.math.isFinite(params.cam.exposure_scale) or params.cam.exposure_scale <= 0)
        return error.InvalidRenderParams;

    const w: usize = @intCast(params.image_width);
    const h: usize = @intCast(params.image_height);
    const stride = try std.math.mul(usize, w, 3);
    if (stride > std.math.maxInt(c_int)) return error.InvalidRenderParams;
    const data = try alloc.alloc(u8, try std.math.mul(usize, stride, h));
    errdefer alloc.free(data);
    const pixel_count = try std.math.mul(usize, w, h);
    const linear = try alloc.alloc(Color, pixel_count);
    defer alloc.free(linear);
    const gbuffer = try alloc.alloc(denoise.Guide, pixel_count);
    defer alloc.free(gbuffer);

    // @notice 未位移的 Sobol 坐标只依赖样本序号，与像素无关。
    // @notice 缓存最多占 80 KiB；超大预算中的后续基础点按需计算。
    const point_count = @min((@as(usize, @intCast(params.samples_per_pixel)) - 1) / sampling.replicas + 1, 4096);
    const points: []sampling.SobolPoint = if (params.sampler == .sobol) try alloc.alloc(sampling.SobolPoint, point_count) else &.{};
    defer alloc.free(points);
    for (points, 0..) |*point, index| point.* = sampling.sobolPoint(@intCast(index));

    const rows_per_task = @min(params.rows_per_task, h);
    const task_count = (h - 1) / rows_per_task + 1;
    const requested = if (params.thread_count == 0) std.Thread.getCpuCount() catch 1 else params.thread_count;
    const worker_count = if (@import("builtin").single_threaded) 1 else @min(@max(requested, 1), task_count);
    var work = RenderWork{
        .params = params,
        .world = world,
        .lights = lights,
        .linear = linear,
        .gbuffer = gbuffer,
        .width = w,
        .height = h,
        .rows_per_task = rows_per_task,
        .sobol_points = points,
    };

    if (params.show_progress) std.debug.print("Rendering with {d} worker(s)...\n", .{worker_count});

    if (worker_count == 1) {
        work.run(true);
    } else if (!@import("builtin").single_threaded) {
        // @notice 所有分配均在调用线程完成，工作线程不访问区域分配器。
        const threads = try alloc.alloc(std.Thread, worker_count - 1);
        defer alloc.free(threads);
        var started: usize = 0;
        // @notice 释放工作上下文或像素缓冲前，必须先汇合已启动的所有线程。
        defer for (threads[0..started]) |thread| thread.join();
        errdefer work.cancelled.store(true, .monotonic);
        for (threads) |*thread| {
            thread.* = try std.Thread.spawn(.{}, RenderWork.run, .{ &work, false });
            started += 1;
        }
        work.run(true);
    }

    const stats = RenderStats{
        .total_samples = work.total_samples.load(.monotonic),
        .early_stopped_pixels = work.early_stopped_pixels.load(.monotonic),
    };
    if (params.stats) |out| out.* = stats;
    if (params.show_progress) std.debug.print("\rRendering: 100% ({d}/{d} rows), {d:.1} samples/pixel\n", .{ h, h, @as(f64, @floatFromInt(stats.total_samples)) / @as(f64, @floatFromInt(w * h)) });

    if (params.denoise) {
        if (params.show_progress) std.debug.print("Denoising...\n", .{});
        try denoise.denoiseJointBilateral(alloc, linear, gbuffer, w, h, params.denoise_options);
    }

    // @notice 线性图像统一编码为显示字节；writeColor 以 samples=1 避免二次除法。
    var i: usize = 0;
    while (i < pixel_count) : (i += 1) {
        color_mod.writeColor(data[i * 3 ..][0..3], linear[i], 1);
    }
    return data;
}

const RenderWork = struct {
    params: RenderParams,
    world: *object.BvhNode,
    lights: ?*object.Object,
    linear: []Color,
    gbuffer: []denoise.Guide,
    width: usize,
    height: usize,
    rows_per_task: usize,
    sobol_points: []const sampling.SobolPoint,
    next_row: std.atomic.Value(usize) = .init(0),
    completed_rows: std.atomic.Value(usize) = .init(0),
    cancelled: std.atomic.Value(bool) = .init(false),
    total_samples: std.atomic.Value(u64) = .init(0),
    early_stopped_pixels: std.atomic.Value(u64) = .init(0),

    fn run(self: *RenderWork, report_progress: bool) void {
        var last_percent: usize = 0;
        while (!self.cancelled.load(.monotonic)) {
            const first = self.next_row.fetchAdd(self.rows_per_task, .monotonic);
            if (first >= self.height) break;
            const end = @min(first + self.rows_per_task, self.height);
            for (first..end) |row| self.renderRow(row);
            const done = self.completed_rows.fetchAdd(end - first, .monotonic) + end - first;
            // @notice 仅调用线程打印进度，每个百分点最多输出一次。
            const percent = done * 100 / self.height;
            if (report_progress and self.params.show_progress and percent > last_percent and percent < 100) {
                std.debug.print("\rRendering: {d}% ({d}/{d} rows)", .{ percent, done, self.height });
                last_percent = percent;
            }
        }
    }

    fn renderRow(self: *RenderWork, row: usize) void {
        const params = self.params;
        // @notice 相机 v 轴向上，而 PNG 行从图像顶部开始。
        const j = self.height - 1 - row;
        const max_samples: u32 = @intCast(params.samples_per_pixel);
        var row_samples: u64 = 0;
        var early_stopped: u64 = 0;
        for (0..self.width) |i| {
            const idx = row * self.width + i;
            const sampler = sampling.PixelSampler.init(params.seed, @intCast(idx), params.sampler);
            const light_sampler = light.Sampler{
                .area = self.lights,
                .background = params.background,
                .environment = params.environment,
                .points = params.point_lights,
                .distant = params.distant_lights,
                .sample_environment = params.sample_environment,
            };
            var estimate: sampling.Estimate = .{};
            while (estimate.count < max_samples) {
                const sequence_index = estimate.count / sampling.replicas;
                const point: sampling.SobolPoint = if (params.sampler == .random) @splat(0) else if (sequence_index < self.sobol_points.len) self.sobol_points[sequence_index] else sampling.sobolPoint(sequence_index);
                const sample = sampler.startSampleWithPoint(estimate.count, point);
                // @notice 样本保持在所属像素内，并处于成像平面 [0,1] 范围。
                const u = (@as(f64, @floatFromInt(i)) + sample[0]) / @as(f64, @floatFromInt(self.width));
                const v = (@as(f64, @floatFromInt(j)) + sample[1]) / @as(f64, @floatFromInt(self.height));
                const r = params.cam.getRaySampled(u, v, sample[2], sample[3], sample[4]);
                // @notice 仅首个样本输出 G-buffer，避免每样本额外开销。
                var primary: color_mod.PrimaryHit = .{};
                const radiance = if (estimate.count == 0)
                    color_mod.rayColorLitPrimary(r, self.world, light_sampler, params.min_bounce, params.rr, &primary)
                else
                    color_mod.rayColorLit(r, self.world, light_sampler, params.min_bounce, params.rr);
                if (estimate.count == 0) {
                    self.gbuffer[idx] = .{ .albedo = primary.albedo, .normal = primary.normal, .depth = primary.depth, .hit = primary.hit };
                }
                estimate.add(radiance.scale(params.cam.sampleWeight(u, v)));
                if (params.adaptive and estimate.converged(params.min_samples, params.absolute_error, params.relative_error)) break;
            }
            row_samples += estimate.count;
            if (estimate.count < max_samples) early_stopped += 1;
            self.linear[idx] = estimate.sum.scale(1.0 / @as(f64, @floatFromInt(estimate.count)));
        }
        _ = self.total_samples.fetchAdd(row_samples, .monotonic);
        _ = self.early_stopped_pixels.fetchAdd(early_stopped, .monotonic);
    }
};

// @brief 渲染像素后单次编码 PNG，随后释放像素缓冲。
// @param out_filename 以零结尾的输出路径；父目录须已存在。
// @return 渲染错误或编码失败错误；失败时不保证不存在部分输出文件。
pub fn renderImage(
    alloc: Allocator,
    params: RenderParams,
    world: *object.BvhNode,
    lights: ?*object.Object,
    out_filename: [*:0]const u8,
) !void {
    const data = try renderPixels(alloc, params, world, lights);
    defer alloc.free(data);

    // @notice 所有工作线程均已汇合：只编码一次，不产生中间文件。
    if (params.show_progress) std.debug.print("Encoding PNG...\n", .{});
    const ok = stb.stbi_write_png(out_filename, params.image_width, params.image_height, params.channel, data.ptr, 0);
    if (ok == 0) {
        std.debug.print("stbi_write_png failed\n", .{});
        return error.WriteFailed;
    }
}
