const std = @import("std");
const math = @import("math.zig");
const material = @import("material.zig");
const texture = @import("texture.zig");
const object = @import("object.zig");
const render = @import("render.zig");
const mesh_mod = @import("mesh.zig");
const exr = @import("exr.zig");
const environment = @import("environment.zig");

const Allocator = std.mem.Allocator;
const Point3 = math.Point3;
const Vec3 = math.Vec3;
const Color = math.Color;
const Uv = mesh_mod.Uv;
const TriangleMesh = mesh_mod.TriangleMesh;
const Transform = math.Transform;

// @brief 导入器错误联合：分配不足、文件缺失、语法错误与不支持的格式。
pub const ImportError = Allocator.Error || error{
    FileNotFound,
    ParseError,
    UnsupportedFormat,
    LoadFailed,
    MissingMaterial,
    InvalidObjectRange,
    MissingBoundingBox,
    InvalidParameter,
    InvalidMesh,
    DecompressFailed,
};

// @brief PBRT 场景导入结果：场景、恒定环境背景与从文件中解析的相机参数。
pub const ImportResult = struct {
    scene: *render.Scene,
    background: Color = .{ .x = 0.3, .y = 0.4, .z = 0.6 },
    environment: ?*environment.EnvironmentMap = null,
    lookfrom: Point3 = .{},
    lookat: Point3 = .{ .z = -1 },
    vup: Vec3 = .{ .y = 1 },
    vfov: f64 = 40,
};

// ============================================================
// PLY
// ============================================================

const PlyFormat = enum { ascii, binary_little_endian, binary_big_endian };

// @brief PLY 顶点字段位置：二进制用字节偏移，ASCII 用字段序号。
const PlyField = struct { byte_offset: usize = 0, index: usize = 0 };

// @brief 解析出的 PLY 头部：顶点/面数量、字节序、顶点字段位置与面索引编码。
const PlyHeader = struct {
    vertex_count: usize = 0,
    face_count: usize = 0,
    format: PlyFormat = .binary_little_endian,
    x: ?PlyField = null,
    y: ?PlyField = null,
    z: ?PlyField = null,
    nx: ?PlyField = null,
    ny: ?PlyField = null,
    nz: ?PlyField = null,
    u: ?PlyField = null,
    v: ?PlyField = null,
    vertex_stride: usize = 0,
    vertex_field_count: usize = 0,
    count_size: usize = 1,
    index_size: usize = 4,
};

// @brief 读取 PLY 网格并包装为对象；mat 为借用材质。
// @return 新对象或 ImportError；顶点须含 x/y/z，面为三角形或可三角化的多边形。
pub fn importPly(alloc: Allocator, path: []const u8, mat: *material.Material) ImportError!*object.Object {
    const bytes = try readFile(alloc, path);
    return parsePlyBytes(alloc, bytes, mat);
}

// @brief 从内存中的 PLY 字节解析网格并包装为对象；供文件导入与测试复用。
pub fn parsePlyBytes(alloc: Allocator, bytes: []const u8, mat: *material.Material) ImportError!*object.Object {
    const header = try parsePlyHeader(bytes);
    if (header.x == null or header.y == null or header.z == null) return error.ParseError;

    const vertex_bytes = try headerPositions(bytes);
    const positions = try alloc.alloc(Point3, header.vertex_count);
    const normals: ?[]Vec3 = if (header.nx != null and header.ny != null and header.nz != null) try alloc.alloc(Vec3, header.vertex_count) else null;
    const uvs: ?[]Uv = if (header.u != null and header.v != null) try alloc.alloc(Uv, header.vertex_count) else null;

    const read_float: ?*const fn ([]const u8, usize) f64 = switch (header.format) {
        .binary_little_endian => readVertexFloatLe,
        .binary_big_endian => readVertexFloatBe,
        .ascii => null,
    };

    for (positions, 0..) |*p, index| {
        if (header.format == .ascii) {
            p.* = Point3.init(
                try asciiFloat(try asciiField(bytes, vertex_bytes, index, header.vertex_field_count, header.x.?.index)),
                try asciiFloat(try asciiField(bytes, vertex_bytes, index, header.vertex_field_count, header.y.?.index)),
                try asciiFloat(try asciiField(bytes, vertex_bytes, index, header.vertex_field_count, header.z.?.index)),
            );
            if (normals) |n| n[index] = Vec3.init(
                try asciiFloat(try asciiField(bytes, vertex_bytes, index, header.vertex_field_count, header.nx.?.index)),
                try asciiFloat(try asciiField(bytes, vertex_bytes, index, header.vertex_field_count, header.ny.?.index)),
                try asciiFloat(try asciiField(bytes, vertex_bytes, index, header.vertex_field_count, header.nz.?.index)),
            );
            if (uvs) |uv| uv[index] = Uv{
                .u = try asciiFloat(try asciiField(bytes, vertex_bytes, index, header.vertex_field_count, header.u.?.index)),
                .v = try asciiFloat(try asciiField(bytes, vertex_bytes, index, header.vertex_field_count, header.v.?.index)),
            };
            continue;
        }
        const base = vertex_bytes + index * header.vertex_stride;
        p.* = Point3.init(
            read_float.?(bytes, base + header.x.?.byte_offset),
            read_float.?(bytes, base + header.y.?.byte_offset),
            read_float.?(bytes, base + header.z.?.byte_offset),
        );
        if (normals) |n| n[index] = Vec3.init(
            read_float.?(bytes, base + header.nx.?.byte_offset),
            read_float.?(bytes, base + header.ny.?.byte_offset),
            read_float.?(bytes, base + header.nz.?.byte_offset),
        );
        if (uvs) |uv| uv[index] = Uv{
            .u = read_float.?(bytes, base + header.u.?.byte_offset),
            .v = read_float.?(bytes, base + header.v.?.byte_offset),
        };
    }

    const indices = try parsePlyFaces(alloc, bytes, header);
    const mesh = try mesh_mod.buildTriangleMesh(alloc, positions, normals, uvs, indices, mat);
    return object.buildMesh(alloc, mesh);
}

// @brief 定位数据区起始字节，即 end_header 行换行之后。
fn headerPositions(bytes: []const u8) ImportError!usize {
    var i: usize = 0;
    while (i + 10 <= bytes.len) : (i += 1) {
        if (std.mem.eql(u8, bytes[i .. i + 10], "end_header")) {
            var j = i + 10;
            while (j < bytes.len and bytes[j] != '\n') : (j += 1) {}
            return if (j < bytes.len) j + 1 else bytes.len;
        }
    }
    return error.ParseError;
}

