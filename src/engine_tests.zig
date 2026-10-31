const std = @import("std");
const e = @import("engine.zig");
const a = std.testing.allocator;
test "general origin stock union and tilted flat sweep independent time interval oracle" {
    const b = e.Bounds{ .lo = .{ -3, -2, -1 }, .hi = .{ 5, 6, 7 } };
    var g = try e.stock(a, b, 0.5, &.{.{ .box = b }});
    defer g.deinit();
    var r = try e.stock(a, b, 0.5, &.{.{ .box = b }});
    defer r.deinit();
    const s = e.Shape{ .sweep = .{ .tool = .{ .radius = 1.2, .length = 3 }, .a = .{ .position = .{ 0, 0, 0 }, .axis = .{ 0.6, 0, 0.8 } }, .b = .{ .position = .{ 3, 2, 1 }, .axis = .{ 0.6, 0, 0.8 } } } };
    var c: e.Changes = .{};
    defer c.deinit(a);
    var d: e.Changes = .{};
    defer d.deinit(a);
    try e.subtract(&g, s, &c, false);
    try e.subtract(&r, s, &d, true);
    for (0..g.blocks.len) |i| try std.testing.expectEqualSlices(u64, &g.bits(i), &r.bits(i));
    try std.testing.expect(c.removed > 0);
    try e.subtract(&g, s, &c, false);
    try std.testing.expectEqual(@as(u64, 0), c.removed);
    try std.testing.expect(g.query(.{ -2.75, -1.75, -0.75 }));
}
test "tool profiles include flutes and reject orientation change" {
    const ball = e.Tool{ .kind = .ball, .radius = 2, .length = 6 };
    try ball.validate();
    try std.testing.expect(ball.distance(1, 5) < 0);
    try std.testing.expect(ball.distance(1, 0) > 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0), ball.distance(0, 0), 1e-12);
    const bull = e.Tool{ .kind = .bull, .radius = 2, .length = 6, .corner = 0.5 };
    try bull.validate();
    try std.testing.expect(bull.distance(1, 0) == 0);
    try std.testing.expect(bull.distance(2, 0) > 0);
    const s = e.Sweep{ .tool = ball, .a = .{ .position = .{ 0, 0, 0 } }, .b = .{ .position = .{ 1, 0, 0 }, .axis = .{ 1, 0, 0 } } };
    try std.testing.expectError(error.OrientationChangeUnsupported, s.validate());
}
const state = @import("state.zig");
const inspect = @import("inspect.zig");
const mesh = @import("mesh_input.zig");
test "state roundtrip, checksum rejection, reversible history, compaction and cavities" {
    const b = e.Bounds{ .lo = .{ -4, -4, -4 }, .hi = .{ 4, 4, 4 } };
    var g = try e.stock(a, b, 0.5, &.{.{ .box = b }});
    defer g.deinit();
    const before = try state.encode(a, g);
    defer a.free(before);
    var changes: e.Changes = .{};
    defer changes.deinit(a);
    try e.subtract(&g, .{ .primitive = .{ .sphere = .{ .center = .{ 0, 0, 0 }, .radius = 2 } } }, &changes, false);
    try std.testing.expect(!g.query(.{ 0, 0, 0 }));
    try std.testing.expect(g.query(.{ 3, 0, 0 }));
    const final = g.stats().occupied;
    const file = try state.encode(a, g);
    defer a.free(file);
    var loaded = try state.decode(a, file);
    defer loaded.deinit();
    for (0..g.blocks.len) |i| try std.testing.expectEqualSlices(u64, &g.bits(i), &loaded.bits(i));
    try state.replay(&g, changes.bytes.items, false);
    try std.testing.expectEqual(@as(u64, 4096), g.stats().occupied);
    try state.replay(&g, changes.bytes.items, true);
    try std.testing.expectEqual(final, g.stats().occupied);
    try std.testing.expectError(error.HistoryStateMismatch, state.replay(&g, changes.bytes.items, true));
    try std.testing.expectError(error.CorruptHistory, state.replay(&g, changes.bytes.items[0..5], false));
    try e.compact(&g);
    try std.testing.expectEqual(final, g.stats().occupied);
    try std.testing.expectEqual(g.stats().mixed_blocks, g.pool.items.len);
    file[file.len - 1] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, state.decode(a, file));
    var initial = try state.decode(a, before);
    defer initial.deinit();
    const diff = try inspect.compare(g, initial);
    try std.testing.expectEqual(@as(u64, 4096) - final, diff.missing);
    try std.testing.expectEqual(@as(u64, 0), diff.excess);
    const hit = (try inspect.ray(g, .{ 10, 0, 0 }, .{ -1, 0, 0 }, 20)).?;
    try std.testing.expectApproxEqAbs(@as(f64, 4), hit.position[0], 1e-8);
    const pixels = try inspect.section(a, g, .{ .origin = .{ -4, -4, 0 }, .u = .{ 1, 0, 0 }, .v = .{ 0, 1, 0 }, .pixel_mm = 0.5, .width = 16, .height = 16 });
    defer a.free(pixels);
    try std.testing.expectEqual(@as(u8, 24), pixels[(8 * 16 + 8) * 3]);
}
fn allocScenario(alloc: std.mem.Allocator) !void {
    const b = e.Bounds{ .lo = .{ 0, 0, 0 }, .hi = .{ 8, 8, 8 } };
    var g = try e.stock(alloc, b, 1, &.{.{ .box = b }});
    defer g.deinit();
    var changes: e.Changes = .{};
    defer changes.deinit(alloc);
    e.subtract(&g, .{ .primitive = .{ .sphere = .{ .center = .{ 4, 4, 4 }, .radius = 2 } } }, &changes, false) catch |err| {
        try std.testing.expectEqual(@as(u64, 512), g.stats().occupied);
        return err;
    };
    const bytes = try state.encode(alloc, g);
    defer alloc.free(bytes);
    var loaded = try state.decode(alloc, bytes);
    defer loaded.deinit();
    try e.compact(&loaded);
}
test "general operations allocation failures preserve occupancy and do not leak" {
    try std.testing.checkAllAllocationFailures(a, allocScenario, .{});
}
test "flat 3D cylinder sweeps independent dense time oracle, reversal and split" {
    var rng = std.Random.DefaultPrng.init(9127);
    const random = rng.random();
    for (0..12) |_| {
        const axis = e.scale(e.V{ random.float(f64), random.float(f64), random.float(f64) }, 1);
        const u = e.scale(axis, 1 / e.norm(axis));
        const s = e.Sweep{ .tool = .{ .radius = 0.7, .length = 1.4 }, .a = .{ .position = .{ -0.3, 0.1, 0.2 }, .axis = u }, .b = .{ .position = .{ 1.2, 1.4, 1.3 }, .axis = u } };
        try s.validate();
        var reverse = s;
        reverse.a = s.b;
        reverse.b = s.a;
        var first = s;
        first.b.position = e.scale(e.add(s.a.position, s.b.position), 0.5);
        var second = s;
        second.a = first.b;
        for (0..100) |_| {
            const p = e.V{ random.float(f64) * 3 - 1, random.float(f64) * 3 - 1, random.float(f64) * 3 - 1 };
            const exact = s.flatContains(p, 0);
            try std.testing.expectEqual(exact, reverse.flatContains(p, 0));
            try std.testing.expectEqual(exact, first.flatContains(p, 0) or second.flatContains(p, 0));
            // Independent exhaustive moving-cylinder predicate; skip its known temporal uncertainty band.
            var sampled = false;
            var expanded = false;
            const dilation = e.norm(e.sub(s.b.position, s.a.position)) / 2000;
            for (0..1001) |i| {
                const t = @as(f64, @floatFromInt(i)) / 1000;
                const q = e.sub(p, e.add(s.a.position, e.scale(e.sub(s.b.position, s.a.position), t)));
                const z = e.dot(q, u);
                const radial = e.norm(e.cross(q, u));
                if (z >= 0 and z <= 1.4 and radial <= 0.7) sampled = true;
                if (z >= -dilation and z <= 1.4 + dilation and radial <= 0.7 + dilation) expanded = true;
            }
            if (sampled) try std.testing.expect(exact);
            if (!expanded) try std.testing.expect(!exact);
        }
    }
}
test "ball and bull conservative sweeps cover continuous poses within declared bound" {
    for ([_]e.Tool{ .{ .kind = .ball, .radius = 1, .length = 3 }, .{ .kind = .bull, .radius = 1, .length = 3, .corner = 0.3 } }) |tool| {
        const s = e.Sweep{ .tool = tool, .a = .{ .position = .{ 0, 0, 0 } }, .b = .{ .position = .{ 2, 1, 1 } }, .tolerance_mm = 0.05 };
        try s.validate();
        try std.testing.expect(s.errorBound() <= 0.05);
        // Independent points on flute, bottom arc, and top at unsampled times.
        for (0..117) |i| {
            const t = (@as(f64, @floatFromInt(i)) + 0.37) / 117;
            const base = e.scale(s.b.position, t);
            for ([_]e.V{ .{ 0.999, 0, 2 }, .{ 0, 0, 0.001 }, .{ 0, 0, 2.999 } }) |offset| try std.testing.expect((e.Shape{ .sweep = s }).contains(e.add(base, offset)));
        }
    }
}
test "noncutting geometry collision is separate from cutter engagement" {
    const b = e.Bounds{ .lo = .{ 0, 0, 0 }, .hi = .{ 4, 4, 4 } };
    var g = try e.stock(a, b, 0.5, &.{.{ .box = b }});
    defer g.deinit();
    const hit = try inspect.collision(g, .{ .sweep = .{ .tool = .{ .radius = 1, .length = 2 }, .a = .{ .position = .{ -2, 2, 3 } }, .b = .{ .position = .{ 6, 2, 3 } } } });
    try std.testing.expect(hit.occupied_centers > 0);
    try std.testing.expectEqual(@as(u64, 512), g.stats().occupied);
}
fn cubeSTL(alloc: std.mem.Allocator) ![]u8 {
    const vertices = [_]e.V{ .{ 0, 0, 0 }, .{ 2, 0, 0 }, .{ 2, 2, 0 }, .{ 0, 2, 0 }, .{ 0, 0, 2 }, .{ 2, 0, 2 }, .{ 2, 2, 2 }, .{ 0, 2, 2 } };
    const faces = [_][3]usize{ .{ 0, 2, 1 }, .{ 0, 3, 2 }, .{ 4, 5, 6 }, .{ 4, 6, 7 }, .{ 0, 1, 5 }, .{ 0, 5, 4 }, .{ 1, 2, 6 }, .{ 1, 6, 5 }, .{ 2, 3, 7 }, .{ 2, 7, 6 }, .{ 3, 0, 4 }, .{ 3, 4, 7 } };
    const bytes = try alloc.alloc(u8, 84 + 12 * 50);
    @memset(bytes, 0);
    std.mem.writeInt(u32, bytes[80..84], 12, .little);
    for (faces, 0..) |face, i| for (face, 0..) |v, j| for (vertices[v], 0..) |value, k| {
        const f: f32 = @floatCast(value);
        const off = 84 + i * 50 + 12 + j * 12 + k * 4;
        std.mem.writeInt(u32, bytes[off..][0..4], @bitCast(f), .little);
    };
    return bytes;
}
test "binary STL BVH parity, boundary, voxelization, malformed and open meshes" {
    const bytes = try cubeSTL(a);
    defer a.free(bytes);
    var m = try mesh.Mesh.parse(a, bytes, 1, .{ -1, -1, -1 });
    defer m.deinit();
    try std.testing.expect(try m.contains(.{ 0, 0, 0 }));
    try std.testing.expect(try m.contains(.{ 1, 0, 0 }));
    try std.testing.expect(!try m.contains(.{ 2, 0, 0 }));
    var g = try m.voxelize(a, .{ .lo = .{ -2, -2, -2 }, .hi = .{ 2, 2, 2 } }, 0.25);
    defer g.deinit();
    try std.testing.expectEqual(@as(u64, 512), g.stats().occupied);
    try std.testing.expectError(error.InvalidSTL, mesh.Mesh.parse(a, bytes[0 .. bytes.len - 1], 1, .{ 0, 0, 0 }));
    std.mem.writeInt(u32, bytes[80..84], 11, .little);
    try std.testing.expectError(error.NonWatertightOrInconsistentSTL, mesh.Mesh.parse(a, bytes[0 .. 84 + 11 * 50], 1, .{ 0, 0, 0 }));
}
const motion = @import("motion.zig");
test "helical centerline conservative coverage and orientation change rejection" {
    const arc = motion.Arc{ .center = .{ 0, 0, 0 }, .radius = 3, .start_angle = 0.17, .sweep_angle = 4.2, .rise = 2 };
    const tool = e.Tool{ .radius = 0.4, .length = 1.3 };
    const plan = try motion.arc(a, tool, arc, 0.04);
    defer plan.deinit(a);
    try std.testing.expect(plan.over_removal_bound_mm <= 0.04);
    const s = e.Shape{ .path = plan.segments };
    try s.validate();
    for (0..337) |i| {
        const t = (@as(f64, @floatFromInt(i)) + 0.37) / 337;
        const p = motion.point(arc, t);
        for ([_]e.V{ .{ 0.399, 0, 0 }, .{ 0, 0, 1.299 }, .{ 0, 0, 0.001 } }) |offset| try std.testing.expect(s.contains(e.add(p, offset)));
    }
}
test "longitudinal and facing rotational envelopes match independent radial oracle" {
    const b = e.Bounds{ .lo = .{ -4, -4, 0 }, .hi = .{ 4, 4, 8 } };
    var g = try e.stock(a, b, 0.25, &.{.{ .cylinder = .{ .base = .{ 0, 0, 0 }, .radius = 3, .length = 8 } }});
    defer g.deinit();
    var changes: e.Changes = .{};
    defer changes.deinit(a);
    const turn = motion.Turning{ .spindle_origin = .{ 0, 0, 0 }, .mode = .longitudinal, .radial_start = 2, .radial_end = 2, .axial_start = 2, .axial_end = 6, .insert_radial_width = 2, .insert_axial_width = 1 };
    try e.subtract(&g, try turn.shape(), &changes, false);
    const face = motion.Turning{ .spindle_origin = .{ 0, 0, 0 }, .mode = .facing, .radial_start = 0, .radial_end = 3, .axial_start = 7, .axial_end = 7, .insert_radial_width = 0.2, .insert_axial_width = 1 };
    try e.subtract(&g, try face.shape(), &changes, false);
    for (0..g.n[2]) |z| for (0..g.n[1]) |y| for (0..g.n[0]) |x| {
        const px = g.origin[0] + g.center(x);
        const py = g.origin[1] + g.center(y);
        const pz = g.center(z);
        const r2 = px * px + py * py;
        const expected = r2 <= 9 and !(r2 >= 4 and pz >= 2 and pz <= 7) and pz < 7;
        try std.testing.expectEqual(expected, g.occupied(.{ x, y, z }));
    };
}
test "random primitive stocks, union and conservative classifiers against independent scalar geometry" {
    var random_state = std.Random.DefaultPrng.init(72831);
    const random = random_state.random();
    for (0..16) |_| {
        const center = e.V{ random.float(f64) * 2 - 1, random.float(f64) * 2 - 1, random.float(f64) * 2 - 1 };
        const radius = 0.3 + random.float(f64) * 1.5;
        const b = e.Bounds{ .lo = .{ -2, -2, -2 }, .hi = .{ 2, 2, 2 } };
        var g = try e.stock(a, b, 0.25, &.{ .{ .sphere = .{ .center = center, .radius = radius } }, .{ .box = .{ .lo = .{ -2, -2, -2 }, .hi = .{ -1, 1, 1 } } } });
        defer g.deinit();
        for (0..g.n[2]) |z| for (0..g.n[1]) |y| for (0..g.n[0]) |x| {
            const p = e.add(g.origin, .{ g.center(x), g.center(y), g.center(z) });
            const q = e.sub(p, center);
            const sphere = e.dot(q, q) <= (radius + 1e-10) * (radius + 1e-10);
            const box = p[0] <= -1 and p[1] <= 1 and p[2] <= 1;
            try std.testing.expectEqual(sphere or box, g.occupied(.{ x, y, z }));
        };
        var sparse = try @import("tiles.zig").Snapshot.init(a, g);
        defer sparse.deinit();
        for (0..g.n[2]) |z| for (0..g.n[1]) |y| for (0..g.n[0]) |x| try std.testing.expectEqual(g.occupied(.{ x, y, z }), sparse.occupied(.{ x, y, z }));
    }
}
test "independent ball bull taper and conical drill stationary profiles" {
    var rng = std.Random.DefaultPrng.init(1981);
    const random = rng.random();
    for (0..2000) |_| {
        const r = random.float(f64) * 3;
        const z = random.float(f64) * 6 - 1;
        const ball = e.Tool{ .kind = .ball, .radius = 2, .length = 4 };
        const ball_expected = z >= 0 and z <= 4 and r <= 2 and (z >= 2 or r * r + (z - 2) * (z - 2) <= 4);
        try std.testing.expectEqual(ball_expected, ball.distance(r, z) <= 0);
        const bull = e.Tool{ .kind = .bull, .radius = 2, .length = 4, .corner = 0.5 };
        const bull_expected = z >= 0 and z <= 4 and r <= 2 and (z >= 0.5 or r <= 1.5 or (r - 1.5) * (r - 1.5) + (z - 0.5) * (z - 0.5) <= 0.25);
        try std.testing.expectEqual(bull_expected, bull.distance(r, z) <= 0);
        const taper = e.Tool{ .kind = .taper, .radius = 2, .length = 4, .tip_radius = 0.5 };
        try std.testing.expectEqual(z >= 0 and z <= 4 and r <= 0.5 + 1.5 * z / 4, taper.distance(r, z) <= 0);
        const drill = e.Tool{ .kind = .drill, .radius = 2, .length = 4 };
        try std.testing.expectEqual(z >= 0 and z <= 4 and r <= z / 2, drill.distance(r, z) <= 0);
    }
}
test "STL intersecting shells rejected and allocation failure cleanup" {
    const cube = try cubeSTL(a);
    defer a.free(cube);
    const data = try a.alloc(u8, 84 + 24 * 50);
    defer a.free(data);
    @memcpy(data[0..84], cube[0..84]);
    std.mem.writeInt(u32, data[80..84], 24, .little);
    @memcpy(data[84..][0..600], cube[84..]);
    @memcpy(data[684..], cube[84..]);
    for (0..12) |i| for (0..3) |v| for (0..3) |axis| {
        const off = 684 + i * 50 + 12 + v * 12 + axis * 4;
        var f: f32 = @bitCast(std.mem.readInt(u32, data[off..][0..4], .little));
        f += 0.7;
        std.mem.writeInt(u32, data[off..][0..4], @bitCast(f), .little);
    };
    try std.testing.expectError(error.SelfIntersectingSTL, mesh.Mesh.parse(a, data, 1, .{ 0, 0, 0 }));
    const Helper = struct {
        fn run(alloc: std.mem.Allocator, bytes: []const u8) !void {
            var m = try mesh.Mesh.parse(alloc, bytes, 1, .{ 0, 0, 0 });
            defer m.deinit();
            var g = try m.voxelize(alloc, .{ .lo = .{ 0, 0, 0 }, .hi = .{ 3, 3, 3 } }, 0.5);
            defer g.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(a, Helper.run, .{cube});
}
test "disconnected pieces, thin wall, tiny bore, tangency, short moves and large local origin" {
    const b = e.Bounds{ .lo = .{ 10000, -10000, 0 }, .hi = .{ 10004, -9996, 4 } };
    var g = try e.stock(a, b, 0.25, &.{.{ .box = b }});
    defer g.deinit();
    var changes: e.Changes = .{};
    defer changes.deinit(a);
    try e.subtract(&g, .{ .primitive = .{ .box = .{ .lo = .{ 10001.5, -10000, 0 }, .hi = .{ 10002.5, -9996, 4 } } } }, &changes, false);
    try std.testing.expect(g.query(.{ 10001, -9998, 2 }));
    try std.testing.expect(!g.query(.{ 10002, -9998, 2 }));
    try std.testing.expect(g.query(.{ 10003, -9998, 2 }));
    const s = e.Sweep{ .tool = .{ .radius = 0.125, .length = 4 }, .a = .{ .position = .{ 10000.625, -9999.375, 0 } }, .b = .{ .position = .{ 10000.625 + 1e-12, -9999.375, 0 } } };
    try e.subtract(&g, .{ .sweep = s }, &changes, false);
    try std.testing.expect(!g.query(s.a.position));
    try std.testing.expect(s.flatContains(.{ 10000.75, -9999.375, 0 }, 0));
    try std.testing.expect(!s.flatContains(.{ 10000.76, -9999.375, 0 }, 0));
}
test "mill and turning envelope share translated tilted spindle coordinates" {
    const axis = e.V{ 0.6, 0, 0.8 };
    const origin = e.V{ -3, 1, -2 };
    const bounds = e.Bounds{ .lo = .{ -8, -4, -7 }, .hi = .{ 8, 8, 10 } };
    var g = try e.stock(a, bounds, 0.5, &.{.{ .cylinder = .{ .base = origin, .axis = axis, .radius = 3, .length = 8 } }});
    defer g.deinit();
    var changes: e.Changes = .{};
    defer changes.deinit(a);
    const t = motion.Turning{ .spindle_origin = origin, .spindle_axis = axis, .mode = .longitudinal, .radial_start = 2, .radial_end = 2, .axial_start = 2, .axial_end = 6, .insert_radial_width = 2, .insert_axial_width = 1 };
    try e.subtract(&g, try t.shape(), &changes, false);
    const mill = e.Sweep{ .tool = .{ .radius = 0.7, .length = 4 }, .a = .{ .position = origin, .axis = axis }, .b = .{ .position = e.add(origin, e.scale(axis, 8)), .axis = axis } };
    try e.subtract(&g, .{ .sweep = mill }, &changes, false);
    for (0..g.n[2]) |z| for (0..g.n[1]) |y| for (0..g.n[0]) |x| {
        const p = e.add(g.origin, .{ g.center(x), g.center(y), g.center(z) });
        const q = e.sub(p, origin);
        const axial = e.dot(q, axis);
        const radial = e.norm(e.cross(q, axis));
        const expected = axial >= 0 and axial <= 8 and radial <= 3 and radial > 0.7 and !(axial >= 2 and axial <= 7 and radial >= 2);
        try std.testing.expectEqual(expected, g.occupied(.{ x, y, z }));
    };
}
test "invalid JSON contracts and tiny geometry remain explicit" {
    const job = @import("job.zig");
    const base = job.Job{ .version = 1, .units = "mm", .bounds = .{ .lo = .{ 0, 0, 0 }, .hi = .{ 2, 2, 2 } }, .voxel_mm = 0.25, .stock = .{ .primitives = &.{.{ .box = .{ .lo = .{ 0, 0, 0 }, .hi = .{ 2, 2, 2 } } }} }, .operations = &.{} };
    var bad = base;
    bad.version = 2;
    try std.testing.expectError(error.UnsupportedJobVersion, job.validate(a, bad));
    bad = base;
    bad.units = "inch";
    try std.testing.expectError(error.UnitsMustBeMillimeters, job.validate(a, bad));
    try std.testing.expectError(error.AxisMustBeUnit, (e.Sweep{ .tool = .{ .radius = 1, .length = 2 }, .a = .{ .position = .{ 0, 0, 0 }, .axis = .{ 0, 0, 2 } }, .b = .{ .position = .{ 1, 0, 0 } } }).validate());
    try std.testing.expectError(error.InvalidTool, (e.Tool{ .kind = .bull, .radius = 1, .length = 2, .corner = 2 }).validate());
    const bounds = e.Bounds{ .lo = .{ 0, 0, 0 }, .hi = .{ 1e-7, 1e-7, 1e-7 } };
    const cyl = e.Primitive{ .cylinder = .{ .base = .{ 5e-8, 5e-8, 0 }, .radius = 1e-9, .length = 1e-7 } };
    var g = try e.stock(a, bounds, 1e-8, &.{cyl});
    defer g.deinit();
    for (0..g.n[2]) |z| for (0..g.n[1]) |y| for (0..g.n[0]) |x| try std.testing.expectEqual(cyl.distance(.{ g.center(x), g.center(y), g.center(z) }) <= e.core.tolerance, g.occupied(.{ x, y, z }));
}
test "candidate ranges include absolute predicate tolerance even below tolerance voxel spacing" {
    const bounds = e.Bounds{ .lo = .{ -2e-10, -2e-10, -2e-10 }, .hi = .{ 2e-10, 2e-10, 2e-10 } };
    const sphere = e.Primitive{ .sphere = .{ .center = .{ 0, 0, 0 }, .radius = 1e-11 } };
    var g = try e.stock(a, bounds, 2e-11, &.{sphere});
    defer g.deinit();
    for (0..g.n[2]) |z| for (0..g.n[1]) |y| for (0..g.n[0]) |x| {
        const p = e.add(g.origin, .{ g.center(x), g.center(y), g.center(z) });
        try std.testing.expectEqual(e.norm(p) <= 1.1e-10, g.occupied(.{ x, y, z }));
    };
}

test "fast Z masks and tight bounds agree with scalar across edges origins dilation and sparse occupancy" {
    var random_state = std.Random.DefaultPrng.init(0xabe871);
    const random = random_state.random();
    const bounds = e.Bounds{ .lo = .{ -2.31, 0.17, -0.43 }, .hi = .{ 2.44, 4.42, 2.82 } };
    var fast = try e.stock(a, bounds, 0.25, &.{.{ .box = bounds }});
    defer fast.deinit();
    var slow = try e.stock(a, bounds, 0.25, &.{.{ .box = bounds }});
    defer slow.deinit();
    var fc: e.Changes = .{};
    defer fc.deinit(a);
    var sc: e.Changes = .{};
    defer sc.deinit(a);
    for (0..70) |step| {
        const z = random.float(f64) * 5 - 1;
        const start = e.V{ random.float(f64) * 7 - 4, random.float(f64) * 6 - 1, z };
        const end = if (step % 10 == 0) e.V{ start[0], start[1], z + random.float(f64) * 3 - 1.5 } else if (step % 5 == 0) start else e.V{ random.float(f64) * 7 - 4, random.float(f64) * 6 - 1, z + (if (step % 4 == 0) random.float(f64) - 0.5 else @as(f64, 0)) };
        const shape = e.Shape{ .sweep = .{ .tool = .{ .radius = 0.05 + random.float(f64), .length = 0.03 + random.float(f64) * 4 }, .a = .{ .position = start }, .b = .{ .position = end }, .dilation_mm = if (step % 3 == 0) 0.13 else 0 } };
        // Mask oracle does no block classification or candidate clipping.
        for (0..fast.blocks.len) |i| {
            const coords = fast.blockCoords(i);
            try std.testing.expectEqualSlices(u64, &e.mask(fast, coords, shape, true, fast.bits(i)), &e.mask(fast, coords, shape, false, fast.bits(i)));
        }
        const contact = try inspect.collision(fast, shape);
        const oracle = try inspect.collisionReference(fast, shape);
        try std.testing.expectEqualDeep(oracle, contact);
        try e.subtract(&fast, shape, &fc, false);
        try e.subtract(&slow, shape, &sc, true);
        try std.testing.expectEqual(fc.removed, sc.removed);
        for (0..fast.blocks.len) |i| try std.testing.expectEqualSlices(u64, &slow.bits(i), &fast.bits(i));
    }
}

test "fast collision exact extrema and counts for full partial disconnected and empty contacts" {
    const b = e.Bounds{ .lo = .{ -1.31, -0.17, -0.43 }, .hi = .{ 3.44, 4.08, 2.82 } };
    var g = try e.stock(a, b, 0.25, &.{.{ .box = b }});
    defer g.deinit();
    // Arbitrary sparse words stress all three extrema and descriptor types.
    var rng = std.Random.DefaultPrng.init(6617);
    for (0..g.blocks.len) |i| {
        if (i % 3 == 0) continue;
        var bits = g.bits(i);
        for (&bits) |*w| w.* &= rng.random().int(u64);
        g.blocks[i] = @intCast(g.pool.items.len);
        try g.pool.append(a, bits);
    }
    const shapes = [_]e.Shape{
        .{ .primitive = .{ .box = b } },
        .{ .primitive = .{ .sphere = .{ .center = .{ 0, 0, 0 }, .radius = 1.17 } } },
        .{ .primitive = .{ .halfspace = .{ .normal = .{ 0.6, 0, 0.8 }, .offset = 0.13 } } },
        .{ .sweep = .{ .tool = .{ .radius = 0.7, .length = 2 }, .a = .{ .position = .{ -1, 1, 1 }, .axis = .{ 0.6, 0, 0.8 } }, .b = .{ .position = .{ 3, 2, -0.3 }, .axis = .{ 0.6, 0, 0.8 } } } },
        .{ .sweep = .{ .tool = .{ .kind = .ball, .radius = 0.7, .length = 2 }, .a = .{ .position = .{ -1, 1, 1 } }, .b = .{ .position = .{ 3, 2, -0.3 } } } },
        .{ .sweep = .{ .tool = .{ .radius = 2, .length = 7 }, .a = .{ .position = .{ 0, 0, 3 } }, .b = .{ .position = .{ 1, 1, 4 } } } },
    };
    for (shapes) |shape| try std.testing.expectEqualDeep(try inspect.collisionReference(g, shape), try inspect.collision(g, shape));
}

test "SIMD prepared Z sweep matches scalar at tangencies axial caps and tiny motions" {
    for ([_]f64{ 0, 1e-15, -1e-12, 0.65, -2.3 }) |dx| {
        const sweep = e.Sweep{ .tool = .{ .radius = 0.7, .length = 2.3 }, .a = .{ .position = .{ 1.13, -0.37, 0.29 } }, .b = .{ .position = .{ 1.13 + dx, -0.37, 0.29 } } };
        const kernel = e.FlatZ.init(sweep).?;
        for ([_]f64{ -e.core.tolerance, 0, 2.3, 2.3 + e.core.tolerance }) |z| {
            var points: [3]e.FlatZ.F = undefined;
            for (0..8) |lane| {
                const delta = (@as(f64, @floatFromInt(lane)) - 3.5) * 1e-15;
                points[0][lane] = sweep.a.position[0];
                points[1][lane] = sweep.a.position[1] + sweep.tool.radius + e.core.tolerance + delta;
                points[2][lane] = sweep.a.position[2] + z + delta;
            }
            const got = kernel.contains8(points);
            for (0..8) |lane| try std.testing.expectEqual(sweep.flatContains(.{ points[0][lane], points[1][lane], points[2][lane] }, 0), got[lane]);
        }
    }
    try std.testing.expect(e.FlatZ.init(.{ .tool = .{ .radius = 1, .length = 2 }, .a = .{ .position = .{ 0, 0, 0 } }, .b = .{ .position = .{ 1, 0, 1 } } }) == null);
}

fn allocationFlat(alloc: std.mem.Allocator) !void {
    const b = e.Bounds{ .lo = .{ 0, 0, 0 }, .hi = .{ 4, 4, 4 } };
    var g = try e.stock(alloc, b, 0.25, &.{.{ .box = b }});
    defer g.deinit();
    var changes: e.Changes = .{};
    defer changes.deinit(alloc);
    e.subtract(&g, .{ .sweep = .{ .tool = .{ .radius = 0.6, .length = 3 }, .a = .{ .position = .{ 1, 2, 2 } }, .b = .{ .position = .{ 3, 2, 2 } } } }, &changes, false) catch |err| {
        try std.testing.expectEqual(@as(u64, 4096), g.stats().occupied);
        return err;
    };
}
test "optimized flat sweep allocation failures leave material intact" {
    try std.testing.checkAllAllocationFailures(a, allocationFlat, .{});
}

test "vertical sweep specialization matches scalar masks and cap rounding" {
    const bounds = e.Bounds{ .lo = .{ -1.13, -0.37, -2.29 }, .hi = .{ 3.12, 4.38, 4.21 } };
    var g = try e.stock(a, bounds, 0.25, &.{.{ .box = bounds }});
    defer g.deinit();
    for ([_]f64{ -3.7, -1e-12, 1e-15, 0, 2.17 }) |dz| {
        const sweep = e.Sweep{ .tool = .{ .radius = 0.7, .length = 2.3 }, .a = .{ .position = .{ 1.13, 0.37, 0.29 } }, .b = .{ .position = .{ 1.13, 0.37, 0.29 + dz } } };
        const shape = e.Shape{ .sweep = sweep };
        const kernel = e.FlatZ.init(sweep).?;
        for (0..g.blocks.len) |i| {
            const b = g.blockCoords(i);
            try std.testing.expectEqualSlices(u64, &e.mask(g, b, shape, true, g.bits(i)), &e.mask(g, b, shape, false, g.bits(i)));
        }
        for ([_]f64{ -e.core.tolerance, 0, 2.3, 2.3 + e.core.tolerance, dz - e.core.tolerance, dz + 2.3 + e.core.tolerance }) |z| {
            var points: [3]e.FlatZ.F = undefined;
            for (0..8) |lane| {
                const delta = (@as(f64, @floatFromInt(lane)) - 3.5) * 1e-15;
                points[0][lane] = 1.13;
                points[1][lane] = 0.37 + sweep.tool.radius + e.core.tolerance + delta;
                points[2][lane] = 0.29 + z + delta;
            }
            const got = kernel.contains8(points);
            for (0..8) |lane| try std.testing.expectEqual(sweep.flatContains(.{ points[0][lane], points[1][lane], points[2][lane] }, 0), got[lane]);
        }
    }
}

test "ball discrete convex search preserves exhaustive pose semantics" {
    var random = std.Random.DefaultPrng.init(0x5199);
    const r = random.random();
    for (0..12000) |i| {
        const radius = 0.2 + r.float(f64) * 2;
        var sweep = e.Sweep{ .tool = .{ .kind = .ball, .radius = radius, .length = radius + r.float(f64) * 4 }, .a = .{ .position = .{ 0.013, -0.017, 0.009 } }, .b = .{ .position = .{ r.float(f64) * 6, r.float(f64) * 4, r.float(f64) * 4 } }, .tolerance_mm = 0.005 };
        if (i % 5 == 0) sweep.b.position = sweep.a.position;
        if (i % 5 == 1) sweep.b.position = e.add(sweep.a.position, .{ 0, 0, 3 });
        if (i % 5 == 2) sweep.b.position = e.add(sweep.a.position, .{ 1e-8, 0, 0 });
        if (i % 5 == 3) {
            sweep.a.axis = .{ 0.6, 0, 0.8 };
            sweep.b.axis = sweep.a.axis;
        }
        const p = e.V{ r.float(f64) * 10 - 2, r.float(f64) * 8 - 2, r.float(f64) * 10 - 2 };
        const scalar = sweep.distance(p);
        const fast = sweep.distanceFast(p);
        try std.testing.expectApproxEqAbs(scalar, fast, 1e-11);
        try std.testing.expectEqual(scalar <= @import("core.zig").tolerance, fast <= @import("core.zig").tolerance);
        const reverse = e.Sweep{ .tool = sweep.tool, .a = sweep.b, .b = sweep.a, .tolerance_mm = sweep.tolerance_mm };
        try std.testing.expectApproxEqAbs(fast, reverse.distanceFast(p), 1e-10);
    }
}

test "mesh uniform block fill matches scalar including partial boundary blocks" {
    const bytes = try cubeSTL(a);
    defer a.free(bytes);
    for ([_]e.V{ .{ 0, 0, 0 }, .{ 0.013, -0.017, 0.009 } }) |translation| {
        var m = try mesh.Mesh.parse(a, bytes, 1, translation);
        defer m.deinit();
        const bounds = e.Bounds{ .lo = .{ -0.3, -0.3, -0.3 }, .hi = .{ 3.1, 3.1, 3.1 } };
        var fast = try m.voxelizeMode(a, bounds, 0.1, false);
        defer fast.deinit();
        try std.testing.expect(m.uniform_blocks > 0);
        var scalar = try m.voxelizeMode(a, bounds, 0.1, true);
        defer scalar.deinit();
        for (0..fast.blocks.len) |i| try std.testing.expectEqualSlices(u64, &scalar.bits(i), &fast.bits(i));
    }
}

test "complete moving ball covers independently constructed hemisphere and flute points" {
    for ([_]e.V{ .{ 0, 0, 0 }, .{ 0, 0, 3 }, .{ 3, 1, 2 }, .{ 1e-8, 0, 0 } }) |end| {
        const s = e.Sweep{ .tool = .{ .kind = .ball, .radius = 1, .length = 4 }, .a = .{ .position = .{ 0, 0, 0 } }, .b = .{ .position = end }, .tolerance_mm = 0.005 };
        for (0..101) |i| {
            const t = @as(f64, @floatFromInt(i)) / 100;
            const base = e.scale(end, t);
            // Independent interior points of hemisphere, cylindrical flute and near tangency.
            for ([_]e.V{ .{ 0.6, 0, 0.2 }, .{ 0.8, 0, 3.9 }, .{ 0, 0, 0 }, .{ 1, 0, 1 } }) |q| {
                try std.testing.expect(s.distanceFast(e.add(base, q)) <= 1e-10);
            }
        }
    }
}

test "ball split motion lattice and near tangent translated centers" {
    const s = e.Sweep{ .tool = .{ .kind = .ball, .radius = 1, .length = 4 }, .a = .{ .position = .{ 10000.013, -9999.983, 0.009 } }, .b = .{ .position = .{ 10002.013, -9999.983, 0.009 } }, .tolerance_mm = 0.025 };
    var left = s;
    var right = s;
    left.b.position = e.scale(e.add(s.a.position, s.b.position), 0.5);
    right.a = left.b;
    for (0..100) |i| for ([_]f64{ -1e-9, 0, 1e-9, 0.01 }) |delta| {
        const p = e.add(s.a.position, .{ @as(f64, @floatFromInt(i)) / 50, 1 + s.errorBound() + delta, 2 });
        const scalar = s.distance(p);
        try std.testing.expectEqual(scalar <= 1e-10, s.distanceFast(p) <= 1e-10);
        try std.testing.expectEqual(scalar <= 1e-10, @min(left.distanceFast(p), right.distanceFast(p)) <= 1e-10);
    };
    left.b.position = e.add(s.a.position, .{ 0.713, 0, 0 });
    right.a = left.b;
    // A non-lattice split changes the sampled approximation, not the continuous path.
    // Both approximations contain that path and stay within the declared tolerance.
    for (0..100) |i| {
        const p = e.add(s.a.position, .{ @as(f64, @floatFromInt(i)) / 50, 1.01, 0.9 });
        try std.testing.expect(@abs(s.distanceFast(p) - @min(left.distanceFast(p), right.distanceFast(p))) <= 2 * s.tolerance_mm + 1e-8);
    }
}

test "cached STL rays match uncached parity at translated faces edges and random points" {
    const bytes = try cubeSTL(a);
    defer a.free(bytes);
    var random = std.Random.DefaultPrng.init(0x5241594341434845);
    const r = random.random();
    for ([_]f64{ 0.001, 1, 100 }) |scale| {
        for ([_]e.V{ .{ 0, 0, 0 }, .{ 0.013, -0.017, 0.009 }, .{ 10000.013, -9999.983, 0.009 } }) |origin| {
            var m = try mesh.Mesh.parse(a, bytes, scale, origin);
            defer m.deinit();
            try std.testing.expect(m.rayCacheBytes() > 0);
            for (0..2000) |_| {
                const local = e.V{ (r.float(f64) * 4 - 1) * scale, (r.float(f64) * 4 - 1) * scale, (r.float(f64) * 4 - 1) * scale };
                const p = e.add(origin, local);
                const expected = local[0] >= 0 and local[0] <= 2 * scale and local[1] >= 0 and local[1] <= 2 * scale and local[2] >= 0 and local[2] <= 2 * scale;
                try std.testing.expectEqual(try m.containsReference(p), try m.contains(p));
                try std.testing.expectEqual(expected, try m.contains(p));
            }
            // Exact faces, edges and vertices, plus either side of the existing
            // boundary tolerance: preserve both classification and error behavior.
            for ([_]e.V{ .{ 0, 0, 0 }, .{ 2, 2, 2 }, .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 1, 1, 2 }, .{ -1e-8, 1, 1 }, .{ 1e-8, 1, 1 } }) |local| {
                const p = e.add(origin, e.scale(local, scale));
                try std.testing.expectEqual(m.containsReference(p), m.contains(p));
            }
        }
    }
}

test "scanline voxelization preserves faces edges partial blocks and canonical pool order" {
    const bytes = try cubeSTL(a);
    defer a.free(bytes);
    for ([_]e.V{ .{ 0, 0, 0 }, .{ 0.013, -0.017, 0.009 }, .{ 10000.013, -9999.983, 0.009 } }) |origin| {
        var m = try mesh.Mesh.parse(a, bytes, 1, origin);
        defer m.deinit();
        const bounds = e.Bounds{ .lo = e.add(origin, .{ -0.125, -0.125, -0.125 }), .hi = e.add(origin, .{ 2.4, 2.4, 2.4 }) };
        var fast = try m.voxelize(a, bounds, 0.25);
        defer fast.deinit();
        try std.testing.expect(m.scanlines > 0);
        try std.testing.expect(m.scanline_fallbacks > 0);
        var scalar = try m.voxelizeMode(a, bounds, 0.25, true);
        defer scalar.deinit();
        for (0..fast.blocks.len) |i| try std.testing.expectEqualSlices(u64, &scalar.bits(i), &fast.bits(i));
        // Imported partial-block slots follow increasing descriptor index.
        var slot: u32 = 0;
        for (fast.blocks) |d| if (d < @import("core.zig").full) {
            try std.testing.expectEqual(slot, d);
            slot += 1;
        };
    }
}

test "collision reports distinguish voxel face contact from proven separation" {
    var g = try e.stock(a, .{ .lo = .{ 0, 0, 0 }, .hi = .{ 1, 1, 1 } }, 1, &.{.{ .box = .{ .lo = .{ 0, 0, 0 }, .hi = .{ 1, 1, 1 } } }});
    defer g.deinit();
    for ([_]f64{ -0.2, -0.1, -0.05, 0.5 }, [_]inspect.Clearance{ .separated_voxel_geometry, .unresolved_voxel_contact, .unresolved_voxel_contact, .occupied_center_contact }) |x, status| {
        const pose = e.Pose{ .position = .{ x, 0.5, 0 } };
        const shape = e.Shape{ .sweep = .{ .tool = .{ .radius = 0.1, .length = 1 }, .a = pose, .b = pose } };
        const contact = try inspect.collision(g, shape);
        try std.testing.expectEqual(status, contact.clearance);
        try std.testing.expectEqual(status == .unresolved_voxel_contact, contact.representation_clearance_uncertain);
        try std.testing.expectEqual(status == .unresolved_voxel_contact, contact.first_unresolved_cell_bounds != null);
    }
    // Both endpoint tools are outside; the continuous sweep intersects the voxel.
    const crossing = e.Shape{ .sweep = .{ .tool = .{ .radius = 0.1, .length = 1 }, .a = .{ .position = .{ -2, 0.5, 0 } }, .b = .{ .position = .{ 2, 0.5, 0 } } } };
    const hit = try inspect.collision(g, crossing);
    try std.testing.expectEqual(inspect.Clearance.occupied_center_contact, hit.clearance);
    try std.testing.expectEqual(@as(u64, 1), hit.occupied_centers);
}

test "defect regions exact face connectivity, block boundaries and deterministic reload" {
    const defects = @import("defects.zig");
    const b = e.Bounds{ .lo = .{ -2, -3, -4 }, .hi = .{ 8, 0, -2 } };
    var stock = try e.stock(a, b, 1, &.{.{ .box = b }});
    defer stock.deinit();
    var target = try e.stock(a, b, 1, &.{.{ .box = b }});
    defer target.deinit();
    // Exhaustively test random small differences against a separate cell flood fill.
    var rng = std.Random.DefaultPrng.init(91823);
    for (0..30) |_| {
        for (0..stock.blocks.len) |i| {
            var sb = stock.validBits(stock.blockCoords(i));
            var tb = target.validBits(target.blockCoords(i));
            for (&sb, &tb) |*s, *t| {
                s.* &= rng.random().int(u64);
                t.* &= rng.random().int(u64);
            }
            try stock.pool.ensureUnusedCapacity(a, 1);
            try target.pool.ensureUnusedCapacity(a, 1);
            stock.blocks[i] = @intCast(stock.pool.items.len);
            stock.pool.appendAssumeCapacity(sb);
            target.blocks[i] = @intCast(target.pool.items.len);
            target.pool.appendAssumeCapacity(tb);
        }
        const regions = try defects.regions(a, stock, target);
        defer a.free(regions);
        var counts: [2]u64 = .{ 0, 0 };
        var visited = [_]bool{false} ** 60;
        var components: usize = 0;
        for (0..2) |kind| {
            @memset(&visited, false);
            for (0..60) |seed| {
                var stack: [60]usize = undefined;
                var top: usize = 0;
                const p = [3]usize{ seed % 10, seed / 10 % 3, seed / 30 };
                const match = if (kind == 0) stock.occupied(p) and !target.occupied(p) else target.occupied(p) and !stock.occupied(p);
                if (visited[seed] or !match) continue;
                components += 1;
                stack[top] = seed;
                top += 1;
                visited[seed] = true;
                var count: u64 = 0;
                var low = p;
                var high = p;
                while (top > 0) {
                    top -= 1;
                    const at = stack[top];
                    count += 1;
                    const pos = [3]usize{ at % 10, at / 10 % 3, at / 30 };
                    for (0..3) |j| {
                        low[j] = @min(low[j], pos[j]);
                        high[j] = @max(high[j], pos[j]);
                    }
                    for (0..3) |axis| for (0..2) |side| {
                        var q = pos;
                        if (side == 0) {
                            if (q[axis] == 0) continue;
                            q[axis] -= 1;
                        } else {
                            q[axis] += 1;
                            if (q[axis] >= stock.n[axis]) continue;
                        }
                        const next = q[0] + 10 * q[1] + 30 * q[2];
                        const hit = if (kind == 0) stock.occupied(q) and !target.occupied(q) else target.occupied(q) and !stock.occupied(q);
                        if (!visited[next] and hit) {
                            visited[next] = true;
                            stack[top] = next;
                            top += 1;
                        }
                    };
                }
                var found = false;
                for (regions) |r| {
                    if (@intFromEnum(r.kind) != kind or r.voxels != count) continue;
                    var matches = true;
                    for (0..3) |j| {
                        matches = matches and r.bounds.lo[j] == b.lo[j] + @as(f64, @floatFromInt(low[j])) and r.bounds.hi[j] == b.lo[j] + @as(f64, @floatFromInt(high[j] + 1));
                    }
                    found = found or matches;
                }
                try std.testing.expect(found);
                counts[kind] += count;
            }
        }
        try std.testing.expectEqual(components, regions.len);
        var actual: [2]u64 = .{ 0, 0 };
        for (regions) |r| {
            actual[@intFromEnum(r.kind)] += r.voxels;
            try std.testing.expect(r.operation == null);
        }
        try std.testing.expectEqualSlices(u64, &counts, &actual);
        const bytes = try state.encode(a, stock);
        defer a.free(bytes);
        var reloaded = try state.decode(a, bytes);
        defer reloaded.deinit();
        const again = try defects.regions(a, reloaded, target);
        defer a.free(again);
        try std.testing.expectEqualDeep(regions, again);
    }
}

fn allocationDefects(allocator: std.mem.Allocator, stock: @import("core.zig").Grid, target: @import("core.zig").Grid) !void {
    const r = try @import("defects.zig").regions(allocator, stock, target);
    defer allocator.free(r);
}
test "defect extraction allocation failures preserve inputs" {
    const b = e.Bounds{ .lo = .{ 0, 0, 0 }, .hi = .{ 10, 3, 2 } };
    var stock = try e.stock(a, b, 1, &.{.{ .box = b }});
    defer stock.deinit();
    var target = try e.stock(a, b, 1, &.{.{ .sphere = .{ .center = .{ 2, 1, 1 }, .radius = 1 } }});
    defer target.deinit();
    const before = try state.encode(a, stock);
    defer a.free(before);
    try std.testing.checkAllAllocationFailures(a, allocationDefects, .{ stock, target });
    const after = try state.encode(a, stock);
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
    target.origin[0] = 1;
    try std.testing.expectError(error.GridMismatch, @import("defects.zig").regions(a, stock, target));
}

test "final surface exposure IDs match independent per-cell removal chronology" {
    const provenance = @import("provenance.zig");
    const b = e.Bounds{ .lo = .{ -2, -1, -1 }, .hi = .{ 8, 4, 3 } };
    var g = try e.stock(a, b, 1, &.{.{ .box = b }});
    defer g.deinit();
    var deltas: std.ArrayList([]u8) = .empty;
    defer {
        for (deltas.items) |d| a.free(d);
        deltas.deinit(a);
    }
    var when = [_]u32{0} ** 200;
    var changes: e.Changes = .{};
    defer changes.deinit(a);
    var rng = std.Random.DefaultPrng.init(841);
    for (0..20) |op| {
        const center = e.V{ rng.random().float(f64) * 10 - 2, rng.random().float(f64) * 5 - 1, rng.random().float(f64) * 4 - 1 };
        try e.subtract(&g, .{ .primitive = .{ .sphere = .{ .center = center, .radius = 1.4 } } }, &changes, false);
        try deltas.append(a, try a.dupe(u8, changes.bytes.items));
        for (0..200) |i| if (when[i] == 0 and !g.occupied(.{ i % 10, i / 10 % 5, i / 50 })) {
            when[i] = @intCast(op + 1);
        };
    }
    var index = try provenance.Index.init(a, g);
    defer index.deinit();
    for (deltas.items, 0..) |delta, op| try index.consume(delta, @intCast(op + 1), @intCast(op % 3 + 1));
    index.sort();
    var expected: usize = 0;
    for (0..200) |i| {
        if (when[i] == 0) continue;
        const p = [3]usize{ i % 10, i / 10 % 5, i / 50 };
        var adjacent = false;
        for (0..3) |axis| for (0..2) |side| {
            var q = p;
            if (side == 0) {
                if (q[axis] == 0) continue;
                q[axis] -= 1;
            } else {
                q[axis] += 1;
                if (q[axis] >= g.n[axis]) continue;
            }
            adjacent = adjacent or g.occupied(q);
        };
        if (!adjacent) continue;
        try std.testing.expectEqual(@as(u64, @intCast(i)), index.entries.items[expected].cell);
        try std.testing.expectEqual(when[i], index.entries.items[expected].operation);
        try std.testing.expectEqual((when[i] - 1) % 3 + 1, index.entries.items[expected].tool);
        expected += 1;
    }
    try std.testing.expect(expected > 0);
    try std.testing.expectEqual(expected, index.entries.items.len);
    try std.testing.expectError(error.CorruptHistory, index.consume(&.{ 1, 2 }, index.last_operation + 1, 0));
    try std.testing.expectError(error.InvalidOperationId, index.consume(&.{}, 0, 0));
    try std.testing.expectError(error.InvalidOperationId, index.consume(&.{}, index.last_operation, 0));
}

fn provenanceAllocations(allocator: std.mem.Allocator, g: @import("core.zig").Grid, delta: []const u8) !void {
    var index = try @import("provenance.zig").Index.init(allocator, g);
    defer index.deinit();
    try index.consume(delta, 1, 1);
    index.sort();
}
test "provenance allocation failures leave authoritative stock unchanged" {
    const b = e.Bounds{ .lo = .{ 0, 0, 0 }, .hi = .{ 10, 3, 3 } };
    var g = try e.stock(a, b, 1, &.{.{ .box = b }});
    defer g.deinit();
    var changes: e.Changes = .{};
    defer changes.deinit(a);
    try e.subtract(&g, .{ .primitive = .{ .sphere = .{ .center = .{ 8, 1, 1 }, .radius = 1.4 } } }, &changes, false);
    const before = try state.encode(a, g);
    defer a.free(before);
    try std.testing.checkAllAllocationFailures(a, provenanceAllocations, .{ g, changes.bytes.items });
    const after = try state.encode(a, g);
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
}

test "XYZAC cylinder continuous coverage and independent sampled distance envelope" {
    const m = @import("motion.zig");
    const tool = e.Tool{ .radius = 1.1, .length = 0.7 };
    const input = m.RotaryLine{ .a = .{ .position = .{ -0.2, 0.1, 0.2 }, .a_deg = 18, .c_deg = -30 }, .b = .{ .position = .{ 0.3, -0.1, 0.1 }, .a_deg = 79, .c_deg = 75 } };
    const plan = try m.rotary(a, tool, input, 0.08);
    defer plan.deinit(a);
    try std.testing.expect(plan.over_removal_bound_mm <= 0.08 + 1e-14);
    const shape = e.Shape{ .path = plan.segments };
    // Independent inverse Euler matrix and finite-cylinder Euclidean distance.
    // Dense temporal samples validate coverage; time Lipschitz bound brackets
    // the missed minimum between oracle samples (not a certified FP proof).
    const samples = 512;
    const lipschitz = e.norm(e.sub(input.b.position, input.a.position)) +
        @sqrt(1.1 * 1.1 + 0.35 * 0.35) * (61.0 + 105.0) * std.math.pi / 180.0;
    var rng = std.Random.DefaultPrng.init(0x2121);
    for (0..1000) |_| {
        var p: e.V = undefined;
        for (&p) |*v| v.* = rng.random().float(f64) * 3 - 1.5;
        var best: f64 = std.math.inf(f64);
        for (0..samples + 1) |i| {
            const t = @as(f64, @floatFromInt(i)) / samples;
            const angle_a = (18 + 61 * t) * std.math.pi / 180.0;
            const angle_c = (-30 + 105 * t) * std.math.pi / 180.0;
            const x = p[0] - (-0.2 + 0.5 * t);
            const y = p[1] - (0.1 - 0.2 * t);
            const z = p[2] - (0.2 - 0.1 * t);
            const xx = @cos(angle_c) * x + @sin(angle_c) * y;
            const yy = -@sin(angle_c) * x + @cos(angle_c) * y;
            const local_y = @cos(angle_a) * yy + @sin(angle_a) * z;
            const local_z = -@sin(angle_a) * yy + @cos(angle_a) * z;
            const dr = @sqrt(xx * xx + local_y * local_y) - 1.1;
            const dz = @abs(local_z) - 0.35;
            const d = @sqrt(@max(dr, 0) * @max(dr, 0) + @max(dz, 0) * @max(dz, 0)) + @min(@max(dr, dz), 0);
            best = @min(best, d);
        }
        if (best <= 0) try std.testing.expect(shape.contains(p));
        if (shape.contains(p)) try std.testing.expect(best <= plan.over_removal_bound_mm + lipschitz / (2 * samples) + 1e-9);
    }
    const reverse = try m.rotary(a, tool, .{ .a = input.b, .b = input.a }, 0.08);
    defer reverse.deinit(a);
    const bounds = e.Bounds{ .lo = .{ -2, -2, -2 }, .hi = .{ 2, 2, 2 } };
    var g = try e.stock(a, bounds, 0.2, &.{.{ .box = bounds }});
    defer g.deinit();
    var r = try e.stock(a, bounds, 0.2, &.{.{ .box = bounds }});
    defer r.deinit();
    var changes: e.Changes = .{};
    defer changes.deinit(a);
    try e.subtract(&g, shape, &changes, false);
    try e.subtract(&r, shape, &changes, true);
    for (0..g.blocks.len) |i| try std.testing.expectEqualSlices(u64, &g.bits(i), &r.bits(i));
    for (0..20) |z| for (0..20) |y| for (0..20) |x| {
        const p: e.V = .{ -1.9 + @as(f64, @floatFromInt(x)) * 0.2, -1.9 + @as(f64, @floatFromInt(y)) * 0.2, -1.9 + @as(f64, @floatFromInt(z)) * 0.2 };
        try std.testing.expectEqual(shape.contains(p), (e.Shape{ .path = reverse.segments }).contains(p));
    };
}

test "XYZAC stationary exact cylinder, unwrapped turns, limits and allocation failure" {
    const m = @import("motion.zig");
    const p = m.XYZAC{ .position = .{ 1, 2, 3 }, .a_deg = 90, .c_deg = 90 };
    const tool = e.Tool{ .radius = 2, .length = 1 };
    const plan = try m.rotary(a, tool, .{ .a = p, .b = p }, 0.01);
    defer plan.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), plan.segments.len);
    try std.testing.expectEqual(@as(f64, 0), plan.over_removal_bound_mm);
    try std.testing.expectApproxEqAbs(@as(f64, 1), p.axis()[0], 1e-12);
    const end = m.XYZAC{ .position = p.position, .a_deg = 90, .c_deg = 450 };
    const turn = try m.rotary(a, tool, .{ .a = p, .b = end }, 0.1);
    defer turn.deinit(a);
    try std.testing.expect(turn.segments.len > 100);
    try std.testing.expectError(error.MotionToleranceTooSmall, m.rotary(a, tool, .{ .a = p, .b = end }, 1e-12));
    try std.testing.expectError(error.RotaryRequiresWheel, m.rotary(a, .{ .kind = .ball, .radius = 1, .length = 2 }, .{ .a = p, .b = p }, 0.1));
    try std.testing.expectError(error.OutOfMemory, m.rotary(std.testing.failing_allocator, tool, .{ .a = p, .b = p }, 0.1));
}

