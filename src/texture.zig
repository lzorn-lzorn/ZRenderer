const std = @import("std");
const math = @import("math.zig");
const noise_mod = @import("noise.zig");
const stb = @import("stb.zig");

const Color = math.Color;
const Point3 = math.Point3;
const Allocator = std.mem.Allocator;

// @brief 对常量、棋盘、噪声及图像纹理统一分派，借用各具体纹理指针。
pub const Texture = union(enum) {
    solid: *SolidColor,
    checker: *CheckerTexture,
    perlin: *PerlinNoiseTexture,
    image: *ImageTexture,

    // @brief 根据纹理坐标和空间位置求颜色。
    // @param u 横向纹理坐标；v 为纵向纹理坐标。
    // @param p 三维位置，供程序纹理求值。
    // @return 未作显示编码的颜色值；图像纹理仅将字节归一化，不作色彩空间解码。
    pub fn value(self: Texture, u: f64, v: f64, p: Point3) Color {
        return switch (self) {
            .solid => |t| t.value(u, v, p),
            .checker => |t| t.value(u, v, p),
            .perlin => |t| t.value(u, v, p),
            .image => |t| t.value(u, v, p),
        };
    }
};

// @brief 分配常量颜色纹理及其包装。
// @return 新纹理或分配错误；成功资源由调用者管理。
pub fn newSolid(alloc: Allocator, c: Color) Allocator.Error!*Texture {
    const s = try alloc.create(SolidColor);
    errdefer alloc.destroy(s);
    s.* = .{ .color_value = c };
    const t = try alloc.create(Texture);
    t.* = .{ .solid = s };
    return t;
}

// @brief 从文件加载图像纹理并包装为 Texture；像素缓冲由 stb 分配，须由场景统一 deinit。
// @param filename 以零结尾的输入路径；srgb 控制 gamma 2.2 线性化。
// @param wrap_repeat 为真时纹理坐标周期平铺。
// @return 新纹理或分配/加载失败；失败自动清理已分配包装。
pub fn loadImage(alloc: Allocator, filename: [*:0]const u8, srgb: bool, wrap_repeat: bool) !*Texture {
    const img = try alloc.create(ImageTexture);
    img.* = ImageTexture.load(filename, srgb, wrap_repeat);
    if (img.data == null) {
        alloc.destroy(img);
        return error.LoadFailed;
    }
    const t = alloc.create(Texture) catch |err| {
        img.deinit();
        alloc.destroy(img);
        return err;
    };
    t.* = .{ .image = img };
    return t;
}

// @brief 分配由两种常量颜色交替组成的棋盘纹理。
// @param c1 偶数区域颜色；c2 为奇数区域颜色。
// @return 包含两个子纹理的新包装或分配错误；失败时清理已分配资源。
pub fn newCheckerColors(alloc: Allocator, c1: Color, c2: Color) Allocator.Error!*Texture {
    const ch = try alloc.create(CheckerTexture);
    errdefer alloc.destroy(ch);
    const t = try alloc.create(Texture);
    errdefer alloc.destroy(t);
    const even = try newSolid(alloc, c1);
    errdefer {
        alloc.destroy(even.solid);
        alloc.destroy(even);
    }
    ch.* = .{ .even = even, .odd = try newSolid(alloc, c2) };
    t.* = .{ .checker = ch };
    return t;
}

// @brief 与位置无关的常量颜色纹理。
pub const SolidColor = struct {
    color_value: Color = .{},

    // @brief 返回保存的颜色，忽略所有坐标参数。
    pub fn value(self: SolidColor, u: f64, v: f64, p: Point3) Color {
        _ = u;
        _ = v;
        _ = p;
        return self.color_value;
    }
};

// @brief 依据空间正弦乘积符号选择两个借用子纹理的三维棋盘。
pub const CheckerTexture = struct {
    even: *Texture,
    odd: *Texture,

    // @brief 选择奇偶子纹理，并将原纹理坐标及位置传给该子纹理。
    pub fn value(self: CheckerTexture, u: f64, v: f64, p: Point3) Color {
        const sines = @sin(10.0 * p.x) * @sin(10.0 * p.y) * @sin(10.0 * p.z);
        if (sines < 0) return self.odd.value(u, v, p);
        return self.even.value(u, v, p);
    }
};

