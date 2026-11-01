const std = @import("std");
const e = @import("engine.zig");
const d = @import("raydexel.zig");
const s = @import("profile_sweep.zig");
const a = std.testing.allocator;
const crown = e.Tool{ .kind = .profile, .radius = 2, .length = 2, .profile = &.{ .{ .z = 0, .radius = 1 }, .{ .z = 0.8, .radius = 2 }, .{ .z = 1.2, .radius = 2 }, .{ .z = 2, .radius = 1 } } };
fn interval(actual: ?d.Interval, lo: f64, hi: f64) !void {
    try std.testing.expect(actual != null);
    try std.testing.expectApproxEqAbs(lo, actual.?.lo, 1e-9);
    try std.testing.expectApproxEqAbs(hi, actual.?.hi, 1e-9);
}
test "continuous finite cylinder sweeps have independent analytic intervals" {
    const p = try d.Profile.init(a, .{ .kind = .profile, .radius = 2, .length = 2, .profile = &.{ .{ .z = 0, .radius = 2 }, .{ .z = 2, .radius = 2 } } });
    defer p.deinit();
    var rims: [8]s.Rim = undefined;
    var planes: [16]s.Plane = undefined;
    const limits = d.Interval{ .lo = -100, .hi = 100 };
    const axial = try s.Sweep.init(p, .{ .position = .{ 0, 0, 0 } }, .{ 0, 0, 3 }, 0, &rims, &planes);
    try interval(try axial.ray(p, .{ 0, 0, -1 }, .{ 0, 0, 1 }, limits), 1, 6);
    const transverse = try s.Sweep.init(p, .{ .position = .{ 0, 0, 0 } }, .{ 4, 0, 0 }, 0, &rims, &planes);
    try interval(try transverse.ray(p, .{ -5, 0, 1 }, .{ 1, 0, 0 }, limits), 3, 11);
    try interval(try transverse.ray(p, .{ -5, 1, 1 }, .{ 1, 0, 0 }, limits), 5 - @sqrt(@as(f64, 3)), 9 + @sqrt(@as(f64, 3)));
    // Neither endpoint tool intersects this ray. A sphere/capsule substitute
    // would give a different axial interval from the finite cylinder.
    const diagonal = try s.Sweep.init(p, .{ .position = .{ 0, 0, 0 } }, .{ 20, 0, 5 }, 0, &rims, &planes);
    try interval(try diagonal.ray(p, .{ 10, 0, 0 }, .{ 0, 0, 1 }, limits), 2, 5);
    try interval(try diagonal.ray(p, .{ 10, 0, 0 }, .{ 0, 0, 1 }, .{ .lo = 3, .hi = 4 }), 3, 4);
}
test "continuous crown boundary construction agrees with reverse motion oracle" {
    const p = try d.Profile.init(a, crown);
    defer p.deinit();
    var random = std.Random.DefaultPrng.init(73582);
    const rng = random.random();
    var rims: [8]s.Rim = undefined;
    var planes: [16]s.Plane = undefined;
    for (0..300) |case| {
        const axis = normalize(.{ rng.float(f64) - 0.5, rng.float(f64) - 0.5, rng.float(f64) - 0.5 });
        const from = e.V{ 0.17, -0.31, 0.23 };
        var movement = e.V{ 8 * rng.float(f64) - 4, 8 * rng.float(f64) - 4, 8 * rng.float(f64) - 4 };
        if (case == 0) movement = .{ 0, 0, 0 };
        if (case == 1) movement = e.scale(axis, 3);
        if (case == 2) movement = e.scale(movement, 1e-12);
        const sweep = try s.Sweep.init(p, .{ .position = from, .axis = axis }, e.add(from, movement), 0.013, &rims, &planes);
        for (0..20) |_| {
            const origin = e.V{ rng.float(f64) * 8 - 4, rng.float(f64) * 8 - 4, rng.float(f64) * 8 - 4 };
            const direction = normalize(.{ rng.float(f64) - 0.5, rng.float(f64) - 0.5, rng.float(f64) - 0.5 });
            const hit = try sweep.ray(p, origin, direction, .{ .lo = -10, .hi = 10 });
            if (hit) |h| if (h.hi - h.lo > 1e-8) {
                const outer = try sweep.rayEnvelope(p, origin, direction, .{ .lo = -10, .hi = 10 }, &.{.{ .lo = -10, .hi = 10 }});
                try std.testing.expect(outer != null);
                try std.testing.expect(outer.?.lo <= h.lo + 1e-9);
                try std.testing.expect(outer.?.hi >= h.hi - 1e-9);
            };
            for (0..81) |i| {
                const t = -10 + @as(f64, @floatFromInt(i)) / 4;
                const actual = if (hit) |h| t >= h.lo and t <= h.hi else false;
                try std.testing.expectEqual(try sweep.containsReference(p, e.add(origin, e.scale(direction, t))), actual);
            }
            if (hit) |h| if (h.hi - h.lo > 1e-6) {
                try std.testing.expect(try sweep.containsReference(p, e.add(origin, e.scale(direction, h.lo + 1e-7))));
                try std.testing.expect(try sweep.containsReference(p, e.add(origin, e.scale(direction, h.hi - 1e-7))));
                try std.testing.expect(!try sweep.containsReference(p, e.add(origin, e.scale(direction, h.lo - 1e-7))));
                try std.testing.expect(!try sweep.containsReference(p, e.add(origin, e.scale(direction, h.hi + 1e-7))));
            };
        }
    }
}