test "rotary pure rotation covers intermediate poses and split curves within bound" {
    const m = @import("motion.zig");
    const tool = e.Tool{ .radius = 1.1, .length = 0.2 };
    const line = m.RotaryLine{ .a = .{ .position = .{ 0, 0, 0 }, .a_deg = 0, .c_deg = 0 }, .b = .{ .position = .{ 0, 0, 0 }, .a_deg = 180, .c_deg = 0 } };
    const plan = try m.rotary(a, tool, line, 0.02);
    defer plan.deinit(a);
    const first = try m.rotary(a, tool, .{ .a = line.a, .b = line.at(0.5) }, 0.02);
    defer first.deinit(a);
    const second = try m.rotary(a, tool, .{ .a = line.at(0.5), .b = line.b }, 0.02);
    defer second.deinit(a);
    // A half turn of this centered disc contains the radius-1.1 ball, including
    // yz diagonal points missed by stamping only the two endpoint discs.
    for (0..100) |i| {
        const angle = @as(f64, @floatFromInt(i)) * 2 * std.math.pi / 100;
        const p: e.V = .{ 0, @cos(angle), @sin(angle) };
        try std.testing.expect((e.Shape{ .path = plan.segments }).contains(p));
        try std.testing.expect((e.Shape{ .path = first.segments }).contains(p) or (e.Shape{ .path = second.segments }).contains(p));
        const outside: e.V = .{ 0, @cos(angle) * 1.2, @sin(angle) * 1.2 };
        try std.testing.expect(!(e.Shape{ .path = plan.segments }).contains(outside));
    }
    // Splitting may change subdivision/dilation, so voxel-exact equality is not
    // promised for general split inputs; both retain the same declared bound.
    const tiny = try m.rotary(a, tool, .{ .a = line.a, .b = .{ .position = .{ 1e-12, 0, 0 }, .a_deg = 1e-10, .c_deg = -1e-10 } }, 0.02);
    defer tiny.deinit(a);
    try std.testing.expect(tiny.over_removal_bound_mm < 1e-10);
    try std.testing.expect((e.Shape{ .path = tiny.segments }).contains(.{ 0, 0, 0 }));
}

