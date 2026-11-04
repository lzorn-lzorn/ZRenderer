const std = @import("std");
const math = @import("math.zig");
const random = @import("random.zig");
const texture = @import("texture.zig");
const pdf_mod = @import("pdf.zig");
const object = @import("object.zig");
const bsdf = @import("bsdf.zig");

const Color = math.Color;
const Vec3 = math.Vec3;
const Ray = math.Ray;
const Point3 = math.Point3;
const Onb = math.Onb;
const Texture = texture.Texture;
const Pdf = pdf_mod.Pdf;
const HitRecord = object.HitRecord;
const Allocator = std.mem.Allocator;

// @brief 旧积分器散射记录，保留原有字段和调用方式。
pub const ScatterRecord = struct {
    specular_ray: Ray = .{},
    is_specular: bool = false,
    attenuation: Color = .{},
    pdf: ?Pdf = null,
};

// @brief 材质的标记联合体，借用具体参数对象；新积分器通过 BSDF 接口分派。
pub const Material = union(enum) {
    lambertian: *Lambertian,
    metal: *Metal,
    dielectric: *Dielectric,
    isotropic: *Isotropic,
    diffuse_light: *DiffuseLight,
    pbr: *Pbr,
    translucent: *Translucent,

    // @brief 旧版四参数散射；新材质仅通过新 BSDF 接口散射。
    pub fn scatter(self: Material, r_in: Ray, rec: *const HitRecord, attenuation: *Color, scattered: *Ray) bool {
        return switch (self) {
            .lambertian => |m| m.scatter(r_in, rec, attenuation, scattered),
            .metal => |m| m.scatter(r_in, rec, attenuation, scattered),
            .dielectric => |m| m.scatter(r_in, rec, attenuation, scattered),
            .isotropic => |m| m.scatter(r_in, rec, attenuation, scattered),
            .diffuse_light => |m| m.scatter(r_in, rec, attenuation, scattered),
            .pbr, .translucent => false,
        };
    }

    // @brief 旧版带显式密度的散射，仅支持 Lambertian。
    pub fn scatterPdf(self: Material, r_in: Ray, rec: *const HitRecord, attenuation: *Color, scattered: *Ray, pdf: *f64) bool {
        return switch (self) {
            .lambertian => |m| m.scatterPdf(r_in, rec, attenuation, scattered, pdf),
            else => false,
        };
    }

    // @brief 旧版散射记录接口；新积分器应使用 bsdfSample 获取完整连续 BSDF。
    pub fn scatterSrec(self: Material, r_in: Ray, rec: *const HitRecord, srec: *ScatterRecord) bool {
        return switch (self) {
            .lambertian => |m| m.scatterSrec(r_in, rec, srec),
            .metal => |m| m.scatterSrec(r_in, rec, srec),
            .dielectric => |m| m.scatterSrec(r_in, rec, srec),
            else => false,
        };
    }

    // @brief 旧版 Lambertian 余弦密度；其他材质返回零，不代表新 BSDF 的混合密度。
    pub fn scatteringPdf(self: Material, r_in: Ray, rec: *const HitRecord, scattered: Ray) f64 {
        return switch (self) {
            .lambertian => |m| m.scatteringPdf(r_in, rec, scattered),
            else => 0.0,
        };
    }

    // @brief 是否含连续表面散射瓣；相函数与发光材质不在该接口内。
    pub fn hasNonDelta(self: Material) bool {
        return switch (self) {
            .lambertian, .pbr, .translucent => true,
            .metal => |m| m.fuzz > 0,
            else => false,
        };
    }

    // @brief 将材质映射为连续闭包；纹理反照率必须为有限的 [0,1] 颜色。
    fn surface(self: Material, rec: *const HitRecord) ?bsdf.Surface {
        return switch (self) {
            .lambertian => |m| blk: {
                const c = m.albedo.value(rec.u, rec.v, rec.p);
                if (!bsdf.validColor(c)) break :blk null;
                break :blk .{ .diffuse = c };
            },
            .metal => |m| if (bsdf.validColor(m.albedo) and bsdf.validUnit(m.fuzz) and m.fuzz > 0)
                .{ .specular = m.albedo, .roughness = m.fuzz }
            else
                null,
            .pbr => |m| blk: {
                if (!m.valid()) break :blk null;
                const r = (m.ior - 1) / (m.ior + 1);
                const f0 = Color.init(r * r, r * r, r * r).scale(1 - m.metallic).add(m.base_color.scale(m.metallic));
                break :blk .{ .diffuse = m.base_color.scale(1 - m.metallic), .specular = f0, .roughness = m.roughness };
            },
            .translucent => |m| if (bsdf.validColor(m.color) and bsdf.validUnit(m.transmission))
                .{ .diffuse = m.color, .transmission = m.transmission }
            else
                null,
            else => null,
        };
    }

    // @brief 返回世界空间方向 wi 的 BSDF 值，不含余弦。
    // @param r_in 入射射线，wo=-normalize(r_in.direction)；rec.normal 朝向 wo。
    // @return delta、发光、相函数或非法输入返回黑色。
    pub fn bsdfEval(self: Material, r_in: Ray, rec: *const HitRecord, wi: Vec3) Color {
        const closure = self.surface(rec) orelse return .{};
        return closure.eval(r_in.direction.neg(), rec.normal, wi);
    }

    // @brief 返回包含所有选瓣概率的立体角密度；delta 的连续密度为零。
    pub fn bsdfPdf(self: Material, r_in: Ray, rec: *const HitRecord, wi: Vec3) f64 {
        const closure = self.surface(rec) orelse return 0;
        return closure.pdf(r_in.direction.neg(), rec.normal, wi);
    }

    // @brief 采样归一化世界方向与已消去选瓣概率的路径权重。
    // @notice 粗糙 GGX 的 null 是合法零贡献事件，不可重采样；isotropic 显式不支持。
    pub fn bsdfSample(self: Material, r_in: Ray, rec: *const HitRecord) ?bsdf.Sample {
        switch (self) {
            .metal => |m| if (m.fuzz == 0) {
                if (!bsdf.validColor(m.albedo)) return null;
                const wo = bsdf.unit(r_in.direction.neg()) orelse return null;
                const n = bsdf.unit(rec.normal) orelse return null;
                if (wo.dot(n) <= 0) return null;
                return .{
                    .direction = bsdf.unit(math.reflect(wo.neg(), n)) orelse return null,
                    .weight = m.albedo,
                    .pdf = 1,
                    .is_delta = true,
                };
            },
            .dielectric => |m| return bsdf.sampleDielectric(r_in.direction.neg(), rec.normal, m.ir, rec.front_face),
            else => {},
        }
        const closure = self.surface(rec) orelse return null;
        return closure.sample(r_in.direction.neg(), rec.normal);
    }

    // @brief 旧版双面发光查询；非发光材质返回黑色。
    pub fn emitted3(self: Material, u: f64, v: f64, p: Point3) Color {
        return switch (self) {
            .diffuse_light => |m| m.emitted(u, v, p),
            else => Color.init(0, 0, 0),
        };
    }

    // @brief 仅查询发光表面正面的辐亮度；背面及非发光材质返回黑色。
    pub fn emitted5(self: Material, r_in: Ray, rec: *const HitRecord, u: f64, v: f64, p: Point3) Color {
        return switch (self) {
            .diffuse_light => |m| m.emittedV2(r_in, rec, u, v, p),
            else => Color.init(0, 0, 0),
        };
    }
};

