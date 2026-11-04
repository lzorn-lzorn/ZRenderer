const std = @import("std");
const math = @import("math.zig");
const random = @import("random.zig");

const Vec3 = math.Vec3;
const Point3 = math.Point3;
const Ray = math.Ray;

pub const Camera = struct {
    origin: Point3 = .{},
    lower_left_corner: Point3 = .{},
    horizontal: Vec3 = .{},
    vertical: Vec3 = .{},
    u: Vec3 = .{},
    v: Vec3 = .{},
    w: Vec3 = .{},
    lens_radius: f64 = 0,
    time0: f64 = 0,
    time1: f64 = 0,
    exposure_scale: f64 = 1,
    sensor_cos4_vignetting: bool = false,
    // @notice 正值标记物理相机；零值保留旧接口的未归一化方向与运算顺序。
    focus_distance: f64 = 0,

    // @brief 保留旧式视场角、世界单位光圈直径和任意时间区间的构造接口。
    // @param vfov 为垂直视场角（度），aperture 为光圈直径，focus_dist 为轴向对焦距离。
    // @method **旧式视口**：$H=2u\tan(\mathrm{vfov}/2),\ W=aH,\ r=\mathrm{aperture}/2$。
    // @return 不校验参数的旧式相机，曝光权重恒为一，方向保持原来的长度。
    pub fn init(
        lookfrom: Point3,
        lookat: Point3,
        vup: Vec3,
        vfov: f64,
        aspect_ratio: f64,
        aperture: f64,
        focus_dist: f64,
        time0: f64,
        time1: f64,
    ) Camera {
        const theta = math.degreesToRadians(vfov);
        const h = @tan(theta / 2.0);
        const viewport_height = 2.0 * h;
        const viewport_width = aspect_ratio * viewport_height;

        const w = lookfrom.sub(lookat).normalized();
        const u = vup.cross(w).normalized();
        const v = w.cross(u);

        return .{
            .origin = lookfrom,
            .horizontal = u.scale(focus_dist * viewport_width),
            .vertical = v.scale(focus_dist * viewport_height),
            .lower_left_corner = lookfrom
                .sub(u.scale(focus_dist * viewport_width * 0.5))
                .sub(v.scale(focus_dist * viewport_height * 0.5))
                .sub(w.scale(focus_dist)),
            .u = u,
            .v = v,
            .w = w,
            .lens_radius = aperture * 0.5,
            .time0 = time0,
            .time1 = time1,
        };
    }

    // @brief 使用线程局部随机数生成镜头与快门样本；胶片坐标仍由调用者提供。
    // @param s、t 为从左至右、从下至上的归一化胶片坐标。
    // @return 与 getRaySampled 相同语义的光线。
    pub fn getRay(self: Camera, s: f64, t: f64) Ray {
        const lens_x = random.randomDouble();
        const lens_y = random.randomDouble();
        const shutter = random.randomDouble();
        return self.getRaySampled(s, t, lens_x, lens_y, shutter);
    }

    // @brief 固定两个镜头维度与一个快门维度，同心圆盘映射不使用拒绝循环。
    // @param s、t、lens_x、lens_y、shutter 必须为有限的 $[0,1]$ 内样本；不做裁剪。
    // @method **对焦与快门**：$P=O-u\mathbf w+(s-1/2)\mathbf H+(t-1/2)\mathbf V$，
    // @method $A=r(d_x\mathbf u+d_y\mathbf v),\ R=(O+A,\widehat{P-O-A}),\ \tau=\tau_0+\xi(\tau_1-\tau_0)$。
    // @notice 物理路径使用相对坐标避免大世界坐标相减丢失精度；旧路径不归一化以保持兼容。
    // @return 光线时间均匀分布于快门区间；输入端点对应区间端点，曝光另由 sampleWeight 返回。
    pub fn getRaySampled(self: Camera, s: f64, t: f64, lens_x: f64, lens_y: f64, shutter: f64) Ray {
        const rd = concentricDisk(lens_x, lens_y).scale(self.lens_radius);
        const offset = self.u.scale(rd.x).add(self.v.scale(rd.y));
        if (self.focus_distance > 0) {
            const direction = self.horizontal.scale(s - 0.5)
                .add(self.vertical.scale(t - 0.5))
                .sub(self.w.scale(self.focus_distance))
                .sub(offset);
            const time = if (shutter == 0) self.time0 else if (shutter == 1) self.time1 else math.clamp(self.time0 + (self.time1 - self.time0) * shutter, self.time0, self.time1);
            return Ray.init(self.origin.add(offset), unitVector(direction), time);
        }
        return Ray.init(
            self.origin.add(offset),
            self.lower_left_corner
                .add(self.horizontal.scale(s))
                .add(self.vertical.scale(t))
                .sub(self.origin)
                .sub(offset),
            self.time0 + (self.time1 - self.time0) * shutter,
        );
    }

    // @brief 返回应乘在线性场景辐亮度上的曝光与可选传感器自然暗角权重。
    // @param s、t 为有限的 $[0,1]$ 内胶片坐标；与当前光线的胶片样本一致。
    // @method **传感器映射**：$x_s=(s-1/2)S_w,\ y_s=(t-1/2)S_h$，
    // @method $\cos\theta=[1+(x_s/v)^2+(y_s/v)^2]^{-1/2},\ W=E\cos^4\theta$。
    // @method 通过单位主光线与光轴点积计算同一余弦，避免直接平方极大斜率。
    // @notice 暗角关闭时 $W=E$；旧式相机不提供传感器几何，始终只返回曝光权重。
    // @return 相对摄影曝光权重，不是绝对标定的传感器响应，也不是镜头采样概率密度。
    pub fn sampleWeight(self: Camera, s: f64, t: f64) f64 {
        if (!self.sensor_cos4_vignetting or self.focus_distance == 0) return self.exposure_scale;
        const chief = unitVector(self.horizontal.scale(s - 0.5)
            .add(self.vertical.scale(t - 0.5))
            .sub(self.w.scale(self.focus_distance)));
        const cosine = math.clamp(@abs(chief.dot(self.w)), 0, 1);
        const cosine_squared = cosine * cosine;
        return self.exposure_scale * (cosine_squared * cosine_squared);
    }
};