test "rotational profile caps, axis, nonconvex waist and invalid input" {
    const profile = e.Tool{ .kind = .profile, .radius = 1, .length = 2, .profile = &.{ .{ .z = 0, .radius = 1 }, .{ .z = 1, .radius = 0.4 }, .{ .z = 2, .radius = 1 } } };
    try profile.validate();
    // Independent piecewise analytic membership, including a reentrant waist.
    for (0..41) |iz| for (0..31) |ir| {
        const z = -0.5 + @as(f64, @floatFromInt(iz)) * 0.075;
        const r = @as(f64, @floatFromInt(ir)) * 0.05;
        const radius = 0.4 + 0.6 * @abs(z - 1);
        if (@abs(r - radius) < 1e-12 or @abs(z) < 1e-12 or @abs(z - 2) < 1e-12) continue;
        try std.testing.expectEqual(z >= 0 and z <= 2 and r < radius, profile.distance(r, z) < 0);
    };
    try std.testing.expectApproxEqAbs(-0.4, profile.distance(0, 1), 1e-12);
    try std.testing.expectApproxEqAbs(-0.1, profile.distance(0, 0.1), 1e-12);
    try std.testing.expectApproxEqAbs(0.5, profile.distance(0, -0.5), 1e-12);
    try std.testing.expectApproxEqAbs(0.5, profile.distance(1.3, -0.4), 1e-12);
    try std.testing.expectApproxEqAbs(0, profile.distance(0.4, 1), 1e-12);
    for ([_][]const e.ProfilePoint{
        &.{},                                                      &.{.{ .z = 0, .radius = 1 }},
        &.{ .{ .z = 0, .radius = 1 }, .{ .z = 0, .radius = 1 } },  &.{ .{ .z = 0.1, .radius = 1 }, .{ .z = 2, .radius = 1 } },
        &.{ .{ .z = 0, .radius = -1 }, .{ .z = 2, .radius = 1 } }, &.{ .{ .z = 0, .radius = 1 }, .{ .z = 2, .radius = std.math.nan(f64) } },
    }) |points| {
        var bad = profile;
        bad.profile = points;
        try std.testing.expectError(error.InvalidToolProfile, bad.validate());
    }
    var bad = profile;
    bad.kind = .flat;
    try std.testing.expectError(error.InvalidToolProfile, bad.validate());
}

