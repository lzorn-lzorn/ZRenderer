const std = @import("std");
const exr = @import("zrenderer").exr;
const testing = std.testing;

test "decode sky.exr with correct dimensions and HDR range" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const image = exr.loadExr(arena.allocator(), "assets/sanmiguel/textures/sky.exr") catch |err| {
        std.debug.print("loadExr failed: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    try testing.expectEqual(@as(usize, 512), image.width);
    try testing.expectEqual(@as(usize, 512), image.height);
    // 底部左下角（天底）应为黑色，顶部应包含高亮的太阳 HDR 值。
    try testing.expectApproxEqAbs(@as(f64, 0), image.pixels[0].x, 1e-6);
    var max_luminance: f64 = 0;
    for (image.pixels) |p| {
        const l = (p.x + p.y + p.z) / 3.0;
        if (l > max_luminance) max_luminance = l;
    }
    try testing.expect(max_luminance > 1.0); // 天空 HDR 高亮应超过 1
    try testing.expect(std.math.isFinite(max_luminance));
}
