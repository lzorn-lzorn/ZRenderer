const std = @import("std");
const math = @import("math.zig");

const Allocator = std.mem.Allocator;
const Color = math.Color;

// @brief 解码后的 EXR 图像：RGB 浮点像素，行主序、自上而下。
pub const ExrImage = struct {
    width: usize = 0,
    height: usize = 0,
    pixels: []Color = &.{},

    // @brief 释放像素缓冲；仅像素缓冲属于调用方分配器。
    pub fn deinit(self: *ExrImage, alloc: Allocator) void {
        alloc.free(self.pixels);
        self.* = .{};
    }
};

// @brief EXR 加载失败：分配不足、格式不支持、解析或解压失败。
pub const LoadError = Allocator.Error || error{
    UnsupportedFormat,
    ParseError,
    DecompressFailed,
};

const ChannelType = enum { uint, half, float };

const Channel = struct { name: []const u8, pixel_type: ChannelType, byte_size: usize };

// @brief 二进制游标，按小端读取 EXR 结构。
const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn readU8(self: *Cursor) LoadError!u8 {
        if (self.pos >= self.bytes.len) return error.ParseError;
        const v = self.bytes[self.pos];
        self.pos += 1;
        return v;
    }

    fn readI32(self: *Cursor) LoadError!i32 {
        if (self.pos + 4 > self.bytes.len) return error.ParseError;
        const v = std.mem.readInt(i32, self.bytes[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }

    fn readU64(self: *Cursor) LoadError!u64 {
        if (self.pos + 8 > self.bytes.len) return error.ParseError;
        const v = std.mem.readInt(u64, self.bytes[self.pos..][0..8], .little);
        self.pos += 8;
        return v;
    }

    // @brief 读取以零结尾的字符串，返回不含终止符的切片。
    fn cstr(self: *Cursor) LoadError![]const u8 {
        const start = self.pos;
        while (self.pos < self.bytes.len and self.bytes[self.pos] != 0) : (self.pos += 1) {}
        if (self.pos >= self.bytes.len) return error.ParseError;
        const result = self.bytes[start..self.pos];
        self.pos += 1; // 跳过终止符
        return result;
    }

    fn skip(self: *Cursor, count: usize) LoadError!void {
        if (self.pos + count > self.bytes.len) return error.ParseError;
        self.pos += count;
    }
};

// @brief 读取并解码 OpenEXR 扫描线图像（半精度或单精度，ZIP/未压缩）。
// @notice 仅支持 RGB/BGR 三通道、扫描线布局与 ZIP/NO_COMPRESSION 压缩。
pub fn loadExr(alloc: Allocator, path: []const u8) LoadError!ExrImage {
    const bytes = try readFile(alloc, path);
    return decodeExr(alloc, bytes);
}

fn decodeExr(alloc: Allocator, bytes: []const u8) LoadError!ExrImage {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..4], &[_]u8{ 0x76, 0x2f, 0x31, 0x01 })) return error.UnsupportedFormat;
    var cur = Cursor{ .bytes = bytes, .pos = 4 };
    _ = try cur.readI32(); // version

    var compression: u8 = 0;
    var width: usize = 0;
    var height: usize = 0;
    var channels: [4]Channel = undefined;
    var channel_count: usize = 0;

    // 解析属性表。
    while (true) {
        const name = try cur.cstr();
        if (name.len == 0) break;
        _ = try cur.cstr(); // type name
        const size = try cur.readI32();
        const value_start = cur.pos;
        if (std.mem.eql(u8, name, "compression")) {
            compression = try cur.readU8();
        } else if (std.mem.eql(u8, name, "dataWindow")) {
            const x_min = try cur.readI32();
            const y_min = try cur.readI32();
            const x_max = try cur.readI32();
            const y_max = try cur.readI32();
            if (x_min < 0 or y_min < 0) return error.UnsupportedFormat;
            width = @intCast(x_max - x_min + 1);
            height = @intCast(y_max - y_min + 1);
        } else if (std.mem.eql(u8, name, "channels")) {
            // chlist：通道名 + 像素类型 + 采样信息，以空名结束。
            while (true) {
                const cname = try cur.cstr();
                if (cname.len == 0) break;
                const pixel_type = try cur.readI32();
                _ = try cur.readU8(); // pLinear
                try cur.skip(3); // reserved
                _ = try cur.readI32(); // xSampling
                _ = try cur.readI32(); // ySampling
                if (channel_count >= channels.len) return error.UnsupportedFormat;
                channels[channel_count] = .{
                    .name = cname,
                    .pixel_type = switch (pixel_type) {
                        0 => .uint,
                        1 => .half,
                        2 => .float,
                        else => return error.UnsupportedFormat,
                    },
                    .byte_size = switch (pixel_type) {
                        1 => 2,
                        2 => 4,
                        else => 4,
                    },
                };
                channel_count += 1;
            }
        }
        // 其余属性值已由上面的游标读取；确保游标停在值末尾。
        cur.pos = value_start + @as(usize, @intCast(size));
    }

    if (width == 0 or height == 0 or channel_count < 3) return error.UnsupportedFormat;

    // 定位 R/G/B 通道。
    var r_index: ?usize = null;
    var g_index: ?usize = null;
    var b_index: ?usize = null;
    for (channels[0..channel_count], 0..) |c, i| {
        if (std.mem.eql(u8, c.name, "R")) r_index = i;
        if (std.mem.eql(u8, c.name, "G")) g_index = i;
        if (std.mem.eql(u8, c.name, "B")) b_index = i;
    }
    const r = r_index orelse 0;
    const g = g_index orelse 1;
    const b = b_index orelse 2;

    const pixels = try alloc.alloc(Color, width * height);
    errdefer alloc.free(pixels);
    @memset(pixels, Color.init(0, 0, 0));

    const scanline_count = height;
    if (compression == 0) {
        // 无压缩：直接顺序读取扫描线。
        for (0..scanline_count) |y| {
            for (0..width) |x| {
                var rgb: [3]f64 = .{ 0, 0, 0 };
                for (channels[0..channel_count], 0..) |c, ci| {
                    const value = switch (c.pixel_type) {
                        .half => @as(f64, halfToF32(try readU16(&cur))),
                        .float => @as(f64, readF32(&cur)),
                        .uint => @as(f64, @floatFromInt(try cur.readU8())),
                    };
                    if (ci == r) rgb[0] = value;
                    if (ci == g) rgb[1] = value;
                    if (ci == b) rgb[2] = value;
                }
                pixels[y * width + x] = Color.init(rgb[0], rgb[1], rgb[2]);
            }
        }
        return .{ .width = width, .height = height, .pixels = pixels };
    }

    if (compression != 3) return error.UnsupportedFormat;

    // ZIP 压缩：偏移表每个 16 扫描线块一个条目。
    const lines_per_block: usize = 16;
    const block_count = (height + lines_per_block - 1) / lines_per_block;
    const offsets = try alloc.alloc(u64, block_count);
    defer alloc.free(offsets);
    for (0..block_count) |i| offsets[i] = try cur.readU64();

    const channel_byte_size: usize = channels[0].byte_size;
    const bytes_per_line = width * channel_count * channel_byte_size;
    for (0..block_count) |block| {
        const line_begin = block * lines_per_block;
        const lines = @min(lines_per_block, height - line_begin);
        const expected = lines * bytes_per_line;
        const chunk_offset = offsets[block];
        const next_offset: u64 = if (block + 1 < block_count) offsets[block + 1] else bytes.len;
        if (chunk_offset + 8 > next_offset or next_offset > bytes.len) return error.ParseError;
        // 每个块前有 8 字节头：y 坐标(int32) + 压缩数据长度(int32)，之后才是 zlib 数据。
        const compressed = bytes[@intCast(chunk_offset + 8)..@intCast(next_offset)];
        const raw = try inflateZlib(alloc, compressed, expected);
        defer alloc.free(raw);
        try reconstructBlock(alloc, raw, width, lines, channel_count, channel_byte_size, r, g, b, pixels, line_begin);
    }
    return .{ .width = width, .height = height, .pixels = pixels };
}