// @brief 逐行解析 ASCII 头部，收集顶点/面信息与字段偏移。
fn parsePlyHeader(bytes: []const u8) ImportError!PlyHeader {
    var header = PlyHeader{};
    if (!std.mem.startsWith(u8, bytes, "ply")) return error.UnsupportedFormat;

    var line_start: usize = 0;
    var vertex_offset: usize = 0;
    while (line_start < bytes.len) {
        const line_end = findLineEnd(bytes, line_start);
        const line = std.mem.trim(u8, bytes[line_start..line_end], " \t\r");
        if (std.mem.eql(u8, line, "end_header")) break;
        if (std.mem.startsWith(u8, line, "format ")) {
            if (std.mem.indexOf(u8, line, "ascii") != null) {
                header.format = .ascii;
            } else if (std.mem.indexOf(u8, line, "binary_little_endian") != null) {
                header.format = .binary_little_endian;
            } else if (std.mem.indexOf(u8, line, "binary_big_endian") != null) {
                header.format = .binary_big_endian;
            } else return error.UnsupportedFormat;
        } else if (std.mem.startsWith(u8, line, "element vertex ")) {
            header.vertex_count = try parseIntSuffix(line, "element vertex ");
        } else if (std.mem.startsWith(u8, line, "element face ")) {
            header.face_count = try parseIntSuffix(line, "element face ");
        } else if (std.mem.startsWith(u8, line, "property ")) {
            if (std.mem.startsWith(u8, line, "property list ")) {
                const rest = line["property list ".len..];
                var it = std.mem.tokenizeScalar(u8, rest, ' ');
                const count_name = it.next() orelse return error.ParseError;
                const index_name = it.next() orelse return error.ParseError;
                header.count_size = typeByteSize(count_name) orelse return error.UnsupportedFormat;
                header.index_size = typeByteSize(index_name) orelse return error.UnsupportedFormat;
            } else {
                const rest = line["property ".len..];
                var it = std.mem.tokenizeScalar(u8, rest, ' ');
                const type_name = it.next() orelse return error.ParseError;
                const prop_name = it.next() orelse return error.ParseError;
                const size = typeByteSize(type_name) orelse return error.UnsupportedFormat;
                const field = PlyField{ .byte_offset = vertex_offset, .index = header.vertex_field_count };
                if (std.mem.eql(u8, prop_name, "x")) header.x = field;
                if (std.mem.eql(u8, prop_name, "y")) header.y = field;
                if (std.mem.eql(u8, prop_name, "z")) header.z = field;
                if (std.mem.eql(u8, prop_name, "nx")) header.nx = field;
                if (std.mem.eql(u8, prop_name, "ny")) header.ny = field;
                if (std.mem.eql(u8, prop_name, "nz")) header.nz = field;
                if (std.mem.eql(u8, prop_name, "u") or std.mem.eql(u8, prop_name, "s") or std.mem.eql(u8, prop_name, "texture_u")) header.u = field;
                if (std.mem.eql(u8, prop_name, "v") or std.mem.eql(u8, prop_name, "t") or std.mem.eql(u8, prop_name, "texture_v")) header.v = field;
                vertex_offset += size;
                header.vertex_field_count += 1;
            }
        }
        line_start = line_end;
        if (line_end >= bytes.len) break;
        if (bytes[line_end] == '\n') line_start = line_end + 1 else line_start = line_end;
    }
    header.vertex_stride = vertex_offset;
    return header;
}

// @brief 解析面数据为三角形索引列表；四边形及以上按扇形三角化。
fn parsePlyFaces(alloc: Allocator, bytes: []const u8, header: PlyHeader) ImportError![]u32 {
    const face_bytes = try headerPositions(bytes);
    // 面数据紧接在顶点数据之后；ASCII 顶点按行存储，需跳过固定数量的行。
    const faces_start = if (header.format == .ascii)
        skipLines(bytes, face_bytes, header.vertex_count)
    else
        face_bytes + header.vertex_count * header.vertex_stride;
    var indices: std.ArrayList(u32) = .empty;

    var offset = faces_start;
    var face_index: usize = 0;
    while (face_index < header.face_count) : (face_index += 1) {
        if (header.format == .ascii) {
            // 跳过到下一行，按空白切分。
            const line_end = findLineEnd(bytes, offset);
            var it = std.mem.tokenizeAny(u8, bytes[offset..line_end], " \t\r");
            const count = try parseUint(it.next() orelse return error.ParseError);
            if (count >= 3) {
                const first = try parseUint(it.next() orelse return error.ParseError);
                var cur = try parseUint(it.next() orelse return error.ParseError);
                var k: usize = 2;
                while (k < count) : (k += 1) {
                    const next = try parseUint(it.next() orelse return error.ParseError);
                    try appendTriangle(alloc, &indices, first, cur, next);
                    cur = next;
                }
            }
            offset = line_end + 1;
            continue;
        }
        const count: usize = switch (header.count_size) {
            1 => bytes[offset],
            2 => std.mem.readInt(u16, bytes[offset..][0..2], endian(header.format)),
            4 => @intCast(std.mem.readInt(u32, bytes[offset..][0..4], endian(header.format))),
            else => return error.UnsupportedFormat,
        };
        offset += header.count_size;
        if (count >= 3) {
            const first = readFaceIndex(bytes, offset, header);
            offset += header.index_size;
            const second = readFaceIndex(bytes, offset, header);
            offset += header.index_size;
            var cur = second;
            var k: usize = 2;
            while (k < count) : (k += 1) {
                const next = readFaceIndex(bytes, offset, header);
                offset += header.index_size;
                try appendTriangle(alloc, &indices, first, cur, next);
                cur = next;
            }
        } else {
            offset += header.index_size * count;
        }
    }
    return indices.toOwnedSlice(alloc);
}

fn appendTriangle(alloc: Allocator, list: *std.ArrayList(u32), a: u32, b: u32, c: u32) Allocator.Error!void {
    try list.append(alloc, a);
    try list.append(alloc, b);
    try list.append(alloc, c);
}

fn readFaceIndex(bytes: []const u8, offset: usize, header: PlyHeader) u32 {
    return switch (header.index_size) {
        1 => bytes[offset],
        2 => @intCast(std.mem.readInt(u16, bytes[offset..][0..2], endian(header.format))),
        else => @intCast(std.mem.readInt(i32, bytes[offset..][0..4], endian(header.format))),
    };
}

