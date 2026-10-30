//! Strict binary STL import, exact edge manifold validation, BVH ray parity.
const std = @import("std");
const e = @import("engine.zig");
const c = @import("core.zig");
const Tri = struct { v: [3]e.V, bounds: e.Bounds };
const Node = struct { bounds: e.Bounds, start: usize, len: usize, left: usize = 0, right: usize = 0 };
const Edge = struct { a: e.V, b: e.V, forward: bool };
fn lessV(a: e.V, b: e.V) bool {
    for (0..3) |j| {
        if (a[j] < b[j]) return true;
        if (a[j] > b[j]) return false;
    }
    return false;
}
fn lessEdge(_: void, a: Edge, b: Edge) bool {
    if (lessV(a.a, b.a)) return true;
    if (lessV(b.a, a.a)) return false;
    return lessV(a.b, b.b);
}
fn sameV(a: e.V, b: e.V) bool {
    return std.mem.eql(f64, &a, &b);
}
pub const Mesh = struct {
    allocator: std.mem.Allocator,
    triangles: []Tri,
    nodes: std.ArrayList(Node) = .empty,
    bounds: e.Bounds,
    parse_validate_ns: u64 = 0,
    bvh_ns: u64 = 0,
    intersection_validate_ns: u64 = 0,
    uniform_blocks: u64 = 0,
    point_queries: u64 = 0,
    pub fn deinit(m: *Mesh) void {
        m.allocator.free(m.triangles);
        m.nodes.deinit(m.allocator);
    }
    pub fn parse(a: std.mem.Allocator, bytes: []const u8, scale_mm: f64, translation: e.V) !Mesh {
        var timer = try std.time.Timer.start();
        if (bytes.len < 84 or !std.math.isFinite(scale_mm) or scale_mm <= 0 or scale_mm > 1e6) return error.InvalidSTL;
        try e.validV(translation);
        const n = std.mem.readInt(u32, bytes[80..84], .little);
        if (n == 0 or n > 1000000 or try std.math.add(usize, 84, try std.math.mul(usize, n, 50)) != bytes.len) return error.InvalidSTL;
        const ts = try a.alloc(Tri, n);
        errdefer a.free(ts);
        const edges = try a.alloc(Edge, try std.math.mul(usize, n, 3));
        defer a.free(edges);
        var bounds = e.Bounds{ .lo = .{ 1e6, 1e6, 1e6 }, .hi = .{ -1e6, -1e6, -1e6 } };
        for (ts, 0..) |*t, i| {
            const record = bytes[84 + i * 50 ..][0..50];
            if (std.mem.readInt(u16, record[48..50], .little) != 0) return error.STLAttributesUnsupported;
            // Normal records are validated but winding, not stored normals, defines topology.
            for (0..12) |j| {
                const f: f32 = @bitCast(std.mem.readInt(u32, record[j * 4 ..][0..4], .little));
                if (!std.math.isFinite(f)) return error.InvalidSTL;
                if (j >= 3) {
                    const vertex = (j - 3) / 3;
                    const axis = (j - 3) % 3;
                    t.v[vertex][axis] = @as(f64, f) * scale_mm + translation[axis];
                }
            }
            t.bounds = .{ .lo = t.v[0], .hi = t.v[0] };
            for (t.v) |v| {
                try e.validV(v);
                for (0..3) |j| {
                    t.bounds.lo[j] = @min(t.bounds.lo[j], v[j]);
                    t.bounds.hi[j] = @max(t.bounds.hi[j], v[j]);
                    bounds.lo[j] = @min(bounds.lo[j], v[j]);
                    bounds.hi[j] = @max(bounds.hi[j], v[j]);
                }
            }
            if (e.norm(e.cross(e.sub(t.v[1], t.v[0]), e.sub(t.v[2], t.v[0]))) <= 1e-16) return error.DegenerateTriangle;
            for (0..3) |j| {
                const x = t.v[j];
                const y = t.v[(j + 1) % 3];
                const forward = lessV(x, y);
                edges[i * 3 + j] = .{ .a = if (forward) x else y, .b = if (forward) y else x, .forward = forward };
            }
        }
        std.mem.sort(Edge, edges, {}, lessEdge);
        var i: usize = 0;
        while (i < edges.len) {
            var end = i + 1;
            while (end < edges.len and sameV(edges[i].a, edges[end].a) and sameV(edges[i].b, edges[end].b)) : (end += 1) {}
            if (end - i != 2 or edges[i].forward == edges[i + 1].forward) return error.NonWatertightOrInconsistentSTL;
            i = end;
        }
        var m = Mesh{ .allocator = a, .triangles = ts, .bounds = bounds };
        errdefer m.nodes.deinit(a);
        try m.nodes.ensureTotalCapacityPrecise(a, try std.math.mul(usize, n, 2));
        m.parse_validate_ns = timer.lap();
        _ = m.build(0, n);
        m.bvh_ns = timer.lap();
        for (0..m.triangles.len) |index| try m.validateIntersections(index, 0);
        m.intersection_validate_ns = timer.lap();
        return m;
    }
    fn overlap(a: e.Bounds, b: e.Bounds) bool {
        for (0..3) |j| if (a.hi[j] < b.lo[j] - 1e-10 or b.hi[j] < a.lo[j] - 1e-10) return false;
        return true;
    }
    fn validateIntersections(m: Mesh, index: usize, node: usize) !void {
        const t = m.triangles[index];
        const n = m.nodes.items[node];
        if (!overlap(t.bounds, n.bounds)) return;
        if (n.len > 8) {
            try m.validateIntersections(index, n.left);
            try m.validateIntersections(index, n.right);
            return;
        }
        for (n.start..n.start + n.len) |i| {
            if (i <= index) continue;
            const other = m.triangles[i];
            if (!overlap(t.bounds, other.bounds)) continue;
            if (trianglesIntersect(t, other)) return error.SelfIntersectingSTL;
        }
    }
    fn trianglesIntersect(a: Tri, b: Tri) bool {
        const n = e.cross(e.sub(a.v[1], a.v[0]), e.sub(a.v[2], a.v[0]));
        const normal = e.scale(n, 1 / e.norm(n));
        var coplanar = true;
        for (b.v) |v| if (@abs(e.dot(normal, e.sub(v, a.v[0]))) > 1e-10) {
            coplanar = false;
        };
        if (coplanar) {
            // Strict 2D triangle overlap, ignoring only shared edges/vertices of zero area.
            for ([2]Tri{ a, b }) |t| for (0..3) |i| {
                const axis = e.cross(normal, e.sub(t.v[(i + 1) % 3], t.v[i]));
                var amin: f64 = std.math.inf(f64);
                var amax: f64 = -std.math.inf(f64);
                var bmin = amin;
                var bmax = amax;
                for (a.v) |v| {
                    const d = e.dot(axis, v);
                    amin = @min(amin, d);
                    amax = @max(amax, d);
                }
                for (b.v) |v| {
                    const d = e.dot(axis, v);
                    bmin = @min(bmin, d);
                    bmax = @max(bmax, d);
                }
                if (@min(amax, bmax) - @max(amin, bmin) <= 1e-10) return false;
            };
            return true;
        }
        for (0..2) |side| {
            const t = if (side == 0) a else b;
            const target = if (side == 0) b else a;
            for (0..3) |i| {
                const start = t.v[i];
                const end = t.v[(i + 1) % 3];
                const d = e.sub(end, start);
                const ab = e.sub(target.v[1], target.v[0]);
                const ac = e.sub(target.v[2], target.v[0]);
                const h = e.cross(d, ac);
                const det = e.dot(ab, h);
                if (@abs(det) < 1e-14 * e.norm(ab) * e.norm(ac) * e.norm(d)) continue;
                const q = e.sub(start, target.v[0]);
                const u = e.dot(q, h) / det;
                const cr = e.cross(q, ab);
                const v = e.dot(d, cr) / det;
                const tval = e.dot(ac, cr) / det;
                if (u < -1e-10 or v < -1e-10 or u + v > 1 + 1e-10 or tval < -1e-10 or tval > 1 + 1e-10) continue;
                const point = e.add(start, e.scale(d, tval));
                var shared = false;
                for (t.v) |tv| for (target.v) |bv| {
                    if (sameV(tv, bv) and e.norm(e.sub(point, tv)) < 1e-9) shared = true;
                };
                if (!shared) return true;
            }
        }
        return false;
    }
    fn build(m: *Mesh, start: usize, len: usize) usize {
        var b = m.triangles[start].bounds;
        for (m.triangles[start..][0..len]) |t| for (0..3) |j| {
            b.lo[j] = @min(b.lo[j], t.bounds.lo[j]);
            b.hi[j] = @max(b.hi[j], t.bounds.hi[j]);
        };
        const id = m.nodes.items.len;
        m.nodes.appendAssumeCapacity(.{ .bounds = b, .start = start, .len = len });
        if (len <= 8) return id;
        const ext = e.sub(b.hi, b.lo);
        const axis: usize = if (ext[0] >= ext[1] and ext[0] >= ext[2]) 0 else if (ext[1] >= ext[2]) 1 else 2;
        const Sort = struct {
            fn less(ax: usize, x: Tri, y: Tri) bool {
                return x.bounds.lo[ax] + x.bounds.hi[ax] < y.bounds.lo[ax] + y.bounds.hi[ax];
            }
        };
        std.mem.sort(Tri, m.triangles[start..][0..len], axis, Sort.less);
        const half = len / 2;
        const left = m.build(start, half);
        const right = m.build(start + half, len - half);
        m.nodes.items[id].left = left;
        m.nodes.items[id].right = right;
        return id;
    }
    fn intersects(b: e.Bounds, p: e.V, d: e.V) bool {
        var lo: f64 = 0;
        var hi: f64 = std.math.inf(f64);
        for (0..3) |j| {
            if (d[j] == 0) {
                if (p[j] < b.lo[j] - 1e-10 or p[j] > b.hi[j] + 1e-10) return false;
            } else {
                const a = (b.lo[j] - p[j]) / d[j];
                const z = (b.hi[j] - p[j]) / d[j];
                lo = @max(lo, @min(a, z));
                hi = @min(hi, @max(a, z));
            }
        }
        return lo <= hi + 1e-10;
    }
    fn hits(m: Mesh, id: usize, p: e.V, d: e.V) !usize {
        const n = m.nodes.items[id];
        if (!intersects(n.bounds, p, d)) return 0;
        if (n.len > 8) return try m.hits(n.left, p, d) + try m.hits(n.right, p, d);
        var result: usize = 0;
        for (m.triangles[n.start..][0..n.len]) |t| {
            const ab = e.sub(t.v[1], t.v[0]);
            const ac = e.sub(t.v[2], t.v[0]);
            const cross = e.cross(d, ac);
            const det = e.dot(ab, cross);
            if (@abs(det) < 1e-14 * e.norm(ab) * e.norm(ac) * e.norm(d)) continue;
            const q = e.sub(p, t.v[0]);
            const u = e.dot(q, cross) / det;
            if (u < -1e-12 or u > 1 + 1e-12) continue;
            const cr = e.cross(q, ab);
            const v = e.dot(d, cr) / det;
            if (v < -1e-12 or u + v > 1 + 1e-12) continue;
            const distance = e.dot(ac, cr) / det;
            if (distance < -1e-10) continue;
            if (@abs(distance) <= 1e-10) return error.PointOnBoundary;
            if (u < 1e-10 or v < 1e-10 or 1 - u - v < 1e-10) return error.AmbiguousRay;
            result += 1;
        }
        return result;
    }
    pub fn contains(m: Mesh, p: e.V) !bool {
        for (0..3) |j| if (p[j] < m.bounds.lo[j] - 1e-10 or p[j] > m.bounds.hi[j] + 1e-10) return false;
        // Retry edge/vertex hits with independent deterministic non-axis directions.
        const directions = [_]e.V{ .{ 1, 0.3713906763541037, 0.6947465906068658 }, .{ 0.238917, 1, 0.513791 }, .{ 0.817931, 0.129873, 1 } };
        var answer: ?bool = null;
        for (directions) |d| {
            const hits_count = m.hits(0, p, d) catch |err| switch (err) {
                error.PointOnBoundary => return true,
                error.AmbiguousRay => continue,
                else => return err,
            };
            const inside = hits_count % 2 == 1;
            if (answer) |previous| {
                if (previous != inside) return error.AmbiguousMesh;
            }
            answer = inside;
        }
        return answer orelse error.AmbiguousMesh;
    }
    // A triangle can intersect a center-box only if its AABB overlaps it.
    // No overlap proves the entire connected box lies in one parity component,
    // including cavities and disconnected shells. Overlap never implies inside.
    fn surfaceOverlap(m: Mesh, id: usize, b: e.Bounds) bool {
        const n = m.nodes.items[id];
        if (!overlap(n.bounds, b)) return false;
        if (n.len > 8) return m.surfaceOverlap(n.left, b) or m.surfaceOverlap(n.right, b);
        for (m.triangles[n.start..][0..n.len]) |t| if (overlap(t.bounds, b)) return true;
        return false;
    }
    fn fillRegion(m: *Mesh, g: c.Grid, block: [3]usize, lo: [3]usize, hi: [3]usize, bits: *c.Bits) !void {
        var bb: e.Bounds = undefined;
        var longest: usize = 0;
        for (0..3) |j| {
            bb.lo[j] = g.origin[j] + g.center(block[j] * 8 + lo[j]);
            bb.hi[j] = g.origin[j] + g.center(block[j] * 8 + hi[j] - 1);
            if (hi[j] - lo[j] > hi[longest] - lo[longest]) longest = j;
        }
        if (hi[longest] - lo[longest] == 1 or !m.surfaceOverlap(0, bb)) {
            m.point_queries += 1;
            if (try m.contains(e.scale(e.add(bb.lo, bb.hi), 0.5))) {
                for (lo[2]..hi[2]) |z| for (lo[1]..hi[1]) |y| for (lo[0]..hi[0]) |x| {
                    bits[z] |= @as(u64, 1) << @as(u6, @intCast(y * 8 + x));
                };
            }
            return;
        }
        var left = hi;
        var right = lo;
        left[longest] = (lo[longest] + hi[longest]) / 2;
        right[longest] = left[longest];
        try m.fillRegion(g, block, lo, left, bits);
        try m.fillRegion(g, block, right, hi, bits);
    }
    pub fn voxelize(m: *Mesh, a: std.mem.Allocator, b: e.Bounds, h: f64) !c.Grid {
        return m.voxelizeMode(a, b, h, false);
    }
    pub fn voxelizeMode(m: *Mesh, a: std.mem.Allocator, b: e.Bounds, h: f64, reference: bool) !c.Grid {
        m.uniform_blocks = 0;
        m.point_queries = 0;
        try b.validate();
        var g = try c.Grid.init(a, e.sub(b.hi, b.lo), h);
        errdefer g.deinit();
        g.origin = b.lo;
        g.material_bounds = .{ m.bounds.lo, m.bounds.hi };
        @memset(g.blocks, c.empty);
        for (g.blocks, 0..) |*d, i| {
            const block = g.blockCoords(i);
            const bb = e.blockBounds(g, block);
            var outside = false;
            for (0..3) |j| if (bb.hi[j] < m.bounds.lo[j] or bb.lo[j] > m.bounds.hi[j]) {
                outside = true;
            };
            if (outside) continue;
            if (!reference and !m.surfaceOverlap(0, bb)) {
                m.point_queries += 1;
                m.uniform_blocks += 1;
                if (try m.contains(e.scale(e.add(bb.lo, bb.hi), 0.5))) {
                    const valid = g.validBits(block);
                    if (e.count(valid) == 512) d.* = c.full else {
                        try g.pool.append(a, valid);
                        d.* = @intCast(g.pool.items.len - 1);
                    }
                }
                continue;
            }
            var bits: c.Bits = @splat(0);
            const ex = g.extent(block);
            if (!reference) {
                try m.fillRegion(g, block, .{ 0, 0, 0 }, ex, &bits);
            } else for (0..ex[2]) |z| for (0..ex[1]) |y| for (0..ex[0]) |x| {
                const p = e.add(g.origin, .{ g.center(block[0] * 8 + x), g.center(block[1] * 8 + y), g.center(block[2] * 8 + z) });
                m.point_queries += 1;
                if (try m.contains(p)) bits[z] |= @as(u64, 1) << @as(u6, @intCast(y * 8 + x));
            };
            if (e.count(bits) == 0) continue;
            if (std.mem.eql(u64, &bits, &g.validBits(block))) d.* = c.full else {
                try g.pool.append(a, bits);
                d.* = @intCast(g.pool.items.len - 1);
            }
        }
        return g;
    }
};