test "XYZAC profile continuous coverage against independent cylinder oracle" {
    const m = @import("motion.zig");
    const tool = e.Tool{ .kind = .profile, .radius = 1.1, .length = 0.7, .profile = &.{ .{ .z = 0, .radius = 1.1 }, .{ .z = 0.7, .radius = 1.1 } } };
    const input = m.RotaryLine{ .a = .{ .position = .{ -0.2, 0.1, 0.2 }, .a_deg = 18, .c_deg = -30 }, .b = .{ .position = .{ 0.3, -0.1, 0.1 }, .a_deg = 79, .c_deg = 75 } };
    const plan = try m.rotary(a, tool, input, 0.08);
    defer plan.deinit(a);
    try std.testing.expect(plan.over_removal_bound_mm <= 0.08 + 1e-12);
    const shape = e.Shape{ .path = plan.segments };
    var rng = std.Random.DefaultPrng.init(0x2122);
    const samples = 512;
    const speed: f64 = @sqrt(0.3) + @sqrt(1.1 * 1.1 + 0.35 * 0.35) * 166 * std.math.pi / 180.0;
    for (0..400) |_| {
        const p: e.V = .{ rng.random().float(f64) * 3 - 1.5, rng.random().float(f64) * 3 - 1.5, rng.random().float(f64) * 3 - 1.5 };
        var best = std.math.inf(f64);
        for (0..samples + 1) |i| {
            const t = @as(f64, @floatFromInt(i)) / samples;
            const aa = (18 + 61 * t) * std.math.pi / 180;
            const cc = (-30 + 105 * t) * std.math.pi / 180;
            const x = p[0] + 0.2 - 0.5 * t;
            const y = p[1] - 0.1 + 0.2 * t;
            const z = p[2] - 0.2 + 0.1 * t;
            const xx = @cos(cc) * x + @sin(cc) * y;
            const yy = -@sin(cc) * x + @cos(cc) * y;
            const local_y = @cos(aa) * yy + @sin(aa) * z;
            const local_z = -@sin(aa) * yy + @cos(aa) * z;
            const dr = @sqrt(xx * xx + local_y * local_y) - 1.1;
            const dz = @abs(local_z) - 0.35;
            best = @min(best, @sqrt(@max(dr, 0) * @max(dr, 0) + @max(dz, 0) * @max(dz, 0)) + @min(@max(dr, dz), 0));
        }
        if (best <= 0) try std.testing.expect(shape.contains(p));
        if (shape.contains(p)) try std.testing.expect(best <= plan.over_removal_bound_mm + speed / (2 * samples) + 1e-9);
    }
    try std.testing.expectError(error.OutOfMemory, m.rotary(std.testing.failing_allocator, tool, input, 0.08));
}

