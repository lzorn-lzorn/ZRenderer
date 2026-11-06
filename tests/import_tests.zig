const std = @import("std");
const math = @import("zrenderer").math;
const mesh = @import("zrenderer").mesh;
const object = @import("zrenderer").object;
const material = @import("zrenderer").material;
const import_mod = @import("zrenderer").import;
const testing = std.testing;

const Point3 = math.Point3;

fn appendF32(list: *std.ArrayList(u8), alloc: std.mem.Allocator, value: f32) !void {
    const bits: u32 = @bitCast(value);
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, bits, .little);
    try list.appendSlice(alloc, &buf);
}

fn appendI32(list: *std.ArrayList(u8), alloc: std.mem.Allocator, value: i32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &buf, value, .little);
    try list.appendSlice(alloc, &buf);
}

// @brief 构造一个单三角形的二进制小端 PLY。
fn binaryTrianglePly(alloc: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const header =
        "ply\n" ++
        "format binary_little_endian 1.0\n" ++
        "element vertex 3\n" ++
        "property float x\nproperty float y\nproperty float z\n" ++
        "property float nx\nproperty float ny\nproperty float nz\n" ++
        "property float u\nproperty float v\n" ++
        "element face 1\n" ++
        "property list uint8 int vertex_indices\n" ++
        "end_header\n";
    try out.appendSlice(alloc, header);
    const verts = [_][8]f32{
        .{ 0, 0, 0, 0, 0, 1, 0, 0 },
        .{ 1, 0, 0, 0, 0, 1, 1, 0 },
        .{ 0, 1, 0, 0, 0, 1, 0, 1 },
    };
    for (verts) |v| {
        for (v) |component| try appendF32(&out, alloc, component);
    }
    try out.append(alloc, 3);
    try appendI32(&out, alloc, 0);
    try appendI32(&out, alloc, 1);
    try appendI32(&out, alloc, 2);
    return out.toOwnedSlice(alloc);
}

fn matPtr(alloc: std.mem.Allocator) !*material.Material {
    const mat = try alloc.create(material.Material);
    const dielectric = try alloc.create(material.Dielectric);
    dielectric.* = .{ .ir = 1.5 };
    mat.* = .{ .dielectric = dielectric };
    return mat;
}

test "binary little-endian PLY parses into a hit-testable mesh" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const bytes = try binaryTrianglePly(alloc);
    const obj = try import_mod.parsePlyBytes(alloc, bytes, try matPtr(alloc));
    var rec: object.HitRecord = .{};
    try testing.expect(obj.hit(math.Ray.init(.{ .x = 0.2, .y = 0.2, .z = -1 }, .{ .z = 1 }, 0), 0, math.infinity, &rec));
    try testing.expectApproxEqAbs(@as(f64, 1), rec.t, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.2), rec.u, 1e-5);
}

test "ascii PLY parses positions, normals and uvs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source =
        "ply\n" ++
        "format ascii 1.0\n" ++
        "element vertex 3\n" ++
        "property float x\nproperty float y\nproperty float z\n" ++
        "property float nx\nproperty float ny\nproperty float nz\n" ++
        "property float u\nproperty float v\n" ++
        "element face 1\n" ++
        "property list uint8 int vertex_indices\n" ++
        "end_header\n" ++
        "0 0 0 0 0 1 0 0\n" ++
        "1 0 0 0 0 1 1 0\n" ++
        "0 1 0 0 0 1 0 1\n" ++
        "3 0 1 2\n";
    const obj = try import_mod.parsePlyBytes(alloc, source, try matPtr(alloc));
    var rec: object.HitRecord = .{};
    try testing.expect(obj.hit(math.Ray.init(.{ .x = 0.2, .y = 0.2, .z = 1 }, .{ .z = -1 }, 0), 0, math.infinity, &rec));
    try testing.expectApproxEqAbs(@as(f64, 1), rec.normal.z, 1e-6);
}

test "obj parses positions, uvs, normals and quad fans" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source =
        "v 0 0 0\n" ++
        "v 1 0 0\n" ++
        "v 1 1 0\n" ++
        "v 0 1 0\n" ++
        "vt 0 0\nvt 1 0\nvt 1 1\nvt 0 1\n" ++
        "vn 0 0 1\nvn 0 0 1\nvn 0 0 1\nvn 0 0 1\n" ++
        "f 1/1/1 2/2/2 3/3/3 4/4/4\n";
    const obj = try import_mod.parseObjBytes(alloc, source, try matPtr(alloc));
    const tri = obj.mesh;
    try testing.expectEqual(@as(usize, 2), tri.triangleCount());
    try testing.expectEqual(@as(usize, 4), tri.vertexCount());
    var rec: object.HitRecord = .{};
    try testing.expect(obj.hit(math.Ray.init(.{ .x = 0.5, .y = 0.5, .z = -1 }, .{ .z = 1 }, 0), 0, math.infinity, &rec));
    try testing.expectApproxEqAbs(@as(f64, 1), rec.t, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.5), rec.u, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.5), rec.v, 1e-12);
}

fn writeTempFile(alloc: std.mem.Allocator, sub_path: []const u8, name: []const u8, content: []const u8) !void {
    const path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/{s}", .{ sub_path, name });
    defer alloc.free(path);
    const path_z = try alloc.dupeSentinel(u8, path, 0);
    defer alloc.free(path_z);
    const file = std.c.fopen(path_z.ptr, "wb") orelse return error.WriteFailed;
    defer _ = std.c.fclose(file);
    _ = std.c.fwrite(content.ptr, 1, content.len, file);
}

test "pbrt scene imports an inline trianglemesh with a named material" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(root);
    try writeTempFile(testing.allocator, &tmp.sub_path, "scene.pbrt",
        "LookAt 0 0 5  0 0 0  0 1 0\n" ++
        "Camera \"perspective\" \"float fov\" [40]\n" ++
        "WorldBegin\n" ++
        "MakeNamedMaterial \"white\" \"string type\" [\"diffuse\"] \"rgb reflectance\" [0.8 0.8 0.8]\n" ++
        "AttributeBegin\n" ++
        "    NamedMaterial \"white\"\n" ++
        "    Shape \"trianglemesh\" \"point P\" [0 0 0  1 0 0  0 1 0] \"integer indices\" [0 1 2]\n" ++
        "AttributeEnd\n" ++
        "WorldEnd\n");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try import_mod.importPbrtScene(arena.allocator(), root, "scene.pbrt");
    defer result.scene.deinit();
    try testing.expectEqual(@as(usize, 1), result.scene.world.list.items.len);
    try testing.expectApproxEqAbs(@as(f64, 5), result.lookfrom.z, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 40), result.vfov, 1e-12);

    var rec: object.HitRecord = .{};
    try testing.expect(result.scene.bvh.hit(math.Ray.init(.{ .x = 0.2, .y = 0.2, .z = -1 }, .{ .z = 1 }, 0), 0, math.infinity, &rec));
}