fn readU16(cur: *Cursor) LoadError!u16 {
    if (cur.pos + 2 > cur.bytes.len) return error.ParseError;
    const v = std.mem.readInt(u16, cur.bytes[cur.pos..][0..2], .little);
    cur.pos += 2;
    return v;
}

fn readF32(cur: *Cursor) f32 {
    const bits = std.mem.readInt(u32, cur.bytes[cur.pos..][0..4], .little);
    cur.pos += 4;
    return @bitCast(bits);
}

// @brief 解压 ZIP 块：逐字节逆 delta、奇偶字节重组、按采样类型写入像素缓冲。
fn reconstructBlock(
    alloc: Allocator,
    raw: []const u8,
    width: usize,
    lines: usize,
    channel_count: usize,
    channel_byte_size: usize,
    r: usize,
    g: usize,
    b: usize,
    pixels: []Color,
    line_begin: usize,
) LoadError!void {
    const n = raw.len;
    // 逐字节逆预测：data[i] = (raw[i] + data[i-1] - 128) mod 256。
    const predicted = try alloc.alloc(u8, n);
    defer alloc.free(predicted);
    if (n > 0) {
        predicted[0] = raw[0];
        for (1..n) |i| predicted[i] = raw[i] +% predicted[i - 1] -% 128;
    }
    // 奇偶字节重组：压缩时偶数字节排前、奇数字节排后，解压时交错还原。
    const half = (n + 1) / 2;
    const out = try alloc.alloc(u8, n);
    defer alloc.free(out);
    for (0..n - half) |k| {
        out[2 * k] = predicted[k];
        out[2 * k + 1] = predicted[half + k];
    }
    // 数据按 (扫描线, 通道, 像素) 排列。
    var offset: usize = 0;
    for (0..lines) |line_offset| {
        const y = line_begin + line_offset;
        for (0..channel_count) |ci| {
            for (0..width) |x| {
                const linear: f64 = if (channel_byte_size == 4)
                    @as(f64, @floatCast(readF32Bytes(out[offset..][0..4])))
                else
                    @as(f64, @floatCast(halfToF32(readU16Bytes(out[offset..][0..2]))));
                offset += channel_byte_size;
                const idx = y * width + x;
                if (ci == r) pixels[idx].x = linear;
                if (ci == g) pixels[idx].y = linear;
                if (ci == b) pixels[idx].z = linear;
            }
        }
    }
}

