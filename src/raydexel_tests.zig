const std = @import("std");
const e = @import("engine.zig");
const d = @import("raydexel.zig");
const a = std.testing.allocator;
const crown = e.Tool{ .kind = .profile, .radius = 2, .length = 2, .profile = &.{ .{ .z = 0, .radius = 1 }, .{ .z = 0.8, .radius = 2 }, .{ .z = 1.2, .radius = 2 }, .{ .z = 2, .radius = 1 } } };
test "analytic crown ray roots caps tangencies and rigid transforms" {
    const profile = try d.Profile.init(a, crown);
    defer profile.deinit();
    const cases = [_]struct { origin: e.V, direction: e.V, expected: ?d.Interval }{
        .{ .origin = .{ 3, 0, 1 }, .direction = .{ -1, 0, 0 }, .expected = .{ .lo = 1, .hi = 5 } },
        .{ .origin = .{ 3, 0, 0.4 }, .direction = .{ -1, 0, 0 }, .expected = .{ .lo = 1.5, .hi = 4.5 } },
        .{ .origin = .{ 1.5, 0, -2 }, .direction = .{ 0, 0, 1 }, .expected = .{ .lo = 2.4, .hi = 3.6 } },
        .{ .origin = .{ 0, 0, -2 }, .direction = .{ 0, 0, 1 }, .expected = .{ .lo = 2, .hi = 4 } },
        .{ .origin = .{ 2, -3, 1 }, .direction = .{ 0, 1, 0 }, .expected = .{ .lo = 3, .hi = 3 } },
        .{ .origin = .{ 3, 0, 4 }, .direction = .{ 0, 0, -1 }, .expected = null },
    };
    for ([_]bool{ false, true }) |rotate| {
        const Transform = struct {
            fn v(point: e.V, yes: bool) e.V {
                return if (yes) .{ point[2], point[0], point[1] } else point;
            }
        };
        const base = e.V{ 3.17, -2.31, 5.19 };
        const pose = try d.Pose.init(profile, .{ .position = base, .axis = Transform.v(.{ 0, 0, 1 }, rotate) }, 0);
        for (cases) |case| {
            const hit = try d.ray(profile, pose, e.add(base, Transform.v(case.origin, rotate)), Transform.v(case.direction, rotate), .{ .lo = 0, .hi = 10 });
            if (case.expected) |expected| {
                try std.testing.expect(hit != null);
                try std.testing.expectApproxEqAbs(expected.lo, hit.?.lo, 1e-7);
                try std.testing.expectApproxEqAbs(expected.hi, hit.?.hi, 1e-7);
            } else try std.testing.expect(hit == null);
        }
    }
}
test "profile miter envelope contains Euclidean dilation and respects analytic distance bound" {
    const profile = try d.Profile.init(a, crown);
    defer profile.deinit();
    const delta = 0.02;
    const pose = try d.Pose.init(profile, .{ .position = .{ 0, 0, 0 } }, delta);
    for (0..401) |iz| {
        const z = -0.1 + @as(f64, @floatFromInt(iz)) * 2.2 / 400;
        const hit = try d.ray(profile, pose, .{ 0, 0, z }, .{ 1, 0, 0 }, .{ .lo = 0, .hi = 3 });
        for (0..401) |ir| {
            const r = @as(f64, @floatFromInt(ir)) * 2.2 / 400;
            const distance = crown.distance(r, z);
            const inside = if (hit) |h| r >= h.lo and r <= h.hi else false;
            if (distance < delta - 1e-12) try std.testing.expect(inside);
            if (inside) try std.testing.expect(distance <= delta * profile.miter + 1e-12);
        }
    }
    const waist = e.Tool{ .kind = .profile, .radius = 2, .length = 2, .profile = &.{ .{ .z = 0, .radius = 2 }, .{ .z = 1, .radius = 1 }, .{ .z = 2, .radius = 2 } } };
    try std.testing.expectError(error.NonconvexProfileUnsupported, d.Profile.init(a, waist));
}
test "continuous intervals retain disconnected pieces and idempotence" {
    var spans: std.ArrayList(d.Interval) = .empty;
    defer spans.deinit(a);
    try spans.ensureTotalCapacity(a, 8);
    spans.appendAssumeCapacity(.{ .lo = 0, .hi = 10 });
    d.subtractIntervals(&spans, .{ .lo = 5, .hi = 5 });
    try std.testing.expectEqual(@as(usize, 1), spans.items.len);
    d.subtractIntervals(&spans, .{ .lo = 2, .hi = 3 });
    d.subtractIntervals(&spans, .{ .lo = 6, .hi = 8 });
    d.subtractIntervals(&spans, .{ .lo = 2, .hi = 3 });
    try std.testing.expectEqual(@as(usize, 3), spans.items.len);
    d.subtractIntervals(&spans, .{ .lo = 2.5, .hi = 7 });
    try std.testing.expectEqual(@as(usize, 2), spans.items.len);
    try std.testing.expectEqual(@as(f64, 2), spans.items[0].hi);
    try std.testing.expectEqual(@as(f64, 8), spans.items[1].lo);
}
fn scenario(allocator: std.mem.Allocator) !void {
    const profile = try d.Profile.init(allocator, crown);
    defer profile.deinit();
    var poses: [24]d.Pose = undefined;
    for (&poses, 0..) |*pose, i| {
        const angle = @as(f64, @floatFromInt(i)) * 0.2;
        pose.* = try d.Pose.init(profile, .{ .position = .{ 1.7 * @cos(angle), 1.7 * @sin(angle), 0.1 * @as(f64, @floatFromInt(i)) }, .axis = .{ @sin(angle), 0, @cos(angle) } }, 0.01);
    }
    var tree = try d.Tree.init(allocator, profile, &poses);
    defer tree.deinit();
    var fast = try d.finishCylinder(allocator, profile, tree, .{ 0, 0, 0 }, 2, 4, 0.4, false);
    defer fast.deinit();
    var slow = try d.finishCylinder(allocator, profile, tree, .{ 0, 0, 0 }, 2, 4, 0.4, true);
    defer slow.deinit();
    try std.testing.expectEqual(fast.columns.items.len, slow.columns.items.len);
    try std.testing.expectEqual(fast.intervals.items.len, slow.intervals.items.len);
    for (fast.intervals.items, slow.intervals.items) |x, y| {
        try std.testing.expectApproxEqAbs(x.lo, y.lo, 1e-9);
        try std.testing.expectApproxEqAbs(x.hi, y.hi, 1e-9);
    }
}
test "ray hierarchy matches exhaustive traversal and allocation failures clean up" {
    try scenario(a);
    try std.testing.checkAllAllocationFailures(a, scenario, .{});
}