// @brief 构造失败分为分配不足与物理参数非法；失败时回收该构造器的部分分配。
pub const CreateError = Allocator.Error || error{InvalidParameter};

// @brief 静态纹理在构造时校验；程序纹理还会在每次 BSDF 求值时校验。
fn validTexture(alb: *const Texture) bool {
    return switch (alb.*) {
        .solid => |s| bsdf.validColor(s.color_value),
        .checker => |c| validTexture(c.even) and validTexture(c.odd),
        .perlin => |p| std.math.isFinite(p.scale),
        else => true,
    };
}

// @brief 校验反照率纹理并分配 Lambertian 参数对象与材质包装。
// @notice 借用 alb，不转移纹理所有权；调用方分别释放参数对象与包装，或使用 arena。
pub fn newLambertian(alloc: Allocator, alb: *Texture) CreateError!*Material {
    if (!validTexture(alb)) return error.InvalidParameter;
    const m = try alloc.create(Lambertian);
    errdefer alloc.destroy(m);
    m.* = .{ .albedo = alb };
    const mat = try alloc.create(Material);
    mat.* = .{ .lambertian = m };
    return mat;
}

// @brief 分配金属材质；a 为线性 F0，f 为 [0,1] 感知粗糙度，零时保留常量 a 的理想镜面。
// @return 调用方拥有参数对象与包装；非法颜色/粗糙度或分配失败返回错误。
pub fn newMetal(alloc: Allocator, a: Color, f: f64) CreateError!*Material {
    if (!bsdf.validColor(a) or !bsdf.validUnit(f)) return error.InvalidParameter;
    const m = try alloc.create(Metal);
    errdefer alloc.destroy(m);
    m.* = .{ .albedo = a, .fuzz = f };
    const mat = try alloc.create(Material);
    mat.* = .{ .metal = m };
    return mat;
}