// @brief 将单位方形样本确定性映射到面积均匀的单位圆盘。
// @param x、y 必须为有限的 $[0,1]$ 内样本。
// @return 位于镜头局部平面的圆盘坐标，中心样本精确返回零向量。
pub fn concentricDisk(x: f64, y: f64) Vec3 {
    const sx = 2 * x - 1;
    const sy = 2 * y - 1;
    if (sx == 0 and sy == 0) return .{};
    const use_x = @abs(sx) > @abs(sy);
    const radius = if (use_x) sx else sy;
    const theta = if (use_x) (math.pi / 4) * (sy / sx) else (math.pi / 2) - (math.pi / 4) * (sx / sy);
    return .{ .x = radius * @cos(theta), .y = radius * @sin(theta) };
}

// @brief 完整保留旧参数默认值；默认观察基退化，调用者仍须显式设置有效观察方向。
pub const CameraArgs = struct {
    lookfrom: Point3 = .{},
    lookat: Point3 = .{},
    vup: Vec3 = .{},
    vfov: f64 = 40.0,
    aspect_ratio: f64 = 16.0 / 9.0,
    aperture: f64 = 0.0,
    focus_dist: f64 = 10.0,
    time0: f64 = 0,
    time1: f64 = 0,

    // @brief 转发旧式构造，不新增验证、错误联合或物理单位转换。
    // @return 与 Camera.init 完全一致的相机。
    pub fn build(self: CameraArgs) Camera {
        return Camera.init(
            self.lookfrom,
            self.lookat,
            self.vup,
            self.vfov,
            self.aspect_ratio,
            self.aperture,
            self.focus_dist,
            self.time0,
            self.time1,
        );
    }
};

// @brief 物理相机的显式构建错误；区分原始输入、观察基、派生几何与曝光。
pub const BuildError = error{
    NonFiniteParameter,
    InvalidParameter,
    InvalidBasis,
    InvalidGeometry,
    InvalidExposure,
};