test "waisted profile motion has independent sampled surface envelope and split coverage" {
    const m = @import("motion.zig");
    const tool = e.Tool{ .kind = .profile, .radius = 1, .length = 2, .profile = &.{ .{ .z = 0, .radius = 1 }, .{ .z = 1, .radius = 0.4 }, .{ .z = 2, .radius = 1 } } };
    const input = m.RotaryLine{ .a = .{ .position = .{ 0, 0, 0 }, .a_deg = 0, .c_deg = 0 }, .b = .{ .position = .{ 0.3, 0, 0 }, .a_deg = 90, .c_deg = 60 } };
    const plan = try m.rotary(a, tool, input, 0.08);
    defer plan.deinit(a);
    const left = try m.rotary(a, tool, .{ .a = input.a, .b = input.at(0.5) }, 0.08);
    defer left.deinit(a);
    const right = try m.rotary(a, tool, .{ .a = input.at(0.5), .b = input.b }, 0.08);
    defer right.deinit(a);
    const shape = e.Shape{ .path = plan.segments };
    var rng = std.Random.DefaultPrng.init(0x2123);
    for (0..160) |_| {
        const p: e.V = .{ rng.random().float(f64) * 3 - 1.5, rng.random().float(f64) * 3 - 1.5, rng.random().float(f64) * 3 - 1.5 };
        var best = std.math.inf(f64);
        for (0..129) |i| {
            const t = @as(f64, @floatFromInt(i)) / 128;
            const aa = t * std.math.pi / 2;
            const cc = t * std.math.pi / 3;
            const x = p[0] - 0.3 * t;
            const xx = @cos(cc) * x + @sin(cc) * p[1];
            const yy = -@sin(cc) * x + @cos(cc) * p[1];
            const y = @cos(aa) * yy + @sin(aa) * p[2];
            const z = -@sin(aa) * yy + @cos(aa) * p[2];
            const r = @sqrt(xx * xx + y * y);
            if (@abs(z) <= 1 and r <= 0.4 + 0.6 * @abs(z)) {
                try std.testing.expect(shape.contains(p));
                try std.testing.expect((e.Shape{ .path = left.segments }).contains(p) or (e.Shape{ .path = right.segments }).contains(p));
                best = 0;
                break;
            }
            // Independently sample the analytic meridian, not Tool.distance.
            for (0..129) |k| {
                const zz = -1 + @as(f64, @floatFromInt(k)) / 64;
                const rr = 0.4 + 0.6 * @abs(zz);
                best = @min(best, @sqrt((r - rr) * (r - rr) + (z - zz) * (z - zz)));
            }
            const cap_r = @max(0, r - 1);
            best = @min(best, @sqrt(cap_r * cap_r + (@abs(z) - 1) * (@abs(z) - 1)));
        }
        const time_error: f64 = (0.3 + @sqrt(2.0) * 150 * std.math.pi / 180.0) / 256.0;
        const surface_error = @sqrt(@as(f64, 1.36)) / 128;
        if (shape.contains(p)) try std.testing.expect(best <= plan.over_removal_bound_mm + time_error + surface_error + 1e-9);
    }
}

