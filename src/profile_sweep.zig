//! Continuous fixed-orientation translation of a convex finite profile.
//! Boundary candidates: endpoint tools, translated rim circles, and conical
//! silhouette generators extruded along the motion. No temporal pose sampling.
const std = @import("std");
const e = @import("engine.zig");
const d = @import("raydexel.zig");
pub const Rim = struct { z: f64, radius: f64 };
pub const Plane = struct { normal: e.V, time_covector: e.V, plane_constant: f64, time_constant: f64, zlo: f64, zhi: f64 };
const Roots = struct { values: [2]f64 = .{ 0, 0 }, count: usize = 0, all: bool = false };
fn roots(aa: f64, bb: f64, cc: f64) !Roots {
    if (!std.math.isFinite(aa) or !std.math.isFinite(bb) or !std.math.isFinite(cc)) return error.NonfiniteSweepIntersection;
    const scale = @max(@abs(aa), @max(@abs(bb), @abs(cc)));
    if (scale == 0) return .{ .all = true };
    const a = aa / scale;
    const b = bb / scale;
    const c = cc / scale;
    if (a == 0) return if (b == 0) .{} else .{ .values = .{ -c / b, 0 }, .count = 1 };
    const discriminant = b * b - 4 * a * c;
    if (discriminant < 0) return .{};
    const q = -0.5 * (b + std.math.copysign(@sqrt(discriminant), b));
    const x = if (q == 0) -b / (2 * a) else q / a;
    const y = if (q == 0) x else c / q;
    return .{ .values = .{ x, y }, .count = if (x == y) 1 else 2 };
}
fn include(result: *?d.Interval, t: f64, bounds: d.Interval) void {
    if (!std.math.isFinite(t) or t < bounds.lo or t > bounds.hi) return;
    if (result.*) |*r| {
        r.lo = @min(r.lo, t);
        r.hi = @max(r.hi, t);
    } else result.* = .{ .lo = t, .hi = t };
}
fn includeInterval(result: *?d.Interval, span: d.Interval, bounds: d.Interval) void {
    const hit = d.intersect(span, bounds) orelse return;
    include(result, hit.lo, bounds);
    include(result, hit.hi, bounds);
}
pub const Sweep = struct {
    start: d.Pose,
    movement: e.V,
    unit: e.V,
    length: f64,
    axial_speed: f64,
    radial_velocity: e.V,
    bounds: e.Bounds,
    envelope_midpoint: e.V,
    envelope_axial_half: f64,
    envelope_radial_half: f64,
    envelope_guard: f64,
    rims: []const Rim,
    planes: []const Plane,

    /// Storage is provided by the owner and reserved before any ray traversal.
    pub fn init(profile: d.Profile, from: e.Pose, destination: e.V, offset: f64, rim_storage: []Rim, plane_storage: []Plane) !Sweep {
        try e.validV(destination);
        if (rim_storage.len < profile.sides.len + 1 or plane_storage.len < profile.sides.len * 2 or profile.sides.len > 256) return error.SweepPreparationCapacity;
        const first = try d.Pose.init(profile, from, offset);
        const movement = e.sub(destination, first.base);
        const length = e.norm(movement);
        const unit = if (length > 0) e.scale(movement, 1 / length) else e.V{ 0, 0, 0 };
        const axial_speed = e.dot(unit, first.axis);
        const radial = e.sub(unit, e.scale(first.axis, axial_speed));
        var bounds = first.bounds;
        for (0..3) |k| {
            bounds.lo[k] += @min(@as(f64, 0), movement[k]);
            bounds.hi[k] += @max(@as(f64, 0), movement[k]);
        }
        // Lower envelope of the parallel-offset meridional support lines.
        // Equal/redundant lines are removed during preparation, not in rays.
        const Line = struct { side: d.Side, b: f64, begin: f64 };
        var lines: [256]Line = undefined;
        var count: usize = 0;
        outer: for (profile.sides) |side| {
            const b = side.intercept + offset * side.normal_length;
            var begin = -std.math.inf(f64);
            while (count > 0) {
                const previous = lines[count - 1];
                if (previous.side.slope == side.slope) {
                    if (previous.b <= b) continue :outer;
                    count -= 1;
                    continue;
                }
                begin = (b - previous.b) / (previous.side.slope - side.slope);
                if (begin > previous.begin) break;
                count -= 1;
            }
            lines[count] = .{ .side = side, .b = b, .begin = if (count == 0) -std.math.inf(f64) else begin };
            count += 1;
        }
        var nr: usize = 0;
        var np: usize = 0;
        const radial_speed = e.norm(radial);
        for (lines[0..count], 0..) |line, i| {
            const lo = @max(-offset, line.begin);
            const hi = @min(profile.length + offset, if (i + 1 < count) lines[i + 1].begin else std.math.inf(f64));
            if (lo >= hi) continue;
            if (nr == 0) {
                rim_storage[nr] = .{ .z = lo, .radius = line.b + line.side.slope * lo };
                nr += 1;
            }
            rim_storage[nr] = .{ .z = hi, .radius = line.b + line.side.slope * hi };
            nr += 1;
            if (length == 0 or radial_speed == 0) continue;
            const cosine = line.side.slope * axial_speed / radial_speed;
            if (@abs(cosine) > 1) continue;
            const along = e.scale(radial, 1 / radial_speed);
            const across = e.cross(first.axis, along);
            const sine = @sqrt(@max(0, 1 - cosine * cosine));
            for ([_]f64{ -1, 1 }) |sign| {
                const u = e.add(e.scale(along, cosine), e.scale(across, sign * sine));
                const generator = e.add(first.axis, e.scale(u, line.side.slope));
                const cross = e.cross(generator, unit);
                const norm = e.norm(cross);
                // A parallel generator extrudes to a line, whose endpoints and
                // rim trajectories already supply the boundary candidates.
                if (norm == 0) continue;
                const normal = e.scale(cross, 1 / norm);
                const time_covector = e.scale(e.cross(normal, generator), 1 / norm);
                const origin = e.scale(u, line.b);
                plane_storage[np] = .{ .normal = normal, .time_covector = time_covector, .plane_constant = e.dot(normal, origin), .time_constant = e.dot(time_covector, origin), .zlo = lo, .zhi = hi };
                np += 1;
            }
        }
        if (nr < 2) return error.DegenerateSweepProfile;
        for (rim_storage[0..nr]) |rim| if (!std.math.isFinite(rim.z) or !std.math.isFinite(rim.radius) or rim.radius <= 0) return error.DegenerateSweepProfile;
        return .{ .envelope_midpoint = e.add(first.base, e.scale(movement, 0.5)), .envelope_axial_half = @abs(axial_speed) * length / 2, .envelope_radial_half = e.norm(radial) * length / 2, .envelope_guard = (1 + profile.radius + profile.length + length) * 1e-8, .start = first, .movement = movement, .unit = unit, .length = length, .axial_speed = axial_speed, .radial_velocity = radial, .bounds = bounds, .rims = rim_storage[0..nr], .planes = plane_storage[0..np] };
    }
    /// A stationary conic enclosure used only for rejection, never subtraction.
    pub fn proxy(s: Sweep, profile: d.Profile) !d.Pose {
        var p = try d.Pose.init(profile, .{ .position = e.add(s.start.base, e.scale(s.movement, 0.5)), .axis = s.start.axis }, s.start.offset + s.length / 2);
        p.bounds = s.bounds;
        return p;
    }
    /// Directional support enclosure of the translation sweep. Rejection only:
    /// radial supports expand by |d_radial|/2 + |m*d_axial|/2; axial caps by
    /// |d_axial|/2. This avoids isotropic half-length inflation of a thin wheel.
    pub fn rayEnvelope(s: Sweep, profile: d.Profile, origin: e.V, direction: e.V, limits: d.Interval, retained: []const d.Interval) !?d.Interval {
        const q = e.sub(origin, s.envelope_midpoint);
        const z = e.dot(q, s.start.axis);
        const vz = e.dot(direction, s.start.axis);
        const cap_offset = s.start.offset + s.envelope_axial_half + s.envelope_guard;
        var interval = d.positive(limits, vz, z + cap_offset) orelse return null;
        interval = d.positive(interval, -vz, profile.length + cap_offset - z) orelse return null;
        var active = d.trimMaterial(retained, interval);
        if (active.len == 0) return null;
        const qr = e.sub(q, e.scale(s.start.axis, z));
        const vr = e.sub(direction, e.scale(s.start.axis, vz));
        const aa = e.dot(vr, vr);
        const bb = 2 * e.dot(qr, vr);
        const cc = e.dot(qr, qr);
        for (profile.sides) |side| {
            const margin = (s.start.offset + s.envelope_guard) * side.normal_length + s.envelope_radial_half + @abs(side.slope) * s.envelope_axial_half;
            const r = side.intercept + side.slope * z + margin;
            const v = side.slope * vz;
            interval = d.positive(interval, v, r) orelse return null;
            interval = (try d.quadratic(interval, aa - v * v, bb - 2 * r * v, cc - r * r)) orelse return null;
            active = d.trimMaterial(active, interval);
            if (active.len == 0) return null;
        }
        return interval;
    }
    fn fullRayBounds(s: Sweep, origin: e.V, direction: e.V) ?d.Interval {
        var span = d.Interval{ .lo = -std.math.inf(f64), .hi = std.math.inf(f64) };
        for (0..3) |k| {
            span = d.positive(span, direction[k], origin[k] - s.bounds.lo[k]) orelse return null;
            span = d.positive(span, -direction[k], s.bounds.hi[k] - origin[k]) orelse return null;
        }
        return span;
    }
    /// Exact-in-real-arithmetic continuous translation; unit ray direction.
    pub fn ray(s: Sweep, profile: d.Profile, origin: e.V, direction: e.V, limits: d.Interval) !?d.Interval {
        if (s.length == 0) return d.ray(profile, s.start, origin, direction, limits);
        const box = s.fullRayBounds(origin, direction) orelse return null;
        if (d.intersect(box, limits) == null) return null;
        if (s.axial_speed == 0) return s.transverse(profile, origin, direction, limits);
        const q = e.sub(origin, s.start.base);
        const z = e.dot(q, s.start.axis);
        const vz = e.dot(direction, s.start.axis);
        const qr = e.sub(q, e.scale(s.start.axis, z));
        const vr = e.sub(direction, e.scale(s.start.axis, vz));
        var result: ?d.Interval = try d.ray(profile, s.start, origin, direction, box);
        var end = s.start;
        end.base = e.add(end.base, s.movement);
        if (try d.ray(profile, end, origin, direction, box)) |hit| includeInterval(&result, hit, box);
        for (s.rims) |rim| {
            // A rim plane can meet this finite ray/motion rectangle only in
            // this axial range. Reject before dividing near-parallel speeds.
            const za = z + vz * box.lo;
            const zb = z + vz * box.hi;
            const motion_z = s.axial_speed * s.length;
            if (rim.z < @min(za, zb) - @max(@as(f64, 0), motion_z) or rim.z > @max(za, zb) - @min(@as(f64, 0), motion_z)) continue;
            // Eliminate the better-conditioned axial coefficient. In particular
            // near-transverse movement must not divide by a nearly zero speed.
            if (@abs(vz) >= @abs(s.axial_speed)) {
                const t0 = (rim.z - z) / vz;
                const dt = s.axial_speed / vz;
                const b = e.add(qr, e.scale(vr, t0));
                const a = e.sub(e.scale(vr, dt), s.radial_velocity);
                const hits = try roots(e.dot(a, a), 2 * e.dot(a, b), e.dot(b, b) - rim.radius * rim.radius);
                if (hits.all) {
                    include(&result, t0, box);
                    include(&result, t0 + dt * s.length, box);
                } else for (hits.values[0..hits.count]) |u| {
                    if (u >= 0 and u <= s.length) include(&result, t0 + dt * u, box);
                }
            } else {
                const u_origin = (z - rim.z) / s.axial_speed;
                const du = vz / s.axial_speed;
                const b = e.sub(qr, e.scale(s.radial_velocity, u_origin));
                const a = e.sub(vr, e.scale(s.radial_velocity, du));
                const hits = try roots(e.dot(a, a), 2 * e.dot(a, b), e.dot(b, b) - rim.radius * rim.radius);
                if (hits.all) {
                    var span = d.positive(box, du, u_origin) orelse continue;
                    span = d.positive(span, -du, s.length - u_origin) orelse continue;
                    includeInterval(&result, span, box);
                } else for (hits.values[0..hits.count]) |t| {
                    const u = u_origin + du * t;
                    if (u >= 0 and u <= s.length) include(&result, t, box);
                }
            }
        }
        for (s.planes) |plane| {
            const denominator = e.dot(plane.normal, direction);
            // For a coplanar ray, the parallelogram boundary lies on the
            // endpoint tools or rim trajectories already evaluated above.
            if (denominator == 0) continue;
            const t = (plane.plane_constant - e.dot(plane.normal, q)) / denominator;
            if (t < box.lo or t > box.hi) continue;
            const u = e.dot(plane.time_covector, q) - plane.time_constant + t * e.dot(plane.time_covector, direction);
            const axial = z + vz * t - s.axial_speed * u;
            if (u >= 0 and u <= s.length and axial >= plane.zlo and axial <= plane.zhi) include(&result, t, box);
        }
        return if (result) |hit| d.intersect(hit, limits) else null;
    }
    fn transverse(s: Sweep, profile: d.Profile, origin: e.V, direction: e.V, limits: d.Interval) !?d.Interval {
        const q = e.sub(origin, s.start.base);
        const z = e.dot(q, s.start.axis);
        const vz = e.dot(direction, s.start.axis);
        var axial = d.positive(limits, vz, z + s.start.offset) orelse return null;
        axial = d.positive(axial, -vz, profile.length + s.start.offset - z) orelse return null;
        const qr = e.sub(q, e.scale(s.start.axis, z));
        const vr = e.sub(direction, e.scale(s.start.axis, vz));
        const u = e.dot(qr, s.unit);
        const vu = e.dot(vr, s.unit);
        var result: ?d.Interval = null;
        for (0..3) |region| {
            var span = axial;
            var b = qr;
            var a = vr;
            if (region == 0) span = d.positive(span, -vu, -u) orelse continue else if (region == 2) {
                span = d.positive(span, vu, u - s.length) orelse continue;
                b = e.sub(qr, s.movement);
            } else {
                span = d.positive(span, vu, u) orelse continue;
                span = d.positive(span, -vu, s.length - u) orelse continue;
                b = e.sub(qr, e.scale(s.unit, u));
                a = e.sub(vr, e.scale(s.unit, vu));
            }
            const aa = e.dot(a, a);
            const bb = 2 * e.dot(a, b);
            const cc = e.dot(b, b);
            var hit = true;
            for (profile.sides) |side| {
                const r = side.intercept + side.slope * z + s.start.offset * side.normal_length;
                const v = side.slope * vz;
                span = d.positive(span, v, r) orelse {
                    hit = false;
                    break;
                };
                span = (try d.quadratic(span, aa - v * v, bb - 2 * r * v, cc - r * r)) orelse {
                    hit = false;
                    break;
                };
            }
            if (hit) includeInterval(&result, span, limits);
        }
        return result;
    }
    /// Independent membership oracle: reverse the motion through a static tool.
    pub fn containsReference(s: Sweep, profile: d.Profile, point: e.V) !bool {
        if (s.length == 0) return try d.ray(profile, s.start, point, .{ 0, 0, 1 }, .{ .lo = 0, .hi = 0 }) != null;
        return try d.ray(profile, s.start, point, e.scale(s.unit, -1), .{ .lo = 0, .hi = s.length }) != null;
    }
};