// @brief 理想薄透镜参数；场景一单位等于一米，传感器与焦距输入使用毫米。
// @notice 默认相机位于原点、朝向负 Z、正 Y 向上；默认对焦距离为十米。
pub const PhysicalCameraArgs = struct {
    lookfrom: Point3 = .{},
    lookat: Point3 = .{ .z = -1 },
    vup: Vec3 = .{ .y = 1 },
    sensor_width_mm: f64 = 36,
    sensor_height_mm: f64 = 20.25,
    focal_length_mm: f64 = 50,
    f_number: f64 = 8,
    focus_distance: f64 = 10,
    shutter_open: f64 = 0,
    shutter_close: f64 = 1.0 / 125.0,
    iso: f64 = 100,
    exposure_compensation: f64 = 0,
    sensor_cos4_vignetting: bool = false,

    // @brief 为图像尺寸选择提供传感器宽高比，不单独执行验证。
    // @method **宽高比**：$a=S_w/S_h$，薄透镜放大率对两个方向相同。
    // @return 成功 build 后保证为有限正数的宽高比。
    pub fn aspectRatio(self: PhysicalCameraArgs) f64 {
        return self.sensor_width_mm / self.sensor_height_mm;
    }

    // @brief 校验全部数值并构造有效的、方向归一化的理想薄透镜相机。
    // @param 焦距 $f=f_{mm}/1000$、物距 $u$、传感器尺寸 $S$ 均转换为米；要求 $u>f>0$。
    // @method **薄透镜**：$1/f=1/u+1/v\Rightarrow v=fu/(u-f)$；横向放大率绝对值为 $v/u$。
    // @method **传感器与焦平面**：$W=S_wu/v,\ H=S_hu/v,\ \mathrm{FOV}_x=2\arctan(S_w/(2v))$。
    // @method 虚拟正向胶片避免实体倒像：$P=O-u\mathbf w+(s-1/2)W\mathbf u+(t-1/2)H\mathbf v$。
    // @method **光圈数**：$N=f/D\Rightarrow r=D/2=f/(2N)$；均匀圆盘样本改变出射点而不改变对焦点。
    // @method **相对曝光**：$E=\frac{\Delta\tau/N^2}{(1/125)/8^2}\frac{ISO}{100}2^{EV}$。
    // @method 使用对数域求值：$\log_2E=\log_2\Delta\tau-\log_2(1/125)+2(\log_2 8-\log_2N)+\log_2ISO-\log_2 100+EV$。
    // @notice 时间单位为秒，允许负的时间原点，但快门持续时间必须为有限正数；不自动重映射场景动画。
    // @return 有限可表示的几何与严格正且有限的曝光；非法输入、退化基或数值溢出返回 BuildError。
    pub fn build(self: PhysicalCameraArgs) BuildError!Camera {
        for ([_]Vec3{ self.lookfrom, self.lookat, self.vup }) |vector| {
            if (!finiteVector(vector)) return error.NonFiniteParameter;
        }
        for ([_]f64{
            self.sensor_width_mm,
            self.sensor_height_mm,
            self.focal_length_mm,
            self.f_number,
            self.focus_distance,
            self.shutter_open,
            self.shutter_close,
            self.iso,
            self.exposure_compensation,
        }) |value| {
            if (!std.math.isFinite(value)) return error.NonFiniteParameter;
        }
        if (self.sensor_width_mm <= 0 or self.sensor_height_mm <= 0 or
            self.focal_length_mm <= 0 or self.f_number <= 0 or
            self.focus_distance <= 0 or self.iso <= 0 or self.shutter_close <= self.shutter_open)
            return error.InvalidParameter;

        const focal = self.focal_length_mm / 1000;
        const sensor_width = self.sensor_width_mm / 1000;
        const sensor_height = self.sensor_height_mm / 1000;
        if (self.focus_distance <= focal) return error.InvalidParameter;
        if (!positiveFinite(focal) or !positiveFinite(sensor_width) or
            !positiveFinite(sensor_height) or !positiveFinite(self.aspectRatio()))
            return error.InvalidGeometry;

        const backward = self.lookfrom.sub(self.lookat);
        if (!finiteVector(backward) or maxAbs(backward) == 0 or maxAbs(self.vup) == 0)
            return error.InvalidBasis;
        const w = unitVector(backward);
        const right = unitVector(self.vup).cross(w);
        // @notice 单位向量夹角的正弦不大于 $10^{-12}$ 时视为数值退化，避免不稳定滚转。
        if (right.lengthSquared() <= 1e-24) return error.InvalidBasis;
        const u = unitVector(right);
        const v = unitVector(w.cross(u));

        const image_distance = focal * (self.focus_distance / (self.focus_distance - focal));
        const width = (sensor_width / image_distance) * self.focus_distance;
        const height = (sensor_height / image_distance) * self.focus_distance;
        const radius = (focal / self.f_number) * 0.5;
        if (!positiveFinite(image_distance) or !positiveFinite(width) or
            !positiveFinite(height) or !positiveFinite(radius)) return error.InvalidGeometry;

        const duration = self.shutter_close - self.shutter_open;
        if (!positiveFinite(duration)) return error.InvalidExposure;
        const log_exposure = (@log2(duration) - @log2(@as(f64, 1.0 / 125.0))) +
            2 * (@log2(@as(f64, 8)) - @log2(self.f_number)) +
            (@log2(self.iso) - @log2(@as(f64, 100))) + self.exposure_compensation;
        const exposure = @exp2(log_exposure);
        if (!positiveFinite(exposure)) return error.InvalidExposure;

        const horizontal = u.scale(width);
        const vertical = v.scale(height);
        const axial = w.scale(self.focus_distance);
        const lower_left = self.lookfrom.sub(horizontal.scale(0.5)).sub(vertical.scale(0.5)).sub(axial);
        if (!finiteVector(lower_left)) return error.InvalidGeometry;
        // @notice 对整个胶片与光圈的每轴绝对值作保守上界检查，拒绝光线起点或方向加法溢出。
        for (0..3) |axis| {
            const lens_bound = radius * (@abs(u.at(axis)) + @abs(v.at(axis)));
            const film_bound = @abs(horizontal.at(axis)) * 0.5 + @abs(vertical.at(axis)) * 0.5;
            const direction_bound = film_bound + @abs(axial.at(axis)) + lens_bound;
            if (!std.math.isFinite(@abs(self.lookfrom.at(axis)) + lens_bound) or
                !std.math.isFinite(@abs(self.lookfrom.at(axis)) + film_bound + @abs(axial.at(axis))) or
                !std.math.isFinite(direction_bound)) return error.InvalidGeometry;
        }
        return .{
            .origin = self.lookfrom,
            .lower_left_corner = lower_left,
            .horizontal = horizontal,
            .vertical = vertical,
            .u = u,
            .v = v,
            .w = w,
            .lens_radius = radius,
            .time0 = self.shutter_open,
            .time1 = self.shutter_close,
            .exposure_scale = exposure,
            .sensor_cos4_vignetting = self.sensor_cos4_vignetting,
            .focus_distance = self.focus_distance,
        };
    }
};

