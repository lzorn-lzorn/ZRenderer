const math = @import("math.zig");
const random = @import("random.zig");

const Vec3 = math.Vec3;
const Point3 = math.Point3;

const point_count = 256;

// @brief 使用梯度表及三张置换表的三维 Perlin 梯度噪声。
pub const Perlin = struct {
    ranvec: [point_count]Vec3 = undefined,
    perm_x: [point_count]u8 = undefined,
    perm_y: [point_count]u8 = undefined,
    perm_z: [point_count]u8 = undefined,

    // @brief 消耗当前线程随机序列，建立梯度及置换表。
    pub fn init() Perlin {
        var self: Perlin = undefined;
        var i: usize = 0;
        while (i < point_count) : (i += 1) {
            self.ranvec[i] = random.randomVecRange(-1, 1).normalized();
        }
        self.perm_x = generatePerm();
        self.perm_y = generatePerm();
        self.perm_z = generatePerm();
        return self;
    }

    // @brief 在空间位置 p 对八个格点的梯度投影作平滑插值。
    // @notice 坐标取整后须可表示为 i32；格点索引按 256 循环。
    pub fn noise(self: Perlin, p: Point3) f64 {
        const u = p.x - @floor(p.x);
        const v = p.y - @floor(p.y);
        const w = p.z - @floor(p.z);
        const i: i32 = @intFromFloat(@floor(p.x));
        const j: i32 = @intFromFloat(@floor(p.y));
        const k: i32 = @intFromFloat(@floor(p.z));

        var c: [2][2][2]Vec3 = undefined;
        var di: i32 = 0;
        while (di < 2) : (di += 1) {
            var dj: i32 = 0;
            while (dj < 2) : (dj += 1) {
                var dk: i32 = 0;
                while (dk < 2) : (dk += 1) {
                    const px: usize = @intCast((i + di) & 255);
                    const py: usize = @intCast((j + dj) & 255);
                    const pz: usize = @intCast((k + dk) & 255);
                    const idx: usize = @intCast(self.perm_x[px] ^ self.perm_y[py] ^ self.perm_z[pz]);
                    c[@intCast(di)][@intCast(dj)][@intCast(dk)] = self.ranvec[idx];
                }
            }
        }
        return perlinInterp(c, u, v, w);
    }

    // @brief 叠加频率逐倍、权重逐半的噪声层，再取绝对值。
    // @param depth 叠加层数；非正值返回零。
    // @method **分层叠加**：$T(\mathbf{p})=|\sum_{i=0}^{depth-1}2^{-i}N(2^i\mathbf{p})|$。
    pub fn turb(self: Perlin, p: Point3, depth: i32) f64 {
        var accum: f64 = 0.0;
        var temp_p = p;
        var weight: f64 = 1.0;
        var i: i32 = 0;
        while (i < depth) : (i += 1) {
            accum += weight * self.noise(temp_p);
            weight *= 0.5;
            temp_p = temp_p.scale(2.0);
        }
        return @abs(accum);
    }
};

fn generatePerm() [point_count]u8 {
    var p: [point_count]u8 = undefined;
    var i: usize = 0;
    while (i < point_count) : (i += 1) {
        p[i] = @intCast(i);
    }
    permute(p[0..], point_count);
    return p;
}

fn permute(p: []u8, n: usize) void {
    var i: usize = n - 1;
    while (i > 0) : (i -= 1) {
        const target: usize = @intCast(random.randomInt(0, @intCast(i)));
        const tmp = p[i];
        p[i] = p[target];
        p[target] = tmp;
    }
}

// @brief 按平滑三线性权重混合八个格点梯度与位移的点积。
fn perlinInterp(c: [2][2][2]Vec3, u: f64, v: f64, w: f64) f64 {
    const uu = fade(u);
    const vv = fade(v);
    const ww = fade(w);

    var accum: f64 = 0.0;
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        const fi: f64 = @floatFromInt(i);
        var j: usize = 0;
        while (j < 2) : (j += 1) {
            const fj: f64 = @floatFromInt(j);
            var k: usize = 0;
            while (k < 2) : (k += 1) {
                const fk: f64 = @floatFromInt(k);
                const weight_v = Vec3.init(u - fi, v - fj, w - fk);
                accum += (fi * uu + (1 - fi) * (1 - uu)) *
                    (fj * vv + (1 - fj) * (1 - vv)) *
                    (fk * ww + (1 - fk) * (1 - ww)) *
                    c[i][j][k].dot(weight_v);
            }
        }
    }
    return accum;
}

// @method **平滑权重**：$f(x)=6x^5-15x^4+10x^3$，端点一阶与二阶导数均为零。
fn fade(x: f64) f64 {
    return x * x * x * (x * (x * 6 - 15) + 10);
}
