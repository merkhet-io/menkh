//! Continuous translations with orientation-only XYZAC subdivision.
const std = @import("std");
const e = @import("engine.zig");
const d = @import("raydexel.zig");
const s = @import("profile_sweep.zig");
const m = @import("motion.zig");
const jobs = @import("job.zig");
pub const Plan = struct {
    coherent_seeds: bool = true,
    // Borrowed immutable cache; owner must retain it until all workers finish.
    prepared: ?*const @import("prepared_z_rays.zig").Scene = null,
    allocator: std.mem.Allocator,
    sweeps: []s.Sweep,
    rims: []s.Rim,
    planes: []s.Plane,
    proxies: []d.Pose,
    bound: f64 = 0,
    guard: f64,
    fn angular(line: m.RotaryLine) f64 {
        const radians = std.math.pi / 180.0;
        const da = @abs(line.b.a_deg - line.a.a_deg) * radians;
        const dc = @abs(line.b.c_deg - line.a.c_deg) * radians;
        const lo = @min(line.a.a_deg, line.b.a_deg) * radians;
        const hi = @max(line.a.a_deg, line.b.a_deg) * radians;
        var sine = @max(@abs(@sin(lo)), @abs(@sin(hi)));
        if (@ceil((lo - std.math.pi / 2.0) / std.math.pi) <= @floor((hi - std.math.pi / 2.0) / std.math.pi)) sine = 1;
        return @sqrt(da * da + sine * sine * dc * dc);
    }
    fn subdivisions(profile: d.Profile, line: m.RotaryLine, tolerance: f64, guard: f64) !usize {
        try line.a.validate();
        try line.b.validate();
        const rho = @sqrt(profile.radius * profile.radius + profile.length * profile.length / 4);
        const nf = @ceil((1 + profile.miter) * rho * angular(line) / (2 * (tolerance - profile.miter * guard)));
        if (!std.math.isFinite(nf) or nf > 5_000_000) return error.TooManyRaySweeps;
        return @max(1, @as(usize, @intFromFloat(nf)));
    }
    pub fn init(a: std.mem.Allocator, profile: d.Profile, operations: []const jobs.Operation, tolerance: f64) !Plan {
        const guard = (1 + profile.radius + profile.length) * 1e-8;
        if (!std.math.isFinite(tolerance) or tolerance <= guard * profile.miter) return error.MotionToleranceTooSmall;
        if (operations.len == 0) return error.EmptyMotion;
        var count: usize = 0;
        for (operations) |op| {
            if (op.tool == null or op.tool.? != 0) return error.SingleRayToolRequired;
            if (op.rotary == null or op.line != null or op.arc != null or op.subtract != null or op.turning != null) return error.RotaryRayMotionRequired;
            count = try std.math.add(usize, count, try subdivisions(profile, op.rotary.?, tolerance, guard));
            if (count > 5_000_000) return error.TooManyRaySweeps;
        }
        const sweeps = try a.alloc(s.Sweep, count);
        errdefer a.free(sweeps);
        const rim_stride = try std.math.add(usize, profile.sides.len, 1);
        const plane_stride = try std.math.mul(usize, profile.sides.len, 2);
        const rims = try a.alloc(s.Rim, try std.math.mul(usize, count, rim_stride));
        errdefer a.free(rims);
        const planes = try a.alloc(s.Plane, try std.math.mul(usize, count, plane_stride));
        errdefer a.free(planes);
        const proxies = try a.alloc(d.Pose, count);
        errdefer a.free(proxies);
        var plan = Plan{ .allocator = a, .sweeps = sweeps, .rims = rims, .planes = planes, .proxies = proxies, .guard = guard };
        var index: usize = 0;
        const rho = @sqrt(profile.radius * profile.radius + profile.length * profile.length / 4);
        for (operations) |op| {
            const line = op.rotary.?;
            const n = try subdivisions(profile, line, tolerance, guard);
            const delta = rho * angular(line) / (2 * @as(f64, @floatFromInt(n)));
            plan.bound = @max(plan.bound, delta + profile.miter * (delta + guard));
            for (0..n) |i| {
                const lo = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
                const hi = @as(f64, @floatFromInt(i + 1)) / @as(f64, @floatFromInt(n));
                const axis = line.at((lo + hi) / 2).axis();
                const shift = e.scale(axis, profile.length / 2);
                sweeps[index] = try s.Sweep.init(profile, .{ .position = e.sub(line.at(lo).position, shift), .axis = axis }, e.sub(line.at(hi).position, shift), delta + guard, rims[index * rim_stride ..][0..rim_stride], planes[index * plane_stride ..][0..plane_stride]);
                proxies[index] = try sweeps[index].proxy(profile);
                proxies[index].motion_index = @intCast(index);
                index += 1;
            }
        }
        if (plan.bound > tolerance + 1e-12) return error.MotionBudgetExceeded;
        return plan;
    }
    pub fn deinit(p: *Plan) void {
        p.allocator.free(p.sweeps);
        p.allocator.free(p.rims);
        p.allocator.free(p.planes);
        p.allocator.free(p.proxies);
    }
    pub fn bytes(p: Plan) usize {
        return p.sweeps.len * @sizeOf(s.Sweep) + p.rims.len * @sizeOf(s.Rim) + p.planes.len * @sizeOf(s.Plane) + p.proxies.len * @sizeOf(d.Pose);
    }
};
pub const Work = struct { coherent_seed_tests: u64 = 0, proxy_tests: u64 = 0, sweep_tests: u64 = 0 };
pub const Output = struct { material: d.Result, work: Work };
fn visit(plan: *const Plan, sweep_work: *Work, tree: d.Tree, profile: d.Profile, index: u32, x: f64, y: f64, material: *std.ArrayList(d.Interval), owners: ?*std.ArrayList([2]u32), work: *d.Work) !void {
    work.node_tests += 1;
    const node = tree.nodes.items[index];
    if (x < node.bounds.lo[0] or x > node.bounds.hi[0] or y < node.bounds.lo[1] or y > node.bounds.hi[1]) return;
    if (!d.overlaps(material.items, .{ .lo = node.bounds.lo[2], .hi = node.bounds.hi[2] })) {
        work.skipped_removed_nodes += 1;
        return;
    }
    if (node.envelope_offset >= 0) {
        var envelope = tree.poses[node.anchorIndex()];
        envelope.offset = node.envelope_offset;
        const limits = d.Interval{ .lo = node.bounds.lo[2], .hi = node.bounds.hi[2] };
        work.envelope_tests += 1;
        const cut = (if (plan.prepared) |cache| try cache.node(index).intersect(x, y, limits, material.items) else try d.rayMaterial(profile, envelope, .{ x, y, 0 }, .{ 0, 0, 1 }, limits, material.items)) orelse return;
        if (!d.overlaps(material.items, cut)) {
            work.skipped_removed_nodes += 1;
            return;
        }
    }
    if (node.count == 0) {
        try visit(plan, sweep_work, tree, profile, node.left, x, y, material, owners, work);
        try visit(plan, sweep_work, tree, profile, node.right_or_anchor, x, y, material, owners, work);
    } else for (tree.poses[node.start .. node.start + node.count]) |pose| {
        if (material.items.len == 0) break;
        if (x < pose.bounds.lo[0] or x > pose.bounds.hi[0] or y < pose.bounds.lo[1] or y > pose.bounds.hi[1]) continue;
        const limits = d.Interval{ .lo = @max(material.items[0].lo, pose.bounds.lo[2]), .hi = @min(material.items[material.items.len - 1].hi, pose.bounds.hi[2]) };
        if (limits.lo > limits.hi or !d.overlaps(material.items, limits)) continue;
        sweep_work.proxy_tests += 1;
        const proxy_hit = (if (plan.prepared) |cache| try cache.sweep(pose.motion_index).intersect(x, y, limits, material.items) else try plan.sweeps[pose.motion_index].rayEnvelope(profile, .{ x, y, 0 }, .{ 0, 0, 1 }, limits, material.items)) orelse continue;
        if (!d.overlaps(material.items, proxy_hit)) continue;
        sweep_work.sweep_tests += 1;
        if (try plan.sweeps[pose.motion_index].ray(profile, .{ x, y, 0 }, .{ 0, 0, 1 }, limits)) |cut| {
            work.cutting_intervals += 1;
            d.subtractIntervalsTracked(material, cut, owners, pose.motion_index);
        }
    }
}
/// Construct a new final stock, publishing nothing on allocation/geometry errors.
/// Primitive stock and whole-job planning are intentionally restricted in v1.
pub fn finishRows(a: std.mem.Allocator, profile: d.Profile, plan: *const Plan, tree: d.Tree, base: e.V, radius: f64, length: f64, spacing: f64, exhaustive: bool, rows: ?[2]u32) !Output {
    try e.validV(base);
    if (!std.math.isFinite(radius) or radius <= 0 or !std.math.isFinite(length) or length <= 0 or !std.math.isFinite(spacing) or spacing <= 0) return error.InvalidRayStock;
    const nf = @ceil(2 * radius / spacing - 0.5);
    if (!std.math.isFinite(nf) or nf < 1 or nf > 65536) return error.InvalidRayResolution;
    const n: u32 = @intFromFloat(nf);
    _ = try std.math.mul(usize, n, n);
    var counters: Work = .{};
    const sweep_work = &counters;
    var result = d.Result{ .allocator = a, .origin = .{ base[0] - radius, base[1] - radius, base[2] }, .spacing = spacing, .n = .{ n, n } };
    errdefer result.deinit();
    var material: std.ArrayList(d.Interval) = .empty;
    defer material.deinit(a);
    try material.ensureTotalCapacityPrecise(a, try std.math.add(usize, tree.poses.len, 1));
    var boundary_owners: std.ArrayList([2]u32) = .empty;
    defer boundary_owners.deinit(a);
    const coherent = plan.coherent_seeds and !exhaustive;
    if (coherent) try boundary_owners.ensureTotalCapacityPrecise(a, try std.math.add(usize, tree.poses.len, 1));
    const owners: ?*std.ArrayList([2]u32) = if (coherent) &boundary_owners else null;
    // Prior-ray endpoint contributors are hints, never reused intersections.
    var seed_ids: std.ArrayList(u32) = .empty;
    defer seed_ids.deinit(a);
    if (coherent) try seed_ids.ensureTotalCapacityPrecise(a, try std.math.mul(usize, boundary_owners.capacity, 2));
    result.scratch_bytes = material.capacity * @sizeOf(d.Interval) + boundary_owners.capacity * @sizeOf([2]u32) + seed_ids.capacity * @sizeOf(u32);
    const range = rows orelse [2]u32{ 0, n };
    if (range[0] > range[1] or range[1] > n) return error.InvalidRayRows;
    for (range[0]..range[1]) |iy| for (0..n) |ix| {
        const x = result.origin[0] + (@as(f64, @floatFromInt(ix)) + 0.5) * spacing;
        const y = result.origin[1] + (@as(f64, @floatFromInt(iy)) + 0.5) * spacing;
        // Reset per row: hints and work counts are independent of worker partitions.
        if (ix == 0) boundary_owners.clearRetainingCapacity();
        if ((x - base[0]) * (x - base[0]) + (y - base[1]) * (y - base[1]) > radius * radius) continue;
        seed_ids.clearRetainingCapacity();
        for (boundary_owners.items) |pair| for (pair) |id| {
            if (id == std.math.maxInt(u32)) continue;
            if (seed_ids.items.len == 0 or seed_ids.items[seed_ids.items.len - 1] != id) seed_ids.appendAssumeCapacity(id);
        };
        boundary_owners.clearRetainingCapacity();
        if (coherent) boundary_owners.appendAssumeCapacity(.{ std.math.maxInt(u32), std.math.maxInt(u32) });
        material.clearRetainingCapacity();
        material.appendAssumeCapacity(.{ .lo = base[2], .hi = base[2] + length });
        if (exhaustive) {
            for (tree.poses) |pose| {
                sweep_work.sweep_tests += 1;
                if (try plan.sweeps[pose.motion_index].ray(profile, .{ x, y, 0 }, .{ 0, 0, 1 }, .{ .lo = base[2], .hi = base[2] + length })) |cut| d.subtractIntervals(&material, cut);
            }
        } else {
            for (seed_ids.items) |id| {
                const cut_sweep = plan.sweeps[id];
                if (x < cut_sweep.bounds.lo[0] or x > cut_sweep.bounds.hi[0] or y < cut_sweep.bounds.lo[1] or y > cut_sweep.bounds.hi[1]) continue;
                sweep_work.coherent_seed_tests += 1;
                sweep_work.sweep_tests += 1;
                if (try cut_sweep.ray(profile, .{ x, y, 0 }, .{ 0, 0, 1 }, .{ .lo = base[2], .hi = base[2] + length })) |cut| d.subtractIntervalsTracked(&material, cut, owners, id);
            }
            // Seed the removed union with widely spaced poses before refining
            // its boundary. This is traversal order only: the exact tree pass
            // still covers every pose. It avoids growing each cut monotonically
            // through thousands of almost identical intervals.
            var seed: usize = 0;
            while (seed < tree.poses.len) : (seed += 64) {
                const pose = tree.poses[seed];
                if (x < pose.bounds.lo[0] or x > pose.bounds.hi[0] or y < pose.bounds.lo[1] or y > pose.bounds.hi[1]) continue;
                result.work.seed_tests += 1;
                sweep_work.sweep_tests += 1;
                if (try plan.sweeps[pose.motion_index].ray(profile, .{ x, y, 0 }, .{ 0, 0, 1 }, .{ .lo = base[2], .hi = base[2] + length })) |cut| d.subtractIntervalsTracked(&material, cut, owners, pose.motion_index);
            }
            try visit(plan, sweep_work, tree, profile, 0, x, y, &material, owners, &result.work);
        }
        const offset = result.intervals.items.len;
        try result.intervals.appendSlice(a, material.items);
        try result.columns.append(a, .{ .x = @intCast(ix), .y = @intCast(iy), .offset = offset, .count = material.items.len });
    };
    return .{ .material = result, .work = counters };
}
