const std = @import("std");
const c = @import("core.zig");
const surf = @import("surface.zig");
const a = std.testing.allocator;
fn equal(g: c.Grid, h: c.Grid) !void {
    try std.testing.expectEqualSlices(usize, &g.n, &h.n);
    for (0..g.blocks.len) |i| try std.testing.expectEqualSlices(u64, &g.bits(i), &h.bits(i));
}
const m = c.Move{ .a = .{ 2, 3, 2 }, .b = .{ 7, 3, 2 }, .radius = 1.3, .length = 8 };
test "initial stock and partial edge blocks, outside queries" {
    var g = try c.Grid.init(a, .{ 9.2, 7.1, 3.0 }, 1);
    defer g.deinit();
    try std.testing.expectEqual(@as(u64, 9 * 7 * 3), g.stats().occupied);
    try std.testing.expect(g.occupied(.{ 8, 6, 2 }));
    try std.testing.expect(!g.occupied(.{ 9, 6, 2 }));
    try std.testing.expect(!g.query(.{ -0.01, 1, 1 }));
    try std.testing.expect(!g.query(.{ std.math.nan(f64), 1, 1 }));
    try std.testing.expectEqual(@as(usize, 0), g.pool.items.len);
}
test "outside, stationary, partial, full block, idempotence" {
    var g = try c.Grid.init(a, .{ 8, 8, 8 }, 1);
    defer g.deinit();
    try g.cut(.{ .a = .{ 50, 50, 0 }, .b = .{ 50, 50, 0 }, .radius = 1, .length = 8 }, false);
    try std.testing.expectEqual(@as(u64, 512), g.stats().occupied);
    const stationary = c.Move{ .a = .{ 4, 4, 0 }, .b = .{ 4, 4, 0 }, .radius = 1, .length = 8 };
    try g.cut(stationary, false);
    const count = g.stats().occupied;
    try std.testing.expect(count < 512 and count > 0);
    try std.testing.expectEqual(@as(usize, 1), g.stats().mixed_blocks);
    try g.cut(stationary, false);
    try std.testing.expectEqual(count, g.stats().occupied);
    try g.cut(.{ .a = .{ 4, 4, 0 }, .b = .{ 4, 4, 0 }, .radius = 20, .length = 8 }, false);
    try std.testing.expectEqual(@as(u64, 0), g.stats().occupied);
    var f = try c.Grid.init(a, .{ 8, 8, 8 }, 1);
    defer f.deinit();
    try f.cut(.{ .a = .{ 4, 4, 0 }, .b = .{ 4, 4, 0 }, .radius = 20, .length = 8 }, false);
    try std.testing.expectEqual(@as(usize, 0), f.pool.items.len);
}
test "reversed and split path and reference" {
    var g = try c.Grid.init(a, .{ 10, 8, 6 }, 0.5);
    defer g.deinit();
    var h = try c.Grid.init(a, .{ 10, 8, 6 }, 0.5);
    defer h.deinit();
    var r = try c.Grid.init(a, .{ 10, 8, 6 }, 0.5);
    defer r.deinit();
    try g.cut(m, false);
    var reverse = m;
    reverse.a = m.b;
    reverse.b = m.a;
    try h.cut(reverse, false);
    try equal(g, h);
    var first = m;
    first.b = .{ 4.5, 3, 2 };
    var second = m;
    second.a = first.b;
    try r.cut(first, false);
    try r.cut(second, false);
    try equal(g, r);
    var scalar = try c.Grid.init(a, .{ 10, 8, 6 }, 0.5);
    defer scalar.deinit();
    try scalar.cut(m, true);
    try equal(g, scalar);
}
test "random movements, scalar and independent exhaustive point oracle" {
    var rng = std.Random.DefaultPrng.init(0x12345678);
    const random = rng.random();
    for (0..35) |_| {
        const h = 0.2 + random.float(f64) * 0.8;
        var g = try c.Grid.init(a, .{ 8.1, 7.3, 5.8 }, h);
        defer g.deinit();
        var r = try c.Grid.init(a, g.size, h);
        defer r.deinit();
        const oracle = try a.alloc(bool, g.n[0] * g.n[1] * g.n[2]);
        defer a.free(oracle);
        @memset(oracle, true);
        for (0..8) |_| {
            const z = random.float(f64) * 9 - 2;
            const move = c.Move{ .a = .{ random.float(f64) * 14 - 3, random.float(f64) * 12 - 2, z }, .b = .{ random.float(f64) * 14 - 3, random.float(f64) * 12 - 2, z }, .radius = 0.01 + random.float(f64) * 4, .length = 0.1 + random.float(f64) * 7 };
            const valid = try move.validated();
            const before = g.stats().occupied;
            try g.cut(move, false);
            try r.cut(move, true);
            try equal(g, r);
            try std.testing.expect(g.stats().occupied <= before);
            for (0..g.n[2]) |iz| for (0..g.n[1]) |iy| for (0..g.n[0]) |ix| {
                const idx = (iz * g.n[1] + iy) * g.n[0] + ix;
                if (valid.contains(.{ g.center(ix), g.center(iy), g.center(iz) })) oracle[idx] = false;
                try std.testing.expectEqual(oracle[idx], g.occupied(.{ ix, iy, iz }));
            };
        }
    }
}
test "invalid parameters and unsupported motion" {
    try std.testing.expectError(error.InvalidVoxelSize, c.Grid.init(a, .{ 1, 1, 1 }, 0));
    try std.testing.expectError(error.InvalidStock, c.Grid.init(a, .{ std.math.inf(f64), 1, 1 }, 1));
    try std.testing.expectError(error.GridTooLargeOrEmpty, c.Grid.init(a, .{ 1, 1, 1 }, 1e-30));
    var g = try c.Grid.init(a, .{ 8, 8, 8 }, 1);
    defer g.deinit();
    var bad = m;
    bad.b[2] += 1;
    try std.testing.expectError(error.UnsupportedMotion, g.cut(bad, false));
    bad = m;
    bad.radius = -1;
    try std.testing.expectError(error.InvalidTool, g.cut(bad, false));
    try std.testing.expectEqual(@as(u64, 512), g.stats().occupied);
}
fn allocationCase(allocator: std.mem.Allocator) !void {
    var g = try c.Grid.init(allocator, .{ 16, 16, 16 }, 1);
    defer g.deinit();
    g.cut(m, false) catch |err| {
        try std.testing.expectEqual(@as(u64, 4096), g.stats().occupied);
        return err;
    };
}
test "allocation failure leaves stock unchanged and leaks nothing" {
    try std.testing.checkAllAllocationFailures(a, allocationCase, .{});
}
test "closed tangency and axial boundary" {
    const t = try (c.Move{ .a = .{ 0.5, 0.5, 0.5 }, .b = .{ 0.5, 0.5, 0.5 }, .radius = 1, .length = 1 }).validated();
    try std.testing.expect(t.contains(.{ 1.5, 0.5, 0.5 }));
    try std.testing.expect(t.contains(.{ 0.5, 0.5, 1.5 }));
    try std.testing.expect(!t.contains(.{ 1.500001, 0.5, 0.5 }));
}
test "mesh omits hidden surfaces and preserves surface area" {
    var g = try c.Grid.init(a, .{ 9, 7, 3 }, 1);
    defer g.deinit();
    var mesh = try surf.generate(a, g);
    defer mesh.deinit(a);
    var area: usize = 0;
    for (mesh.items) |q| area += q.width * q.height;
    try std.testing.expectEqual(@as(usize, 2 * (9 * 7 + 9 * 3 + 7 * 3)), area);
    try g.cut(.{ .a = .{ 4, 3, 1 }, .b = .{ 7, 3, 1 }, .radius = 1, .length = 3 }, false);
    var cutmesh = try surf.generate(a, g);
    defer cutmesh.deinit(a);
    area = 0;
    for (cutmesh.items) |q| area += q.width * q.height;
    var expected: usize = 0;
    for (0..g.n[2]) |z| for (0..g.n[1]) |y| for (0..g.n[0]) |x| {
        const p = [3]usize{ x, y, z };
        if (!g.occupied(p)) continue;
        for (0..3) |axis| {
            var q = p;
            q[axis] += 1;
            if (!g.occupied(q)) expected += 1;
            q = p;
            if (q[axis] == 0) {
                expected += 1;
            } else {
                q[axis] -= 1;
                if (!g.occupied(q)) expected += 1;
            }
        }
    };
    try std.testing.expectEqual(expected, area);
}