fn endian(format: PlyFormat) std.builtin.Endian {
    return switch (format) {
        .binary_big_endian => .big,
        else => .little,
    };
}

fn readVertexFloatLe(bytes: []const u8, offset: usize) f64 {
    return @as(f64, @floatCast(readF32(bytes, offset, .little)));
}

fn readVertexFloatBe(bytes: []const u8, offset: usize) f64 {
    return @as(f64, @floatCast(readF32(bytes, offset, .big)));
}

fn readF32(bytes: []const u8, offset: usize, e: std.builtin.Endian) f32 {
    const bits = std.mem.readInt(u32, bytes[offset..][0..4], e);
    return @bitCast(bits);
}

// @brief 把 PLY 标量类型名映射为字节宽度；未知类型返回 null。
fn typeByteSize(name: []const u8) ?usize {
    const lower = name;
    if (std.mem.eql(u8, lower, "char") or std.mem.eql(u8, lower, "uchar") or
        std.mem.eql(u8, lower, "int8") or std.mem.eql(u8, lower, "uint8")) return 1;
    if (std.mem.eql(u8, lower, "short") or std.mem.eql(u8, lower, "ushort") or
        std.mem.eql(u8, lower, "int16") or std.mem.eql(u8, lower, "uint16")) return 2;
    if (std.mem.eql(u8, lower, "int") or std.mem.eql(u8, lower, "uint") or
        std.mem.eql(u8, lower, "int32") or std.mem.eql(u8, lower, "uint32") or
        std.mem.eql(u8, lower, "float") or std.mem.eql(u8, lower, "float32")) return 4;
    if (std.mem.eql(u8, lower, "double") or std.mem.eql(u8, lower, "float64") or
        std.mem.eql(u8, lower, "int64") or std.mem.eql(u8, lower, "uint64")) return 8;
    return null;
}

// @brief 在 ASCII 顶点数据中取出第 index 行记录的第 field 个字段。
fn asciiField(bytes: []const u8, start: usize, index: usize, field_count: usize, field: usize) ImportError![]const u8 {
    _ = field_count;
    var line_start = start;
    var i: usize = 0;
    while (i < index) : (i += 1) {
        const end = findLineEnd(bytes, line_start);
        if (end >= bytes.len) return error.ParseError;
        line_start = end + 1;
    }
    const line_end = findLineEnd(bytes, line_start);
    var it = std.mem.tokenizeAny(u8, bytes[line_start..line_end], " \t\r");
    var k: usize = 0;
    while (k < field) : (k += 1) _ = it.next() orelse return error.ParseError;
    return it.next() orelse error.ParseError;
}

fn asciiFloat(s: []const u8) ImportError!f64 {
    return std.fmt.parseFloat(f64, s) catch return error.ParseError;
}

fn parseUint(s: []const u8) ImportError!u32 {
    return std.fmt.parseInt(u32, s, 10) catch return error.ParseError;
}

fn parseIntSuffix(line: []const u8, prefix: []const u8) ImportError!usize {
    const rest = line[prefix.len..];
    const value = std.fmt.parseInt(usize, std.mem.trim(u8, rest, " \t\r"), 10) catch return error.ParseError;
    return value;
}

fn findLineEnd(bytes: []const u8, start: usize) usize {
    var i = start;
    while (i < bytes.len and bytes[i] != '\n') : (i += 1) {}
    return i;
}

// @brief 从 start 起跳过 count 个换行分隔的行，返回下一行起始位置。
fn skipLines(bytes: []const u8, start: usize, count: usize) usize {
    var pos = start;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const end = findLineEnd(bytes, pos);
        if (end >= bytes.len) return end;
        pos = end + 1;
    }
    return pos;
}

fn readFile(alloc: Allocator, path: []const u8) ImportError![]u8 {
    const path_z = try alloc.dupeSentinel(u8, path, 0);
    defer alloc.free(path_z);
    const file = std.c.fopen(path_z.ptr, "rb") orelse return error.FileNotFound;
    defer _ = std.c.fclose(file);
    var list: std.ArrayList(u8) = .empty;
    var buffer: [16384]u8 = undefined;
    while (true) {
        const count = std.c.fread(&buffer, 1, buffer.len, file);
        if (count > 0) try list.appendSlice(alloc, buffer[0..count]);
        if (count < buffer.len) break;
    }
    return list.toOwnedSlice(alloc);
}

// ============================================================
// OBJ
// ============================================================

const ObjKey = struct {
    vi: i64,
    vti: i64,
    vni: i64,
};

// @brief 读取 Wavefront OBJ 网格并包装为对象；mat 为借用材质。
// @return 新对象或 ImportError；面按扇形三角化，逐角点去重后共享顶点。
pub fn importObj(alloc: Allocator, path: []const u8, mat: *material.Material) ImportError!*object.Object {
    const bytes = try readFile(alloc, path);
    return parseObjBytes(alloc, bytes, mat);
}

// @brief 从内存中的 OBJ 文本解析网格并包装为对象；供文件导入与测试复用。
pub fn parseObjBytes(alloc: Allocator, bytes: []const u8, mat: *material.Material) ImportError!*object.Object {
    var positions: std.ArrayList(Point3) = .empty;
    var uvs: std.ArrayList(Uv) = .empty;
    var normals: std.ArrayList(Vec3) = .empty;
    var out_positions: std.ArrayList(Point3) = .empty;
    var out_uvs: std.ArrayList(Uv) = .empty;
    var out_normals: std.ArrayList(Vec3) = .empty;
    var indices: std.ArrayList(u32) = .empty;
    var dedup = std.AutoHashMap(ObjKey, u32).init(alloc);
    defer dedup.deinit();
    var has_uvs = false;
    var has_normals = false;

    var it = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var tok = std.mem.tokenizeAny(u8, line, " \t");
        const keyword = tok.next() orelse continue;
        if (std.mem.eql(u8, keyword, "v")) {
            try positions.append(alloc, Point3.init(
                try parseCoord(tok.next()),
                try parseCoord(tok.next()),
                try parseCoord(tok.next()),
            ));
        } else if (std.mem.eql(u8, keyword, "vt")) {
            try uvs.append(alloc, .{ .u = try parseCoord(tok.next()), .v = try parseCoord(tok.next()) });
            has_uvs = true;
        } else if (std.mem.eql(u8, keyword, "vn")) {
            try normals.append(alloc, Vec3.init(
                try parseCoord(tok.next()),
                try parseCoord(tok.next()),
                try parseCoord(tok.next()),
            ));
            has_normals = true;
        } else if (std.mem.eql(u8, keyword, "f")) {
            var corner_ids: [64]u32 = undefined;
            var count: usize = 0;
            while (tok.next()) |corner| {
                if (count >= corner_ids.len) return error.UnsupportedFormat;
                corner_ids[count] = try resolveObjCorner(alloc, corner, positions.items, uvs.items, normals.items, has_uvs, has_normals, &dedup, &out_positions, &out_uvs, &out_normals);
                count += 1;
            }
            if (count < 3) return error.ParseError;
            var k: usize = 1;
            while (k + 1 < count) : (k += 1) {
                try indices.append(alloc, corner_ids[0]);
                try indices.append(alloc, corner_ids[k]);
                try indices.append(alloc, corner_ids[k + 1]);
            }
        }
    }

    const mesh = try mesh_mod.buildTriangleMesh(
        alloc,
        try out_positions.toOwnedSlice(alloc),
        if (has_normals) try out_normals.toOwnedSlice(alloc) else null,
        if (has_uvs) try out_uvs.toOwnedSlice(alloc) else null,
        try indices.toOwnedSlice(alloc),
        mat,
    );
    return object.buildMesh(alloc, mesh);
}