// @brief 分配相对空气折射率为 ir 的平滑介电体，支持 [1e-6,1e6]。
// @return 调用方拥有参数对象与包装；无嵌套介质栈，也不模拟吸收。
pub fn newDielectric(alloc: Allocator, ir: f64) CreateError!*Material {
    if (!bsdf.validIor(ir)) return error.InvalidParameter;
    const m = try alloc.create(Dielectric);
    errdefer alloc.destroy(m);
    m.* = .{ .ir = ir };
    const mat = try alloc.create(Material);
    mat.* = .{ .dielectric = m };
    return mat;
}

// @brief 分配旧版各向同性体相函数及其常量反照率纹理；不支持新表面 BSDF 接口。
// @notice 调用方负责包装、Isotropic、内部 Texture 与 SolidColor 共四个对象，或使用 arena。
pub fn newIsotropic(alloc: Allocator, c: Color) CreateError!*Material {
    if (!bsdf.validColor(c)) return error.InvalidParameter;
    const m = try alloc.create(Isotropic);
    errdefer alloc.destroy(m);
    const mat = try alloc.create(Material);
    errdefer alloc.destroy(mat);
    m.* = .{ .albedo = try texture.newSolid(alloc, c) };
    mat.* = .{ .isotropic = m };
    return mat;
}

// @brief 不透明金属度工作流；base_color 为线性反照率，roughness 为感知粗糙度。
// @notice 粗糙度零值采用 alpha=0.001 的连续 GGX；理想镜面请使用 newMetal(...,0)。
pub const Pbr = struct {
    base_color: Color,
    metallic: f64,
    roughness: f64,
    ior: f64 = 1.5,

    fn valid(self: Pbr) bool {
        return bsdf.validColor(self.base_color) and bsdf.validUnit(self.metallic) and bsdf.validUnit(self.roughness) and bsdf.validIor(self.ior);
    }
};

// @brief 校验并分配金属度工作流材质；使用保守互易漫反射预算，不宣称精确兼容 glTF。
// @return 调用方拥有 Pbr 参数对象与 Material 包装；部分分配失败自动回收。
pub fn newPbr(alloc: Allocator, params: Pbr) CreateError!*Material {
    if (!params.valid()) return error.InvalidParameter;
    const m = try alloc.create(Pbr);
    errdefer alloc.destroy(m);
    m.* = params;
    const mat = try alloc.create(Material);
    mat.* = .{ .pbr = m };
    return mat;
}