fn playbackIndexAllocation(g: @import("core.zig").Grid, bytes: []const u8, alloc: std.mem.Allocator) !void {
    var index = @import("provenance.zig").Index.initAllFrames(alloc, g);
    defer index.deinit();
    try index.consumeFrame(g, bytes, 1, 1);
    index.sort();
    try std.testing.expect(index.entries.items.len > 0);
}

test "playback exposure allocation and explicit limit preserve authoritative stock" {
    const bounds = e.Bounds{ .lo = .{ -1, -1, -1 }, .hi = .{ 2.4, 2.8, 1.6 } };
    var g = try e.stock(a, bounds, 0.2, &.{.{ .box = bounds }});
    defer g.deinit();
    var changes: e.Changes = .{};
    defer changes.deinit(a);
    try e.subtract(&g, .{ .primitive = .{ .box = .{ .lo = .{ -0.7, -0.5, -0.3 }, .hi = .{ 1.5, 1.6, 1.3 } } } }, &changes, false);
    const before = try @import("state.zig").encode(a, g);
    defer a.free(before);
    try std.testing.checkAllAllocationFailures(a, struct {
        fn run(alloc: std.mem.Allocator, grid: @import("core.zig").Grid, bytes: []const u8) !void {
            try playbackIndexAllocation(grid, bytes, alloc);
        }
    }.run, .{ g, changes.bytes.items });
    var limited = @import("provenance.zig").Index.initAllFrames(a, g);
    defer limited.deinit();
    limited.max_entries = 0;
    try std.testing.expectError(error.ProvenanceTooLarge, limited.consumeFrame(g, changes.bytes.items, 1, 1));
    const after = try @import("state.zig").encode(a, g);
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
}