test "stock boundary follows center predicate; spatial query follows raster cells" {
    for ([_]f64{ 0.15, 0.25, 0.35, 0.45, 0.51, 0.57, 0.8, 0.81, 0.85, 0.9, 1.0 }) |size| {
        var g = try c.Grid.init(a, .{ size, size, size }, 0.1);
        defer g.deinit();
        var expected: usize = 0;
        while ((@as(f64, @floatFromInt(expected)) + 0.5) * 0.1 < size) expected += 1;
        try std.testing.expectEqual(expected, g.n[0]);
        try std.testing.expectEqual(@as(u64, expected * expected * expected), g.stats().occupied);
    }
    var g = try c.Grid.init(a, .{ 0.57, 0.57, 0.57 }, 0.1);
    defer g.deinit();
    try std.testing.expect(g.query(.{ 0.59, 0.59, 0.59 }));
    try std.testing.expect(!g.query(.{ 0.61, 0.5, 0.5 }));
    try std.testing.expect(!g.query(.{ std.math.floatMax(f64), 0, 0 }));
}

test "example groove has 4 mm depth and no breakthrough" {
    var g = try c.Grid.init(a, .{ 40, 30, 10 }, 0.25);
    defer g.deinit();
    try g.cut(.{ .a = .{ 10, 15, 6 }, .b = .{ 30, 15, 6 }, .radius = 3, .length = 10 }, false);
    try std.testing.expect(g.query(.{ 20, 15, 5.99 }));
    try std.testing.expect(!g.query(.{ 20, 15, 6.01 }));
    try std.testing.expect(g.query(.{ 20, 15, 0.01 }));
    try std.testing.expect(g.query(.{ 20, 2, 9.99 }));
    try std.testing.expectEqual(@as(u64, 730112), g.stats().occupied);
}