fn normalize(v: e.V) e.V {
    return e.scale(v, 1 / e.norm(v));
}

test "continuous profile reversals splits tilted tangencies and near transverse movement" {
    const p = try d.Profile.init(a, crown);
    defer p.deinit();
    var rims: [4][8]s.Rim = undefined;
    var planes: [4][16]s.Plane = undefined;
    for ([_]e.V{ .{ 4, 0, 0 }, .{ 4, 0, 1e-14 }, .{ 2.5, 0, 2 }, .{ 0, 0, 4 }, .{ 1e-12, 2e-12, -1e-12 }, .{ 0, 0, 0 } }) |move| {
        const from = e.V{ 0, 0, 0 };
        const mid = e.scale(move, 0.5);
        const whole = try s.Sweep.init(p, .{ .position = from }, move, 0, &rims[0], &planes[0]);
        const reverse = try s.Sweep.init(p, .{ .position = move }, from, 0, &rims[1], &planes[1]);
        const first = try s.Sweep.init(p, .{ .position = from }, mid, 0, &rims[2], &planes[2]);
        const second = try s.Sweep.init(p, .{ .position = mid }, move, 0, &rims[3], &planes[3]);
        for (0..21) |ix| for (0..21) |iz| {
            const origin = e.V{ @as(f64, @floatFromInt(ix)) * 0.3 - 2, -5, @as(f64, @floatFromInt(iz)) * 0.3 - 1 };
            const direction = e.V{ 0, 1, 0 };
            const limits = d.Interval{ .lo = -10, .hi = 10 };
            const hit = try whole.ray(p, origin, direction, limits);
            const back = try reverse.ray(p, origin, direction, limits);
            const h1 = try first.ray(p, origin, direction, limits);
            const h2 = try second.ray(p, origin, direction, limits);
            if (hit) |h| {
                if (h.hi - h.lo < 1e-6) {
                    try std.testing.expect(back != null);
                    try std.testing.expectApproxEqAbs(h.lo, back.?.lo, 2e-7);
                    try std.testing.expectApproxEqAbs(h.hi, back.?.hi, 2e-7);
                } else try interval(back, h.lo, h.hi);
                try std.testing.expect(h1 != null or h2 != null);
                const combined = if (h1) |x| if (h2) |y| d.Interval{ .lo = @min(x.lo, y.lo), .hi = @max(x.hi, y.hi) } else x else h2.?;
                if (h.hi - h.lo < 1e-6) {
                    try std.testing.expectApproxEqAbs(h.lo, combined.lo, 2e-7);
                    try std.testing.expectApproxEqAbs(h.hi, combined.hi, 2e-7);
                } else try interval(combined, h.lo, h.hi);
            } else {
                try std.testing.expect(back == null);
                try std.testing.expect(h1 == null and h2 == null);
            }
        };
    }
}
const swept = @import("swept_raydexel.zig");
fn pipeline(allocator: std.mem.Allocator) !void {
    const p = try d.Profile.init(allocator, crown);
    defer p.deinit();
    const ops = [_]@import("job.zig").Operation{.{ .id = "cut", .tool = 0, .rotary = .{ .a = .{ .position = .{ 1, 0, 1 }, .a_deg = 10, .c_deg = -10 }, .b = .{ .position = .{ -1, 0, 3 }, .a_deg = 16, .c_deg = 20 } } }};
    var plan = try swept.Plan.init(allocator, p, &ops, 0.02);
    defer plan.deinit();
    try std.testing.expect(plan.bound <= 0.02);
    var tree = try d.Tree.init(allocator, p, plan.proxies);
    defer tree.deinit();
    var fast = try swept.finishRows(allocator, p, &plan, tree, .{ 0, 0, 0 }, 2, 4, 0.4, false, null);
    defer fast.material.deinit();
    var slow = try swept.finishRows(allocator, p, &plan, tree, .{ 0, 0, 0 }, 2, 4, 0.4, true, null);
    defer slow.material.deinit();
    try std.testing.expectEqual(fast.material.intervals.items.len, slow.material.intervals.items.len);
    for (fast.material.intervals.items, slow.material.intervals.items) |x, y| {
        try interval(x, y.lo, y.hi);
    }
}
test "continuous sweep hierarchy matches exhaustive rays and allocation failures clean up" {
    try pipeline(a);
    try std.testing.checkAllAllocationFailures(a, pipeline, .{});
}