// @brief 以 Perlin 湍流扰动条纹相位的灰度大理石纹理。
pub const PerlinNoiseTexture = struct {
    noise: noise_mod.Perlin,
    scale: f64,

    // @brief 初始化随机梯度噪声及条纹空间频率 sc。
    pub fn init(sc: f64) PerlinNoiseTexture {
        return .{ .noise = noise_mod.Perlin.init(), .scale = sc };
    }

    // @brief 根据位置 p 返回七层湍流扰动的灰度条纹，忽略纹理坐标。
    pub fn value(self: PerlinNoiseTexture, u: f64, v: f64, p: Point3) Color {
        _ = u;
        _ = v;
        return Color.init(1, 1, 1).scale(0.5 * (1.0 + @sin(self.scale * p.z + 10.0 * self.noise.turb(p, 7))));
    }
};

// @brief 拥有 stb 解码像素缓冲的三通道图像纹理。
// @notice 浅拷贝不转移所有权，不能对共享同一缓冲的副本重复释放。
// @notice srgb 为真时按 gamma 2.2 线性化解码；wrap_repeat 为真时纹理坐标周期平铺。
pub const ImageTexture = struct {
    data: ?[*]u8 = null,
    width: i32 = 0,
    height: i32 = 0,
    bytes_per_scanline: i32 = 0,
    bytes_per_pixel: i32 = 3,
    srgb: bool = false,
    wrap_repeat: bool = false,

    // @brief 从以零结尾的文件路径加载紧密排列的 RGB 图像。
    // @return 成功时保存 stb 缓冲；失败时记录空数据并输出诊断。
    // @notice 兼容入口：不使用 sRGB 解码并钳位纹理坐标。
    pub fn init(filename: [*:0]const u8) ImageTexture {
        return load(filename, false, false);
    }

    // @brief 按显式解码与平铺策略加载图像。
    // @param filename 以零结尾的输入路径；srgb 控制 gamma 2.2 线性化。
    // @param wrap_repeat 为真时纹理坐标取小数平铺，否则钳位到 [0,1]。
    // @return 成功时保存 stb 缓冲；失败时记录空数据并输出诊断。
    pub fn load(filename: [*:0]const u8, srgb: bool, wrap_repeat: bool) ImageTexture {
        var self = ImageTexture{ .srgb = srgb, .wrap_repeat = wrap_repeat };
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

    // @brief 用 stb 配套释放函数销毁像素缓冲并重置状态。
    pub fn deinit(self: *ImageTexture) void {
        if (self.data) |data| stb.stbi_image_free(data);
        self.* = .{};
    }

    // @brief 翻转 v 后最近邻取样；位置 p 不参与求值。
    // @return 归一化字节颜色，可选 sRGB 线性化；数据缺失时返回青色。
    pub fn value(self: ImageTexture, u_in: f64, v_in: f64, p: Point3) Color {
        _ = p;
        if (self.data == null) return Color.init(0, 1, 1);

        const u = if (self.wrap_repeat) wrapFraction(u_in) else math.clamp(u_in, 0.0, 1.0);
        const v = 1.0 - (if (self.wrap_repeat) wrapFraction(v_in) else math.clamp(v_in, 0.0, 1.0));

        var i: i32 = @intFromFloat(u * @as(f64, @floatFromInt(self.width)));
        var j: i32 = @intFromFloat(v * @as(f64, @floatFromInt(self.height)));
        if (i >= self.width) i = self.width - 1;
        if (j >= self.height) j = self.height - 1;

        const offset: usize = @intCast(j * self.bytes_per_scanline + i * self.bytes_per_pixel);
        const pixel = self.data.? + offset;
        return Color.init(
            decodeByte(pixel[0], self.srgb),
            decodeByte(pixel[1], self.srgb),
            decodeByte(pixel[2], self.srgb),
        );
    }
};

// @brief 把任意纹理坐标映射到 [0,1) 的小数部分，实现周期平铺。
fn wrapFraction(v: f64) f64 {
    const f = v - @floor(v);
    return f;
}

// @brief 将字节分量归一化，并按需做 gamma 2.2 线性化解码。
// @notice 与 writeColor 的 gamma 2.2 输出编码互逆；不是严格 sRGB 传递函数。
fn decodeByte(byte: u8, srgb: bool) f64 {
    const c = @as(f64, @floatFromInt(byte)) / 255.0;
    return if (srgb) math.pow(c, 2.2) else c;
}
