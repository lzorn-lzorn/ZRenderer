const math = @import("math.zig");
const random = @import("random.zig");
const object = @import("object.zig");

const Vec3 = math.Vec3;
const Point3 = math.Point3;
const Onb = math.Onb;

// @brief 方向概率密度（PDF）的统一接口；密度相对于立体角 dω，而非面积或方向向量体积。
// @notice 生成方向不必归一化；求值与生成必须对应同一分布及同一测度。
pub const Pdf = union(enum) {
    cosine: CosinePdf,
    hittable: HittablePdf,
    mixture: MixturePdf,

    // @brief 求给定非零方向的立体角密度。
    // @return 每球面度的概率密度。
    pub fn value(self: Pdf, direction: Vec3) f64 {
        return switch (self) {
            .cosine => |p| p.value(direction),
            .hittable => |p| p.value(direction),
            .mixture => |p| p.value(direction),
        };
    }

    // @brief 从当前分布抽取方向。
    pub fn generate(self: Pdf) Vec3 {
        return switch (self) {
            .cosine => |p| p.generate(),
            .hittable => |p| p.generate(),
            .mixture => |p| p.generate(),
        };
    }
};

// @brief 以局部主轴为法线的余弦加权半球分布。
// @method **归一化**：$p(\omega)=\max(0,\cos\theta)/\pi$，且 $\int_0^{2\pi}\int_0^{\pi/2}p(\omega)\sin\theta\,d\theta\,d\phi=1$。
pub const CosinePdf = struct {
    uvw: Onb = .{},

    // @brief 从非零法线 w 构造分布坐标系。
    pub fn init(w: Vec3) CosinePdf {
        var self: CosinePdf = .{};
        self.uvw.buildFromW(w);
        return self;
    }

    // @brief 求非零方向的余弦密度；背向半球为零。
    pub fn value(self: CosinePdf, direction: Vec3) f64 {
        const cosine = direction.normalized().dot(self.uvw.w());
        return if (cosine <= 0) 0.0 else cosine / math.pi;
    }

    // @brief 将局部余弦样本变换为世界方向。
    pub fn generate(self: CosinePdf) Vec3 {
        return self.uvw.local(random.randomCosineDirection());
    }
};

// @brief 从固定原点朝支持采样的几何体生成方向。
// @notice 仅支持 Object 中实现 pdfValue/random 的分支；默认占位方向不构成有效分布。
pub const HittablePdf = struct {
    ptr: *object.Object,
    o: Point3,

    // @brief 委托几何体求相对于原点 o 的立体角密度。
    pub fn value(self: HittablePdf, direction: Vec3) f64 {
        return self.ptr.pdfValue(self.o, direction);
    }

    // @brief 生成从 o 朝几何体的方向，长度由几何实现决定。
    pub fn generate(self: HittablePdf) Vec3 {
        return self.ptr.random(self.o);
    }
};

// @brief 两个借用分布的等权混合；引用对象须在使用期间存活。
// @method **全概率公式**：以各 1/2 概率选择分支，边缘密度为 $p(\omega)=\tfrac12p_0(\omega)+\tfrac12p_1(\omega)$。
// @method 重要性权重应除以完整混合密度，而不是仅除以被抽中分支的密度。
pub const MixturePdf = struct {
    p0: *Pdf,
    p1: *Pdf,

    // @brief 返回两个分支的加权总密度。
    pub fn value(self: MixturePdf, direction: Vec3) f64 {
        return 0.5 * self.p0.value(direction) + 0.5 * self.p1.value(direction);
    }

    // @brief 等概率选择一个分支并抽取方向。
    pub fn generate(self: MixturePdf) Vec3 {
        return if (random.randomDouble() < 0.5) self.p0.generate() else self.p1.generate();
    }
};