test "orientation subdivision covers independently sampled true wheel surface" {
    const p = try d.Profile.init(a, crown);
    defer p.deinit();
    const ops = [_]@import("job.zig").Operation{.{ .id = "cut", .tool = 0, .rotary = .{ .a = .{ .position = .{ 1, 0, 1 }, .a_deg = 80, .c_deg = -20 }, .b = .{ .position = .{ -1, 0, 3 }, .a_deg = 100, .c_deg = 20 } } }};
    var plan = try swept.Plan.init(a, p, &ops, 0.02);
    defer plan.deinit();
    const line = ops[0].rotary.?;
    for (0..101) |it| {
        const t = @as(f64, @floatFromInt(it)) / 100;
        const actual = line.at(t);
        const axis = actual.axis();
        const u = normalize(e.cross(axis, .{ 1, 0, 0 }));
        const v = e.cross(axis, u);
        const index = @min(plan.sweeps.len - 1, @as(usize, @intFromFloat(t * @as(f64, @floatFromInt(plan.sweeps.len)))));
        for (crown.profile) |rim| for (0..24) |ia| {
            const theta = @as(f64, @floatFromInt(ia)) * 2 * std.math.pi / 24;
            const point = e.add(actual.position, e.add(e.scale(axis, rim.z - 1), e.add(e.scale(u, rim.radius * @cos(theta)), e.scale(v, rim.radius * @sin(theta)))));
            try std.testing.expect(try plan.sweeps[index].containsReference(p, point));
        };
    }
    // Over-removal check against a separate Tool.distance evaluation at the
    // same translation time; sampled, not a certified floating-point proof.
    for (plan.sweeps, 0..) |sweep, index| {
        const t = (@as(f64, @floatFromInt(index)) + 0.25) / @as(f64, @floatFromInt(plan.sweeps.len));
        const actual = line.at(t);
        const axis = actual.axis();
        const u = normalize(e.cross(sweep.start.axis, .{ 1, 0, 0 }));
        for (sweep.rims) |rim| {
            const point = e.add(sweep.start.base, e.add(e.scale(sweep.movement, 0.25), e.add(e.scale(sweep.start.axis, rim.z), e.scale(u, rim.radius))));
            const q = e.sub(point, e.sub(actual.position, e.scale(axis, 1)));
            const z = e.dot(q, axis);
            const r = e.norm(e.sub(q, e.scale(axis, z)));
            try std.testing.expect(crown.distance(r, z) <= plan.bound + 1e-10);
        }
    }
}

