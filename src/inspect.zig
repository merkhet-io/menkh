const std = @import("std");
const c = @import("core.zig");
const e = @import("engine.zig");
pub const Comparison = struct { excess: u64 = 0, missing: u64 = 0, common: u64 = 0, excess_mm3: f64 = 0, missing_mm3: f64 = 0 };
pub fn compare(stock: c.Grid, target: c.Grid) !Comparison {
    if (stock.h != target.h or !std.mem.eql(f64, &stock.origin, &target.origin) or !std.mem.eql(usize, &stock.n, &target.n)) return error.GridMismatch;
    var r: Comparison = .{};
    for (0..stock.blocks.len) |i| {
        const s = stock.bits(i);
        const t = target.bits(i);
        for (s, t) |x, y| {
            r.excess += @popCount(x & ~y);
            r.missing += @popCount(y & ~x);
            r.common += @popCount(x & y);
        }
    }
    r.excess_mm3 = @as(f64, @floatFromInt(r.excess)) * std.math.pow(f64, stock.h, 3);
    r.missing_mm3 = @as(f64, @floatFromInt(r.missing)) * std.math.pow(f64, stock.h, 3);
    return r;
}
pub const Hit = struct { position: e.V, index: [3]usize, distance_mm: f64 };
pub fn ray(g: c.Grid, start: e.V, direction: e.V, max_distance: f64) !?Hit {
    try e.validV(start);
    try e.unit(direction);
    if (!std.math.isFinite(max_distance) or max_distance <= 0) return error.InvalidDistance;
    var enter: f64 = 0;
    var leave = max_distance;
    for (0..3) |j| {
        const low = g.origin[j];
        const high = low + @as(f64, @floatFromInt(g.n[j])) * g.h;
        if (direction[j] == 0) {
            if (start[j] < low or start[j] >= high) return null;
        } else {
            const a = (low - start[j]) / direction[j];
            const b = (high - start[j]) / direction[j];
            enter = @max(enter, @min(a, b));
            leave = @min(leave, @max(a, b));
        }
    }
    if (enter > leave) return null;
    var t = enter;
    const max_steps = g.n[0] + g.n[1] + g.n[2] + 8;
    for (0..max_steps) |_| {
        const pos = e.add(start, e.scale(direction, t + g.h * 1e-8));
        var index: [3]usize = undefined;
        for (0..3) |j| {
            const v = @floor((pos[j] - g.origin[j]) / g.h);
            if (v < 0 or v >= @as(f64, @floatFromInt(g.n[j]))) return null;
            index[j] = @intFromFloat(v);
        }
        if (g.occupied(index)) return .{ .position = e.add(start, e.scale(direction, t)), .index = index, .distance_mm = t };
        var next = std.math.inf(f64);
        for (0..3) |j| {
            if (direction[j] == 0) continue;
            const boundary = g.origin[j] + @as(f64, @floatFromInt(index[j] + @as(usize, if (direction[j] > 0) 1 else 0))) * g.h;
            next = @min(next, (boundary - start[j]) / direction[j]);
        }
        t = @max(t + g.h * 1e-10, next);
        if (t > leave) return null;
    }
    return error.RayTraversalLimit;
}
pub const Contact = struct { occupied_centers: u64 = 0, region: ?e.Bounds = null, representation_clearance_uncertain: bool = true };
pub fn collision(g: c.Grid, s: e.Shape) !Contact {
    try s.validate();
    var result: Contact = .{};
    const range = e.clippedRange(g, s.cuttingBounds());
    for (range.lo[2]..range.hi[2]) |z| for (range.lo[1]..range.hi[1]) |y| for (range.lo[0]..range.hi[0]) |x| {
        const b = [3]usize{ x, y, z };
        const i = g.blockIndex(b);
        if (g.blocks[i] == c.empty) continue;
        const hit = e.mask(g, b, s, false, g.bits(i));
        const hits = e.count(hit);
        if (hits == 0) continue;
        result.occupied_centers += hits;
        // Exact occupied-center extrema from the 8 words, without visiting hits individually.
        var xy: u64 = 0;
        var minz: usize = 8;
        var maxz: usize = 0;
        for (hit, 0..) |word, zi| if (word != 0) {
            xy |= word;
            minz = @min(minz, zi);
            maxz = zi;
        };
        const miny = @ctz(xy) / 8;
        const maxy = (63 - @clz(xy)) / 8;
        var columns = xy | (xy >> 32);
        columns |= columns >> 16;
        columns |= columns >> 8;
        const xs: u8 = @truncate(columns);
        const low = [3]usize{ @ctz(xs), miny, minz };
        const high = [3]usize{ 7 - @clz(xs), maxy, maxz };
        var bb: e.Bounds = undefined;
        for (0..3) |j| {
            bb.lo[j] = g.origin[j] + g.center(b[j] * 8 + low[j]);
            bb.hi[j] = g.origin[j] + g.center(b[j] * 8 + high[j]);
        }
        if (result.region) |*current| {
            for (0..3) |j| {
                current.lo[j] = @min(current.lo[j], bb.lo[j]);
                current.hi[j] = @max(current.hi[j], bb.hi[j]);
            }
        } else result.region = bb;
    };
    return result;
}
// Simple full-grid oracle retained independently of candidate bounds and masks.
pub fn collisionReference(g: c.Grid, s: e.Shape) !Contact {
    try s.validate();
    var r: Contact = .{};
    for (g.blocks, 0..) |d, i| {
        if (d == c.empty) continue;
        const b = g.blockCoords(i);
        const extent = g.extent(b);
        for (0..extent[2]) |z| for (0..extent[1]) |y| for (0..extent[0]) |x| {
            const index = [3]usize{ b[0] * 8 + x, b[1] * 8 + y, b[2] * 8 + z };
            if (!g.occupied(index)) continue;
            const p = e.add(g.origin, .{ g.center(index[0]), g.center(index[1]), g.center(index[2]) });
            if (s.contains(p)) {
                r.occupied_centers += 1;
                if (r.region) |*bb| {
                    for (0..3) |j| {
                        bb.lo[j] = @min(bb.lo[j], p[j]);
                        bb.hi[j] = @max(bb.hi[j], p[j]);
                    }
                } else r.region = .{ .lo = p, .hi = p };
            }
        };
    }
    return r;
}
pub const Section = struct { origin: e.V, u: e.V, v: e.V, pixel_mm: f64, width: usize, height: usize };
pub fn section(a: std.mem.Allocator, g: c.Grid, s: Section) ![]u8 {
    try e.validV(s.origin);
    try e.unit(s.u);
    try e.unit(s.v);
    if (@abs(e.dot(s.u, s.v)) > 1e-10 or !std.math.isFinite(s.pixel_mm) or s.pixel_mm <= 0 or s.width == 0 or s.height == 0) return error.InvalidSection;
    const size = try std.math.mul(usize, s.width, s.height);
    if (size > 100000000) return error.SectionTooLarge;
    const pixels = try a.alloc(u8, try std.math.mul(usize, size, 3));
    for (0..s.height) |y| for (0..s.width) |x| {
        const p = e.add(s.origin, e.add(e.scale(s.u, (@as(f64, @floatFromInt(x)) + 0.5) * s.pixel_mm), e.scale(s.v, (@as(f64, @floatFromInt(y)) + 0.5) * s.pixel_mm)));
        const at = (y * s.width + x) * 3;
        @memset(pixels[at..][0..3], if (g.query(p)) 220 else 24);
    };
    return pixels;
}