test "bounded midpoint conic poses cover independent moving crown surface samples" {
    const motion = @import("motion.zig");
    const profile = try d.Profile.init(a, crown);
    defer profile.deinit();
    const line = motion.RotaryLine{ .a = .{ .position = .{ -0.2, 0.1, 0.3 }, .a_deg = 10, .c_deg = -10 }, .b = .{ .position = .{ 0.4, -0.1, 0.5 }, .a_deg = 16, .c_deg = 20 } };
    var poses: std.ArrayList(d.Pose) = .empty;
    defer poses.deinit(a);
    const bound = try @import("raydexel_motion.zig").append(a, &poses, profile, crown, line, 0.04);
    try std.testing.expect(bound.total_mm <= 0.04);
    for (0..61) |it| {
        const actual = line.at(@as(f64, @floatFromInt(it)) / 60);
        const axis = actual.axis();
        const raw_u = e.cross(axis, .{ 1, 0, 0 });
        const u = e.scale(raw_u, 1 / e.norm(raw_u));
        const v = e.cross(axis, u);
        for ([_]f64{ 0, 0.4, 1, 1.6, 2 }) |z| {
            // Independent closed-form crown radius, not the solver's constraints.
            const radius = @min(@min(1 + 1.25 * z, 2), 3.5 - 1.25 * z);
            for (0..16) |iturn| {
                const angle = @as(f64, @floatFromInt(iturn)) * 2 * std.math.pi / 16;
                const radial = e.add(e.scale(u, radius * @cos(angle)), e.scale(v, radius * @sin(angle)));
                const point = e.add(actual.position, e.add(e.scale(axis, z - 1), radial));
                var covered = false;
                for (poses.items) |pose| {
                    if (try d.ray(profile, pose, point, .{ 0, 0, 1 }, .{ .lo = 0, .hi = 0 }) != null) {
                        covered = true;
                        break;
                    }
                }
                try std.testing.expect(covered);
            }
        }
    }
}

