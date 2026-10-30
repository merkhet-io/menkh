const std = @import("std");
pub const Bits = [8]u64;
pub const empty: u32 = std.math.maxInt(u32);
pub const full: u32 = empty - 1;
pub const tolerance = 1e-10; // mm, closed cutter expanded by this absolute tolerance
const limit = 1e6; // local mm, bounds floating arithmetic and rejects accidental world coordinates
pub const Move = struct {
    a: [3]f64,
    b: [3]f64,
    radius: f64,
    length: f64,
    pub fn validated(self: Move) !Move {
        for (self.a ++ self.b) |v| if (!std.math.isFinite(v) or @abs(v) > limit) return error.InvalidCoordinate;
        if (!std.math.isFinite(self.radius) or !std.math.isFinite(self.length) or self.radius <= 0 or self.length <= 0 or self.radius > limit or self.length > limit) return error.InvalidTool;
        if (self.a[2] != self.b[2]) return error.UnsupportedMotion;
        var m = self;
        if (m.a[0] > m.b[0] or (m.a[0] == m.b[0] and m.a[1] > m.b[1])) std.mem.swap([3]f64, &m.a, &m.b);
        return m;
    }
    pub fn xy(self: Move, x: f64, y: f64, margin: f64) bool {
        const dx = self.b[0] - self.a[0];
        const dy = self.b[1] - self.a[1];
        const d2 = dx * dx + dy * dy;
        const t = if (d2 == 0) 0 else std.math.clamp(((x - self.a[0]) * dx + (y - self.a[1]) * dy) / d2, 0, 1);
        const ex = x - (self.a[0] + t * dx);
        const ey = y - (self.a[1] + t * dy);
        const r = @max(0, self.radius + tolerance - margin);
        return ex * ex + ey * ey <= r * r;
    }
    pub fn contains(self: Move, p: [3]f64) bool {
        return p[2] >= self.a[2] - tolerance and p[2] <= self.a[2] + self.length + tolerance and self.xy(p[0], p[1], 0);
    }
};
pub const Stats = struct { occupied: u64 = 0, empty_blocks: usize = 0, full_blocks: usize = 0, mixed_blocks: usize = 0, descriptor_bytes: usize = 0, pool_bytes: usize = 0, pool_used_bytes: usize = 0 };
pub const Grid = struct {
    allocator: std.mem.Allocator,
    origin: [3]f64 = .{ 0, 0, 0 },
    material_bounds: ?[2][3]f64 = null,
    size: [3]f64,
    h: f64,
    n: [3]usize,
    nb: [3]usize,
    blocks: []u32,
    pool: std.ArrayList(Bits) = .empty,
    pub fn init(a: std.mem.Allocator, size: [3]f64, h: f64) !Grid {
        if (!std.math.isFinite(h) or h <= 0) return error.InvalidVoxelSize;
        var n: [3]usize = undefined;
        var nb: [3]usize = undefined;
        for (size, 0..) |s, i| {
            if (!std.math.isFinite(s) or s <= 0 or s > limit) return error.InvalidStock;
            const count = @ceil(s / h - 0.5); // centers strictly inside [0,size)
            if (!std.math.isFinite(count) or count < 1 or count > 0x7fffffff) return error.GridTooLargeOrEmpty;
            n[i] = @intFromFloat(count);
            // Correct division rounding against the exact center predicate used everywhere else.
            while (n[i] > 0 and (@as(f64, @floatFromInt(n[i] - 1)) + 0.5) * h >= s) n[i] -= 1;
            while ((@as(f64, @floatFromInt(n[i])) + 0.5) * h < s) n[i] += 1;
            if (n[i] == 0 or n[i] > 0x7fffffff) return error.GridTooLargeOrEmpty;
            nb[i] = (n[i] + 7) / 8;
        }
        const count = try std.math.mul(usize, try std.math.mul(usize, nb[0], nb[1]), nb[2]);
        if (count >= full) return error.GridTooLargeOrEmpty;
        _ = try std.math.mul(usize, count, @sizeOf(u32));
        _ = try std.math.mul(u64, try std.math.mul(u64, n[0], n[1]), n[2]);
        const blocks = try a.alloc(u32, count);
        @memset(blocks, full);
        return .{ .allocator = a, .size = size, .h = h, .n = n, .nb = nb, .blocks = blocks };
    }
    pub fn deinit(g: *Grid) void {
        g.allocator.free(g.blocks);
        g.pool.deinit(g.allocator);
    }
    pub fn center(g: Grid, i: usize) f64 {
        return (@as(f64, @floatFromInt(i)) + 0.5) * g.h;
    }
    pub fn blockIndex(g: Grid, b: [3]usize) usize {
        return (b[2] * g.nb[1] + b[1]) * g.nb[0] + b[0];
    }
    pub fn blockCoords(g: Grid, i: usize) [3]usize {
        return .{ i % g.nb[0], (i / g.nb[0]) % g.nb[1], i / (g.nb[0] * g.nb[1]) };
    }
    pub fn extent(g: Grid, b: [3]usize) [3]usize {
        return .{ @min(8, g.n[0] - b[0] * 8), @min(8, g.n[1] - b[1] * 8), @min(8, g.n[2] - b[2] * 8) };
    }
    pub fn validBits(g: Grid, b: [3]usize) Bits {
        const e = g.extent(b);
        var valid: Bits = @splat(0);
        const row = (@as(u64, 1) << @as(u6, @intCast(e[0]))) - 1;
        for (0..e[2]) |z| for (0..e[1]) |y| {
            valid[z] |= row << @as(u6, @intCast(y * 8));
        };
        return valid;
    }
    pub fn bits(g: Grid, i: usize) Bits {
        return switch (g.blocks[i]) {
            empty => @splat(0),
            full => g.validBits(g.blockCoords(i)),
            else => |slot| g.pool.items[slot],
        };
    }
    pub fn occupied(g: Grid, p: [3]usize) bool {
        for (p, g.n) |v, n| if (v >= n) return false;
        const d = g.blocks[g.blockIndex(.{ p[0] / 8, p[1] / 8, p[2] / 8 })];
        return switch (d) {
            empty => false,
            full => true,
            else => g.pool.items[d][p[2] % 8] & (@as(u64, 1) << @as(u6, @intCast(p[1] % 8 * 8 + p[0] % 8))) != 0,
        };
    }
    pub fn query(g: Grid, p: [3]f64) bool {
        var idx: [3]usize = undefined;
        for (p, 0..) |world, i| {
            const v = world - g.origin[i];
            if (!std.math.isFinite(v) or v < 0) return false;
            const q = @floor(v / g.h);
            if (q >= @as(f64, @floatFromInt(g.n[i]))) return false;
            idx[i] = @intFromFloat(q);
        }
        return g.occupied(idx);
    }
    pub fn stats(g: Grid) Stats {
        var s: Stats = .{ .descriptor_bytes = g.blocks.len * 4, .pool_bytes = g.pool.capacity * @sizeOf(Bits), .pool_used_bytes = g.pool.items.len * @sizeOf(Bits) };
        for (g.blocks, 0..) |d, i| switch (d) {
            empty => s.empty_blocks += 1,
            full => {
                s.full_blocks += 1;
                const e = g.extent(g.blockCoords(i));
                s.occupied += e[0] * e[1] * e[2];
            },
            else => {
                s.mixed_blocks += 1;
                for (g.pool.items[d]) |word| s.occupied += @popCount(word);
            },
        };
        return s;
    }
    fn range(g: Grid, m: Move) ?struct { lo: [3]usize, hi: [3]usize } {
        const low = [3]f64{ @min(m.a[0], m.b[0]) - m.radius - tolerance, @min(m.a[1], m.b[1]) - m.radius - tolerance, m.a[2] - tolerance };
        const high = [3]f64{ @max(m.a[0], m.b[0]) + m.radius + tolerance, @max(m.a[1], m.b[1]) + m.radius + tolerance, m.a[2] + m.length + tolerance };
        var lo: [3]usize = undefined;
        var hi: [3]usize = undefined;
        for (0..3) |i| {
            if (high[i] < g.center(0) or low[i] > g.center(g.n[i] - 1)) return null;
            // A deliberately padded voxel AABB: never drops a boundary center through rounding.
            const l = @max(0, @floor(low[i] / g.h) - 1);
            const u = @min(@as(f64, @floatFromInt(g.n[i])), @max(0, @ceil(high[i] / g.h) + 1));
            lo[i] = @as(usize, @intFromFloat(l)) / 8;
            hi[i] = (@as(usize, @intFromFloat(u)) + 7) / 8;
        }
        return .{ .lo = lo, .hi = hi };
    }
    fn cutMask(g: Grid, b: [3]usize, m: Move, reference: bool) Bits {
        const e = g.extent(b);
        var result: Bits = @splat(0);
        if (reference) {
            for (0..e[2]) |z| for (0..e[1]) |y| for (0..e[0]) |x| {
                if (m.contains(.{ g.center(b[0] * 8 + x), g.center(b[1] * 8 + y), g.center(b[2] * 8 + z) })) result[z] |= @as(u64, 1) << @as(u6, @intCast(y * 8 + x));
            };
            return result;
        }
        const x0 = g.center(b[0] * 8);
        const x1 = g.center(b[0] * 8 + e[0] - 1);
        const y0 = g.center(b[1] * 8);
        const y1 = g.center(b[1] * 8 + e[1] - 1);
        // Capsule is convex. All four corner centers inside => entire XY center rectangle inside.
        // Extra clearance avoids promoting floating-point boundary cases to full coverage.
        const inside = m.xy(x0, y0, 1e-8) and m.xy(x1, y0, 1e-8) and m.xy(x0, y1, 1e-8) and m.xy(x1, y1, 1e-8);
        var xy: u64 = 0;
        if (inside) {
            xy = g.validBits(b)[0];
        } else {
            for (0..e[1]) |y| for (0..e[0]) |x| {
                if (m.xy(g.center(b[0] * 8 + x), g.center(b[1] * 8 + y), 0)) xy |= @as(u64, 1) << @as(u6, @intCast(y * 8 + x));
            };
        }
        for (0..e[2]) |z| {
            const p = g.center(b[2] * 8 + z);
            if (p >= m.a[2] - tolerance and p <= m.a[2] + m.length + tolerance) result[z] = xy;
        }
        return result;
    }
    fn remaining(g: Grid, i: usize, mask: Bits) Bits {
        var r = g.bits(i);
        for (&r, mask) |*v, c| v.* &= ~c;
        return r;
    }
    fn isZero(b: Bits) bool {
        var v: u64 = 0;
        for (b) |x| v |= x;
        return v == 0;
    }
    pub fn cut(g: *Grid, input: Move, reference: bool) !void {
        var local = input;
        for (0..3) |i| {
            local.a[i] -= g.origin[i];
            local.b[i] -= g.origin[i];
        }
        const m = try local.validated();
        const r = g.range(m) orelse return;
        // Preflight only full blocks that really become mixed. Failure leaves occupancy untouched.
        var needed: usize = 0;
        for (r.lo[2]..r.hi[2]) |z| for (r.lo[1]..r.hi[1]) |y| for (r.lo[0]..r.hi[0]) |x| {
            const b = [3]usize{ x, y, z };
            const i = g.blockIndex(b);
            if (g.blocks[i] != full) continue;
            const mask = g.cutMask(b, m, reference);
            const rem = g.remaining(i, mask);
            if (!isZero(rem) and !std.mem.eql(u64, &rem, &g.validBits(b))) needed += 1;
        };
        const capacity = try std.math.add(usize, g.pool.items.len, needed);
        if (capacity >= full) return error.PoolTooLarge;
        try g.pool.ensureTotalCapacityPrecise(g.allocator, capacity);
        for (r.lo[2]..r.hi[2]) |z| for (r.lo[1]..r.hi[1]) |y| for (r.lo[0]..r.hi[0]) |x| {
            const b = [3]usize{ x, y, z };
            const i = g.blockIndex(b);
            const d = g.blocks[i];
            if (d == empty) continue;
            const before = g.bits(i);
            const rem = g.remaining(i, g.cutMask(b, m, reference));
            if (std.mem.eql(u64, &before, &rem)) continue;
            if (isZero(rem)) {
                g.blocks[i] = empty;
            } else if (d == full) {
                g.blocks[i] = @intCast(g.pool.items.len);
                g.pool.appendAssumeCapacity(rem);
            } else {
                g.pool.items[d] = rem;
            }
        };
    }
};
