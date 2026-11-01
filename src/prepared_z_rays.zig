//! Shared, immutable coefficients for conic rejection along world-Z rays.
//! Four conic constraints share vector arithmetic, with scalar clipping in the
//! original side order. Strict floating-point evaluation is required: no fastmath.
//! This is a rejection proxy only; the exact finite-tool sweep is unchanged.
const std = @import("std");
const e = @import("engine.zig");
const d = @import("raydexel.zig");
const s = @import("profile_sweep.zig");
const F = @Vector(4, f64);
const U = @Vector(4, u64);
fn f(value: f64) F {
    return @splat(value);
}
const Side = struct { slope: F, intercept: F, margin: F, velocity: F, qa: F };
pub const Ray = struct {
    base: e.V,
    axis: e.V,
    cap_offset: f64,
    length: f64,
    vz: f64,
    vr: e.V,
    sides: []const Side,
    side_count: usize,
    fn init(profile: d.Profile, base: e.V, axis: e.V, cap_offset: f64, offset: f64, radial_half: f64, axial_half: f64, directional: bool, storage: []Side) Ray {
        const vz = e.dot(.{ 0, 0, 1 }, axis);
        const vr = e.sub(.{ 0, 0, 1 }, e.scale(axis, vz));
        const aa = e.dot(vr, vr);
        for (storage, 0..) |*prepared, group| {
            prepared.* = .{ .slope = f(0), .intercept = f(0), .margin = f(0), .velocity = f(0), .qa = f(1) };
            for (0..@min(4, profile.sides.len - group * 4)) |lane| {
                const side = profile.sides[group * 4 + lane];
                const v = side.slope * vz;
                prepared.slope[lane] = side.slope;
                prepared.intercept[lane] = side.intercept;
                prepared.margin[lane] = if (directional) offset * side.normal_length + radial_half + @abs(side.slope) * axial_half else offset * side.normal_length;
                prepared.velocity[lane] = v;
                prepared.qa[lane] = aa - v * v;
            }
        }
        return .{ .base = base, .axis = axis, .cap_offset = cap_offset, .length = profile.length, .vz = vz, .vr = vr, .sides = storage, .side_count = profile.sides.len };
    }
    pub fn intersect(self: Ray, x: f64, y: f64, limits: d.Interval, retained: []const d.Interval) !?d.Interval {
        const q = e.sub(.{ x, y, 0 }, self.base);
        const z = e.dot(q, self.axis);
        var interval = d.positive(limits, self.vz, z + self.cap_offset) orelse return null;
        interval = d.positive(interval, -self.vz, self.length + self.cap_offset - z) orelse return null;
        var active = d.trimMaterial(retained, interval);
        if (active.len == 0) return null;
        const qr = e.sub(q, e.scale(self.axis, z));
        const bb = 2 * e.dot(qr, self.vr);
        const cc = e.dot(qr, qr);
        for (self.sides, 0..) |side, group| {
            const r = side.intercept + side.slope * f(z) + side.margin;
            const a = side.qa;
            const b = f(bb) - f(2) * r * side.velocity;
            const c = f(cc) - r * r;
            const disc = b * b - f(4) * a * c;
            // Negative-discriminant and linear lanes are discarded below. Their
            // speculative roots/divisions never participate in interval clipping.
            const root = @sqrt(@max(disc, f(0)));
            const sign: U = @splat(@as(u64, 1) << 63);
            const signed_root: F = @bitCast((@as(U, @bitCast(root)) & ~sign) | (@as(U, @bitCast(b)) & sign));
            const roots_q = f(-0.5) * (b + signed_root);
            const roots_x = @select(f64, roots_q == f(0), -b / (f(2) * a), roots_q / a);
            const roots_y = @select(f64, roots_q == f(0), roots_x, c / roots_q);
            const lo = @min(roots_x, roots_y);
            const hi = @max(roots_x, roots_y);
            for (0..@min(4, self.side_count - group * 4)) |lane| {
                interval = d.positive(interval, side.velocity[lane], r[lane]) orelse return null;
                if (a[lane] == 0) {
                    interval = d.positive(interval, -b[lane], -c[lane]) orelse return null;
                } else if (disc[lane] < 0) {
                    if (a[lane] > 0) return null;
                } else if (a[lane] > 0) {
                    interval = d.intersect(interval, .{ .lo = lo[lane], .hi = hi[lane] }) orelse return null;
                } else if (lo[lane] != hi[lane]) {
                    const left = d.intersect(interval, .{ .lo = -std.math.inf(f64), .hi = lo[lane] });
                    const right = d.intersect(interval, .{ .lo = hi[lane], .hi = std.math.inf(f64) });
                    if (left != null and right != null) return error.AmbiguousRayIntersection;
                    interval = left orelse right orelse return null;
                }
                active = d.trimMaterial(active, interval);
                if (active.len == 0) return null;
            }
        }
        return interval;
    }
};
pub const Scene = struct {
    allocator: std.mem.Allocator,
    rays: []Ray,
    sides: []Side,
    node_count: usize,
    pub fn init(a: std.mem.Allocator, profile: d.Profile, sweeps: []const s.Sweep, tree: d.Tree) !Scene {
        const count = try std.math.add(usize, tree.nodes.items.len, sweeps.len);
        const rays = try a.alloc(Ray, count);
        errdefer a.free(rays);
        const groups = profile.sides.len / 4 + @intFromBool(profile.sides.len % 4 != 0);
        const sides = try a.alloc(Side, try std.math.mul(usize, count, groups));
        errdefer a.free(sides);
        for (tree.nodes.items, 0..) |n, i| {
            const pose = tree.poses[n.anchorIndex()];
            const offset = @max(@as(f64, 0), n.envelope_offset);
            rays[i] = Ray.init(profile, pose.base, pose.axis, offset, offset, 0, 0, false, sides[i * groups ..][0..groups]);
        }
        for (sweeps, tree.nodes.items.len..) |cut, i| {
            rays[i] = Ray.init(profile, cut.envelope_midpoint, cut.start.axis, cut.start.offset + cut.envelope_axial_half + cut.envelope_guard, cut.start.offset + cut.envelope_guard, cut.envelope_radial_half, cut.envelope_axial_half, true, sides[i * groups ..][0..groups]);
        }
        return .{ .allocator = a, .rays = rays, .sides = sides, .node_count = tree.nodes.items.len };
    }
    pub fn deinit(self: *Scene) void {
        self.allocator.free(self.rays);
        self.allocator.free(self.sides);
    }
    pub fn bytes(self: Scene) usize {
        return self.rays.len * @sizeOf(Ray) + self.sides.len * @sizeOf(Side);
    }
    pub fn node(self: Scene, index: usize) Ray {
        return self.rays[index];
    }
    pub fn sweep(self: Scene, index: usize) Ray {
        return self.rays[self.node_count + index];
    }
};