// @brief 玉石外观的薄层漫反射/漫透射混合，不是体散射或完整 BSSRDF。
pub const Translucent = struct {
    color: Color,
    transmission: f64,
};

// @brief 分配反照率为 color、透射比例为 transmission 的薄层余弦散射材质。
// @return 调用方拥有 Translucent 与 Material；颜色和透射比例必须有限且在 [0,1]。
pub fn newTranslucent(alloc: Allocator, color: Color, transmission: f64) CreateError!*Material {
    if (!bsdf.validColor(color) or !bsdf.validUnit(transmission)) return error.InvalidParameter;
    const m = try alloc.create(Translucent);
    errdefer alloc.destroy(m);
    m.* = .{ .color = color, .transmission = transmission };
    const mat = try alloc.create(Material);
    mat.* = .{ .translucent = m };
    return mat;
}

// @brief 借用反照率纹理的理想漫反射材质；旧方法要求有效交点及纹理。
pub const Lambertian = struct {
    albedo: *Texture,

    // @brief 旧版随机散射方向与反照率输出，保留射线时间。
    pub fn scatter(self: Lambertian, r_in: Ray, rec: *const HitRecord, attenuation: *Color, scattered: *Ray) bool {
        var scatter_direction = rec.normal.add(random.randomUnitSphere());
        if (scatter_direction.nearZero()) scatter_direction = rec.normal;
        scattered.* = Ray.init(rec.p, scatter_direction, r_in.time);
        attenuation.* = self.albedo.value(rec.u, rec.v, rec.p);
        return true;
    }

    // @brief 旧版余弦半球采样，同时输出归一化方向、反照率与立体角密度。
    pub fn scatterPdf(self: Lambertian, r_in: Ray, rec: *const HitRecord, attenuation: *Color, scattered: *Ray, pdf: *f64) bool {
        var uvw: Onb = .{};
        uvw.buildFromW(rec.normal);
        const direction = uvw.local(random.randomCosineDirection());
        scattered.* = Ray.init(rec.p, direction.normalized(), r_in.time);
        attenuation.* = self.albedo.value(rec.u, rec.v, rec.p);
        pdf.* = uvw.w().dot(scattered.direction) / math.pi;
        return true;
    }

    // @brief 填充旧连续散射记录，保存余弦 PDF 对象供旧积分器采样。
    pub fn scatterSrec(self: Lambertian, r_in: Ray, rec: *const HitRecord, srec: *ScatterRecord) bool {
        _ = r_in;
        srec.is_specular = false;
        srec.attenuation = self.albedo.value(rec.u, rec.v, rec.p);
        srec.pdf = Pdf{ .cosine = pdf_mod.CosinePdf.init(rec.normal) };
        return true;
    }

    // @brief 返回旧 Lambertian 的 max(0,n·wi)/pi，要求单位交点法线及非零散射方向。
    pub fn scatteringPdf(self: Lambertian, r_in: Ray, rec: *const HitRecord, scattered: Ray) f64 {
        _ = self;
        _ = r_in;
        const cosine = rec.normal.dot(scattered.direction.normalized());
        return if (cosine < 0) 0.0 else cosine / math.pi;
    }
};