fn parseCoord(token: ?[]const u8) ImportError!f64 {
    const s = token orelse return error.ParseError;
    return std.fmt.parseFloat(f64, s) catch return error.ParseError;
}

// @brief 解析一个面角点并去重；新顶点追加到输出数组并返回其下标。
// @notice 支持 v、v/vt、v//vn、v/vt/vn 及负索引；输出数组始终等长保持对齐。
fn resolveObjCorner(
    alloc: Allocator,
    corner: []const u8,
    positions: []const Point3,
    uvs: []const Uv,
    normals: []const Vec3,
    has_uvs: bool,
    has_normals: bool,
    dedup: *std.AutoHashMap(ObjKey, u32),
    out_positions: *std.ArrayList(Point3),
    out_uvs: *std.ArrayList(Uv),
    out_normals: *std.ArrayList(Vec3),
) ImportError!u32 {
    var vti: i64 = -1;
    var vni: i64 = -1;
    var parts_it = std.mem.splitScalar(u8, corner, '/');
    const vi = try parseObjIndex(parts_it.next(), positions.len);
    if (parts_it.next()) |vt_part| {
        if (vt_part.len > 0) vti = try parseObjIndex(vt_part, uvs.len);
    }
    if (parts_it.next()) |vn_part| {
        if (vn_part.len > 0) vni = try parseObjIndex(vn_part, normals.len);
    }

    const key = ObjKey{ .vi = vi, .vti = vti, .vni = vni };
    if (dedup.get(key)) |existing| return existing;

    const vertex_index: u32 = @intCast(out_positions.items.len);
    try out_positions.append(alloc, positions[@intCast(vi)]);
    if (has_uvs) try out_uvs.append(alloc, if (vti >= 0) uvs[@intCast(vti)] else Uv{});
    if (has_normals) try out_normals.append(alloc, if (vni >= 0) normals[@intCast(vni)] else Vec3{});
    try dedup.put(key, vertex_index);
    return vertex_index;
}

fn parseObjIndex(token: ?[]const u8, count: usize) ImportError!i64 {
    const s = token orelse return error.ParseError;
    const value = std.fmt.parseInt(i64, s, 10) catch return error.ParseError;
    if (value > 0) return value - 1;
    if (value < 0) return @as(i64, @intCast(count)) + value;
    return error.ParseError;
}

// ============================================================
// PBRT
// ============================================================

// @brief PBRT 词法单元；ident 引用源缓冲，number 已解析，string 已去除引号。
const Token = union(enum) {
    ident: []const u8,
    number: f64,
    string: []const u8,
};

