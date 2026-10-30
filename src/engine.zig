//! General local-coordinate geometry and transactional block rasterization.
const std = @import("std");
pub const core = @import("core.zig");
pub const V = [3]f64;
pub const Coverage = enum(u8) { outside, inside, partial };
pub fn add(a: V, b: V) V {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}
pub fn sub(a: V, b: V) V {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}
pub fn scale(a: V, s: f64) V {
    return .{ a[0] * s, a[1] * s, a[2] * s };
}
pub fn dot(a: V, b: V) f64 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
pub fn norm(a: V) f64 {
    return @sqrt(dot(a, a));
}
pub fn cross(a: V, b: V) V {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}
pub fn validV(v: V) !void {
    for (v) |x| if (!std.math.isFinite(x) or @abs(x) > 1e6) return error.InvalidCoordinate;
}
fn positive(x: f64) !void {
    if (!std.math.isFinite(x) or x <= 0 or x > 1e6) return error.InvalidDimension;
}
pub const Bounds = struct {
    lo: V,
    hi: V,
    pub fn validate(b: Bounds) !void {
        try validV(b.lo);
        try validV(b.hi);
        for (0..3) |i| if (b.lo[i] >= b.hi[i]) return error.InvalidBounds;
    }
    pub fn expanded(b: Bounds, r: f64) Bounds {
        return .{ .lo = add(b.lo, .{ -r, -r, -r }), .hi = add(b.hi, .{ r, r, r }) };
    }
};
pub const Sphere = struct { center: V, radius: f64 };
pub const Cylinder = struct { base: V, axis: V = .{ 0, 0, 1 }, radius: f64, length: f64 };
pub const Capsule = struct { a: V, b: V, radius: f64 };
pub const Annulus = struct { base: V, axis: V, inner: f64, outer: f64, length: f64 };
pub const Plane = struct { normal: V, offset: f64 }; // removes dot(normal,p) >= offset
pub const Primitive = union(enum) {
    annulus: Annulus,
    box: Bounds,
    sphere: Sphere,
    cylinder: Cylinder,
    capsule: Capsule,
    halfspace: Plane,
    pub fn validate(s: Primitive) !void {
        switch (s) {
            .annulus => |v| {
                try validV(v.base);
                try unit(v.axis);
                try positive(v.outer);
                try positive(v.length);
                if (!std.math.isFinite(v.inner) or v.inner < 0 or v.inner >= v.outer) return error.InvalidDimension;
            },
            .box => |b| try b.validate(),
            .sphere => |v| {
                try validV(v.center);
                try positive(v.radius);
            },
            .cylinder => |v| {
                try validV(v.base);
                try unit(v.axis);
                try positive(v.radius);
                try positive(v.length);
            },
            .capsule => |v| {
                try validV(v.a);
                try validV(v.b);
                try positive(v.radius);
            },
            .halfspace => |v| {
                try unit(v.normal);
                if (!std.math.isFinite(v.offset) or @abs(v.offset) > 1e6) return error.InvalidCoordinate;
            },
        }
    }
    pub fn distance(s: Primitive, p: V) f64 {
        return switch (s) {
            .annulus => |v| blk: {
                const d = sub(p, v.base);
                const z = dot(d, v.axis);
                const r = norm(sub(d, scale(v.axis, z)));
                const radial = if (v.inner == 0) r - v.outer else @abs(r - (v.inner + v.outer) / 2) - (v.outer - v.inner) / 2;
                break :blk sd2(radial, @abs(z - v.length / 2) - v.length / 2);
            },
            .sphere => |v| norm(sub(p, v.center)) - v.radius,
            .capsule => |v| blk: {
                const d = sub(v.b, v.a);
                const t = if (dot(d, d) == 0) 0 else std.math.clamp(dot(sub(p, v.a), d) / dot(d, d), 0, 1);
                break :blk norm(sub(p, add(v.a, scale(d, t)))) - v.radius;
            },
            .halfspace => |v| v.offset - dot(v.normal, p),
            .cylinder => |v| blk: {
                const d = sub(p, v.base);
                const z = dot(d, v.axis);
                break :blk sd2(norm(sub(d, scale(v.axis, z))) - v.radius, @abs(z - v.length / 2) - v.length / 2);
            },
            .box => |b| blk: {
                const c = scale(add(b.lo, b.hi), 0.5);
                const e = scale(sub(b.hi, b.lo), 0.5);
                const d = sub(p, c);
                const q = V{ @abs(d[0]) - e[0], @abs(d[1]) - e[1], @abs(d[2]) - e[2] };
                break :blk norm(.{ @max(q[0], 0), @max(q[1], 0), @max(q[2], 0) }) + @min(@max(q[0], @max(q[1], q[2])), 0);
            },
        };
    }
    pub fn bounds(s: Primitive) Bounds {
        return switch (s) {
            .annulus => |v| segmentBounds(v.base, add(v.base, scale(v.axis, v.length))).expanded(v.outer),
            .box => |b| b,
            .sphere => |v| (Bounds{ .lo = v.center, .hi = v.center }).expanded(v.radius),
            .capsule => |v| segmentBounds(v.a, v.b).expanded(v.radius),
            .cylinder => |v| segmentBounds(v.base, add(v.base, scale(v.axis, v.length))).expanded(v.radius),
            .halfspace => .{ .lo = .{ -1e6, -1e6, -1e6 }, .hi = .{ 1e6, 1e6, 1e6 } },
        };
    }
};
pub fn unit(v: V) !void {
    try validV(v);
    if (@abs(norm(v) - 1) > 1e-10) return error.AxisMustBeUnit;
}
fn sd2(x: f64, y: f64) f64 {
    return @sqrt(@max(x, 0) * @max(x, 0) + @max(y, 0) * @max(y, 0)) + @min(@max(x, y), 0);
}
pub fn segmentBounds(a: V, b: V) Bounds {
    var out: Bounds = undefined;
    for (0..3) |i| {
        out.lo[i] = @min(a[i], b[i]);
        out.hi[i] = @max(a[i], b[i]);
    }
    return out;
}
pub const ToolKind = enum { flat, ball, bull, taper, drill };
pub const Tool = struct {
    kind: ToolKind = .flat,
    radius: f64,
    length: f64,
    corner: f64 = 0,
    tip_radius: f64 = 0,
    pub fn validate(t: Tool) !void {
        try positive(t.radius);
        try positive(t.length);
        if (!std.math.isFinite(t.corner) or !std.math.isFinite(t.tip_radius)) return error.InvalidTool;
        switch (t.kind) {
            .flat => if (t.corner != 0 or t.tip_radius != 0) return error.InvalidTool,
            .ball => if (t.length < t.radius or t.corner != 0 or t.tip_radius != 0) return error.InvalidTool,
            .bull => if (t.corner <= 0 or t.corner > t.radius or t.corner > t.length or t.tip_radius != 0) return error.InvalidTool,
            .taper => if (t.tip_radius < 0 or t.tip_radius > t.radius or t.corner != 0) return error.InvalidTool,
            .drill => if (t.tip_radius != 0 or t.corner != 0) return error.InvalidTool,
        }
    }
    // Exact signed distance to a solid of revolution. Ball includes the cylindrical flute.
    pub fn distance(t: Tool, r: f64, z: f64) f64 {
        switch (t.kind) {
            .flat => return sd2(r - t.radius, @abs(z - t.length / 2) - t.length / 2),
            .ball, .bull => {
                const c = if (t.kind == .ball) t.radius else t.corner;
                const qx = r - (t.radius - c);
                const qz = c - z;
                const lower = if (qx > 0 and qz > 0) @sqrt(qx * qx + qz * qz) - c else @max(qx, qz) - c;
                // The top intersects the vertical side at a sharp corner; use Euclidean corner distance.
                if (z > t.length) return sd2(r - t.radius, z - t.length);
                return @max(lower, z - t.length);
            },
            .taper, .drill => {
                const r0 = if (t.kind == .drill) 0 else t.tip_radius;
                const dr = t.radius - r0;
                const dz = t.length;
                const k = std.math.clamp(((r - r0) * dr + z * dz) / (dr * dr + dz * dz), 0, 1);
                const side = @sqrt((r - r0 - k * dr) * (r - r0 - k * dr) + (z - k * dz) * (z - k * dz));
                const bottom = @sqrt(@max(r - r0, 0) * @max(r - r0, 0) + z * z);
                const top = @sqrt(@max(r - t.radius, 0) * @max(r - t.radius, 0) + (z - dz) * (z - dz));
                const d = @min(side, @min(bottom, top));
                return if (z >= 0 and z <= dz and r <= r0 + dr * z / dz) -d else d;
            },
        }
    }
};
pub const Pose = struct {
    position: V,
    axis: V = .{ 0, 0, 1 },
    pub fn validate(p: Pose) !void {
        try validV(p.position);
        try unit(p.axis);
    }
};
pub const Sweep = struct {
    tool: Tool,
    a: Pose,
    b: Pose,
    tolerance_mm: f64 = 0.02,
    dilation_mm: f64 = 0,
    pub fn validate(s: Sweep) !void {
        try s.tool.validate();
        try s.a.validate();
        try s.b.validate();
        try positive(s.tolerance_mm);
        if (!std.math.isFinite(s.dilation_mm) or s.dilation_mm < 0 or s.dilation_mm > 1e6) return error.InvalidMotionTolerance;
        if (!std.mem.eql(f64, &s.a.axis, &s.b.axis)) return error.OrientationChangeUnsupported;
        if (s.samples() > 1000000) return error.MotionToleranceTooSmall;
    }
    pub fn exact(s: Sweep) bool {
        return s.tool.kind == .flat;
    }
    pub fn samples(s: Sweep) usize {
        if (s.exact()) return 1;
        const n = @ceil(norm(sub(s.b.position, s.a.position)) / (2 * s.tolerance_mm));
        if (!std.math.isFinite(n) or n > 1000000) return 1000001;
        return @max(1, @as(usize, @intFromFloat(n)));
    }
    pub fn errorBound(s: Sweep) f64 {
        return (if (s.exact()) @sqrt(@as(f64, 2)) * s.dilation_mm else s.dilation_mm) + (if (s.exact() or norm(sub(s.b.position, s.a.position)) == 0) @as(f64, 0) else norm(sub(s.b.position, s.a.position)) / (2 * @as(f64, @floatFromInt(s.samples()))));
    }
    pub fn bounds(s: Sweep) Bounds {
        const e = @sqrt(s.tool.radius * s.tool.radius + s.tool.length * s.tool.length) + s.errorBound();
        return segmentBounds(s.a.position, s.b.position).expanded(e);
    }
    // Exact finite-cylinder sweep: intersect the time interval admitted by axial caps
    // with the interval admitted by the radial quadratic. Never substitutes a capsule.
    pub fn flatContains(s: Sweep, p: V, margin: f64) bool {
        const u = s.a.axis;
        const q = sub(p, s.a.position);
        const v = sub(s.b.position, s.a.position);
        const z = dot(q, u);
        const vz = dot(v, u);
        var lo: f64 = 0;
        var hi: f64 = 1;
        const eps = core.tolerance + s.dilation_mm - margin;
        if (vz == 0) {
            if (z < -eps or z > s.tool.length + eps) return false;
        } else {
            const t0 = (z - s.tool.length - eps) / vz;
            const t1 = (z + eps) / vz;
            lo = @max(lo, @min(t0, t1));
            hi = @min(hi, @max(t0, t1));
            if (lo > hi) return false;
        }
        const qr = sub(q, scale(u, z));
        const vr = sub(v, scale(u, vz));
        const vv = dot(vr, vr);
        const t = if (vv == 0) lo else std.math.clamp(dot(qr, vr) / vv, lo, hi);
        const r = s.tool.radius + eps;
        if (r < 0) return false;
        const d = sub(qr, scale(vr, t));
        return dot(d, d) <= r * r;
    }
    fn poseDistance(s: Sweep, p: V, i: usize, n: usize) f64 {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
        const q = sub(p, add(s.a.position, scale(sub(s.b.position, s.a.position), t)));
        const z = dot(q, s.a.axis);
        return s.tool.distance(norm(sub(q, scale(s.a.axis, z))), z);
    }
    pub fn distance(s: Sweep, p: V) f64 {
        return s.distanceCounted(p, false, null);
    }
    pub fn distanceFast(s: Sweep, p: V) f64 {
        return s.distanceCounted(p, true, null);
    }
    pub fn distanceCounted(s: Sweep, p: V, optimized: bool, evaluations: ?*u64) f64 {
        const n = s.samples();
        var lo: usize = 0;
        var hi = n;
        // The complete ball tool is convex; its signed distance restricted to
        // a translation line is convex. Minimize on the SAME discrete pose lattice.
        // Keep the original pose arithmetic and a final exhaustive small bracket.
        if (optimized and s.tool.kind == .ball) while (hi - lo > 8) {
            const mid = lo + (hi - lo) / 2;
            const left = s.poseDistance(p, mid, n);
            const right = s.poseDistance(p, mid + 1, n);
            if (evaluations) |v| v.* += 2;
            if (left < right) hi = mid + 1 else lo = mid;
        };
        var best: f64 = std.math.inf(f64);
        for (lo..hi + 1) |i| best = @min(best, s.poseDistance(p, i, n));
        if (evaluations) |v| v.* += hi + 1 - lo;
        return best - s.errorBound();
    }
};
fn capsuleContains(cap: Capsule, p: V, margin: f64) bool {
    const d = sub(cap.b, cap.a);
    const t = if (dot(d, d) == 0) 0 else std.math.clamp(dot(sub(p, cap.a), d) / dot(d, d), 0, 1);
    const q = sub(p, add(cap.a, scale(d, t)));
    const r = @max(0, cap.radius + core.tolerance - margin);
    return dot(q, q) <= r * r;
}
pub const Shape = union(enum) {
    primitive: Primitive,
    sweep: Sweep,
    path: []const Sweep,
    pub fn validate(s: Shape) !void {
        switch (s) {
            .path => |v| {
                if (v.len == 0) return error.EmptyMotion;
                for (v) |segment| try segment.validate();
            },
            .primitive => |v| try v.validate(),
            .sweep => |v| try v.validate(),
        }
    }
    pub fn bounds(s: Shape) Bounds {
        return switch (s) {
            .path => |v| blk: {
                var b = v[0].bounds();
                for (v[1..]) |segment| {
                    const bb = segment.bounds();
                    for (0..3) |j| {
                        b.lo[j] = @min(b.lo[j], bb.lo[j]);
                        b.hi[j] = @max(b.hi[j], bb.hi[j]);
                    }
                }
                break :blk b;
            },
            .primitive => |v| v.bounds(),
            .sweep => |v| v.bounds(),
        };
    }
    // Tight bound for the canonical +Z finite cylinder. Other orientations retain
    // the conservative general bound. Scalar subtraction keeps the original bound.
    pub fn cuttingBounds(s: Shape) Bounds {
        if (s == .sweep and std.mem.eql(f64, &s.sweep.a.axis, &V{ 0, 0, 1 })) {
            const v = s.sweep;
            const eps = core.tolerance + v.errorBound();
            var b = segmentBounds(v.a.position, v.b.position);
            for (0..2) |j| {
                b.lo[j] -= v.tool.radius + eps;
                b.hi[j] += v.tool.radius + eps;
            }
            b.lo[2] -= eps;
            b.hi[2] += v.tool.length + eps;
            return b;
        }
        return s.bounds();
    }
    pub fn contains(s: Shape, p: V) bool {
        return switch (s) {
            .path => |v| blk: {
                for (v) |segment| if ((Shape{ .sweep = segment }).contains(p)) break :blk true;
                break :blk false;
            },
            .primitive => |v| blk: {
                if (v == .capsule) break :blk capsuleContains(v.capsule, p, 0);
                break :blk v.distance(p) <= core.tolerance;
            },
            .sweep => |v| if (v.exact()) v.flatContains(p, 0) else v.distance(p) <= core.tolerance,
        };
    }
    pub fn classify(s: Shape, b: Bounds) Coverage {
        if (s == .sweep) {
            if (FlatZ.init(s.sweep)) |flat| return flat.classify(b);
        }
        if (s == .path) {
            var partial = false;
            for (s.path) |segment| switch ((Shape{ .sweep = segment }).classify(b)) {
                .inside => return .inside,
                .partial => partial = true,
                .outside => {},
            };
            return if (partial) .partial else .outside;
        }
        if (s == .primitive) switch (s.primitive) {
            .box => |box| {
                var inside = true;
                for (0..3) |j| {
                    if (b.hi[j] < box.lo[j] - core.tolerance - 1e-8 or b.lo[j] > box.hi[j] + core.tolerance + 1e-8) return .outside;
                    if (b.lo[j] < box.lo[j] + 1e-8 or b.hi[j] > box.hi[j] - 1e-8) inside = false;
                }
                if (inside) return .inside;
            },
            .halfspace => |plane| {
                var low: f64 = 0;
                var high: f64 = 0;
                for (0..3) |j| {
                    low += @min(plane.normal[j] * b.lo[j], plane.normal[j] * b.hi[j]);
                    high += @max(plane.normal[j] * b.lo[j], plane.normal[j] * b.hi[j]);
                }
                if (low > plane.offset + 1e-8) return .inside;
                if (high < plane.offset - core.tolerance - 1e-8) return .outside;
                return .partial;
            },
            .cylinder => |v| {
                if (std.mem.eql(f64, &v.axis, &V{ 0, 0, 1 })) {
                    var min2: f64 = 0;
                    var max2: f64 = 0;
                    for (0..2) |j| {
                        const mn = @max(@max(b.lo[j] - v.base[j], v.base[j] - b.hi[j]), 0);
                        const mx = @max(@abs(b.lo[j] - v.base[j]), @abs(b.hi[j] - v.base[j]));
                        min2 += mn * mn;
                        max2 += mx * mx;
                    }
                    if (min2 > (v.radius + 1e-8) * (v.radius + 1e-8) or b.lo[2] > v.base[2] + v.length + 1e-8 or b.hi[2] < v.base[2] - 1e-8) return .outside;
                    if (max2 < @max(0, v.radius - 1e-8) * @max(0, v.radius - 1e-8) and b.lo[2] > v.base[2] + 1e-8 and b.hi[2] < v.base[2] + v.length - 1e-8) return .inside;
                    return .partial;
                }
            },
            else => {},
        };
        const mid = scale(add(b.lo, b.hi), 0.5);
        const rad = norm(scale(sub(b.hi, b.lo), 0.5)) * (1 + 1e-8);
        if (s == .primitive and s.primitive == .capsule) {
            const cap = s.primitive.capsule;
            var all = true;
            for (0..8) |i| {
                const p = V{ if (i & 1 == 0) b.lo[0] else b.hi[0], if (i & 2 == 0) b.lo[1] else b.hi[1], if (i & 4 == 0) b.lo[2] else b.hi[2] };
                if (!capsuleContains(cap, p, 1e-8)) {
                    all = false;
                    break;
                }
            }
            if (all) return .inside;
            if (!capsuleContains(cap, mid, -rad - 1e-8)) return .outside;
            return .partial;
        }
        if (s == .sweep and s.sweep.exact()) {
            var all = true;
            for (0..8) |i| {
                const p = V{ if (i & 1 == 0) b.lo[0] else b.hi[0], if (i & 2 == 0) b.lo[1] else b.hi[1], if (i & 4 == 0) b.lo[2] else b.hi[2] };
                if (!s.sweep.flatContains(p, 1e-8)) {
                    all = false;
                    break;
                }
            }
            if (all) return .inside;
            // Expanding both cylinder radius and axial caps by the center-box radius
            // contains the Minkowski expansion, so rejection is conservative.
            if (!s.sweep.flatContains(mid, -rad - 1e-8)) return .outside;
            return .partial;
        }
        const d = switch (s) {
            .path => unreachable,
            .primitive => |v| v.distance(mid),
            .sweep => |v| v.distanceFast(mid),
        };
        if (d > rad + core.tolerance + 1e-8) return .outside;
        if (d < -rad - 1e-8) return .inside;
        if (s == .primitive and s.primitive == .capsule and d < 0) {
            var all = true;
            for (0..8) |i| {
                const p = V{ if (i & 1 == 0) b.lo[0] else b.hi[0], if (i & 2 == 0) b.lo[1] else b.hi[1], if (i & 4 == 0) b.lo[2] else b.hi[2] };
                if (s.primitive.distance(p) > -1e-8) {
                    all = false;
                    break;
                }
            }
            if (all) return .inside;
        }
        return .partial;
    }
};
pub const FlatColumn = struct { coverage: Coverage, bits: u64 = 0, ready: bool = false };
pub const Work = struct { candidate_blocks: u64 = 0, partial_blocks: u64 = 0, voxel_tests: u64 = 0, point_pose_evaluations: u64 = 0 };
pub const Changes = struct {
    work: Work = .{},
    bytes: std.ArrayList(u8) = .empty,
    // One byte per candidate-range block, reused between operations. Geometry
    // classification happens before mutation and is not repeated by the write pass.
    coverage: std.ArrayList(Coverage) = .empty,
    flat_columns: std.ArrayList(FlatColumn) = .empty,
    removed: u64 = 0,
    blocks: usize = 0,
    affected: ?Bounds = null,
    pub fn deinit(c: *Changes, a: std.mem.Allocator) void {
        c.bytes.deinit(a);
        c.coverage.deinit(a);
        c.flat_columns.deinit(a);
    }
};
pub const Range = struct { lo: [3]usize, hi: [3]usize };
fn range(g: core.Grid, b: Bounds) Range {
    var r: Range = undefined;
    for (0..3) |j| {
        const n: f64 = @floatFromInt(g.n[j]);
        const low = std.math.clamp(@floor((b.lo[j] - 4 * core.tolerance - g.origin[j]) / g.h) - 1, 0, n);
        const high = std.math.clamp(@ceil((b.hi[j] + 4 * core.tolerance - g.origin[j]) / g.h) + 1, 0, n);
        r.lo[j] = @as(usize, @intFromFloat(low)) / 8;
        r.hi[j] = (@as(usize, @intFromFloat(high)) + 7) / 8;
        r.hi[j] = @max(r.lo[j], r.hi[j]);
    }
    return r;
}
pub fn clippedRange(g: core.Grid, input: Bounds) Range {
    var b = input;
    if (g.material_bounds) |mb| for (0..3) |j| {
        b.lo[j] = @max(b.lo[j], mb[0][j]);
        b.hi[j] = @min(b.hi[j], mb[1][j]);
    };
    for (0..3) |j| if (b.lo[j] > b.hi[j]) return .{ .lo = .{ 0, 0, 0 }, .hi = .{ 0, 0, 0 } };
    return range(g, b);
}

