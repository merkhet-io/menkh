//! Experimental continuous Z intervals and analytic convex-profile intersections.
//! Batch final-stock solver: no voxel-center subdivision and no history facade.
const std = @import("std");
const e = @import("engine.zig");
pub const Interval = struct { lo: f64, hi: f64 };
pub const Side = struct { slope: f64, intercept: f64, normal_length: f64 };
pub const Profile = struct {
    allocator: std.mem.Allocator,
    sides: []Side,
    radius: f64,
    length: f64,
    miter: f64,
    pub fn init(a: std.mem.Allocator, tool: e.Tool) !Profile {
        try tool.validate();
        if (tool.kind != .profile) return error.ConvexProfileRequired;
        if (tool.profile[0].radius <= 0 or tool.profile[tool.profile.len - 1].radius <= 0) return error.PositiveProfileCapsRequired;
        const sides = try a.alloc(Side, tool.profile.len - 1);
        errdefer a.free(sides);
        var miter: f64 = 1;
        // Normals are (radial, axial), beginning with the lower axial cap.
        var previous: [2]f64 = .{ 0, -1 };
        for (sides, tool.profile[0 .. tool.profile.len - 1], tool.profile[1..], 0..) |*side, p, q, i| {
            const slope = (q.radius - p.radius) / (q.z - p.z);
            if (i > 0 and slope > sides[i - 1].slope) return error.NonconvexProfileUnsupported;
            const length = @sqrt(1 + slope * slope);
            side.* = .{ .slope = slope, .intercept = p.radius - slope * p.z, .normal_length = length };
            const normal = [2]f64{ 1 / length, -slope / length };
            const cosine = std.math.clamp(previous[0] * normal[0] + previous[1] * normal[1], -1, 1);
            miter = @max(miter, @sqrt(2 / (1 + cosine)));
            previous = normal;
        }
        miter = @max(miter, @sqrt(2 / (1 + previous[1])));
        if (!std.math.isFinite(miter) or miter > 8) return error.ProfileMiterTooLarge;
        return .{ .allocator = a, .sides = sides, .radius = tool.radius, .length = tool.length, .miter = miter };
    }
    pub fn deinit(p: Profile) void {
        p.allocator.free(p.sides);
    }
};
pub const Pose = struct {
    base: e.V,
    axis: e.V,
    offset: f64,
    motion_index: u32 = 0,
    bounds: e.Bounds,
    pub fn init(profile: Profile, pose: e.Pose, offset: f64) !Pose {
        try pose.validate();
        if (!std.math.isFinite(offset) or offset < 0) return error.InvalidRayOffset;
        const axis = e.scale(pose.axis, 1 / e.norm(pose.axis));
        const center = e.add(pose.position, e.scale(axis, profile.length / 2));
        var bounds: e.Bounds = undefined;
        for (0..3) |k| {
            const half = profile.radius * @sqrt(@max(0, 1 - axis[k] * axis[k])) + profile.length / 2 * @abs(axis[k]) + offset * profile.miter;
            bounds.lo[k] = center[k] - half;
            bounds.hi[k] = center[k] + half;
        }
        return .{ .base = pose.position, .axis = axis, .offset = offset, .bounds = bounds };
    }
};
pub fn intersect(a: Interval, b: Interval) ?Interval {
    const out = Interval{ .lo = @max(a.lo, b.lo), .hi = @min(a.hi, b.hi) };
    return if (out.lo <= out.hi) out else null;
}
// Clip b + a*t >= 0 without a guessed near-zero slope cutoff.
pub fn positive(interval: Interval, a: f64, b: f64) ?Interval {
    if (a == 0) return if (b >= 0) interval else null;
    return intersect(interval, if (a > 0) .{ .lo = -b / a, .hi = std.math.inf(f64) } else .{ .lo = -std.math.inf(f64), .hi = -b / a });
}
pub fn quadratic(interval: Interval, a: f64, b: f64, c: f64) !?Interval {
    if (a == 0) return positive(interval, -b, -c);
    const disc = b * b - 4 * a * c;
    if (disc < 0) return if (a < 0) interval else null;
    const root = @sqrt(disc);
    const q = -0.5 * (b + std.math.copysign(root, b));
    const x = if (q == 0) -b / (2 * a) else q / a;
    const y = if (q == 0) x else c / q;
    const lo = @min(x, y);
    const hi = @max(x, y);
    if (a > 0) return intersect(interval, .{ .lo = lo, .hi = hi });
    if (lo == hi) return interval;
    const left = intersect(interval, .{ .lo = -std.math.inf(f64), .hi = lo });
    const right = intersect(interval, .{ .lo = hi, .hi = std.math.inf(f64) });
    // With the cone's nonnegative RHS constraint the intersection is convex.
    // Never silently select one component in an ambiguous numeric result.
    if (left != null and right != null) return error.AmbiguousRayIntersection;
    return left orelse right;
}
/// Ray origin + t*direction; direction must be a unit vector. Closed cutter
/// intervals include tangency; zero-length cuts do not affect volume.
pub fn ray(profile: Profile, pose: Pose, origin: e.V, direction: e.V, limits: Interval) !?Interval {
    return rayRetained(false, profile, pose, origin, direction, limits, &.{});
}
pub fn rayMaterial(profile: Profile, pose: Pose, origin: e.V, direction: e.V, limits: Interval, retained: []const Interval) !?Interval {
    return rayRetained(true, profile, pose, origin, direction, limits, retained);
}
fn trimMaterial(material: []const Interval, interval: Interval) []const Interval {
    var first: usize = 0;
    var end = material.len;
    while (first < end and material[first].hi <= interval.lo) first += 1;
    while (end > first and material[end - 1].lo >= interval.hi) end -= 1;
    return material[first..end];
}
fn rayRetained(comptime filter: bool, profile: Profile, pose: Pose, origin: e.V, direction: e.V, limits: Interval, retained: []const Interval) !?Interval {
    var active = retained;
    const q = e.sub(origin, pose.base);
    const z = e.dot(q, pose.axis);
    const vz = e.dot(direction, pose.axis);
    var interval = positive(limits, vz, z + pose.offset) orelse return null;
    interval = positive(interval, -vz, profile.length + pose.offset - z) orelse return null;
    if (filter) {
        active = trimMaterial(active, interval);
        if (active.len == 0) return null;
    }
    const qr = e.sub(q, e.scale(pose.axis, z));
    const vr = e.sub(direction, e.scale(pose.axis, vz));
    const aa = e.dot(vr, vr);
    const bb = 2 * e.dot(qr, vr);
    const cc = e.dot(qr, qr);
    for (profile.sides) |side| {
        const r = side.intercept + side.slope * z + pose.offset * side.normal_length;
        const v = side.slope * vz;
        interval = positive(interval, v, r) orelse return null;
        const qa = aa - v * v;
        const qb = bb - 2 * r * v;
        const qc = cc - r * r;
        interval = (try quadratic(interval, qa, qb, qc)) orelse return null;
        if (filter) {
            active = trimMaterial(active, interval);
            if (active.len == 0) return null;
        }
    }
    return interval;
}
pub const Node = struct {
    bounds: e.Bounds,
    // A leaf's contiguous pose range, or an internal node's envelope anchor.
    start: u32,
    count: u32,
    left: u32 = 0,
    // count == 0: right child; count > 0: leaf envelope anchor pose.
    // Reuse the inactive child slot without changing leaf/seed traversal order.
    right_or_anchor: u32 = 0,
    envelope_offset: f64 = -1,
    pub fn anchorIndex(node: Node) u32 {
        return if (node.count == 0) node.start else node.right_or_anchor;
    }
};
pub const Tree = struct {
    allocator: std.mem.Allocator,
    poses: []Pose,
    profile: Profile,
    nodes: std.ArrayList(Node) = .empty,
    pub fn init(a: std.mem.Allocator, profile: Profile, input: []const Pose) !Tree {
        if (input.len == 0 or input.len > 5_000_000) return error.InvalidPoseCount;
        var tree = Tree{ .allocator = a, .poses = try a.dupe(Pose, input), .profile = profile };
        errdefer tree.deinit();
        try tree.nodes.ensureTotalCapacityPrecise(a, nodeCount(input.len));
        _ = tree.build(0, @intCast(input.len));
        return tree;
    }
    fn nodeCount(n: usize) usize {
        return if (n <= 8) 1 else 1 + nodeCount(n / 2) + nodeCount(n - n / 2);
    }
    pub fn deinit(t: *Tree) void {
        t.allocator.free(t.poses);
        t.nodes.deinit(t.allocator);
    }
    fn less(axis: usize, a: Pose, b: Pose) bool {
        return a.bounds.lo[axis] + a.bounds.hi[axis] < b.bounds.lo[axis] + b.bounds.hi[axis];
    }
    fn build(t: *Tree, start: u32, count: u32) u32 {
        var bounds = t.poses[start].bounds;
        for (t.poses[start .. start + count]) |p| for (0..3) |k| {
            bounds.lo[k] = @min(bounds.lo[k], p.bounds.lo[k]);
            bounds.hi[k] = @max(bounds.hi[k], p.bounds.hi[k]);
        };
        const index: u32 = @intCast(t.nodes.items.len);
        t.nodes.appendAssumeCapacity(.{ .bounds = bounds, .start = start, .count = count });
        if (count > 8) {
            // Split centroid extent, not tool AABB extent: a wide, thin wheel
            // must not force endless XY splits of poses separated axially.
            var centers = e.Bounds{ .lo = .{ std.math.inf(f64), std.math.inf(f64), std.math.inf(f64) }, .hi = .{ -std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) } };
            for (t.poses[start .. start + count]) |pose| for (0..3) |k| {
                const center = (pose.bounds.lo[k] + pose.bounds.hi[k]) / 2;
                centers.lo[k] = @min(centers.lo[k], center);
                centers.hi[k] = @max(centers.hi[k], center);
            };
            var axis: usize = 0;
            for (1..3) |k| if (centers.hi[k] - centers.lo[k] > centers.hi[axis] - centers.lo[axis]) {
                axis = k;
            };
            std.mem.sort(Pose, t.poses[start .. start + count], axis, less);
            const left = t.build(start, count / 2);
            const right = t.build(start + count / 2, count - count / 2);
            t.nodes.items[index].left = left;
            t.nodes.items[index].right_or_anchor = right;
            t.nodes.items[index].count = 0;
        }
        // Compare each offset body to the SAME offset body at the anchor.
        // Translation + rotation displaces its points by at most margin-offset;
        // its radius about the base is <= rho + offset*miter. Each normalized
        // conic/cap constraint is 1-Lipschitz, so adding this displacement to
        // the original offset encloses it. No extra miter on the offset itself.
        // Rejection only: leaves retain original poses.
        if (count <= 256) {
            const rho = @sqrt(t.profile.radius * t.profile.radius + t.profile.length * t.profile.length);
            // Anchor near the group's center in position/orientation space,
            // rather than at an arbitrary edge of the sorted pose range.
            var mean_base: e.V = .{ 0, 0, 0 };
            var mean_axis: e.V = .{ 0, 0, 0 };
            for (t.poses[start .. start + count]) |pose| {
                mean_base = e.add(mean_base, pose.base);
                mean_axis = e.add(mean_axis, pose.axis);
            }
            mean_base = e.scale(mean_base, 1 / @as(f64, @floatFromInt(count)));
            mean_axis = e.scale(mean_axis, 1 / @as(f64, @floatFromInt(count)));
            var chosen = start;
            var best = std.math.inf(f64);
            for (t.poses[start .. start + count], start..) |pose, i| {
                const db = e.sub(pose.base, mean_base);
                const da = e.sub(pose.axis, mean_axis);
                const score = e.dot(db, db) + rho * rho * e.dot(da, da);
                if (score < best) {
                    best = score;
                    chosen = @intCast(i);
                }
            }
            // For small leaves, minimize the actual envelope radius over all
            // available anchors. For larger groups compare center and original
            // anchors; never widen their enclosure just to use a central pose.
            var margin = t.envelopeMargin(start, count, chosen, rho);
            const candidates = if (count <= 8) count else @as(u32, 1);
            for (start..start + candidates) |candidate| {
                const candidate_margin = t.envelopeMargin(start, count, @intCast(candidate), rho);
                if (candidate_margin < margin) {
                    margin = candidate_margin;
                    chosen = @intCast(candidate);
                }
            }
            if (t.nodes.items[index].count > 0) {
                t.nodes.items[index].right_or_anchor = chosen;
            } else t.nodes.items[index].start = chosen;
            t.nodes.items[index].envelope_offset = margin + 1e-8 * (1 + rho + margin);
        }
        return index;
    }
    fn envelopeMargin(t: Tree, start: u32, count: u32, anchor_index: u32, rho: f64) f64 {
        const anchor = t.poses[anchor_index];
        var value: f64 = 0;
        for (t.poses[start .. start + count]) |pose| {
            value = @max(value, pose.offset + e.norm(e.sub(pose.base, anchor.base)) + (rho + pose.offset * t.profile.miter) * e.norm(e.sub(pose.axis, anchor.axis)));
        }
        return value;
    }
    pub fn bytes(t: Tree) usize {
        return t.poses.len * @sizeOf(Pose) + t.nodes.capacity * @sizeOf(Node);
    }
};
pub const Work = struct { node_tests: u64 = 0, ray_pose_tests: u64 = 0, cutting_intervals: u64 = 0, skipped_removed_nodes: u64 = 0, envelope_tests: u64 = 0, seed_tests: u64 = 0 };
pub const Column = struct { x: u32, y: u32, offset: usize, count: usize };
pub const Result = struct {
    allocator: std.mem.Allocator,
    origin: e.V,
    spacing: f64,
    n: [2]u32,
    columns: std.ArrayList(Column) = .empty,
    intervals: std.ArrayList(Interval) = .empty,
    work: Work = .{},
    scratch_bytes: usize = 0,
    pub fn deinit(r: *Result) void {
        r.columns.deinit(r.allocator);
        r.intervals.deinit(r.allocator);
    }
    pub fn bytes(r: Result) usize {
        return r.columns.capacity * @sizeOf(Column) + r.intervals.capacity * @sizeOf(Interval);
    }
    pub fn volume(r: Result) f64 {
        var length: f64 = 0;
        for (r.intervals.items) |span| length += span.hi - span.lo;
        return length * r.spacing * r.spacing;
    }
};
/// Scratch capacity must cover initial length + number of cutter intervals.
/// Endpoint surfaces remain closed; removed/retained boundary ambiguity has
/// zero ray length and is reported separately from center-sampled comparisons.
pub fn subtractIntervals(material: *std.ArrayList(Interval), cut: Interval) void {
    if (cut.lo >= cut.hi) return; // Regularized difference: a tangent point has no volume.
    var i: usize = 0;
    while (i < material.items.len) {
        const span = material.items[i];
        if (cut.hi <= span.lo) break;
        if (cut.lo >= span.hi) {
            i += 1;
            continue;
        }
        if (cut.lo <= span.lo and cut.hi >= span.hi) {
            _ = material.orderedRemove(i);
        } else if (cut.lo <= span.lo) {
            material.items[i].lo = cut.hi;
            break;
        } else if (cut.hi >= span.hi) {
            material.items[i].hi = cut.lo;
            i += 1;
        } else {
            material.insertAssumeCapacity(i + 1, .{ .lo = cut.hi, .hi = span.hi });
            material.items[i].hi = cut.lo;
            break;
        }
    }
}
pub fn overlaps(material: []const Interval, box: Interval) bool {
    for (material) |span| {
        if (span.lo >= box.hi) return false;
        if (span.hi > box.lo) return true;
    }
    return false;
}
fn visit(tree: Tree, profile: Profile, index: u32, x: f64, y: f64, material: *std.ArrayList(Interval), work: *Work) !void {
    work.node_tests += 1;
    const node = tree.nodes.items[index];
    if (x < node.bounds.lo[0] or x > node.bounds.hi[0] or y < node.bounds.lo[1] or y > node.bounds.hi[1]) return;
    if (!overlaps(material.items, .{ .lo = node.bounds.lo[2], .hi = node.bounds.hi[2] })) {
        work.skipped_removed_nodes += 1;
        return;
    }
    if (node.envelope_offset >= 0) {
        var envelope = tree.poses[node.anchorIndex()];
        envelope.offset = node.envelope_offset;
        const limits = Interval{ .lo = node.bounds.lo[2], .hi = node.bounds.hi[2] };
        work.envelope_tests += 1;
        const cut = (try rayRetained(true, profile, envelope, .{ x, y, 0 }, .{ 0, 0, 1 }, limits, material.items)) orelse return;
        if (!overlaps(material.items, cut)) {
            work.skipped_removed_nodes += 1;
            return;
        }
    }
    if (node.count == 0) {
        try visit(tree, profile, node.left, x, y, material, work);
        try visit(tree, profile, node.right_or_anchor, x, y, material, work);
    } else for (tree.poses[node.start .. node.start + node.count]) |pose| {
        if (material.items.len == 0) break;
        if (x < pose.bounds.lo[0] or x > pose.bounds.hi[0] or y < pose.bounds.lo[1] or y > pose.bounds.hi[1]) continue;
        const limits = Interval{ .lo = @max(material.items[0].lo, pose.bounds.lo[2]), .hi = @min(material.items[material.items.len - 1].hi, pose.bounds.hi[2]) };
        if (limits.lo > limits.hi or !overlaps(material.items, limits)) continue;
        work.ray_pose_tests += 1;
        if (try rayRetained(true, profile, pose, .{ x, y, 0 }, .{ 0, 0, 1 }, limits, material.items)) |cut| {
            work.cutting_intervals += 1;
            subtractIntervals(material, cut);
        }
    }
}
/// Construct a new final stock, publishing nothing on allocation/geometry errors.
/// Primitive stock and whole-job planning are intentionally restricted in v1.
pub fn finishCylinder(a: std.mem.Allocator, profile: Profile, tree: Tree, base: e.V, radius: f64, length: f64, spacing: f64, exhaustive: bool) !Result {
    return finishCylinderRows(a, profile, tree, base, radius, length, spacing, exhaustive, null);
}
pub fn finishCylinderRows(a: std.mem.Allocator, profile: Profile, tree: Tree, base: e.V, radius: f64, length: f64, spacing: f64, exhaustive: bool, rows: ?[2]u32) !Result {
    try e.validV(base);
    if (!std.math.isFinite(radius) or radius <= 0 or !std.math.isFinite(length) or length <= 0 or !std.math.isFinite(spacing) or spacing <= 0) return error.InvalidRayStock;
    const nf = @ceil(2 * radius / spacing - 0.5);
    if (!std.math.isFinite(nf) or nf < 1 or nf > 65536) return error.InvalidRayResolution;
    const n: u32 = @intFromFloat(nf);
    _ = try std.math.mul(usize, n, n);
    var result = Result{ .allocator = a, .origin = .{ base[0] - radius, base[1] - radius, base[2] }, .spacing = spacing, .n = .{ n, n } };
    errdefer result.deinit();
    var material: std.ArrayList(Interval) = .empty;
    defer material.deinit(a);
    try material.ensureTotalCapacityPrecise(a, try std.math.add(usize, tree.poses.len, 1));
    result.scratch_bytes = material.capacity * @sizeOf(Interval);
    const range = rows orelse [2]u32{ 0, n };
    if (range[0] > range[1] or range[1] > n) return error.InvalidRayRows;
    for (range[0]..range[1]) |iy| for (0..n) |ix| {
        const x = result.origin[0] + (@as(f64, @floatFromInt(ix)) + 0.5) * spacing;
        const y = result.origin[1] + (@as(f64, @floatFromInt(iy)) + 0.5) * spacing;
        if ((x - base[0]) * (x - base[0]) + (y - base[1]) * (y - base[1]) > radius * radius) continue;
        material.clearRetainingCapacity();
        material.appendAssumeCapacity(.{ .lo = base[2], .hi = base[2] + length });
        if (exhaustive) {
            for (tree.poses) |pose| {
                result.work.ray_pose_tests += 1;
                if (try ray(profile, pose, .{ x, y, 0 }, .{ 0, 0, 1 }, .{ .lo = base[2], .hi = base[2] + length })) |cut| subtractIntervals(&material, cut);
            }
        } else {
            // Seed the removed union with widely spaced poses before refining
            // its boundary. This is traversal order only: the exact tree pass
            // still covers every pose. It avoids growing each cut monotonically
            // through thousands of almost identical intervals.
            var seed: usize = 0;
            while (seed < tree.poses.len) : (seed += 64) {
                const pose = tree.poses[seed];
                if (x < pose.bounds.lo[0] or x > pose.bounds.hi[0] or y < pose.bounds.lo[1] or y > pose.bounds.hi[1]) continue;
                result.work.seed_tests += 1;
                if (try ray(profile, pose, .{ x, y, 0 }, .{ 0, 0, 1 }, .{ .lo = base[2], .hi = base[2] + length })) |cut| subtractIntervals(&material, cut);
            }
            try visit(tree, profile, 0, x, y, &material, &result.work);
        }
        const offset = result.intervals.items.len;
        try result.intervals.appendSlice(a, material.items);
        try result.columns.append(a, .{ .x = @intCast(ix), .y = @intCast(iy), .offset = offset, .count = material.items.len });
    };
    return result;
}