// @brief 递归解析 PBRT v2 场景文件，支持 Include、实例化、网格与命名材质/纹理。
const PbrtParser = struct {
    alloc: Allocator,
    root: []const u8,
    result: ImportResult,
    materials: std.StringHashMap(*material.Material),
    textures: std.StringHashMap(*texture.Texture),
    objects: std.StringHashMap(*object.Object),
    ctm: [16]f64 = mat4Identity(),
    ctm_stack: std.ArrayList([16]f64),
    material: ?*material.Material = null,
    material_stack: std.ArrayList(?*material.Material),
    object_stack: std.ArrayList(ObjectDef),
    tokens: []Token = &.{},
    pos: usize = 0,

    const ObjectDef = struct { name: []const u8, group: *object.ObjectGroup };

    fn init(alloc: Allocator, root: []const u8, scene: *render.Scene) PbrtParser {
        return .{
            .alloc = alloc,
            .root = root,
            .result = .{ .scene = scene },
            .materials = std.StringHashMap(*material.Material).init(alloc),
            .textures = std.StringHashMap(*texture.Texture).init(alloc),
            .objects = std.StringHashMap(*object.Object).init(alloc),
            .ctm_stack = .empty,
            .material_stack = .empty,
            .object_stack = .empty,
        };
    }

    fn parseFile(self: *PbrtParser, path: []const u8) ImportError!void {
        const bytes = try readFile(self.alloc, path);
        self.tokens = try tokenize(self.alloc, bytes);
        self.pos = 0;
        try self.parseTokens();
    }

    fn parseTokens(self: *PbrtParser) ImportError!void {
        while (self.pos < self.tokens.len) {
            const directive = try self.expectIdent();
            try self.dispatch(directive);
        }
    }

    fn dispatch(self: *PbrtParser, directive: []const u8) ImportError!void {
        if (std.mem.eql(u8, directive, "Include")) {
            const filename = try self.expectString();
            const joined = try std.fs.path.join(self.alloc, &.{ self.root, filename });
            // @notice 递归解析会覆盖共享的 token 流与游标，返回后须恢复外层文件的解析位置。
            const saved_tokens = self.tokens;
            const saved_pos = self.pos;
            defer {
                self.tokens = saved_tokens;
                self.pos = saved_pos;
            }
            try self.parseFile(joined);
        } else if (std.mem.eql(u8, directive, "Transform")) {
            const m = try self.readMatrix();
            self.ctm = m;
        } else if (std.mem.eql(u8, directive, "ConcatTransform")) {
            const m = try self.readMatrix();
            self.ctm = mat4Mul(self.ctm, m);
        } else if (std.mem.eql(u8, directive, "Scale")) {
            const sx = try self.expectNumber();
            const sy = try self.expectNumber();
            const sz = try self.expectNumber();
            self.ctm = mat4Mul(self.ctm, mat4Scale(sx, sy, sz));
        } else if (std.mem.eql(u8, directive, "Translate")) {
            const dx = try self.expectNumber();
            const dy = try self.expectNumber();
            const dz = try self.expectNumber();
            self.ctm = mat4Mul(self.ctm, mat4Translate(dx, dy, dz));
        } else if (std.mem.eql(u8, directive, "Rotate")) {
            const deg = try self.expectNumber();
            const ax = try self.expectNumber();
            const ay = try self.expectNumber();
            const az = try self.expectNumber();
            self.ctm = mat4Mul(self.ctm, mat4Rotate(deg, ax, ay, az));
        } else if (std.mem.eql(u8, directive, "AttributeBegin")) {
            try self.ctm_stack.append(self.alloc, self.ctm);
            try self.material_stack.append(self.alloc, self.material);
        } else if (std.mem.eql(u8, directive, "AttributeEnd")) {
            self.ctm = self.ctm_stack.pop() orelse return error.ParseError;
            self.material = self.material_stack.pop() orelse return error.ParseError;
        } else if (std.mem.eql(u8, directive, "ObjectBegin")) {
            const name = try self.expectString();
            const group = try self.alloc.create(object.ObjectGroup);
            group.* = object.ObjectGroup.init(self.alloc);
            try self.object_stack.append(self.alloc, .{ .name = name, .group = group });
        } else if (std.mem.eql(u8, directive, "ObjectEnd")) {
            const def = self.object_stack.pop() orelse return error.ParseError;
            const wrapped = try self.alloc.create(object.Object);
            wrapped.* = .{ .group = def.group };
            try self.objects.put(def.name, wrapped);
        } else if (std.mem.eql(u8, directive, "ObjectInstance")) {
            const name = try self.expectString();
            const def = self.objects.get(name) orelse return error.ParseError;
            const transform = math.buildAffineTransform(self.ctm) orelse return error.ParseError;
            try self.result.scene.addObject(try object.buildInstance(self.alloc, def, transform));
        } else if (std.mem.eql(u8, directive, "NamedMaterial")) {
            const name = try self.expectString();
            self.material = self.materials.get(name) orelse return error.MissingMaterial;
        } else if (std.mem.eql(u8, directive, "MakeNamedMaterial")) {
            try self.parseMakeNamedMaterial();
        } else if (std.mem.eql(u8, directive, "Texture")) {
            try self.parseTexture();
        } else if (std.mem.eql(u8, directive, "Shape")) {
            try self.parseShape();
        } else if (std.mem.eql(u8, directive, "LightSource")) {
            try self.parseLightSource();
        } else if (std.mem.eql(u8, directive, "AreaLightSource")) {
            _ = try self.expectString(); // light type
            try self.skipParams();
        } else if (std.mem.eql(u8, directive, "LookAt")) {
            const ex = try self.expectNumber();
            const ey = try self.expectNumber();
            const ez = try self.expectNumber();
            const tx = try self.expectNumber();
            const ty = try self.expectNumber();
            const tz = try self.expectNumber();
            const ux = try self.expectNumber();
            const uy = try self.expectNumber();
            const uz = try self.expectNumber();
            self.result.lookfrom = Point3.init(ex, ey, ez);
            self.result.lookat = Point3.init(tx, ty, tz);
            self.result.vup = Vec3.init(ux, uy, uz);
        } else if (std.mem.eql(u8, directive, "Camera")) {
            try self.parseCamera();
        } else if (std.mem.eql(u8, directive, "WorldBegin")) {
            // @notice WorldBegin 前的变换属于相机（如 Scale -1 1 1 修正 lookat），不作用于几何。
            self.ctm = mat4Identity();
        } else {
            // 其余指令（WorldBegin/End、Film、Sampler、Integrator、PixelFilter 等）：
            // 带类型的指令先消费首字符串参数，再跳过键值参数；无参数指令直接跳过。
            if (self.pos < self.tokens.len and self.tokens[self.pos] == .string) {
                _ = try self.expectString();
            }
            try self.skipParams();
        }
    }

    fn parseMakeNamedMaterial(self: *PbrtParser) ImportError!void {
        const name = try self.expectString();
        var type_name: []const u8 = "";
        var reflectance: ?*texture.Texture = null;
        var reflectance_color: ?Color = null;
        var transmittance: ?*texture.Texture = null;
        var roughness: f64 = 0.1;
        var eta: f64 = 1.5;

        while (self.pos < self.tokens.len and self.tokens[self.pos] == .string) {
            const header = try self.readParamHeader();
            const ptype = header.ptype;
            const pname = header.pname;
            if (std.mem.eql(u8, ptype, "string") and std.mem.eql(u8, pname, "type")) {
                type_name = try self.readStringValue();
            } else if (std.mem.eql(u8, ptype, "texture") and std.mem.eql(u8, pname, "reflectance")) {
                const tex_name = try self.readStringValue();
                reflectance = self.textures.get(tex_name) orelse return error.MissingMaterial;
            } else if (std.mem.eql(u8, ptype, "texture") and std.mem.eql(u8, pname, "transmittance")) {
                const tex_name = try self.readStringValue();
                transmittance = self.textures.get(tex_name) orelse return error.MissingMaterial;
            } else if (std.mem.eql(u8, ptype, "texture") and std.mem.eql(u8, pname, "roughness")) {
                const tex_name = try self.readStringValue();
                _ = self.textures.get(tex_name); // 纹理粗糙度暂不支持，使用标量默认。
            } else if (std.mem.eql(u8, ptype, "rgb") and std.mem.eql(u8, pname, "reflectance")) {
                reflectance_color = try self.readColor();
            } else if (std.mem.eql(u8, ptype, "float") and std.mem.eql(u8, pname, "roughness")) {
                roughness = try self.readScalar();
            } else if (std.mem.eql(u8, ptype, "float") and std.mem.eql(u8, pname, "eta")) {
                eta = try self.readScalar();
            } else {
                try self.skipValue();
            }
        }

        const mat: *material.Material = if (std.mem.eql(u8, type_name, "diffuse")) blk: {
            if (reflectance) |tex| break :blk try material.newLambertian(self.alloc, tex);
            break :blk try material.newLambertian(self.alloc, try texture.newSolid(self.alloc, reflectance_color orelse Color.init(0.5, 0.5, 0.5)));
        } else if (std.mem.eql(u8, type_name, "coateddiffuse")) blk: {
            const tex = reflectance orelse try texture.newSolid(self.alloc, reflectance_color orelse Color.init(0.5, 0.5, 0.5));
            break :blk try material.createCoated(self.alloc, tex, roughness, eta);
        } else if (std.mem.eql(u8, type_name, "dielectric")) blk: {
            break :blk try material.newDielectric(self.alloc, eta);
        } else if (std.mem.eql(u8, type_name, "diffusetransmission")) blk: {
            if (transmittance) |tex| break :blk try material.createDiffuseTransmission(self.alloc, tex);
            break :blk try material.newLambertian(self.alloc, try texture.newSolid(self.alloc, reflectance_color orelse Color.init(0.5, 0.5, 0.5)));
        } else blk: {
            // 未识别材质：退化为漫反射。
            if (reflectance) |tex| break :blk try material.newLambertian(self.alloc, tex);
            if (transmittance) |tex| break :blk try material.newLambertian(self.alloc, tex);
            break :blk try material.newLambertian(self.alloc, try texture.newSolid(self.alloc, reflectance_color orelse Color.init(0.5, 0.5, 0.5)));
        };
        try self.materials.put(name, mat);
    }

    fn parseTexture(self: *PbrtParser) ImportError!void {
        const name = try self.expectString();
        _ = try self.expectString(); // spectrum|float
        const kind = try self.expectString(); // imagemap|scale 等
        if (!std.mem.eql(u8, kind, "imagemap")) {
            try self.skipParams();
            return;
        }
        var filename: []const u8 = "";
        while (self.pos < self.tokens.len and self.tokens[self.pos] == .string) {
            const header = try self.readParamHeader();
            const ptype = header.ptype;
            const pname = header.pname;
            if (std.mem.eql(u8, ptype, "string") and std.mem.eql(u8, pname, "filename")) {
                filename = try self.readStringValue();
            } else {
                try self.skipValue();
            }
        }
        if (filename.len == 0) return;
        const joined = try std.fs.path.join(self.alloc, &.{ self.root, filename });
        const path = try self.alloc.dupeSentinel(u8, joined, 0);
        const image = try texture.loadImage(self.alloc, path.ptr, true, true);
        try self.textures.put(name, image);
        // 登记到场景，便于统一释放 stb 像素缓冲。
        try self.result.scene.addImage(image.image);
    }

    fn parseShape(self: *PbrtParser) ImportError!void {
        const shape_type = try self.expectString();
        const mat = self.material orelse return error.MissingMaterial;
        if (std.mem.eql(u8, shape_type, "plymesh")) {
            var filename: []const u8 = "";
            var alpha: ?*texture.Texture = null;
            while (self.pos < self.tokens.len and self.tokens[self.pos] == .string) {
                const header = try self.readParamHeader();
                const ptype = header.ptype;
                const pname = header.pname;
                if (std.mem.eql(u8, ptype, "string") and std.mem.eql(u8, pname, "filename")) {
                    filename = try self.readStringValue();
                } else if (std.mem.eql(u8, ptype, "texture") and std.mem.eql(u8, pname, "alpha")) {
                    const tex_name = try self.readStringValue();
                    alpha = self.textures.get(tex_name) orelse return error.MissingMaterial;
                } else {
                    try self.skipValue();
                }
            }
            if (filename.len == 0) return error.ParseError;
            const joined = try std.fs.path.join(self.alloc, &.{ self.root, filename });
            const obj = try importPly(self.alloc, joined, mat);
            obj.mesh.alpha = alpha;
            try self.placeObject(obj);
        } else if (std.mem.eql(u8, shape_type, "trianglemesh")) {
            const obj = try self.parseTriangleMesh(mat);
            try self.placeObject(obj);
        } else {
            try self.skipParams();
        }
    }

    // @brief 读取内联 trianglemesh（point P、integer indices、normal N、float uv）。
    fn parseTriangleMesh(self: *PbrtParser, mat: *material.Material) ImportError!*object.Object {
        var positions: std.ArrayList(Point3) = .empty;
        var normals: std.ArrayList(Vec3) = .empty;
        var uvs: std.ArrayList(Uv) = .empty;
        var indices: std.ArrayList(u32) = .empty;
        var alpha: ?*texture.Texture = null;

        while (self.pos < self.tokens.len and self.tokens[self.pos] == .string) {
            const header = try self.readParamHeader();
            const ptype = header.ptype;
            const pname = header.pname;
            if (std.mem.eql(u8, ptype, "texture") and std.mem.eql(u8, pname, "alpha")) {
                const tex_name = try self.readStringValue();
                alpha = self.textures.get(tex_name) orelse return error.MissingMaterial;
            } else if (std.mem.eql(u8, ptype, "point") and std.mem.eql(u8, pname, "P")) {
                const values = try self.readArray();
                var i: usize = 0;
                while (i + 2 < values.len) : (i += 3) {
                    try positions.append(self.alloc, Point3.init(numberValue(values[i]), numberValue(values[i + 1]), numberValue(values[i + 2])));
                }
            } else if (std.mem.eql(u8, ptype, "normal") and std.mem.eql(u8, pname, "N")) {
                const values = try self.readArray();
                var i: usize = 0;
                while (i + 2 < values.len) : (i += 3) {
                    try normals.append(self.alloc, Vec3.init(numberValue(values[i]), numberValue(values[i + 1]), numberValue(values[i + 2])));
                }
            } else if (std.mem.eql(u8, ptype, "float") and (std.mem.eql(u8, pname, "uv") or std.mem.eql(u8, pname, "st"))) {
                const values = try self.readArray();
                var i: usize = 0;
                while (i + 1 < values.len) : (i += 2) {
                    try uvs.append(self.alloc, .{ .u = numberValue(values[i]), .v = numberValue(values[i + 1]) });
                }
            } else if (std.mem.eql(u8, ptype, "integer") and std.mem.eql(u8, pname, "indices")) {
                const values = try self.readArray();
                for (values) |value| try indices.append(self.alloc, @intFromFloat(numberValue(value)));
            } else {
                try self.skipValue();
            }
        }

        const mesh = try mesh_mod.buildTriangleMesh(
            self.alloc,
            try positions.toOwnedSlice(self.alloc),
            if (normals.items.len == positions.items.len and positions.items.len > 0) try normals.toOwnedSlice(self.alloc) else null,
            if (uvs.items.len == positions.items.len and positions.items.len > 0) try uvs.toOwnedSlice(self.alloc) else null,
            try indices.toOwnedSlice(self.alloc),
            mat,
        );
        mesh.alpha = alpha;
        return object.buildMesh(self.alloc, mesh);
    }

    // @brief 按当前 CTM 摆放对象：恒等则直接加入目标，否则用实例包装。
    fn placeObject(self: *PbrtParser, obj: *object.Object) ImportError!void {
        const transform = math.buildAffineTransform(self.ctm) orelse return error.ParseError;
        const placed = if (isIdentity(self.ctm)) obj else try object.buildInstance(self.alloc, obj, transform);
        if (self.object_stack.items.len > 0) {
            try self.object_stack.items[self.object_stack.items.len - 1].group.add(placed);
        } else {
            try self.result.scene.addObject(placed);
        }
    }

    fn parseLightSource(self: *PbrtParser) ImportError!void {
        _ = try self.expectString(); // light type
        var scale: f64 = 1;
        var filename: []const u8 = "";
        while (self.pos < self.tokens.len and self.tokens[self.pos] == .string) {
            const header = try self.readParamHeader();
            const ptype = header.ptype;
            const pname = header.pname;
            if (std.mem.eql(u8, ptype, "float") and std.mem.eql(u8, pname, "scale")) {
                scale = try self.readScalar();
            } else if (std.mem.eql(u8, ptype, "string") and std.mem.eql(u8, pname, "filename")) {
                filename = try self.readStringValue();
            } else {
                try self.skipValue();
            }
        }
        self.result.background = Color.init(0.09, 0.10, 0.13).scale(scale);
        if (filename.len > 0) {
            const joined = try std.fs.path.join(self.alloc, &.{ self.root, filename });
            const image = try exr.loadExr(self.alloc, joined);
            // 当前 CTM 即 LightSource 的旋转（如 Rotate 160 0 0 1）。
            const rotation = math.buildAffineTransform(self.ctm) orelse math.Transform.identity();
            self.result.environment = try environment.EnvironmentMap.build(self.alloc, image.pixels, image.width, image.height, rotation, scale);
        }
    }

    fn parseCamera(self: *PbrtParser) ImportError!void {
        _ = try self.expectString(); // camera type
        while (self.pos < self.tokens.len and self.tokens[self.pos] == .string) {
            const header = try self.readParamHeader();
            const ptype = header.ptype;
            const pname = header.pname;
            if (std.mem.eql(u8, ptype, "float") and std.mem.eql(u8, pname, "fov")) {
                self.result.vfov = try self.readScalar();
            } else {
                try self.skipValue();
            }
        }
    }

    // @brief 跳过当前指令剩余参数，直到遇到非字符串 token（下一指令名）。
    fn skipParams(self: *PbrtParser) ImportError!void {
        while (self.pos < self.tokens.len and self.tokens[self.pos] == .string) {
            _ = try self.readParamHeader();
            try self.skipValue();
        }
    }

    // @brief 跳过单个参数值：数组、标量或字符串。
    fn skipValue(self: *PbrtParser) ImportError!void {
        if (self.pos >= self.tokens.len) return;
        const tok = self.tokens[self.pos];
        self.pos += 1;
        switch (tok) {
            .ident => |s| {
                if (std.mem.eql(u8, s, "[")) {
                    var depth: usize = 1;
                    while (self.pos < self.tokens.len and depth > 0) {
                        const inner = self.tokens[self.pos];
                        self.pos += 1;
                        if (inner == .ident and std.mem.eql(u8, inner.ident, "[")) depth += 1;
                        if (inner == .ident and std.mem.eql(u8, inner.ident, "]")) depth -= 1;
                    }
                }
            },
            else => {},
        }
    }

    // @brief 读取参数头：PBRT v2 中 `"type name"` 是单个含空格的字符串，拆分为类型与名称。
    fn readParamHeader(self: *PbrtParser) ImportError!struct { ptype: []const u8, pname: []const u8 } {
        const token = try self.expectString();
        var it = std.mem.tokenizeAny(u8, token, " \t");
        const ptype = it.next() orelse return error.ParseError;
        const pname = it.next() orelse return error.ParseError;
        return .{ .ptype = ptype, .pname = pname };
    }

    // @brief 读取一个字符串参数值，兼容 `[ "value" ]` 与裸字符串两种形式。
    fn readStringValue(self: *PbrtParser) ImportError![]const u8 {
        if (self.pos >= self.tokens.len) return error.ParseError;
        if (self.tokens[self.pos] == .ident and std.mem.eql(u8, self.tokens[self.pos].ident, "[")) {
            self.pos += 1;
            const value = try self.expectString();
            _ = try self.expectIdent(); // ']'
            return value;
        }
        return self.expectString();
    }

    // @brief 读取单个浮点参数值，兼容 `[ value ]` 与裸标量两种形式。
    fn readScalar(self: *PbrtParser) ImportError!f64 {
        if (self.pos >= self.tokens.len) return error.ParseError;
        if (self.tokens[self.pos] == .number) {
            const value = self.tokens[self.pos].number;
            self.pos += 1;
            return value;
        }
        if (self.tokens[self.pos] == .ident and std.mem.eql(u8, self.tokens[self.pos].ident, "[")) {
            self.pos += 1;
            const value = try self.expectNumber();
            _ = try self.expectIdent(); // ']'
            return value;
        }
        return error.ParseError;
    }

    // @brief 读取 RGB 颜色参数：`[ r g b ]` 三个浮点。
    fn readColor(self: *PbrtParser) ImportError!Color {
        if (self.pos < self.tokens.len and self.tokens[self.pos] == .ident and
            std.mem.eql(u8, self.tokens[self.pos].ident, "["))
        {
            self.pos += 1;
            const r = try self.expectNumber();
            const g = try self.expectNumber();
            const b = try self.expectNumber();
            _ = try self.expectIdent(); // ']'
            return Color.init(r, g, b);
        }
        const r = try self.readScalar();
        const g = try self.readScalar();
        const b = try self.readScalar();
        return Color.init(r, g, b);
    }

    // @brief 读取方括号数组内容，返回其中的 token 切片（不含括号）。
    fn readArray(self: *PbrtParser) ImportError![]const Token {
        self.pos += 1; // '['
        const start = self.pos;
        var depth: usize = 1;
        while (self.pos < self.tokens.len and depth > 0) {
            const tok = self.tokens[self.pos];
            self.pos += 1;
            switch (tok) {
                .ident => |s| {
                    if (std.mem.eql(u8, s, "[")) depth += 1;
                    if (std.mem.eql(u8, s, "]")) depth -= 1;
                },
                else => {},
            }
        }
        return self.tokens[start .. self.pos - 1];
    }

    fn readMatrix(self: *PbrtParser) ImportError![16]f64 {
        _ = try self.expectIdent(); // '['
        var m: [16]f64 = undefined;
        var i: usize = 0;
        while (i < 16) : (i += 1) m[i] = try self.expectNumber();
        _ = try self.expectIdent(); // ']'
        return m;
    }

    fn expectIdent(self: *PbrtParser) ImportError![]const u8 {
        if (self.pos >= self.tokens.len) return error.ParseError;
        const tok = self.tokens[self.pos];
        self.pos += 1;
        return switch (tok) {
            .ident => |s| s,
            else => error.ParseError,
        };
    }

    fn expectNumber(self: *PbrtParser) ImportError!f64 {
        if (self.pos >= self.tokens.len) return error.ParseError;
        const tok = self.tokens[self.pos];
        self.pos += 1;
        return switch (tok) {
            .number => |n| n,
            else => error.ParseError,
        };
    }

    fn expectString(self: *PbrtParser) ImportError![]const u8 {
        if (self.pos >= self.tokens.len) return error.ParseError;
        const tok = self.tokens[self.pos];
        self.pos += 1;
        return switch (tok) {
            .string => |s| s,
            else => error.ParseError,
        };
    }
};

