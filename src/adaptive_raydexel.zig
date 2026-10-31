//! Surface-interval-driven swept-volume refinement. Only exact cutter samples
//! may witness error-controlled acceptance; approximate cuts never grow the bound.
const std = @import("std");
const e = @import("engine.zig");
const d = @import("raydexel.zig");
const m = @import("motion.zig");
const jobs = @import("job.zig");
pub const Temporal = struct { outer: d.Pose, left: u32 = 0, right: u32 = 0 };
pub const Plan = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Temporal) = .empty,
    roots: std.ArrayList(d.Pose) = .empty,
    tolerance: f64,
    guard: f64,
    max_depth: u32 = 0,
    pub fn init(a: std.mem.Allocator, profile: d.Profile, operations: []const jobs.Operation, tolerance: f64) !Plan {
        const guard = (1 + profile.radius + profile.length) * 1e-8;
        if (!std.math.isFinite(tolerance) or tolerance <= 4 * guard) return error.MotionToleranceTooSmall;
        var plan = Plan{ .allocator = a, .tolerance = tolerance, .guard = guard };
        errdefer plan.deinit();
        for (operations) |op| {
            if (op.tool == null or op.tool.? != 0) return error.SingleRayToolRequired;
            if (op.rotary == null or op.line != null or op.arc != null or op.subtract != null or op.turning != null) return error.RotaryRayMotionRequired;
            const line = op.rotary.?;
            try line.a.validate();
            try line.b.validate();
            const rho = @sqrt(profile.radius * profile.radius + profile.length * profile.length / 4);
            const half_movement = e.norm(e.sub(line.b.position, line.a.position)) / 2 + rho * (@abs(line.b.a_deg - line.a.a_deg) + @abs(line.b.c_deg - line.a.c_deg)) * (std.math.pi / 360.0);
            const root = try plan.build(profile, line, half_movement, 0, 1, 0);
            var outer = plan.nodes.items[root].outer;
            outer.motion_index = root;
            try plan.roots.append(a, outer);
        }
        if (plan.roots.items.len == 0) return error.EmptyMotion;
        return plan;
    }
    pub fn deinit(p: *Plan) void {
        p.nodes.deinit(p.allocator);
        p.roots.deinit(p.allocator);
    }
    fn build(p: *Plan, profile: d.Profile, line: m.RotaryLine, half_movement: f64, lo: f64, hi: f64, depth: u32) !u32 {
        if (depth > 24 or p.nodes.items.len >= 5_000_000) return error.MotionRefinementLimit;
        const mid = (lo + hi) / 2;
        const actual = line.at(mid);
        const axis = actual.axis();
        const outer = try d.Pose.init(profile, .{ .position = e.sub(actual.position, e.scale(axis, profile.length / 2)), .axis = axis }, half_movement * (hi - lo) + p.guard);
        const index: u32 = @intCast(p.nodes.items.len);
        try p.nodes.append(p.allocator, .{ .outer = outer });
        p.max_depth = @max(p.max_depth, depth);
        if (outer.offset * profile.miter > p.tolerance) {
            const left = try p.build(profile, line, half_movement, lo, mid, depth + 1);
            const right = try p.build(profile, line, half_movement, mid, hi, depth + 1);
            p.nodes.items[index].left = left;
            p.nodes.items[index].right = right;
        }
        return index;
    }
    pub fn bytes(p: Plan) usize {
        return p.nodes.capacity * @sizeOf(Temporal) + p.roots.capacity * @sizeOf(d.Pose);
    }
};
pub const Work = struct {
    spatial_nodes: u64 = 0,
    temporal_nodes: u64 = 0,
    analytic_ray_tests: u64 = 0,
    witness_accepts: u64 = 0,
    tolerance_leaf_accepts: u64 = 0,
    already_removed_skips: u64 = 0,
};
pub const Output = struct { material: d.Result, work: Work };
const State = struct {
    material: std.ArrayList(d.Interval),
    witnesses: std.ArrayList(d.Interval),
    profile: d.Profile,
    plan: *const Plan,
    tree: d.Tree,
    x: f64 = 0,
    y: f64 = 0,
    limits: d.Interval,
    work: Work = .{},
    fn remove(s: *State, cut: d.Interval) !void {
        if (s.material.items.len == s.material.capacity) return error.RayIntervalBudgetExceeded;
        d.subtractIntervals(&s.material, cut);
    }
    fn witness(s: *State, cut: d.Interval) !void {
        if (cut.lo == cut.hi) return; // A tangent point is not a volume witness.
        var span = cut;
        var first: usize = 0;
        while (first < s.witnesses.items.len and s.witnesses.items[first].hi < span.lo) : (first += 1) {}
        var last = first;
        while (last < s.witnesses.items.len and s.witnesses.items[last].lo <= span.hi) : (last += 1) {
            span.lo = @min(span.lo, s.witnesses.items[last].lo);
            span.hi = @max(span.hi, s.witnesses.items[last].hi);
        }
        if (first == last) {
            if (s.witnesses.items.len == s.witnesses.capacity) return error.RayIntervalBudgetExceeded;
            s.witnesses.insertAssumeCapacity(first, span);
        } else {
            s.witnesses.items[first] = span;
            const removed = last - first - 1;
            std.mem.copyForwards(d.Interval, s.witnesses.items[first + 1 ..], s.witnesses.items[last..]);
            s.witnesses.items.len -= removed;
        }
        try s.remove(cut);
    }
    fn witnessed(s: *const State, cut: d.Interval) bool {
        // No accumulation of approximation: only undilated true-time tool
        // intervals participate, never previously accepted outer envelopes.
        const epsilon = s.plan.tolerance - s.plan.guard;
        var frontier = cut.lo;
        for (s.witnesses.items) |span| {
            if (span.hi + epsilon < frontier) continue;
            if (span.lo - epsilon > frontier) return false;
            frontier = @max(frontier, span.hi + epsilon);
            if (frontier >= cut.hi) return true;
        }
        return false;
    }
    fn hit(s: *State, pose: d.Pose) !?d.Interval {
        s.work.analytic_ray_tests += 1;
        return d.ray(s.profile, pose, .{ s.x, s.y, 0 }, .{ 0, 0, 1 }, s.limits);
    }
    fn actual(s: *State, outer: d.Pose) !void {
        var pose = outer;
        pose.offset = 0;
        if (try s.hit(pose)) |cut| try s.witness(cut);
    }
    fn temporal(s: *State, index: u32) !void {
        s.work.temporal_nodes += 1;
        const node = s.plan.nodes.items[index];
        if (s.x < node.outer.bounds.lo[0] or s.x > node.outer.bounds.hi[0] or s.y < node.outer.bounds.lo[1] or s.y > node.outer.bounds.hi[1]) return;
        const cut = (try s.hit(node.outer)) orelse return;
        if (!d.overlaps(s.material.items, cut)) {
            s.work.already_removed_skips += 1;
            return;
        }
        try s.actual(node.outer);
        if (s.witnessed(cut)) {
            s.work.witness_accepts += 1;
            try s.remove(cut);
        } else if (node.left == 0) {
            // This entire envelope is within tolerance of its exact midpoint
            // cutter in 3D, including tangencies with no same-ray witness.
            s.work.tolerance_leaf_accepts += 1;
            try s.remove(cut);
        } else {
            try s.temporal(node.left);
            try s.temporal(node.right);
        }
    }
    fn spatial(s: *State, index: u32) !void {
        s.work.spatial_nodes += 1;
        const node = s.tree.nodes.items[index];
        if (s.x < node.bounds.lo[0] or s.x > node.bounds.hi[0] or s.y < node.bounds.lo[1] or s.y > node.bounds.hi[1]) return;
        if (!d.overlaps(s.material.items, .{ .lo = node.bounds.lo[2], .hi = node.bounds.hi[2] })) return;
        if (node.envelope_offset >= 0) {
            var envelope = s.tree.poses[node.start];
            envelope.offset = node.envelope_offset;
            const cut = (try s.hit(envelope)) orelse return;
            if (!d.overlaps(s.material.items, cut)) {
                s.work.already_removed_skips += 1;
                return;
            }
            if (s.witnessed(cut)) {
                s.work.witness_accepts += 1;
                try s.remove(cut);
                return;
            }
        }
        if (node.count == 0) {
            try s.spatial(node.left);
            try s.spatial(node.right);
        } else for (s.tree.poses[node.start .. node.start + node.count]) |pose| try s.temporal(pose.motion_index);
    }
};
pub fn finish(a: std.mem.Allocator, profile: d.Profile, plan: *const Plan, tree: d.Tree, base: e.V, radius: f64, length: f64, spacing: f64) !Output {
    return finishRows(a, profile, plan, tree, base, radius, length, spacing, null);
}
pub fn finishRows(a: std.mem.Allocator, profile: d.Profile, plan: *const Plan, tree: d.Tree, base: e.V, radius: f64, length: f64, spacing: f64, rows: ?[2]u32) !Output {
    try e.validV(base);
    if (!std.math.isFinite(spacing) or spacing <= 0 or !std.math.isFinite(radius) or radius <= 0 or !std.math.isFinite(length) or length <= 0) return error.InvalidRayResolution;
    const nf = @ceil(2 * radius / spacing - 0.5);
    if (nf < 1 or nf > 65536) return error.InvalidRayResolution;
    const n: u32 = @intFromFloat(nf);
    var result = d.Result{ .allocator = a, .origin = .{ base[0] - radius, base[1] - radius, base[2] }, .spacing = spacing, .n = .{ n, n } };
    errdefer result.deinit();
    var state = State{ .material = .empty, .witnesses = .empty, .profile = profile, .plan = plan, .tree = tree, .limits = .{ .lo = base[2], .hi = base[2] + length } };
    defer state.material.deinit(a);
    defer state.witnesses.deinit(a);
    // Explicit bounded scratch, no allocation during a ray traversal.
    try state.material.ensureTotalCapacityPrecise(a, 4096);
    try state.witnesses.ensureTotalCapacityPrecise(a, 4096);
    result.scratch_bytes = (state.material.capacity + state.witnesses.capacity) * @sizeOf(d.Interval);
    const range = rows orelse [2]u32{ 0, n };
    if (range[0] > range[1] or range[1] > n) return error.InvalidRayRows;
    for (range[0]..range[1]) |iy| for (0..n) |ix| {
        state.x = result.origin[0] + (@as(f64, @floatFromInt(ix)) + 0.5) * spacing;
        state.y = result.origin[1] + (@as(f64, @floatFromInt(iy)) + 0.5) * spacing;
        if ((state.x - base[0]) * (state.x - base[0]) + (state.y - base[1]) * (state.y - base[1]) > radius * radius) continue;
        state.material.clearRetainingCapacity();
        state.witnesses.clearRetainingCapacity();
        state.material.appendAssumeCapacity(state.limits);
        for (plan.roots.items) |pose| {
            if (state.x < pose.bounds.lo[0] or state.x > pose.bounds.hi[0] or state.y < pose.bounds.lo[1] or state.y > pose.bounds.hi[1]) continue;
            try state.actual(pose);
        }
        try state.spatial(0);
        const offset = result.intervals.items.len;
        try result.intervals.appendSlice(a, state.material.items);
        try result.columns.append(a, .{ .x = @intCast(ix), .y = @intCast(iy), .offset = offset, .count = state.material.items.len });
    };
    return .{ .material = result, .work = state.work };
}
