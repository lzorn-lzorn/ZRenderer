const std = @import("std");
const scene = @import("scene.zig");
const main = @import("main.zig");
const math = @import("math.zig");
const object = @import("object.zig");
const color = @import("color.zig");
const testing = std.testing;

// @brief 小毛束场景验证实际 PBR 类型、光源注册和可复现的几何，而非仅测试构造函数。
test "scene includes deterministic PBR water jade fur and area emitter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try scene.loadRandomScene(a, .{ .fur_strands = 4 });
    const second = try scene.loadRandomScene(a, .{ .fur_strands = 4 });
    try testing.expect(first.light != null);
    try testing.expect(first.world.list.items[first.world.list.items.len - 1] == first.light.?);
    try testing.expectEqual(first.world.list.items.len, second.world.list.items.len);
    var capsules: usize = 0;
    var water: usize = 0;
    var jade: usize = 0;
    var pbr: usize = 0;
    for (first.world.list.items, second.world.list.items) |lhs, rhs| {
        try testing.expectEqual(std.meta.activeTag(lhs.*), std.meta.activeTag(rhs.*));
        if (lhs.* == .capsule) {
            capsules += 1;
            try testing.expectEqual(lhs.capsule.start, rhs.capsule.start);
        }
        if (lhs.* == .sphere) {
            try testing.expectEqual(lhs.sphere.center(0), rhs.sphere.center(0));
            switch (lhs.sphere.material.*) {
                .dielectric => |m| if (m.ir == 1.333) {
                    water += 1;
                },
                .translucent => jade += 1,
                .pbr => pbr += 1,
                else => {},
            }
        }
    }
    try testing.expect(capsules >= 8 and capsules <= 16);
    try testing.expect(water >= 2 and jade >= 2 and pbr > 100);
    var rec: object.HitRecord = .{};
    try testing.expect(first.bvh.hit(math.Ray.init(.{ .x = 3, .y = 0.9 }, .{ .x = -1 }, 0), 0, math.infinity, &rec));
    const bare = try scene.loadRandomScene(a, .{ .fur_strands = 0 });
    for (bare.world.list.items) |obj| try testing.expect(obj.* != .capsule);
}

test "physical camera and fur CLI accepts values and rejects invalid input" {
    const o = try main.Options.parse(&.{ "--focal-length", "85", "--f-number", "2", "--focus-distance", "5", "--shutter", "0.01", "--iso", "200", "--exposure", "-1", "--fur-strands", "0" });
    try testing.expectEqual(@as(f64, 85), o.focal_length_mm);
    try testing.expectEqual(@as(f64, 2), o.f_number);
    try testing.expectEqual(@as(f64, -1), o.exposure_compensation);
    try testing.expectEqual(@as(usize, 0), o.fur_strands);
    try testing.expectError(error.InvalidCameraParameter, main.Options.parse(&.{ "--iso", "nan" }));
    try testing.expectError(error.InvalidCameraParameter, main.Options.parse(&.{ "--f-number", "0" }));
    try testing.expectError(error.InvalidCameraParameter, main.Options.parse(&.{ "--shutter", "-1" }));
    try testing.expectError(error.ShutterOutsideSceneInterval, main.Options.parse(&.{ "--shutter", "2" }));
    try testing.expectError(error.InvalidFurCount, main.Options.parse(&.{ "--fur-strands", "100001" }));
    try testing.expectError(error.MissingOptionValue, main.Options.parse(&.{"--exposure"}));
}

// @brief 编码阶段必须在幂运算之前处理负值、NaN 和无穷，不能触发整数转换异常。
test "display conversion sanitizes invalid radiance before gamma" {
    var bytes: [3]u8 = undefined;
    color.writeColor(&bytes, .{ .x = -1, .y = std.math.nan(f64), .z = std.math.inf(f64) }, 1);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255 }, &bytes);
}