test "zero-length and oblique split paths preserve identical occupancy" {
    var g = try c.Grid.init(a, .{ 12, 10, 8 }, 0.25);
    defer g.deinit();
    var r = try c.Grid.init(a, g.size, g.h);
    defer r.deinit();
    const diagonal = c.Move{ .a = .{ 1, 1, 2 }, .b = .{ 9, 7, 2 }, .radius = 1.5, .length = 5 };
    try g.cut(diagonal, false);
    var first = diagonal;
    first.b = .{ 5, 4, 2 };
    var second = diagonal;
    second.a = first.b;
    try r.cut(first, false);
    try r.cut(second, false);
    try equal(g, r);
    var reverse = diagonal;
    reverse.a = diagonal.b;
    reverse.b = diagonal.a;
    var reversed = try c.Grid.init(a, g.size, g.h);
    defer reversed.deinit();
    try reversed.cut(reverse, false);
    try equal(g, reversed);
    const stationary = c.Move{ .a = .{ 4, 3, 1 }, .b = .{ 4, 3, 1 }, .radius = 2.1, .length = 3 };
    try g.cut(stationary, false);
    try r.cut(stationary, true);
    try equal(g, r);
}

const drill = @import("drill.zig");
test "drill capsule matches exhaustive sphere sweep oracle and is idempotent" {
    var g = try c.Grid.init(a, .{ 12, 12, 16 }, 0.5);
    defer g.deinit();
    try drill.apply(&g, .cylinder);
    const op = drill.Operation{ .capsule = .{ .a = .{ 2, 3, 1 }, .b = .{ 10, 9, 15 }, .radius = 2 } };
    const before = g.stats().occupied;
    try drill.apply(&g, op);
    var expected: u64 = 0;
    for (0..g.n[2]) |z| for (0..g.n[1]) |y| for (0..g.n[0]) |x| {
        const p = [3]f64{ g.center(x), g.center(y), g.center(z) };
        const cylinder: drill.Operation = .cylinder;
        const kept = !cylinder.removes(p) and !op.removes(p);
        try std.testing.expectEqual(kept, g.occupied(.{ x, y, z }));
        expected += @intFromBool(kept);
    };
    try std.testing.expect(expected < before);
    try drill.apply(&g, op);
    try std.testing.expectEqual(expected, g.stats().occupied);
    var reverse = op;
    reverse.capsule.a = op.capsule.b;
    reverse.capsule.b = op.capsule.a;
    try drill.apply(&g, reverse);
    try std.testing.expectEqual(expected, g.stats().occupied);
    try std.testing.expectError(error.InvalidTool, drill.apply(&g, .{ .capsule = .{ .a = .{ 0, 0, 0 }, .b = .{ 1, 1, 1 }, .radius = -1 } }));
}
fn drillAllocation(allocator: std.mem.Allocator) !void {
    var g = try c.Grid.init(allocator, .{ 12, 12, 16 }, 0.5);
    defer g.deinit();
    const before = g.stats().occupied;
    drill.apply(&g, .cylinder) catch |err| {
        try std.testing.expectEqual(before, g.stats().occupied);
        return err;
    };
}
test "drill allocation failure is transactional" {
    try std.testing.checkAllAllocationFailures(a, drillAllocation, .{});
}
test "drill sequence preserves shank and core while removing both flutes and tip" {
    var g = try c.Grid.init(a, .{ 12, 12, 60 }, 0.5);
    defer g.deinit();
    try drill.apply(&g, .cylinder);
    var count = g.stats().occupied;
    for (0..2) |flute| for (0..drill.steps) |i| {
        try drill.apply(&g, .{ .capsule = .{ .a = drill.point(flute, @as(f64, @floatFromInt(i)) / drill.steps), .b = drill.point(flute, @as(f64, @floatFromInt(i + 1)) / drill.steps), .radius = drill.cutter_radius } });
        const after = g.stats().occupied;
        try std.testing.expect(after <= count);
        count = after;
    };
    for (0..drill.facets) |i| try drill.apply(&g, .{ .tip = @as(f64, @floatFromInt(i)) / drill.facets * 2 * std.math.pi });
    try std.testing.expect(g.query(.{ 6.25, 6.25, 40.25 }));
    try std.testing.expect(g.query(.{ 11.25, 6.25, 5.25 }));
    try std.testing.expect(!g.query(.{ 11.25, 6.25, 58.25 }));
    for (0..2) |flute| {
        const p = drill.point(flute, 0.5);
        try std.testing.expect(!g.query(p));
    }
    try std.testing.expect(g.stats().occupied < count);
}

