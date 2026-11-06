const std = @import("std");
const math = @import("math.zig");
const material = @import("material.zig");
const object = @import("object.zig");
const texture = @import("texture.zig");

const Point3 = math.Point3;
const Vec3 = math.Vec3;
const Aabb = math.Aabb;
const Ray = math.Ray;
const Allocator = std.mem.Allocator;
const HitRecord = object.HitRecord;

// @brief 二维纹理坐标；图像纹理按 u、v 取值。
pub const Uv = struct {
    u: f64 = 0,
    v: f64 = 0,
};

// @brief 网格内三角形 BVH 节点；叶子保存排序后三角形范围，内部保存左右子节点。
const TriBvhNode = struct {
    bbox: Aabb = .{},
    left: u32 = 0, // 内部：左子节点索引；叶子：起始三角形序号
    right: u32 = 0, // 内部：右子节点索引；叶子：三角形数量
    is_leaf: bool = false,
};

// @brief 叶子最多包含的三角形数，超过则继续分割。
const leaf_size: usize = 8;

// @brief 三角形网格：共享顶点、可选平滑法线与纹理坐标，索引每三个一组。
// @notice 所有数组均由调用方分配并由场景分配器统一管理；网格持有借用材质。
// @notice 命中不裁剪背面，两侧使用同一几何；缺失平滑法线时退化为面法线。
// @notice 大网格自带三角形 BVH，命中时不再线性扫描全部三角形。
pub const TriangleMesh = struct {
    positions: []Point3,
    normals: ?[]Vec3 = null,
    uvs: ?[]Uv = null,
    indices: []u32,
    material: *material.Material,
    alpha: ?*texture.Texture = null,
    bbox: Aabb = .{},
    triangle_order: []u32 = &.{}, // 排序后的三角形序号，叶子按范围引用
    bvh_nodes: []TriBvhNode = &.{},

    // @brief 返回顶点数。
    pub fn vertexCount(self: TriangleMesh) usize {
        return self.positions.len;
    }

    // @brief 返回三角形数，即索引数除以三。
    pub fn triangleCount(self: TriangleMesh) usize {
        return self.indices.len / 3;
    }

    // @brief 在参数闭区间内求最近命中（Möller–Trumbore）。
    // @param rec 成功时写入交点、插值法线与纹理坐标；法线面向入射侧。
    // @return 是否命中；退化三角形（零面积）不产生命中。
    pub fn hit(self: *const TriangleMesh, r: Ray, t_min: f64, t_max: f64, rec: *HitRecord) bool {
        if (self.bvh_nodes.len == 0) {
            var closest = t_max;
            var found = false;
            var tri: usize = 0;
            while (tri < self.triangleCount()) : (tri += 1) {
                if (self.hitTriangle(tri, r, t_min, closest, rec)) {
                    closest = rec.t;
                    found = true;
                }
            }
            return found;
        }
        return self.hitBvh(r, t_min, t_max, rec);
    }

    // @brief 用网格内 BVH 求交，近侧优先。
    fn hitBvh(self: *const TriangleMesh, r: Ray, t_min: f64, t_max: f64, rec: *HitRecord) bool {
        const query = math.AabbRay.init(r);
        var stack: [64]u32 = undefined;
        var stack_len: usize = 0;
        stack[stack_len] = 0;
        stack_len += 1;
        var closest = t_max;
        var found = false;
        while (stack_len > 0) {
            stack_len -= 1;
            const node_idx = stack[stack_len];
            const node = self.bvh_nodes[node_idx];
            if (node.bbox.intervalCached(query, t_min, closest) == null) continue;
            if (node.is_leaf) {
                var k: u32 = 0;
                while (k < node.right) : (k += 1) {
                    const tri: usize = self.triangle_order[node.left + k];
                    if (self.hitTriangle(tri, r, t_min, closest, rec)) {
                        closest = rec.t;
                        found = true;
                    }
                }
            } else {
                // 近侧后入栈（LIFO 先访问近侧）。
                const left_entry = self.bvh_nodes[node.left].bbox.intervalCached(query, t_min, closest);
                const right_entry = self.bvh_nodes[node.right].bbox.intervalCached(query, t_min, closest);
                const right_first = right_entry != null and (left_entry == null or right_entry.?.entry < left_entry.?.entry);
                const far = if (right_first) node.left else node.right;
                const near = if (right_first) node.right else node.left;
                stack[stack_len] = far;
                stack_len += 1;
                stack[stack_len] = near;
                stack_len += 1;
            }
        }
        return found;
    }

    // @brief 对单个三角形执行 Möller–Trumbore；命中时写入 rec 并返回真。
    fn hitTriangle(self: *const TriangleMesh, tri: usize, r: Ray, t_min: f64, t_max: f64, rec: *HitRecord) bool {
        const i = tri * 3;
        const idx0: usize = self.indices[i];
        const idx1: usize = self.indices[i + 1];
        const idx2: usize = self.indices[i + 2];
        const p0 = self.positions[idx0];
        const p1 = self.positions[idx1];
        const p2 = self.positions[idx2];
        const e1 = p1.sub(p0);
        const e2 = p2.sub(p0);
        const pvec = r.direction.cross(e2);
        const det = e1.dot(pvec);
        if (det == 0 or !std.math.isFinite(det)) return false;
        const inv_det = 1.0 / det;
        const tvec = r.origin.sub(p0);
        const u = tvec.dot(pvec) * inv_det;
        if (u < 0 or u > 1) return false;
        const qvec = tvec.cross(e1);
        const v = r.direction.dot(qvec) * inv_det;
        if (v < 0 or u + v > 1) return false;
        const t = e2.dot(qvec) * inv_det;
        if (t < t_min or t > t_max) return false;

        const w0 = 1.0 - u - v;
        const outward = self.normalAt(idx0, idx1, idx2, w0, u, v, e1, e2);
        rec.t = t;
        rec.p = r.at(t);
        if (self.uvs) |uvs| {
            const uv0 = uvs[idx0];
            const uv1 = uvs[idx1];
            const uv2 = uvs[idx2];
            rec.u = w0 * uv0.u + u * uv1.u + v * uv2.u;
            rec.v = w0 * uv0.v + u * uv1.v + v * uv2.v;
        } else {
            rec.u = 0;
            rec.v = 0;
        }
        rec.material = self.material;
        rec.alpha = self.alpha;
        rec.setFaceNormal(r, outward);
        return true;
    }

    // @brief 平滑法线插值或退化时使用面法线，作为面向入射侧之前的几何外向法线。
    fn normalAt(self: *const TriangleMesh, idx0: usize, idx1: usize, idx2: usize, w0: f64, w1: f64, w2: f64, e1: Vec3, e2: Vec3) Vec3 {
        if (self.normals) |normals| {
            const interpolated = normals[idx0].scale(w0).add(normals[idx1].scale(w1)).add(normals[idx2].scale(w2));
            const len = interpolated.length();
            if (len > 0) return interpolated.div(len);
        }
        const face = e1.cross(e2);
        const len = face.length();
        return if (len > 0) face.div(len) else Vec3.init(0, 1, 0);
    }

    // @brief 返回加载时预计算的精确包围盒，忽略时间参数。
    pub fn boundingBox(self: *const TriangleMesh, t0: f64, t1: f64, out: *Aabb) bool {
        _ = t0;
        _ = t1;
        out.* = self.bbox;
        return true;
    }
};