test "tilted cutter bounds and cylinder rejection preserve exhaustive subtraction" {
    const profiles = [_][]const e.ProfilePoint{
        &.{ .{ .z = 0, .radius = 1 }, .{ .z = 0.3, .radius = 1.2 }, .{ .z = 0.7, .radius = 1 } },
        &.{ .{ .z = 0, .radius = 1.2 }, .{ .z = 0.4, .radius = 0.2 }, .{ .z = 0.7, .radius = 1.2 } },
    };
    var rng = std.Random.DefaultPrng.init(0x43987);
    for (0..12) |trial| {
        const tool = e.Tool{ .kind = .profile, .radius = 1.2, .length = 0.7, .profile = profiles[trial % 2] };
        var axis: e.V = undefined;
        for (&axis) |*v| v.* = rng.random().float(f64) * 2 - 1;
        axis = e.scale(axis, 1 / e.norm(axis));
        const sweep = e.Sweep{ .tool = tool, .a = .{ .position = .{ -0.2, 0.1, -0.1 }, .axis = axis }, .b = .{ .position = .{ 0.3, -0.2, 0.2 }, .axis = axis }, .tolerance_mm = 0.08, .dilation_mm = 0.03 };
        try sweep.validate();
        const bounds = e.Bounds{ .lo = .{ -2, -2, -2 }, .hi = .{ 2, 2, 2 } };
        const shape = e.Shape{ .sweep = sweep };
        const tight = shape.cuttingBounds();
        var g = try e.stock(a, bounds, 0.2, &.{.{ .box = bounds }});
        defer g.deinit();
        var r = try e.stock(a, bounds, 0.2, &.{.{ .box = bounds }});
        defer r.deinit();
        var changes: e.Changes = .{};
        defer changes.deinit(a);
        try e.subtract(&g, shape, &changes, false);
        try e.subtract(&r, shape, &changes, true);
        for (0..g.blocks.len) |i| try std.testing.expectEqualSlices(u64, &g.bits(i), &r.bits(i));
        // Independent support-function oracle: an enclosing cylinder's support
        // point in each world-axis direction must be inside the tightened box.
        for (0..3) |k| for ([_]f64{ -1, 1 }) |sign| {
            var radial = e.scale(axis, -sign * axis[k]);
            radial[k] += sign;
            if (e.norm(radial) > 1e-12) radial = e.scale(radial, tool.radius / e.norm(radial));
            for ([_]e.V{ sweep.a.position, sweep.b.position }) |endpoint| {
                var p = e.add(endpoint, radial);
                if (sign * axis[k] > 0) p = e.add(p, e.scale(axis, tool.length));
                p[k] += sign * sweep.errorBound();
                try std.testing.expect(p[k] >= tight.lo[k] and p[k] <= tight.hi[k]);
            }
        };
    }
}

