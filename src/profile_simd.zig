//! Batched f64 profile distance with the same meridional geometry as Tool.distance.
//! sqrt is monotone: sqrt(min squared distances) equals min(sqrt distances).
const std = @import("std");
const e = @import("engine.zig");
const c = @import("core.zig");
pub const F = @Vector(8, f64);
fn splat(x: f64) F {
    return @splat(x);
}
pub fn distance(tool: e.Tool, r: F, z: F) F {
    var inside: @Vector(8, bool) = @splat(false);
    var best: F = @splat(std.math.inf(f64));
    for (tool.profile[0 .. tool.profile.len - 1], tool.profile[1..]) |p, q| {
        const dr = q.radius - p.radius;
        const dz = q.z - p.z;
        const u = @min(@max(((r - splat(p.radius)) * splat(dr) + (z - splat(p.z)) * splat(dz)) / splat(dr * dr + dz * dz), splat(0)), splat(1));
        const x = r - (splat(p.radius) + u * splat(dr));
        const y = z - (splat(p.z) + u * splat(dz));
        best = @min(best, x * x + y * y);
        inside |= (z >= splat(p.z)) & (z <= splat(q.z)) & (r <= splat(p.radius) + splat(dr) * ((z - splat(p.z)) / splat(dz)));
    }
    for ([_]e.ProfilePoint{ tool.profile[0], tool.profile[tool.profile.len - 1] }) |cap| {
        const x = @max(r - splat(cap.radius), splat(0));
        const y = z - splat(cap.z);
        best = @min(best, x * x + y * y);
    }
    const d = @sqrt(best);
    return @select(f64, inside, -d, d);
}
pub fn mask(g: c.Grid, b: [3]usize, sweep: e.Sweep, available: c.Bits, work: ?*e.Work) c.Bits {
    const extent = g.extent(b);
    const n = sweep.samples();
    const error_bound = sweep.errorBound();
    const axis = sweep.a.axis;
    const movement = e.sub(sweep.b.position, sweep.a.position);
    var px: F = undefined;
    inline for (0..8) |x| px[x] = g.origin[0] + g.center(b[0] * 8 + x);
    var result: c.Bits = @splat(0);
    for (0..extent[2]) |iz| for (0..extent[1]) |iy| {
        const shift: u6 = @intCast(iy * 8);
        const active: u8 = @truncate(available[iz] >> shift);
        if (active == 0) continue;
        const py = g.origin[1] + g.center(b[1] * 8 + iy);
        const pz = g.origin[2] + g.center(b[2] * 8 + iz);
        if (work) |w| w.voxel_tests += @popCount(active);
        var hits: u8 = 0;
        if (@popCount(active) <= 2) {
            for (0..extent[0]) |ix| {
                const bit = @as(u8, 1) << @as(u3, @intCast(ix));
                if (active & bit == 0) continue;
                if (sweep.distanceCounted(.{ px[ix], py, pz }, true, if (work) |w| &w.point_pose_evaluations else null) <= c.tolerance) hits |= bit;
            }
        } else {
            for (0..n + 1) |i| {
                const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
                const position = e.add(sweep.a.position, e.scale(movement, t));
                const qx = px - splat(position[0]);
                const qy = splat(py - position[1]);
                const qz = splat(pz - position[2]);
                const z = qx * splat(axis[0]) + qy * splat(axis[1]) + qz * splat(axis[2]);
                const rx = qx - splat(axis[0]) * z;
                const ry = qy - splat(axis[1]) * z;
                const rz = qz - splat(axis[2]) * z;
                const r = @sqrt(rx * rx + ry * ry + rz * rz);
                const hit: u8 = @bitCast(distance(sweep.tool, r, z) - splat(error_bound) <= splat(c.tolerance));
                hits |= hit & active;
                if (work) |w| w.point_pose_evaluations += 8;
                if (hits == active) break;
            }
        }
        result[iz] |= @as(u64, hits) << shift;
    };
    return result;
}