test "continuous sweeps are byte deterministic across worker counts" {
    const p = try d.Profile.init(a, crown);
    defer p.deinit();
    const ops = [_]@import("job.zig").Operation{.{ .id = "cut", .tool = 0, .rotary = .{ .a = .{ .position = .{ 1, 0, 1 }, .a_deg = 10, .c_deg = -10 }, .b = .{ .position = .{ -1, 0, 3 }, .a_deg = 16, .c_deg = 20 } } }};
    var plan = try swept.Plan.init(a, p, &ops, 0.02);
    defer plan.deinit();
    var tree = try d.Tree.init(a, p, plan.proxies);
    defer tree.deinit();
    var one = try @import("raydexel_parallel.zig").finishContinuous(a, p, &plan, tree, .{ 0, 0, 0 }, 2, 4, 0.2, 1);
    defer one.material.deinit();
    var four = try @import("raydexel_parallel.zig").finishContinuous(a, p, &plan, tree, .{ 0, 0, 0 }, 2, 4, 0.2, 4);
    defer four.material.deinit();
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(one.material.intervals.items), std.mem.sliceAsBytes(four.material.intervals.items));
    try std.testing.expectEqualDeep(one.material.columns.items, four.material.columns.items);
    try std.testing.expectEqualDeep(one.sweep_work, four.sweep_work);
    try std.testing.expectEqualDeep(one.material.work, four.material.work);
}
test "continuous preparation rejects invalid input and insufficient storage" {
    const p = try d.Profile.init(a, crown);
    defer p.deinit();
    var rims: [8]s.Rim = undefined;
    var planes: [16]s.Plane = undefined;
    try std.testing.expectError(error.SweepPreparationCapacity, s.Sweep.init(p, .{ .position = .{ 0, 0, 0 } }, .{ 1, 0, 0 }, 0, rims[0..1], &planes));
    try std.testing.expectError(error.InvalidRayOffset, s.Sweep.init(p, .{ .position = .{ 0, 0, 0 } }, .{ 1, 0, 0 }, -1, &rims, &planes));
    try std.testing.expectError(error.MotionToleranceTooSmall, swept.Plan.init(a, p, &.{}, 0));
    try std.testing.expectError(error.EmptyMotion, swept.Plan.init(a, p, &.{}, 0.01));
    const invalid = [_]@import("job.zig").Operation{.{ .id = "invalid", .tool = 0 }};
    try std.testing.expectError(error.RotaryRayMotionRequired, swept.Plan.init(a, p, &invalid, 0.01));
    // Pure translation must not be subdivided into isolated placements.
    const straight = [_]@import("job.zig").Operation{.{ .id = "long", .tool = 0, .rotary = .{ .a = .{ .position = .{ 0, 0, 0 }, .a_deg = 0, .c_deg = 0 }, .b = .{ .position = .{ 100, 0, 0 }, .a_deg = 0, .c_deg = 0 } } }};
    var plan = try swept.Plan.init(a, p, &straight, 0.01);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), plan.sweeps.len);
}

test "directional sweep enclosures preserve exhaustive material in randomized overlapping jobs" {
    const p = try d.Profile.init(a, crown);
    defer p.deinit();
    var random = std.Random.DefaultPrng.init(493521);
    const rng = random.random();
    for (0..12) |_| {
        var ops: [32]@import("job.zig").Operation = undefined;
        for (&ops) |*op| {
            const from = @import("motion.zig").XYZAC{ .position = .{ rng.float(f64) * 6 - 3, rng.float(f64) * 6 - 3, rng.float(f64) * 6 - 1 }, .a_deg = rng.float(f64) * 180, .c_deg = rng.float(f64) * 360 };
            var to = from;
            to.position = e.add(from.position, .{ rng.float(f64) - 0.5, rng.float(f64) - 0.5, rng.float(f64) - 0.5 });
            to.a_deg += rng.float(f64) * 10 - 5;
            to.c_deg += rng.float(f64) * 10 - 5;
            op.* = .{ .id = "random", .tool = 0, .rotary = .{ .a = from, .b = to } };
        }
        var plan = try swept.Plan.init(a, p, &ops, 0.025);
        defer plan.deinit();
        var tree = try d.Tree.init(a, p, plan.proxies);
        defer tree.deinit();
        var fast = try swept.finishRows(a, p, &plan, tree, .{ 0, 0, 0 }, 2, 4, 0.4, false, null);
        defer fast.material.deinit();
        var slow = try swept.finishRows(a, p, &plan, tree, .{ 0, 0, 0 }, 2, 4, 0.4, true, null);
        defer slow.material.deinit();
        try std.testing.expectEqualDeep(fast.material.columns.items, slow.material.columns.items);
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(fast.material.intervals.items), std.mem.sliceAsBytes(slow.material.intervals.items));
    }
}