const fine = @import("fine.zig");
test "cube-grid block classification agrees with exhaustive material oracle" {
    var g = try fine.cylinder(a, 64);
    defer g.deinit();
    try std.testing.expectEqualSlices(usize, &.{ 64, 64, 64 }, &g.n);
    const oracle = try a.alloc(bool, 64 * 64 * 64);
    defer a.free(oracle);
    const cylinder: drill.Operation = .cylinder;
    for (0..64) |z| for (0..64) |y| for (0..64) |x| {
        const expected = !cylinder.removes(.{ g.center(x) - 24, g.center(y) - 24, g.center(z) });
        oracle[(z * 64 + y) * 64 + x] = expected;
        try std.testing.expectEqual(expected, g.occupied(.{ x, y, z }));
    };
    const ops = [_]drill.Operation{
        .{ .capsule = .{ .a = .{ 1, 2, 10 }, .b = .{ 10, 9, 40 }, .radius = 3.3 } },
        .{ .capsule = .{ .a = .{ 6, 6, 25 }, .b = .{ 6, 6, 25 }, .radius = 4 } },
        .{ .tip = 0.3 },
        .{ .tip = 2.1 },
        .{ .capsule = .{ .a = .{ -20, -20, -20 }, .b = .{ -10, -10, -10 }, .radius = 1 } },
        .{ .capsule = .{ .a = .{ 6, 6, 45 }, .b = .{ 6, 6, 50 }, .radius = 12 } },
    };
    var changes: fine.Changes = .{};
    defer changes.deinit(a);
    for (ops) |op| {
        const before = g.stats().occupied;
        try fine.cut(&g, op, &changes);
        var expected: u64 = 0;
        for (0..64) |z| for (0..64) |y| for (0..64) |x| {
            const i = (z * 64 + y) * 64 + x;
            if (op.removes(.{ g.center(x) - 24, g.center(y) - 24, g.center(z) })) oracle[i] = false;
            try std.testing.expectEqual(oracle[i], g.occupied(.{ x, y, z }));
            expected += @intFromBool(oracle[i]);
        };
        try std.testing.expectEqual(expected, g.stats().occupied);
        try std.testing.expectEqual(before - expected, changes.removed);
    }
}
fn replayTest(g: *c.Grid, bytes: []const u8, forward: bool) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const id = std.mem.readInt(u32, bytes[offset..][0..4], .little);
        const before = std.mem.readInt(u32, bytes[offset + 4 ..][0..4], .little);
        const after = std.mem.readInt(u32, bytes[offset + 8 ..][0..4], .little);
        offset += 12;
        const beforeOffset = offset;
        if (before < c.full) offset += 64;
        const afterOffset = offset;
        if (after < c.full) offset += 64;
        const d = if (forward) after else before;
        g.blocks[id] = d;
        if (d < c.full) {
            const bitsOffset = if (forward) afterOffset else beforeOffset;
            for (0..8) |i| g.pool.items[d][i] = std.mem.readInt(u64, bytes[bitsOffset + i * 8 ..][0..8], .little);
        }
    }
}
test "reversible block history restores exact bits in both directions" {
    var g = try fine.cylinder(a, 128);
    defer g.deinit();
    const initial = try a.alloc(c.Bits, g.blocks.len);
    defer a.free(initial);
    for (initial, 0..) |*bits, i| bits.* = g.bits(i);
    var changes: fine.Changes = .{};
    defer changes.deinit(a);
    try fine.cut(&g, .{ .capsule = .{ .a = .{ 2, 1, 5 }, .b = .{ 10, 11, 55 }, .radius = 3.3 } }, &changes);
    const final = try a.alloc(c.Bits, g.blocks.len);
    defer a.free(final);
    for (final, 0..) |*bits, i| bits.* = g.bits(i);
    replayTest(&g, changes.bytes.items, false);
    for (initial, 0..) |bits, i| try std.testing.expectEqualSlices(u64, &bits, &g.bits(i));
    replayTest(&g, changes.bytes.items, true);
    for (final, 0..) |bits, i| try std.testing.expectEqualSlices(u64, &bits, &g.bits(i));
    try fine.cut(&g, .{ .capsule = .{ .a = .{ 2, 1, 5 }, .b = .{ 10, 11, 55 }, .radius = 3.3 } }, &changes);
    try std.testing.expectEqual(@as(usize, 0), changes.bytes.items.len);
}
fn fineAllocations(allocator: std.mem.Allocator) !void {
    var g = try fine.cylinder(allocator, 64);
    defer g.deinit();
    const before = g.stats().occupied;
    var changes: fine.Changes = .{};
    defer changes.deinit(allocator);
    fine.cut(&g, .{ .capsule = .{ .a = .{ 1, 1, 5 }, .b = .{ 10, 10, 50 }, .radius = 4 } }, &changes) catch |err| {
        try std.testing.expectEqual(before, g.stats().occupied);
        return err;
    };
}
test "fine grid errors and allocation failures" {
    try std.testing.checkAllAllocationFailures(a, fineAllocations, .{});
    try std.testing.expectError(error.GridMustBeMultipleOfEightBetween32And4096, fine.cylinder(a, 4097));
    var g = try fine.cylinder(a, 64);
    defer g.deinit();
    var changes: fine.Changes = .{};
    defer changes.deinit(a);
    try std.testing.expectError(error.InvalidCoordinate, fine.cut(&g, .{ .tip = std.math.nan(f64) }, &changes));
}

