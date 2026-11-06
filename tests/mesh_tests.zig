const std = @import("std");
const math = @import("zrenderer").math;
const mesh = @import("zrenderer").mesh;
const object = @import("zrenderer").object;
const material = @import("zrenderer").material;
const bsdf = @import("zrenderer").bsdf;
const testing = std.testing;

const Point3 = math.Point3;
const Vec3 = math.Vec3;

test "affine transform maps points, vectors and normals consistently" {
    const t = math.buildAffineTransform(.{ 2, 0, 0, 1, 0, 3, 0, 2, 0, 0, 4, 3, 0, 0, 0, 1 }).?;
    const p = t.applyPoint(Point3.init(1, 1, 1));
    try testing.expectApproxEqAbs(@as(f64, 3), p.x, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 5), p.y, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 7), p.z, 1e-12);
    const back = t.toObjectPoint(p);
    try testing.expectApproxEqAbs(@as(f64, 1), back.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1), back.y, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1), back.z, 1e-9);
    const normal = t.applyNormal(Vec3.init(1, 0, 0));
    try testing.expectApproxEqAbs(@as(f64, 1), normal.length(), 1e-12);
}

test "triangle mesh validates inputs before allocating" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var mat = material.Material{ .dielectric = undefined };
    const no_positions = try alloc.dupe(Point3, &[_]Point3{});
    const tri_indices = try alloc.dupe(u32, &[_]u32{ 0, 1, 2 });
    try testing.expectError(error.InvalidMesh, mesh.buildTriangleMesh(alloc, no_positions, null, null, tri_indices, &mat));
    const positions = try alloc.dupe(Point3, &[_]Point3{ Point3.init(0, 0, 0), Point3.init(1, 0, 0), Point3.init(0, 1, 0) });
    const short_indices = try alloc.dupe(u32, &[_]u32{ 0, 1 });
    try testing.expectError(error.InvalidMesh, mesh.buildTriangleMesh(alloc, positions, null, null, short_indices, &mat));
    const bad_indices = try alloc.dupe(u32, &[_]u32{ 0, 1, 9 });
    try testing.expectError(error.InvalidMesh, mesh.buildTriangleMesh(alloc, positions, null, null, bad_indices, &mat));
}

test "triangle mesh intersects a ray and interpolates uv" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var mat = material.Material{ .dielectric = try alloc.create(material.Dielectric) };
    mat.dielectric.* = .{ .ir = 1.5 };
    const positions = try alloc.dupe(Point3, &[_]Point3{ Point3.init(0, 0, 0), Point3.init(1, 0, 0), Point3.init(0, 1, 0) });
    const uvs = try alloc.dupe(mesh.Uv, &[_]mesh.Uv{ .{ .u = 0, .v = 0 }, .{ .u = 1, .v = 0 }, .{ .u = 0, .v = 1 } });
    const indices = try alloc.dupe(u32, &[_]u32{ 0, 1, 2 });
    const tri = try mesh.buildTriangleMesh(alloc, positions, null, uvs, indices, &mat);

    var rec: object.HitRecord = .{};
    // 三角形外向法线朝 +z；从 +z 侧入射为正面命中。
    const ray = math.Ray.init(Point3.init(0.25, 0.25, 1), Vec3.init(0, 0, -1), 0);
    try testing.expect(tri.hit(ray, 0, math.infinity, &rec));
    try testing.expectApproxEqAbs(@as(f64, 1), rec.t, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.25), rec.u, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.25), rec.v, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1), rec.normal.z, 1e-12);

    // 背面命中仍应成立，法线翻转到入射侧。
    var back_rec: object.HitRecord = .{};
    const back_ray = math.Ray.init(Point3.init(0.25, 0.25, -1), Vec3.init(0, 0, 1), 0);
    try testing.expect(tri.hit(back_ray, 0, math.infinity, &back_rec));
    try testing.expect(!back_rec.front_face);
    try testing.expectApproxEqAbs(@as(f64, -1), back_rec.normal.z, 1e-12);

    // 平行射线不命中。
    var miss: object.HitRecord = .{};
    try testing.expect(!tri.hit(math.Ray.init(Point3.init(0, 0, -1), Vec3.init(1, 0, 0), 0), 0, math.infinity, &miss));
}

test "triangle mesh interpolates smooth normals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var mat = material.Material{ .dielectric = try alloc.create(material.Dielectric) };
    mat.dielectric.* = .{ .ir = 1.5 };
    const positions = try alloc.dupe(Point3, &[_]Point3{ Point3.init(0, 0, 0), Point3.init(1, 0, 0), Point3.init(0, 1, 0) });
    const normals = try alloc.dupe(Vec3, &[_]Vec3{ Vec3.init(0, 0, 1), Vec3.init(0, 0, 1), Vec3.init(0, 0, 1) });
    const indices = try alloc.dupe(u32, &[_]u32{ 0, 1, 2 });
    const tri = try mesh.buildTriangleMesh(alloc, positions, normals, null, indices, &mat);
    var rec: object.HitRecord = .{};
    try testing.expect(tri.hit(math.Ray.init(Point3.init(0.2, 0.2, 1), Vec3.init(0, 0, -1), 0), 0, math.infinity, &rec));
    try testing.expectApproxEqAbs(@as(f64, 1), rec.normal.z, 1e-12);
}

test "surface opacity transmits straight through as a delta event" {
    // opacity=0 时表面完全透明，采样应直线穿过且不衰减。
    const surface = bsdf.Surface{ .diffuse = Vec3.init(1, 1, 1), .opacity = 0 };
    const wo = Vec3.init(0, 0, 1);
    const n = Vec3.init(0, 0, 1);
    const sample = surface.sample(wo, n).?;
    try testing.expect(sample.is_delta);
    try testing.expectApproxEqAbs(@as(f64, -1), sample.direction.z, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1), sample.weight.x, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1), sample.pdf, 1e-12);
}

test "instance object transforms hits and bounding boxes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var mat = material.Material{ .dielectric = try alloc.create(material.Dielectric) };
    mat.dielectric.* = .{ .ir = 1.5 };
    const positions = try alloc.dupe(Point3, &[_]Point3{ Point3.init(0, 0, 0), Point3.init(1, 0, 0), Point3.init(0, 1, 0) });
    const indices = try alloc.dupe(u32, &[_]u32{ 0, 1, 2 });
    const tri = try mesh.buildTriangleMesh(alloc, positions, null, null, indices, &mat);
    const inner = try object.buildMesh(alloc, tri);
    const translate = math.buildAffineTransform(.{ 1, 0, 0, 5, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }).?;
    const inst = try object.buildInstance(alloc, inner, translate);

    var rec: object.HitRecord = .{};
    try testing.expect(inst.hit(math.Ray.init(Point3.init(5.25, 0.25, -1), Vec3.init(0, 0, 1), 0), 0, math.infinity, &rec));
    try testing.expectApproxEqAbs(@as(f64, 5.25), rec.p.x, 1e-12);

    var box: math.Aabb = undefined;
    try testing.expect(inst.boundingBox(0, 1, &box));
    try testing.expectApproxEqAbs(@as(f64, 5), box.min.x, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 6), box.max.x, 1e-12);
}
