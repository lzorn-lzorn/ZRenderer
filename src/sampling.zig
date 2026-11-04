// @brief 相机域随机化准蒙特卡洛采样与自适应误差估计。
// @notice 用八组独立随机化数字位移形成副本，在副本之间估计误差；不能把相关的 Sobol 点当作独立同分布样本。
const std = @import("std");
const math = @import("math.zig");
const random = @import("random.zig");
const Color = math.Color;

// @brief 相机维度使用伪随机采样或数字位移 Sobol 低差异序列。
pub const Sampler = enum { random, sobol };
pub const replicas: u32 = 8;
pub const dimensions = 5; // @brief 成像平面 x/y、镜头 x/y 和快门时间，共五维。
// @brief 五维未位移 Sobol 坐标，以 32 位定点数表示。
pub const SobolPoint = [dimensions]u32;

// @brief 用整数混合派生确定性种子；不用于密码学。
pub fn hash(value: u64) u64 {
    var z = value +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

// @brief Sobol 第 2 至 5 维的本原多项式系数及初始奇数方向分子；第 1 维直接使用二的幂。
const Polynomial = struct { degree: usize, a: u32, m: [3]u32 };
const polynomials = [_]Polynomial{
    .{ .degree = 1, .a = 0, .m = .{ 1, 0, 0 } },
    .{ .degree = 2, .a = 1, .m = .{ 1, 3, 0 } },
    .{ .degree = 3, .a = 1, .m = .{ 1, 3, 1 } },
    .{ .degree = 3, .a = 2, .m = .{ 1, 1, 1 } },
};

const directions = makeDirections();

fn makeDirections() [dimensions][32]u32 {
    @setEvalBranchQuota(10000);
    var table: [dimensions][32]u32 = undefined;
    for (0..32) |i| table[0][i] = @as(u32, 1) << @as(u5, @intCast(31 - i));
    for (polynomials, 1..) |p, d| {
        for (0..p.degree) |i| table[d][i] = p.m[i] << @as(u5, @intCast(31 - i));
        for (p.degree..32) |i| {
            var v = table[d][i - p.degree] ^ (table[d][i - p.degree] >> @as(u5, @intCast(p.degree)));
            for (1..p.degree) |k| {
                if (((p.a >> @as(u5, @intCast(p.degree - 1 - k))) & 1) != 0) v ^= table[d][i - k];
            }
            table[d][i] = v;
        }
    }
    return table;
}

// @brief 返回按格雷码排序、未扰乱的 32 位 Sobol 坐标。
// @param index 序列中的零起始下标。
// @param dimension 零起始维度，必须小于 dimensions。
// @method **方向数展开**：$g=i\oplus(i\gg1)$，将 g 中置位位对应的方向数逐个异或：$x_{i,d}=\bigoplus_{k:g_k=1}v_{d,k}$。
pub fn sobolBits(index: u32, dimension: usize) u32 {
    std.debug.assert(dimension < dimensions);
    var gray = index ^ (index >> 1);
    var result: u32 = 0;
    while (gray != 0) {
        result ^= directions[dimension][@ctz(gray)];
        gray &= gray - 1;
    }
    return result;
}

// @brief 生成指定序号的完整五维基础点，可跨像素共享。
pub fn sobolPoint(index: u32) SobolPoint {
    var result: SobolPoint = undefined;
    for (&result, 0..) |*value, d| value.* = sobolBits(index, d);
    return result;
}

// @brief 保存单个像素的种子及八个副本的逐维数字位移。
// @method **数字位移**：$u_{i,r,d}=[(x_{i,d}\oplus\Delta_{r,d})+1/2]/2^{32}$；异或不是实数加法平移。
// @method 固定副本内共享位移，保留二进制分层结构；不同副本的位移由散列分别派生，按伪随机独立副本建模。
// @notice 中点偏移使坐标严格位于 (0,1)；这里不是逐位嵌套扰乱，也没有独立性的数学保证。
pub const PixelSampler = struct {
    mode: Sampler,
    pixel_seed: u64,
    shifts: [replicas][dimensions]u32,

    // @brief 按全局种子及像素编号派生副本位移，不消耗线程随机序列。
    // @param pixel_index 固定图像布局中的线性像素编号，不是任务或线程编号。
    pub fn init(seed: u64, pixel_index: u64, mode: Sampler) PixelSampler {
        var self: PixelSampler = .{ .mode = mode, .pixel_seed = hash(seed ^ hash(pixel_index)), .shifts = undefined };
        for (0..replicas) |r| {
            const replica_seed = hash(self.pixel_seed ^ hash(@intCast(r)));
            for (0..dimensions) |d| self.shifts[r][d] = @truncate(hash(replica_seed ^ hash(@intCast(d))));
        }
        return self;
    }

    // @brief 开始一个样本，同时重置线程局部的路径伪随机数生成器。
    // @param sample 像素内零起始样本编号；轮流分配到各副本。
    // @return 五个固定相机维度，顺序为成像平面、镜头和快门。
    // @notice 拒绝采样及路径长度变化不影响固定相机维度或其他像素。
    pub fn startSample(self: *const PixelSampler, sample: u32) [dimensions]f64 {
        return self.startSampleWithPoint(sample, if (self.mode == .sobol) sobolPoint(sample / replicas) else @splat(0));
    }

    // @brief 使用渲染器共享的预计算基础点，避免每个像素重复展开格雷码。
    // @param point Sobol 模式下必须对应 sample / replicas；随机模式忽略此参数。
    // @return 应用当前像素及副本位移后的五个相机坐标。
    // @method **调度确定性**：路径种子仅依赖全局种子、像素及样本编号；每条路径重新播种，因此线程编号和任务领取顺序不参与序列。
    // @notice 在同一构建和设置下可复现；不承诺跨编译器或浮点平台逐位一致。
    pub fn startSampleWithPoint(self: *const PixelSampler, sample: u32, point: SobolPoint) [dimensions]f64 {
        random.seed(hash(self.pixel_seed ^ (0xd1b54a32d192ed03 *% (@as(u64, sample) + 1))));
        var result: [dimensions]f64 = undefined;
        for (&result, 0..) |*value, d| {
            value.* = switch (self.mode) {
                .random => random.randomDouble(),
                .sobol => (@as(f64, @floatFromInt(point[d] ^ self.shifts[sample % replicas][d])) + 0.5) / 4294967296.0,
            };
        }
        return result;
    }
};

// @brief 每个工作线程复用的固定大小像素估计状态，不分配全图方差缓冲。
pub const Estimate = struct {
    sum: Color = .{},
    replica_sums: [replicas]Color = @splat(.{}),
    count: u32 = 0,
    stable_checks: u8 = 0,
    finite: bool = true,

    // @brief 累积线性 RGB 样本，按编号轮转写入副本，并记录非有限值。
    // @param value 与采样器当前编号对应的路径辐亮度。
    pub fn add(self: *Estimate, value: Color) void {
        self.finite = self.finite and std.math.isFinite(value.x) and std.math.isFinite(value.y) and std.math.isFinite(value.z);
        const r = self.count % replicas;
        self.replica_sums[r] = self.replica_sums[r].add(value);
        self.sum = self.sum.add(value);
        self.count += 1;
    }

    // @brief 只在均衡的二次幂副本块（总计 16、32、64 等样本）上检查停止条件。
    // @param min_samples 允许检查前的最少总样本数。
    // @param absolute 每个线性颜色通道的绝对误差阈值。
    // @param relative 每个线性颜色通道相对均值的误差阈值。
    // @return 三通道连续两次有效检查均通过时为 true；默认最早在 32 个样本时停止。
    // @method **副本标准误差**：每副本有 n 个样本，$\bar X_r=S_r/n$，$\bar X=\sum_r\bar X_r/R$，其中 $R=8$。
    // @method 副本均值样本方差除以 R 得总均值方差估计：$\mathrm{SE}=\sqrt{\sum_r(\bar X_r-\bar X)^2/[R(R-1)]}$。
    // @method 各通道须满足 $2.5\,\mathrm{SE}\le a+b|\bar X|$；不把副本内相关点当作独立样本。
    // @notice 2.5 倍标准误差只是偏保守的启发式阈值，不是反复检验下有保证的置信区间。
    // @notice 稀有高贡献路径可能尚未出现；副本数少、伪随机相关和可选停止均限制估计可靠性，停止规则可引入偏差。参考图应关闭自适应。
    pub fn converged(self: *Estimate, min_samples: u32, absolute: f64, relative: f64) bool {
        if (!self.finite or self.count < @max(min_samples, 2 * replicas) or self.count % replicas != 0) return false;
        const n = self.count / replicas;
        if ((n & (n - 1)) != 0) return false;
        const mean = self.sum.div(@floatFromInt(self.count));
        var m2: Color = .{};
        for (self.replica_sums) |sum| {
            const delta = sum.div(@floatFromInt(n)).sub(mean);
            m2 = m2.add(delta.mul(delta));
        }
        for (0..3) |channel| {
            const se = @sqrt(m2.at(channel) / @as(f64, replicas * (replicas - 1)));
            if (2.5 * se > absolute + relative * @abs(mean.at(channel))) {
                self.stable_checks = 0;
                return false;
            }
        }
        self.stable_checks +|= 1;
        return self.stable_checks >= 2;
    }
};