// The capsule × axial-interval product is valid only for this exact motion.
// Evaluate the same f64 expression order as flatContains, once per occupied XY
// column instead of once per voxel. No stepped poses and no additional dilation.
pub const FlatZ = struct {
    pub const F = @Vector(8, f64);
    sweep: Sweep,
    dx: f64,
    dy: f64,
    vv: f64,
    eps: f64,
    pub fn init(s: Sweep) ?FlatZ {
        if (!s.exact() or (s.a.position[2] != s.b.position[2] and
            (s.a.position[0] != s.b.position[0] or s.a.position[1] != s.b.position[1])) or
            !std.mem.eql(f64, &s.a.axis, &V{ 0, 0, 1 })) return null;
        const d = sub(s.b.position, s.a.position);
        return .{ .sweep = s, .dx = d[0], .dy = d[1], .vv = d[0] * d[0] + d[1] * d[1], .eps = core.tolerance + s.dilation_mm };
    }
    fn xyContains(f: FlatZ, x: f64, y: f64, margin: f64) bool {
        const qx = x - f.sweep.a.position[0];
        const qy = y - f.sweep.a.position[1];
        const t = if (f.vv == 0) 0 else std.math.clamp((qx * f.dx + qy * f.dy) / f.vv, 0, 1);
        const ex = qx - f.dx * t;
        const ey = qy - f.dy * t;
        const r = f.sweep.tool.radius + f.eps - margin;
        return r >= 0 and ex * ex + ey * ey <= r * r;
    }
    fn classify(f: FlatZ, b: Bounds) Coverage {
        return f.classifyWithXY(b, f.classifyXY(b));
    }
    fn classifyWithXY(f: FlatZ, b: Bounds, xy: Coverage) Coverage {
        const low = b.lo[2] - @max(f.sweep.a.position[2], f.sweep.b.position[2]);
        const high = b.hi[2] - @min(f.sweep.a.position[2], f.sweep.b.position[2]);
        if (xy == .outside or high < -f.eps - 1e-8 or low > f.sweep.tool.length + f.eps + 1e-8) return .outside;
        if (xy == .inside and
            b.lo[2] - @min(f.sweep.a.position[2], f.sweep.b.position[2]) >= -f.eps + 1e-8 and
            b.hi[2] - @max(f.sweep.a.position[2], f.sweep.b.position[2]) <= f.sweep.tool.length + f.eps - 1e-8) return .inside;
        return .partial;
    }
    fn classifyXY(f: FlatZ, b: Bounds) Coverage {
        if (f.xyContains(b.lo[0], b.lo[1], 1e-8) and f.xyContains(b.hi[0], b.lo[1], 1e-8) and
            f.xyContains(b.lo[0], b.hi[1], 1e-8) and f.xyContains(b.hi[0], b.hi[1], 1e-8)) return .inside;
        const mid = scale(add(b.lo, b.hi), 0.5);
        const half = scale(sub(b.hi, b.lo), 0.5);
        const radius = @sqrt(half[0] * half[0] + half[1] * half[1]) * (1 + 1e-8);
        if (!f.xyContains(mid[0], mid[1], -radius - 1e-8)) return .outside;
        return .partial;
    }
    pub fn radial8(f: FlatZ, qx: F, qy: F) @Vector(8, bool) {
        const dx: F = @splat(f.dx);
        const dy: F = @splat(f.dy);
        const t = if (f.vv == 0) @as(F, @splat(0)) else @min(@as(F, @splat(1)), @max(@as(F, @splat(0)), (qx * dx + qy * dy) / @as(F, @splat(f.vv))));
        const ex = qx - dx * t;
        const ey = qy - dy * t;
        const radius = f.sweep.tool.radius + f.eps;
        return ex * ex + ey * ey <= @as(F, @splat(radius * radius));
    }
    // Preserve the scalar time-interval arithmetic for vertical translations,
    // including its boundary rounding; do not replace it with shifted endpoints.
    fn axialContains(f: FlatZ, z: f64) bool {
        const vz = f.sweep.b.position[2] - f.sweep.a.position[2];
        if (vz == 0) return z >= -f.eps and z <= f.sweep.tool.length + f.eps;
        const t0 = (z - f.sweep.tool.length - f.eps) / vz;
        const t1 = (z + f.eps) / vz;
        return @max(@as(f64, 0), @min(t0, t1)) <= @min(@as(f64, 1), @max(t0, t1));
    }
    // Batch API used by the diagnostic benchmark; same radial kernel as masks.
    pub fn contains8(f: FlatZ, p: [3]F) @Vector(8, bool) {
        const z = p[2] - @as(F, @splat(f.sweep.a.position[2]));
        var axial = (z >= @as(F, @splat(-f.eps))) & (z <= @as(F, @splat(f.sweep.tool.length + f.eps)));
        if (f.sweep.a.position[2] != f.sweep.b.position[2]) {
            inline for (0..8) |lane| axial[lane] = f.axialContains(z[lane]);
        }
        return f.radial8(p[0] - @as(F, @splat(f.sweep.a.position[0])), p[1] - @as(F, @splat(f.sweep.a.position[1]))) & axial;
    }
    fn mask(f: FlatZ, g: core.Grid, b: [3]usize, available: core.Bits) core.Bits {
        const extent = g.extent(b);
        var result: core.Bits = @splat(0);
        var axial: [8]bool = @splat(false);
        var columns: u64 = 0;
        for (0..extent[2]) |z| {
            const qz = (g.origin[2] + g.center(b[2] * 8 + z)) - f.sweep.a.position[2];
            axial[z] = f.axialContains(qz);
            if (axial[z]) columns |= available[z];
        }
        const xy = f.xyMask(g, b, columns);
        for (0..extent[2]) |z| if (axial[z]) {
            result[z] = available[z] & xy;
        };
        return result;
    }
    fn maskWithXY(f: FlatZ, g: core.Grid, b: [3]usize, available: core.Bits, xy: u64) core.Bits {
        var result: core.Bits = @splat(0);
        for (0..g.extent(b)[2]) |z| {
            const qz = (g.origin[2] + g.center(b[2] * 8 + z)) - f.sweep.a.position[2];
            if (f.axialContains(qz)) result[z] = available[z] & xy;
        }
        return result;
    }
    fn xyMask(f: FlatZ, g: core.Grid, b: [3]usize, input: u64) u64 {
        const extent = g.extent(b);
        var columns = input;
        var xy: u64 = 0;
        const radius = f.sweep.tool.radius + f.eps;
        if (@popCount(columns) <= 4) {
            while (columns != 0) {
                const bit: u6 = @intCast(@ctz(columns));
                columns &= columns - 1;
                const x = @as(usize, bit) % 8;
                const y = @as(usize, bit) / 8;
                const qx = (g.origin[0] + g.center(b[0] * 8 + x)) - f.sweep.a.position[0];
                const qy = (g.origin[1] + g.center(b[1] * 8 + y)) - f.sweep.a.position[1];
                const t = if (f.vv == 0) 0 else std.math.clamp((qx * f.dx + qy * f.dy) / f.vv, 0, 1);
                const ex = qx - f.dx * t;
                const ey = qy - f.dy * t;
                if (ex * ex + ey * ey <= radius * radius) xy |= @as(u64, 1) << bit;
            }
        } else {
            var qx: F = undefined;
            inline for (0..8) |x| qx[x] = (g.origin[0] + g.center(b[0] * 8 + x)) - f.sweep.a.position[0];
            for (0..extent[1]) |y| {
                const shift: u6 = @intCast(y * 8);
                if ((columns >> shift) & 0xff == 0) continue;
                const qy: F = @splat((g.origin[1] + g.center(b[1] * 8 + y)) - f.sweep.a.position[1]);
                const hits: u8 = @bitCast(f.radial8(qx, qy));
                xy |= @as(u64, hits) << shift;
            }
        }
        return xy;
    }
};