fn readF32Bytes(bytes4: *const [4]u8) f32 {
    const bits = std.mem.readInt(u32, bytes4, .little);
    return @bitCast(bits);
}

fn readU16Bytes(bytes2: *const [2]u8) u16 {
    return std.mem.readInt(u16, bytes2, .little);
}

fn inflateZlib(alloc: Allocator, compressed: []const u8, expected: usize) LoadError![]u8 {
    const out = try alloc.alloc(u8, expected);
    errdefer alloc.free(out);
    var reader = std.Io.Reader.fixed(compressed);
    var buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&reader, .zlib, &buffer);
    var written: usize = 0;
    while (written < expected) {
        const bytes = decompress.reader.peekGreedy(1) catch |err| switch (err) {
            error.ReadFailed => return error.DecompressFailed,
            error.EndOfStream => break,
        };
        if (bytes.len == 0) break;
        const n = @min(bytes.len, expected - written);
        @memcpy(out[written..][0..n], bytes[0..n]);
        written += n;
        decompress.reader.toss(n);
    }
    if (written != expected) return error.DecompressFailed;
    return out;
}

// @brief IEEE 754 半精度转单精度，正确处理次正规数与 inf/nan。
fn halfToF32(h: u16) f32 {
    const sign: u32 = @as(u32, h & 0x8000) << 16;
    const exp: i32 = @as(i32, (h >> 10) & 0x1F);
    var man: u32 = h & 0x3FF;
    var bits: u32 = 0;
    if (exp == 0) {
        if (man == 0) {
            bits = sign;
        } else {
            var e: i32 = -14;
            while ((man & 0x400) == 0) {
                man <<= 1;
                e -= 1;
            }
            man &= 0x3FF;
            bits = sign | (@as(u32, @intCast(e + 127)) << 23) | (man << 13);
        }
    } else if (exp == 31) {
        bits = sign | 0x7F800000 | (man << 13);
    } else {
        bits = sign | (@as(u32, @intCast(exp - 15 + 127)) << 23) | (man << 13);
    }
    return @bitCast(bits);
}

fn readFile(alloc: Allocator, path: []const u8) LoadError![]u8 {
    const path_z = try alloc.dupeSentinel(u8, path, 0);
    defer alloc.free(path_z);
    const file = std.c.fopen(path_z.ptr, "rb") orelse return error.ParseError;
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