// @brief 检查标量是否严格为正且有限，同时拒绝下溢到零的派生量。
fn positiveFinite(value: f64) bool {
    return std.math.isFinite(value) and value > 0;
}

// @brief 检查向量各分量的有限性，不先计算可能溢出的平方长度。
fn finiteVector(value: Vec3) bool {
    return std.math.isFinite(value.x) and std.math.isFinite(value.y) and std.math.isFinite(value.z);
}

// @brief 返回最大绝对分量，用于稳定归一化与零向量检测。
fn maxAbs(value: Vec3) f64 {
    return @max(@abs(value.x), @max(@abs(value.y), @abs(value.z)));
}

// @brief 先按最大分量缩放，避免平方长度溢出或整体下溢。
// @param value 必须为非零有限向量，调用者负责验证。
// @return 单位长度向量；逐分量除法避免极小缩放量的倒数溢出。
fn unitVector(value: Vec3) Vec3 {
    const scale = maxAbs(value);
    const scaled = Vec3.init(value.x / scale, value.y / scale, value.z / scale);
    return scaled.scale(1.0 / scaled.length());
}

// @brief 保留旧式参数标签，避免破坏现有调用方。
pub const Tag = enum {
    lookfrom,
    lookat,
    vup,
    vfov,
    aspect_ratio,
    aperture,
    focus_dist,
    time_range,
};