pub fn blockBounds(g: core.Grid, b: [3]usize) Bounds {
    const e = g.extent(b);
    var out: Bounds = undefined;
    for (0..3) |j| {
        out.lo[j] = g.origin[j] + g.center(b[j] * 8);
        out.hi[j] = g.origin[j] + g.center(b[j] * 8 + e[j] - 1);
    }
    return out;
}
pub fn mask(g: core.Grid, b: [3]usize, s: Shape, reference: bool, available: core.Bits) core.Bits {
    return classifiedMask(g, b, s, reference, available, if (reference) .partial else s.classify(blockBounds(g, b)), null);
}
fn classifiedMask(g: core.Grid, b: [3]usize, s: Shape, reference: bool, available: core.Bits, coverage: Coverage, work: ?*Work) core.Bits {
    switch (coverage) {
        .outside => return @splat(0),
        .inside => return available,
        .partial => {},
    }
    if (!reference and s == .sweep) {
        if (FlatZ.init(s.sweep)) |flat| return flat.mask(g, b, available);
    }
    var bits: core.Bits = @splat(0);
    const e = g.extent(b);
    for (0..e[2]) |z| for (0..e[1]) |y| for (0..e[0]) |x| {
        if (available[z] & (@as(u64, 1) << @as(u6, @intCast(y * 8 + x))) == 0) continue;
        const p = add(g.origin, .{ g.center(b[0] * 8 + x), g.center(b[1] * 8 + y), g.center(b[2] * 8 + z) });
        if (work) |w| w.voxel_tests += 1;
        const inside = if (s == .sweep and !s.sweep.exact()) s.sweep.distanceCounted(p, !reference, if (work) |w| &w.point_pose_evaluations else null) <= core.tolerance else s.contains(p);
        if (inside) bits[z] |= @as(u64, 1) << @as(u6, @intCast(y * 8 + x));
    };
    return bits;
}
pub fn count(bits: core.Bits) u64 {
    var n: u64 = 0;
    for (bits) |w| n += @popCount(w);
    return n;
}
fn writeChange(c: *Changes, i: usize, old: u32, new: u32, before: core.Bits, after: core.Bits) void {
    var header: [12]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], @intCast(i), .little);
    std.mem.writeInt(u32, header[4..8], old, .little);
    std.mem.writeInt(u32, header[8..12], new, .little);
    c.bytes.appendSliceAssumeCapacity(&header);
    if (old < core.full) c.bytes.appendSliceAssumeCapacity(std.mem.asBytes(&before));
    if (new < core.full) c.bytes.appendSliceAssumeCapacity(std.mem.asBytes(&after));
}
pub fn subtract(g: *core.Grid, s: Shape, c: *Changes, reference: bool) !void {
    try s.validate();
    c.work = .{};
    var bounds = if (reference) s.bounds() else s.cuttingBounds();
    if (g.material_bounds) |mb| for (0..3) |j| {
        bounds.lo[j] = @max(bounds.lo[j], mb[0][j]);
        bounds.hi[j] = @min(bounds.hi[j], mb[1][j]);
    };
    if (s == .primitive and s.primitive == .halfspace) {
        const plane = s.primitive.halfspace;
        for (0..3) |j| {
            if (@abs(plane.normal[j]) < 1e-15) continue;
            var rest: f64 = 0;
            for (0..3) |k| if (k != j) {
                rest += @max(plane.normal[k] * bounds.lo[k], plane.normal[k] * bounds.hi[k]);
            };
            const v = (plane.offset - rest - core.tolerance) / plane.normal[j];
            if (plane.normal[j] > 0) bounds.lo[j] = @max(bounds.lo[j], v) else bounds.hi[j] = @min(bounds.hi[j], v);
        }
    }
    const r = clippedRange(g.*, bounds);
    const flat = if (!reference and s == .sweep) FlatZ.init(s.sweep) else null;
    const row_count = r.hi[0] - r.lo[0];
    if (!reference) {
        const xy_count = try std.math.mul(usize, r.hi[0] - r.lo[0], r.hi[1] - r.lo[1]);
        const block_count = try std.math.mul(usize, xy_count, r.hi[2] - r.lo[2]);
        try c.coverage.ensureTotalCapacityPrecise(g.allocator, block_count);
        c.coverage.clearRetainingCapacity();
        if (flat) |f| {
            try c.flat_columns.resize(g.allocator, xy_count);
            for (r.lo[1]..r.hi[1]) |y| for (r.lo[0]..r.hi[0]) |x| {
                c.flat_columns.items[(y - r.lo[1]) * row_count + x - r.lo[0]] = .{
                    .coverage = f.classifyXY(blockBounds(g.*, .{ x, y, 0 })),
                };
            };
        }
    }
    var needed: usize = 0;
    var candidates: usize = 0;
    for (r.lo[2]..r.hi[2]) |z| for (r.lo[1]..r.hi[1]) |y| for (r.lo[0]..r.hi[0]) |x| {
        const b = [3]usize{ x, y, z };
        const d = g.blocks[g.blockIndex(b)];
        const coverage: Coverage = if (d == core.empty) .outside else if (reference) .partial else if (flat) |f| f.classifyWithXY(blockBounds(g.*, b), c.flat_columns.items[(y - r.lo[1]) * row_count + x - r.lo[0]].coverage) else s.classify(blockBounds(g.*, b));
        if (!reference) c.coverage.appendAssumeCapacity(coverage);
        if (coverage == .outside) continue;
        candidates += 1;
        c.work.candidate_blocks += 1;
        if (coverage == .partial) c.work.partial_blocks += 1;
        if (d == core.full and coverage == .partial) needed += 1;
    };
    try c.bytes.ensureTotalCapacityPrecise(g.allocator, try std.math.mul(usize, candidates, 140));
    const capacity = try std.math.add(usize, g.pool.items.len, needed);
    if (capacity >= core.full) return error.PoolTooLarge;
    try g.pool.ensureTotalCapacityPrecise(g.allocator, capacity);
    c.bytes.clearRetainingCapacity();
    c.removed = 0;
    c.blocks = 0;
    c.affected = null;
    var coverage_index: usize = 0;
    for (r.lo[2]..r.hi[2]) |z| for (r.lo[1]..r.hi[1]) |y| for (r.lo[0]..r.hi[0]) |x| {
        const b = [3]usize{ x, y, z };
        const i = g.blockIndex(b);
        const d = g.blocks[i];
        const coverage: Coverage = if (reference) .partial else c.coverage.items[coverage_index];
        coverage_index += 1;
        if (d == core.empty or coverage == .outside) continue;
        const before = g.bits(i);
        var after = before;
        const m = if (coverage == .partial and flat != null) blk: {
            const column = &c.flat_columns.items[(y - r.lo[1]) * row_count + x - r.lo[0]];
            if (!column.ready) {
                column.bits = flat.?.xyMask(g.*, b, g.validBits(b)[0]);
                column.ready = true;
            }
            break :blk flat.?.maskWithXY(g.*, b, before, column.bits);
        } else classifiedMask(g.*, b, s, reference, before, coverage, &c.work);
        for (&after, m) |*w, v| w.* &= ~v;
        if (std.mem.eql(u64, &before, &after)) continue;
        const remaining = count(after);
        c.removed += count(before) - remaining;
        c.blocks += 1;
        const bb = blockBounds(g.*, b).expanded(g.h / 2);
        if (c.affected) |*a| {
            for (0..3) |j| {
                a.lo[j] = @min(a.lo[j], bb.lo[j]);
                a.hi[j] = @max(a.hi[j], bb.hi[j]);
            }
        } else c.affected = bb;
        if (remaining == 0) {
            g.blocks[i] = core.empty;
        } else if (d == core.full) {
            g.blocks[i] = @intCast(g.pool.items.len);
            g.pool.appendAssumeCapacity(after);
        } else g.pool.items[d] = after;
        writeChange(c, i, d, g.blocks[i], before, after);
    };
}
// Initial stock is a union of primitives; allocation failure destroys the unpublished grid.
pub fn stock(a: std.mem.Allocator, b: Bounds, h: f64, primitives: []const Primitive) !core.Grid {
    try b.validate();
    if (primitives.len == 0) return error.EmptyStockDefinition;
    for (primitives) |p| try p.validate();
    var g = try core.Grid.init(a, sub(b.hi, b.lo), h);
    errdefer g.deinit();
    g.origin = b.lo;
    @memset(g.blocks, core.empty);
    var active = Bounds{ .lo = b.hi, .hi = b.lo };
    for (primitives) |p| {
        const pb = p.bounds();
        for (0..3) |j| {
            active.lo[j] = @min(active.lo[j], pb.lo[j]);
            active.hi[j] = @max(active.hi[j], pb.hi[j]);
        }
    }
    for (0..3) |j| {
        active.lo[j] = @max(active.lo[j], b.lo[j]);
        active.hi[j] = @min(active.hi[j], b.hi[j]);
    }
    g.material_bounds = .{ active.lo, active.hi };
    if (primitives.len == 1 and primitives[0] == .cylinder and std.mem.eql(f64, &primitives[0].cylinder.axis, &V{ 0, 0, 1 })) {
        try fillCylinderZ(&g, primitives[0].cylinder);
        return g;
    }
    for (primitives) |p| {
        const s = Shape{ .primitive = p };
        const r = range(g, s.bounds());
        for (r.lo[2]..r.hi[2]) |z| for (r.lo[1]..r.hi[1]) |y| for (r.lo[0]..r.hi[0]) |x| {
            const coords = [3]usize{ x, y, z };
            const i = g.blockIndex(coords);
            if (g.blocks[i] == core.full) continue;
            const m = mask(g, coords, s, false, g.validBits(coords));
            var bits = g.bits(i);
            for (&bits, m) |*w, v| w.* |= v;
            if (count(bits) == 0) continue;
            if (std.mem.eql(u64, &bits, &g.validBits(coords))) {
                g.blocks[i] = core.full;
            } else if (g.blocks[i] < core.full) {
                g.pool.items[g.blocks[i]] = bits;
            } else {
                if (g.pool.items.len >= core.full) return error.PoolTooLarge;
                try g.pool.append(a, bits);
                g.blocks[i] = @intCast(g.pool.items.len - 1);
            }
        };
    }
    return g;
}
// Explicit checkpoint boundary: caller must discard old slot-index histories first.
pub fn compact(g: *core.Grid) !void {
    var pool: std.ArrayList(core.Bits) = .empty;
    errdefer pool.deinit(g.allocator);
    try pool.ensureTotalCapacityPrecise(g.allocator, g.stats().mixed_blocks);
    for (g.blocks) |d| if (d < core.full) {
        pool.appendAssumeCapacity(g.pool.items[d]);
    };
    var i: u32 = 0;
    for (g.blocks) |*d| if (d.* < core.full) {
        d.* = i;
        i += 1;
    };
    g.pool.deinit(g.allocator);
    g.pool = pool;
}