fn adaptiveScenario(allocator: std.mem.Allocator, oracle: bool) !void {
    const adaptive = @import("adaptive_raydexel.zig");
    const motion = @import("motion.zig");
    const jobs = @import("job.zig");
    const profile = try d.Profile.init(allocator, crown);
    defer profile.deinit();
    const line = motion.RotaryLine{ .a = .{ .position = .{ -0.5, 0.2, 1.6 }, .a_deg = 10, .c_deg = -10 }, .b = .{ .position = .{ 0.5, 0.2, 2.4 }, .a_deg = 16, .c_deg = 20 } };
    const operations = [_]jobs.Operation{.{ .id = "cavity", .tool = 0, .rotary = line }};
    var plan = try adaptive.Plan.init(allocator, profile, &operations, 0.025);
    defer plan.deinit();
    var tree = try d.Tree.init(allocator, profile, plan.roots.items);
    defer tree.deinit();
    var result = try adaptive.finish(allocator, profile, &plan, tree, .{ 0, 0, 0 }, 2, 4, 0.4);
    defer result.material.deinit();
    if (!oracle) return;
    try std.testing.expect(result.work.witness_accepts > 0);
    var actual_poses: [129]e.Pose = undefined;
    for (&actual_poses, 0..) |*pose, i| {
        const actual = line.at(@as(f64, @floatFromInt(i)) / 128);
        pose.* = .{ .position = e.sub(actual.position, e.scale(actual.axis(), 1)), .axis = actual.axis() };
    }
    const sample_gap = (e.norm(e.sub(line.b.position, line.a.position)) + @sqrt(@as(f64, 5)) * (6 + 30) * (std.math.pi / 180.0)) / 256;
    for (result.material.columns.items) |col| for (0..41) |iz| {
        const point: e.V = .{ -2 + (@as(f64, @floatFromInt(col.x)) + 0.5) * 0.4, -2 + (@as(f64, @floatFromInt(col.y)) + 0.5) * 0.4, @as(f64, @floatFromInt(iz)) * 0.1 };
        var retained = false;
        for (result.material.intervals.items[col.offset .. col.offset + col.count]) |span| if (point[2] >= span.lo and point[2] <= span.hi) {
            retained = true;
        };
        var minimum = std.math.inf(f64);
        for (actual_poses) |pose| {
            const q = e.sub(point, pose.position);
            const z = e.dot(q, pose.axis);
            const radius = e.norm(e.sub(q, e.scale(pose.axis, z)));
            minimum = @min(minimum, crown.distance(radius, z));
        }
        if (minimum < -1e-9) try std.testing.expect(!retained);
        if (!retained) try std.testing.expect(minimum <= 0.025 + sample_gap + 1e-8);
    };
}
test "adaptive swept intervals cover independent dense motion oracle within declared bound" {
    try adaptiveScenario(a, true);
}
test "adaptive planning and interval allocation failures clean up unpublished result" {
    try std.testing.checkAllAllocationFailures(a, adaptiveScenario, .{false});
}

test "ray workers preserve continuous interval endpoints and counters exactly" {
    const adaptive = @import("adaptive_raydexel.zig");
    const parallel = @import("raydexel_parallel.zig");
    const jobs = @import("job.zig");
    const profile = try d.Profile.init(a, crown);
    defer profile.deinit();
    const ops = [_]jobs.Operation{.{ .id = "cut", .tool = 0, .rotary = .{ .a = .{ .position = .{ -0.3, 0.1, 2 }, .a_deg = 12, .c_deg = 10 }, .b = .{ .position = .{ 0.3, 0.1, 2 }, .a_deg = 16, .c_deg = 30 } } }};
    var plan = try adaptive.Plan.init(a, profile, &ops, 0.04);
    defer plan.deinit();
    var tree = try d.Tree.init(a, profile, plan.roots.items);
    defer tree.deinit();
    for ([_]bool{ false, true }) |use_adaptive| {
        var one = try parallel.finish(a, profile, if (use_adaptive) &plan else null, tree, .{ 0, 0, 0 }, 2, 4, 0.4, 1);
        defer one.material.deinit();
        var many = try parallel.finish(a, profile, if (use_adaptive) &plan else null, tree, .{ 0, 0, 0 }, 2, 4, 0.4, 4);
        defer many.material.deinit();
        try std.testing.expectEqualSlices(d.Column, one.material.columns.items, many.material.columns.items);
        try std.testing.expectEqualSlices(d.Interval, one.material.intervals.items, many.material.intervals.items);
        try std.testing.expectEqualDeep(one.work, many.work);
        try std.testing.expectEqualDeep(one.material.work, many.material.work);
    }
    try std.testing.expectError(error.InvalidWorkerCount, parallel.finish(a, profile, &plan, tree, .{ 0, 0, 0 }, 2, 4, 0.4, 0));
}

test "analytic conic ray interval matches independent meridional distance at random poses" {
    const profile = try d.Profile.init(a, crown);
    defer profile.deinit();
    var rng = std.Random.DefaultPrng.init(0x5f997);
    for (0..200) |_| {
        const axis_raw: e.V = .{ rng.random().float(f64) - 0.5, rng.random().float(f64) - 0.5, rng.random().float(f64) - 0.5 };
        const axis = e.scale(axis_raw, 1 / e.norm(axis_raw));
        const dir_raw: e.V = .{ rng.random().float(f64) - 0.5, rng.random().float(f64) - 0.5, rng.random().float(f64) - 0.5 };
        const dir = e.scale(dir_raw, 1 / e.norm(dir_raw));
        const origin: e.V = .{ rng.random().float(f64) * 6 - 3, rng.random().float(f64) * 6 - 3, rng.random().float(f64) * 6 - 3 };
        const base = e.V{ 0.17, -0.31, 0.23 };
        const pose = try d.Pose.init(profile, .{ .position = base, .axis = axis }, 0);
        const hit = try d.ray(profile, pose, origin, dir, .{ .lo = -5, .hi = 5 });
        for (0..101) |i| {
            const t = @as(f64, @floatFromInt(i)) / 10 - 5;
            const q = e.sub(e.add(origin, e.scale(dir, t)), base);
            const z = e.dot(q, axis);
            const radius = e.norm(e.sub(q, e.scale(axis, z)));
            const distance = crown.distance(radius, z);
            if (@abs(distance) < 1e-8) continue;
            const inside = if (hit) |interval| t >= interval.lo and t <= interval.hi else false;
            try std.testing.expectEqual(distance < 0, inside);
        }
    }
}