test "prepared conics preserve scalar bits across lane tails and degenerate axes" {
    const points = [_]e.ProfilePoint{
        .{ .z = 0, .radius = 1 },   .{ .z = 1, .radius = 2 },
        .{ .z = 2, .radius = 2.5 }, .{ .z = 3, .radius = 2.5 },
        .{ .z = 4, .radius = 2 },   .{ .z = 5, .radius = 1 },
    };
    for (1..6) |count| {
        const profile = try d.Profile.init(std.testing.allocator, .{ .kind = .profile, .radius = if (count == 1) 2 else 2.5, .length = @floatFromInt(count), .profile = points[0 .. count + 1] });
        defer profile.deinit();
        for ([_]e.V{ .{ 0, 0, 1 }, .{ 1, 0, 0 }, .{ 1, 1e-12, 1e-12 }, .{ 0.3, -0.7, 0.2 } }) |axis| {
            const pose = try d.Pose.init(profile, .{ .position = .{ 0.17, -0.23, 0.31 }, .axis = e.scale(axis, 1 / e.norm(axis)) }, 0.013);
            var storage: [2]Side = undefined;
            const ray = Ray.init(profile, pose.base, pose.axis, pose.offset, pose.offset, 0, 0, false, storage[0 .. (count + 3) / 4]);
            const limits = d.Interval{ .lo = -20, .hi = 20 };
            const retained = [_]d.Interval{ .{ .lo = -20, .hi = -1 }, .{ .lo = 1, .hi = 20 } };
            for (0..41) |ix| for (0..41) |iy| {
                const x = @as(f64, @floatFromInt(ix)) * 0.17 - 3.4;
                const y = @as(f64, @floatFromInt(iy)) * 0.19 - 3.8;
                const expected = try d.rayMaterial(profile, pose, .{ x, y, 0 }, .{ 0, 0, 1 }, limits, &retained);
                const actual = try ray.intersect(x, y, limits, &retained);
                try std.testing.expectEqual(expected != null, actual != null);
                if (expected) |hit| {
                    try std.testing.expectEqual(@as(u64, @bitCast(hit.lo)), @as(u64, @bitCast(actual.?.lo)));
                    try std.testing.expectEqual(@as(u64, @bitCast(hit.hi)), @as(u64, @bitCast(actual.?.hi)));
                }
            };
        }
    }
}