fn numberValue(tok: Token) f64 {
    return switch (tok) {
        .number => |n| n,
        else => 0,
    };
}

fn isIdentity(m: [16]f64) bool {
    const id = mat4Identity();
    for (m, id) |a, b| {
        if (a != b) return false;
    }
    return true;
}

fn mat4Identity() [16]f64 {
    return .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
}

// @brief 行主序 4x4 矩阵乘法：先应用 b 再应用 a，即 a * b。
fn mat4Mul(a: [16]f64, b: [16]f64) [16]f64 {
    var out: [16]f64 = undefined;
    var row: usize = 0;
    while (row < 4) : (row += 1) {
        var col: usize = 0;
        while (col < 4) : (col += 1) {
            out[row * 4 + col] = a[row * 4 + 0] * b[0 * 4 + col] +
                a[row * 4 + 1] * b[1 * 4 + col] +
                a[row * 4 + 2] * b[2 * 4 + col] +
                a[row * 4 + 3] * b[3 * 4 + col];
        }
    }
    return out;
}

fn mat4Scale(sx: f64, sy: f64, sz: f64) [16]f64 {
    return .{ sx, 0, 0, 0, 0, sy, 0, 0, 0, 0, sz, 0, 0, 0, 0, 1 };
}

fn mat4Translate(dx: f64, dy: f64, dz: f64) [16]f64 {
    return .{ 1, 0, 0, dx, 0, 1, 0, dy, 0, 0, 1, dz, 0, 0, 0, 1 };
}