test {
    _ = @import("engine_tests.zig");
}

test "block height export matches scalar scan for random partial blocks and cavities" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var g = try c.Grid.init(a, .{ 4.25, 3.75, 5.25 }, 0.25);
    defer g.deinit();
    var rng = std.Random.DefaultPrng.init(92734);
    for (0..4) |pass| {
        for (0..g.blocks.len) |i| {
            if (pass == 0) continue;
            if (pass == 3 or i % 3 == 0) {
                g.blocks[i] = c.empty;
                continue;
            }
            if (i % 3 == 1) continue;
            var bits = g.validBits(g.blockCoords(i));
            for (&bits) |*w| w.* &= rng.random().int(u64);
            g.blocks[i] = @intCast(g.pool.items.len);
            try g.pool.append(a, bits);
        }
        try surf.ppm(a, g, temp.dir);
        const image = try temp.dir.readFileAlloc(a, "height.ppm", 100000);
        defer a.free(image);
        const header = try std.fmt.allocPrint(a, "P6\n{d} {d}\n255\n", .{ g.n[0], g.n[1] });
        defer a.free(header);
        try std.testing.expectEqualStrings(header, image[0..header.len]);
        try std.testing.expectEqual(header.len + g.n[0] * g.n[1] * 3, image.len);
        for (0..g.n[1]) |y| for (0..g.n[0]) |x| {
            var z = g.n[2];
            while (z > 0 and !g.occupied(.{ x, y, z - 1 })) z -= 1;
            const value: u8 = @intFromFloat(255 * @as(f64, @floatFromInt(z)) / @as(f64, @floatFromInt(g.n[2])));
            const offset = header.len + ((g.n[1] - 1 - y) * g.n[0] + x) * 3;
            for (image[offset..][0..3]) |v| try std.testing.expectEqual(value, v);
        };
    }
}