fn fillCylinderZ(g: *core.Grid, v: Cylinder) !void {
    const r = range(g.*, (Primitive{ .cylinder = v }).bounds());
    // Reuse the 64 radial distances for every axial block in a column.
    for (r.lo[1]..r.hi[1]) |y| for (r.lo[0]..r.hi[0]) |x| {
        const ex = g.extent(.{ x, y, 0 });
        var radial: [64]f64 = @splat(std.math.inf(f64));
        var xy: u64 = 0;
        for (0..ex[1]) |iy| for (0..ex[0]) |ix| {
            const dx = g.origin[0] + g.center(x * 8 + ix) - v.base[0];
            const dy = g.origin[1] + g.center(y * 8 + iy) - v.base[1];
            const distance = @sqrt(dx * dx + dy * dy) - v.radius;
            radial[iy * 8 + ix] = distance;
            if (distance <= core.tolerance) xy |= @as(u64, 1) << @as(u6, @intCast(iy * 8 + ix));
        };
        if (xy == 0) continue;
        for (r.lo[2]..r.hi[2]) |z| {
            const b = [3]usize{ x, y, z };
            const extent = g.extent(b);
            var bits: core.Bits = @splat(0);
            for (0..extent[2]) |iz| {
                const height = g.origin[2] + g.center(z * 8 + iz);
                const axial = @abs(height - v.base[2] - v.length / 2) - v.length / 2;
                if (axial <= 0) {
                    bits[iz] = xy;
                } else if (axial <= core.tolerance) {
                    for (0..64) |bit| if (sd2(radial[bit], axial) <= core.tolerance) {
                        bits[iz] |= @as(u64, 1) << @as(u6, @intCast(bit));
                    };
                }
            }
            if (count(bits) == 0) continue;
            const i = g.blockIndex(b);
            if (std.mem.eql(u64, &bits, &g.validBits(b))) g.blocks[i] = core.full else {
                try g.pool.append(g.allocator, bits);
                g.blocks[i] = @intCast(g.pool.items.len - 1);
            }
        }
    };
}