// @brief 金属反射参数；新接口中 fuzz>0 为 GGX，fuzz=0 为离散镜面。
pub const Metal = struct {
    albedo: Color,
    fuzz: f64,

    // @brief 旧版不带 fuzz 扰动的理想反射，方向位于表面外侧时返回成功。
    // @notice 旧版入口保留历史镜面行为；粗糙金属的 GGX 仅由新 BSDF 接口提供。
    pub fn scatter(self: Metal, r_in: Ray, rec: *const HitRecord, attenuation: *Color, scattered: *Ray) bool {
        const reflected = math.reflect(r_in.direction.normalized(), rec.normal);
        scattered.* = Ray.init(rec.p, reflected, r_in.time);
        attenuation.* = self.albedo;
        return scattered.direction.dot(rec.normal) > 0;
    }

    // @brief 填充旧离散散射记录，将 fuzz 球内扰动叠加到镜面方向。
    // @notice 旧版随机扰动不是物理 GGX；为兼容旧调用而保留，不能用于新积分器。
    pub fn scatterSrec(self: Metal, r_in: Ray, rec: *const HitRecord, srec: *ScatterRecord) bool {
        const reflected = math.reflect(r_in.direction.normalized(), rec.normal);
        srec.specular_ray = Ray.init(rec.p, reflected.add(random.randomInUnitSphere().scale(self.fuzz)), r_in.time);
        srec.attenuation = self.albedo;
        srec.is_specular = true;
        srec.pdf = null;
        return true;
    }
};

// @brief 相对空气折射率 ir 的无吸收平滑介电体。
pub const Dielectric = struct {
    ir: f64,

    // @brief 以精确 Fresnel 选择反射/折射；旧 attenuation 也含辐亮度 eta² 因子。
    pub fn scatter(self: Dielectric, r_in: Ray, rec: *const HitRecord, attenuation: *Color, scattered: *Ray) bool {
        const sample = bsdf.sampleDielectric(r_in.direction.neg(), rec.normal, self.ir, rec.front_face) orelse return false;
        attenuation.* = sample.weight;
        scattered.* = Ray.init(rec.p, sample.direction, r_in.time);
        return true;
    }

    // @brief 将新介电 delta 样本适配到旧离散记录，不产生连续 PDF 对象。
    pub fn scatterSrec(self: Dielectric, r_in: Ray, rec: *const HitRecord, srec: *ScatterRecord) bool {
        const sample = bsdf.sampleDielectric(r_in.direction.neg(), rec.normal, self.ir, rec.front_face) orelse return false;
        srec.is_specular = true;
        srec.pdf = null;
        srec.attenuation = sample.weight;
        srec.specular_ray = Ray.init(rec.p, sample.direction, r_in.time);
        return true;
    }
};

// @brief 借用反照率纹理的旧版各向同性体散射参数，不是表面 BSDF。
pub const Isotropic = struct {
    albedo: *Texture,

    // @brief 旧体散射：在单位球内取方向并输出纹理反照率，保留射线时间。
    pub fn scatter(self: Isotropic, r_in: Ray, rec: *const HitRecord, attenuation: *Color, scattered: *Ray) bool {
        scattered.* = Ray.init(rec.p, random.randomInUnitSphere(), r_in.time);
        attenuation.* = self.albedo.value(rec.u, rec.v, rec.p);
        return true;
    }
};

// @brief 借用辐亮度纹理的漫发光表面，不含散射瓣。
pub const DiffuseLight = struct {
    emit: *Texture,

    // @brief 发光表面不散射，返回 false 且不修改输出。
    pub fn scatter(self: DiffuseLight, r_in: Ray, rec: *const HitRecord, attenuation: *Color, scattered: *Ray) bool {
        _ = self;
        _ = r_in;
        _ = rec;
        _ = attenuation;
        _ = scattered;
        return false;
    }

    // @brief 旧版不区分正反面的纹理辐亮度查询。
    pub fn emitted(self: DiffuseLight, u: f64, v: f64, p: Point3) Color {
        return self.emit.value(u, v, p);
    }

    // @brief 只在 front_face 为真时返回发光纹理，背面返回黑色。
    pub fn emittedV2(self: DiffuseLight, r_in: Ray, rec: *const HitRecord, u: f64, v: f64, p: Point3) Color {
        _ = r_in;
        return if (rec.front_face) self.emit.value(u, v, p) else Color.init(0, 0, 0);
    }
};