// @brief 构造网格参数校验与分配失败，或几何本身无效。
pub const BuildError = Allocator.Error || error{ InvalidMesh };

// @brief 校验输入并分配三角形网格，预计算包围盒；大网格同时构建三角形 BVH。
// @param positions 顶点位置；normals 可选平滑法线，须与 positions 等长。
// @param uvs 可选纹理坐标，须与 positions 等长；indices 每三个一组，引用顶点下标。
// @param mat 借用材质，不转移所有权。
// @return 新网格或 InvalidMesh/OutOfMemory；失败自动清理分配。
// @notice 顶点下标越界、索引数非三的倍数、零顶点或零三角形均视为无效网格。
pub fn buildTriangleMesh(
    alloc: Allocator,
    positions: []Point3,
    normals: ?[]Vec3,
    uvs: ?[]Uv,
    indices: []u32,
    mat: *material.Material,
) BuildError!*TriangleMesh {
    if (positions.len == 0 or indices.len == 0 or indices.len % 3 != 0) return error.InvalidMesh;
    if (normals) |n| {
        if (n.len != positions.len) return error.InvalidMesh;
    }
    if (uvs) |uv| {
        if (uv.len != positions.len) return error.InvalidMesh;
    }
    for (indices) |index| {
        if (index >= positions.len) return error.InvalidMesh;
    }

    var bbox = Aabb.init(positions[0], positions[0]);
    for (positions[1..]) |p| {
        bbox = math.surroundingBox(bbox, Aabb.init(p, p));
    }

    const mesh = try alloc.create(TriangleMesh);
    mesh.* = .{
        .positions = positions,
        .normals = normals,
        .uvs = uvs,
        .indices = indices,
        .material = mat,
        .bbox = bbox,
    };
    if (indices.len / 3 > leaf_size * 4) {
        const built = try buildTriangleBvh(alloc, positions, indices);
        mesh.triangle_order = built.order;
        mesh.bvh_nodes = built.nodes;
    }
    return mesh;
}

