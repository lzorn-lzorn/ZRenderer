const std = @import("std");
const math = @import("math.zig");
const random = @import("random.zig");
const material = @import("material.zig");
const texture = @import("texture.zig");
const object = @import("object.zig");
const render = @import("render.zig");
const Point3 = math.Point3;
const Color = math.Color;

// @brief 随机场景控制参数；固定种子独立于渲染线程和逐像素随机流。
pub const Options = struct {
    seed: u64 = random.default_seed,
    fur_strands: usize = 1800,
};

// @brief 在球面生成两段弯曲细毛，每段为精确胶囊几何，拥有真实轮廓、投影和遮挡。
// @param radius 球半径，count 毛束数量；mat 为各向同性粗糙表面 BSDF。
// @method 球面根部使用 $z=1-2\xi_1,\phi=2\pi\xi_2$，均匀面积密度为 $1/(4\pi R^2)$。
// @method 中点沿法向生长，末端加入切向弯曲；半径递减近似纤维渐细，两段胶囊可能重叠。
// @notice 这是显式毛束几何加普通 GGX，不是 Marschner/Chiang 毛发 BSDF；不模拟毛鳞片和内部纤维散射。
pub fn addFur(scene: *render.Scene, center: Point3, radius: f64, count: usize, mat: *material.Material) !void {
    const alloc = scene.alloc;
    for (0..count) |_| {
        const z = random.randomDoubleRange(-1, 1);
        const phi = 2 * math.pi * random.randomDouble();
        const r = @sqrt(@max(0, 1 - z * z));
        const normal = Point3.init(r * @cos(phi), z, r * @sin(phi));
        var frame: math.Onb = .{};
        frame.buildFromW(normal);
        const bend = frame.u().scale(random.randomDoubleRange(-0.45, 0.45))
            .add(frame.v().scale(random.randomDoubleRange(-0.45, 0.45)));
        const length = radius * random.randomDoubleRange(0.07, 0.17);
        const root = center.add(normal.scale(radius * 0.997));
        const middle = root.add(normal.scale(length * 0.55)).add(bend.scale(length * 0.15));
        const tip = root.add(normal.scale(length)).add(bend.scale(length));
        try scene.addObject(try object.newCapsule(alloc, root, middle, radius * 0.005, mat));
        try scene.addObject(try object.newCapsule(alloc, middle, tip, radius * 0.003, mat));
    }
}

// @brief 构建原随机球阵列并添加可识别的 PBR 展示球；所有资源由调用者 arena 统一释放。
// @param options fur_strands 仅控制大展示球毛束数；零表示关闭所有细毛几何，保留球体。
// @notice 水球只有空气/水界面光学、不做流体模拟；玉球是薄层漫透射近似，不是体积玉石。
pub fn loadRandomScene(alloc: std.mem.Allocator, options: Options) !*render.Scene {
    random.seed(options.seed);
    const scene = try alloc.create(render.Scene);
    scene.* = render.Scene.init(alloc, "random_scene_pbr");
    const checker = try texture.newCheckerColors(alloc, Color.init(0.2, 0.3, 0.1), Color.init(0.9, 0.9, 0.9));
    const ground = try material.newLambertian(alloc, checker);
    try scene.addObject(try object.newSphere(alloc, .{ .y = -1000 }, .{ .y = -1000 }, 0, 1, 1000, ground));

    const water = try material.newDielectric(alloc, 1.333);
    const jade = try material.newTranslucent(alloc, .{ .x = 0.42, .y = 0.86, .z = 0.57 }, 0.72);
    const fur = try material.newPbr(alloc, .{ .base_color = .{ .x = 0.48, .y = 0.19, .z = 0.065 }, .metallic = 0, .roughness = 0.72 });
    const hero_centers = [_]Point3{ .{ .y = 0.9, .z = -2.5 }, .{ .y = 0.9 }, .{ .y = 0.9, .z = 2.5 } };
    const hero_materials = [_]*material.Material{ water, jade, fur };
    var water_count: usize = 0;
    var jade_count: usize = 0;
    var fur_count: usize = 0;
    var a: i32 = -11;
    while (a < 11) : (a += 1) {
        var b: i32 = -11;
        while (b < 11) : (b += 1) {
            const choose = random.randomDouble();
            const center = Point3.init(@as(f64, @floatFromInt(a)) + 0.9 * random.randomDouble(), 0.2, @as(f64, @floatFromInt(b)) + 0.9 * random.randomDouble());
            var reserved = false;
            for (hero_centers) |hero| {
                const dx = center.x - hero.x;
                const dz = center.z - hero.z;
                if (dx * dx + dz * dz < 1.4) reserved = true;
            }
            if (reserved) continue;
            var mat: *material.Material = undefined;
            var end = center;
            var furry = false;
            if (choose < 0.025 and water_count < 3) {
                mat = water;
                water_count += 1;
            } else if (choose < 0.055 and jade_count < 3) {
                mat = jade;
                jade_count += 1;
            } else if (choose < 0.065 and fur_count < 1) {
                mat = fur;
                furry = true;
                fur_count += 1;
            } else if (choose < 0.7) {
                const albedo = random.randomVec().mul(random.randomVec());
                mat = try material.newPbr(alloc, .{ .base_color = albedo, .metallic = 0, .roughness = random.randomDoubleRange(0.2, 0.85) });
                // @notice 动画按秒定义在 [0,1]，物理快门只采样其中一小段，不人为拉长运动模糊。
                end = center.add(.{ .y = random.randomDoubleRange(0, 0.5) });
            } else if (choose < 0.9) {
                mat = try material.newPbr(alloc, .{ .base_color = random.randomVecRange(0.5, 1), .metallic = 1, .roughness = random.randomDoubleRange(0.08, 0.5) });
            } else {
                mat = try material.newDielectric(alloc, 1.5);
            }
            try scene.addObject(try object.newSphere(alloc, center, end, 0, 1, 0.2, mat));
            if (furry and options.fur_strands > 0) try addFur(scene, center, 0.2, @min(options.fur_strands, 128), fur);
        }
    }
    for (hero_centers, hero_materials) |center, mat| {
        try scene.addObject(try object.newSphere(alloc, center, center, 0, 1, 0.9, mat));
    }
    try addFur(scene, hero_centers[2], 0.9, options.fur_strands, fur);

    // @brief 向下发光的大面积灯产生可采样高光；同一对象同时加入世界和光源集合。
    const emission = try alloc.create(material.DiffuseLight);
    emission.* = .{ .emit = try texture.newSolid(alloc, .{ .x = 8, .y = 7.5, .z = 6.5 }) };
    const emitter = try alloc.create(material.Material);
    emitter.* = .{ .diffuse_light = emission };
    const rect = try object.newXzRect(alloc, -3, 3, -4, 4, 6, emitter);
    const flipped = try alloc.create(object.FlipFace);
    flipped.* = .{ .ptr = rect };
    const lamp = try alloc.create(object.Object);
    lamp.* = .{ .flip_face = flipped };
    try scene.addObject(lamp);
    scene.light = lamp;
    try scene.buildBvh();
    return scene;
}