test "boundary voxel and face counts match independent six-neighbor oracle" {
    var g = try c.Grid.init(a, .{ 4.25, 3.75, 5.25 }, 0.25);
    defer g.deinit();
    const box = surf.boundaryCounts(g);
    try std.testing.expectEqual(@as(u64, 17 * 15 * 21 - 15 * 13 * 19), box.surface_voxels);
    try std.testing.expectEqual(@as(u64, 2 * (17 * 15 + 17 * 21 + 15 * 21)), box.exposed_faces);
    var rng = std.Random.DefaultPrng.init(52918);
    for (0..g.blocks.len) |i| {
        var bits = g.bits(i);
        for (&bits) |*w| w.* &= rng.random().int(u64);
        g.blocks[i] = @intCast(g.pool.items.len);
        try g.pool.append(a, bits);
    }
    var expected: surf.BoundaryCounts = .{};
    for (0..g.n[2]) |z| for (0..g.n[1]) |y| for (0..g.n[0]) |x| {
        const p = [3]usize{ x, y, z };
        if (!g.occupied(p)) continue;
        var faces: u64 = 0;
        for (0..3) |axis| {
            var q = p;
            if (p[axis] == 0) {
                faces += 1;
            } else {
                q[axis] -= 1;
                faces += @intFromBool(!g.occupied(q));
            }
            q = p;
            q[axis] += 1;
            faces += @intFromBool(!g.occupied(q));
        }
        expected.exposed_faces += faces;
        expected.surface_voxels += @intFromBool(faces > 0);
    };
    try std.testing.expectEqualDeep(expected, surf.boundaryCounts(g));
    @memset(g.blocks, c.empty);
    try std.testing.expectEqualDeep(surf.BoundaryCounts{}, surf.boundaryCounts(g));
}

test {
    _ = @import("sparse.zig");
}