fn mat4Rotate(deg: f64, ax: f64, ay: f64, az: f64) [16]f64 {
    const len = @sqrt(ax * ax + ay * ay + az * az);
    if (len == 0) return mat4Identity();
    const x = ax / len;
    const y = ay / len;
    const z = az / len;
    const c = @cos(math.degreesToRadians(deg));
    const s = @sin(math.degreesToRadians(deg));
    const t = 1.0 - c;
    return .{
        t * x * x + c,     t * x * y - s * z, t * x * z + s * y, 0,
        t * x * y + s * z, t * y * y + c,     t * y * z - s * x, 0,
        t * x * z - s * y, t * y * z + s * x, t * z * z + c,     0,
        0,                 0,                 0,                 1,
    };
}

// @brief 把源文件切分为 token 列表；字符串引用源缓冲，须在解析期间保持存活。
fn tokenize(alloc: Allocator, source: []const u8) ImportError![]Token {
    var tokens: std.ArrayList(Token) = .empty;
    var i: usize = 0;
    while (i < source.len) {
        const c = source[i];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            i += 1;
            continue;
        }
        if (c == '#') {
            while (i < source.len and source[i] != '\n') : (i += 1) {}
            continue;
        }
        if (c == '"') {
            i += 1;
            const start = i;
            while (i < source.len and source[i] != '"') : (i += 1) {}
            if (i >= source.len) return error.ParseError;
            try tokens.append(alloc, .{ .string = source[start..i] });
            i += 1;
            continue;
        }
        if (c == '[' or c == ']') {
            try tokens.append(alloc, .{ .ident = source[i .. i + 1] });
            i += 1;
            continue;
        }
        // 数字或标识符：扫描到空白、引号或括号。
        const start = i;
        while (i < source.len and source[i] != ' ' and source[i] != '\t' and source[i] != '\r' and
            source[i] != '\n' and source[i] != '"' and source[i] != '[' and source[i] != ']' and source[i] != '#')
        {
            i += 1;
        }
        const slice = source[start..i];
        if (std.fmt.parseFloat(f64, slice)) |number| {
            try tokens.append(alloc, .{ .number = number });
        } else |_| {
            try tokens.append(alloc, .{ .ident = slice });
        }
    }
    return tokens.toOwnedSlice(alloc);
}

// @brief 导入 PBRT v2 场景文件，返回场景、背景与相机参数。
// @param root 场景根目录；entry 为相对 root 的入口文件名。
pub fn importPbrtScene(alloc: Allocator, root: []const u8, entry: []const u8) ImportError!ImportResult {
    const scene = try alloc.create(render.Scene);
    scene.* = render.Scene.init(alloc, entry);
    var parser = PbrtParser.init(alloc, root, scene);
    const joined = try std.fs.path.join(alloc, &.{ root, entry });
    try parser.parseFile(joined);
    if (parser.result.scene.world.list.items.len == 0) return error.ParseError;
    try scene.buildBvh();
    return parser.result;
}

// @brief 导入 San Miguel 入口场景；root 为包含 sanmiguel-entry.pbrt 的目录。
// @return 场景、背景与相机参数；场景含约 250 万三角形与共享实例化。
pub fn importSanMiguel(alloc: Allocator, root: []const u8) ImportError!ImportResult {
    return importPbrtScene(alloc, root, "sanmiguel-entry.pbrt");
}