test "temporal envelope grouping matches reference for mixed tools and orientations" {
    const tool = e.Tool{ .kind = .profile, .radius = 1, .length = 1, .profile = &.{ .{ .z = 0, .radius = 1 }, .{ .z = 0.5, .radius = 0.3 }, .{ .z = 1, .radius = 1 } } };
    var sweeps: [19]e.Sweep = undefined;
    for (&sweeps, 0..) |*s, i| {
        const t = @as(f64, @floatFromInt(i)) * 0.03;
        const axis: e.V = .{ @sin(t), 0, @cos(t) };
        s.* = .{ .tool = tool, .a = .{ .position = .{ t, -0.2, 0 }, .axis = axis }, .b = .{ .position = .{ t + 0.02, -0.19, 0.01 }, .axis = axis }, .tolerance_mm = 0.015, .dilation_mm = 0.006 };
    }
    // Force fallback in one group; the other groups exercise changing axes and
    // a nonconvex waist. The final group is shorter than the batching width.
    sweeps[9].tool = .{ .kind = .ball, .radius = 0.6, .length = 1 };
    const bounds = e.Bounds{ .lo = .{ -1.3, -1.4, -0.4 }, .hi = .{ 2, 1.4, 1.6 } };
    var g = try e.stock(a, bounds, 0.17, &.{.{ .box = bounds }});
    defer g.deinit();
    var r = try e.stock(a, bounds, 0.17, &.{.{ .box = bounds }});
    defer r.deinit();
    var changes: e.Changes = .{};
    defer changes.deinit(a);
    try e.subtract(&g, .{ .path = &sweeps }, &changes, false);
    try e.subtract(&r, .{ .path = &sweeps }, &changes, true);
    for (0..g.blocks.len) |i| try std.testing.expectEqualSlices(u64, &g.bits(i), &r.bits(i));
}