const TriBuildEntry = struct {
    triangle: u32,
    centroid: Point3,
    bbox: Aabb,
};

const TriBvhResult = struct { order: []u32, nodes: []TriBvhNode };

// @brief 按质心最长轴中位分割，构建网格内三角形 BVH。
fn buildTriangleBvh(alloc: Allocator, positions: []Point3, indices: []u32) Allocator.Error!TriBvhResult {
    const tri_count = indices.len / 3;
    const entries = try alloc.alloc(TriBuildEntry, tri_count);
    defer alloc.free(entries);
    for (0..tri_count) |t| {
        const i = t * 3;
        const p0 = positions[indices[i]];
        const p1 = positions[indices[i + 1]];
        const p2 = positions[indices[i + 2]];
        const min = Point3.init(@min(p0.x, @min(p1.x, p2.x)), @min(p0.y, @min(p1.y, p2.y)), @min(p0.z, @min(p1.z, p2.z)));
        const max = Point3.init(@max(p0.x, @max(p1.x, p2.x)), @max(p0.y, @max(p1.y, p2.y)), @max(p0.z, @max(p1.z, p2.z)));
        const box = Aabb.init(min, max);
        entries[t] = .{
            .triangle = @intCast(t),
            .centroid = min.scale(0.5).add(max.scale(0.5)),
            .bbox = box,
        };
    }
    var order: std.ArrayList(u32) = .empty;
    var nodes: std.ArrayList(TriBvhNode) = .empty;
    _ = try buildNodes(alloc, entries, &order, &nodes);
    return .{ .order = try order.toOwnedSlice(alloc), .nodes = try nodes.toOwnedSlice(alloc) };
}

fn buildNodes(
    alloc: Allocator,
    entries: []TriBuildEntry,
    order: *std.ArrayList(u32),
    nodes: *std.ArrayList(TriBvhNode),
) Allocator.Error!u32 {
    var bbox = entries[0].bbox;
    for (entries[1..]) |e| bbox = math.surroundingBox(bbox, e.bbox);

    if (entries.len <= leaf_size) {
        const idx: u32 = @intCast(nodes.items.len);
        try nodes.append(alloc, .{
            .bbox = bbox,
            .left = @intCast(order.items.len),
            .right = @intCast(entries.len),
            .is_leaf = true,
        });
        for (entries) |e| try order.append(alloc, e.triangle);
        return idx;
    }

    const extent = bbox.max.sub(bbox.min);
    var axis: usize = 0;
    if (extent.y > extent.x) axis = 1;
    if (extent.z > extent.at(axis)) axis = 2;
    sortTriEntries(entries, axis);
    const mid = entries.len / 2;

    const idx: u32 = @intCast(nodes.items.len);
    try nodes.append(alloc, .{ .bbox = bbox, .is_leaf = false });
    const left = try buildNodes(alloc, entries[0..mid], order, nodes);
    const right = try buildNodes(alloc, entries[mid..], order, nodes);
    nodes.items[idx].left = left;
    nodes.items[idx].right = right;
    return idx;
}

const TriSortCtx = struct { axis: usize };

fn sortTriEntries(entries: []TriBuildEntry, axis: usize) void {
    const Sorter = struct {
        fn lessThan(ctx: TriSortCtx, a: TriBuildEntry, b: TriBuildEntry) bool {
            return a.centroid.at(ctx.axis) < b.centroid.at(ctx.axis);
        }
    };
    std.sort.pdq(TriBuildEntry, entries, TriSortCtx{ .axis = axis }, Sorter.lessThan);
}
