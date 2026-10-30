//! Exact six-connected components of raster differences, represented as X runs.
const std = @import("std");
const c = @import("core.zig");
const e = @import("engine.zig");
pub const Region = struct { kind: enum { excess, missing }, voxels: u64, volume_mm3: f64, bounds: e.Bounds, operation: ?usize = null };
const Run = struct { x: usize, end: usize, y: usize, z: usize, parent: usize = 0 };
fn less(_: void, a: Run, b: Run) bool {
    return if (a.z != b.z) a.z < b.z else if (a.y != b.y) a.y < b.y else a.x < b.x;
}
fn root(r: []Run, index: usize) usize {
    var i = index;
    while (r[i].parent != i) {
        r[i].parent = r[r[i].parent].parent;
        i = r[i].parent;
    }
    return i;
}
fn join(r: []Run, a: usize, b: usize) void {
    const x = root(r, a);
    const y = root(r, b);
    r[@max(x, y)].parent = @min(x, y);
}
// Caller owns result. Inputs are never mutated, including on allocation failure.
pub fn regions(a: std.mem.Allocator, stock: c.Grid, target: c.Grid) ![]Region {
    if (stock.h != target.h or !std.mem.eql(f64, &stock.origin, &target.origin) or !std.mem.eql(usize, &stock.n, &target.n)) return error.GridMismatch;
    var result: std.ArrayList(Region) = .empty;
    errdefer result.deinit(a);
    for (0..2) |kind| {
        var runs: std.ArrayList(Run) = .empty;
        defer runs.deinit(a);
        for (0..stock.blocks.len) |i| {
            const s = stock.bits(i);
            const t = target.bits(i);
            const b = stock.blockCoords(i);
            for (s, t, 0..) |sw, tw, z| {
                const word = if (kind == 0) sw & ~tw else tw & ~sw;
                for (0..8) |y| {
                    const row: u8 = @truncate(word >> @intCast(y * 8));
                    var x: usize = 0;
                    while (x < 8) {
                        if ((row & (@as(u8, 1) << @intCast(x))) == 0) {
                            x += 1;
                            continue;
                        }
                        const start = x;
                        while (x < 8 and (row & (@as(u8, 1) << @intCast(x))) != 0) : (x += 1) {}
                        try runs.append(a, .{ .x = b[0] * 8 + start, .end = b[0] * 8 + x, .y = b[1] * 8 + y, .z = b[2] * 8 + z });
                    }
                }
            }
        }
        std.mem.sort(Run, runs.items, {}, less);
        // Merge X runs across block boundaries before connecting neighboring rows.
        var n: usize = 0;
        for (runs.items) |r| {
            if (n > 0 and runs.items[n - 1].z == r.z and runs.items[n - 1].y == r.y and runs.items[n - 1].end == r.x) {
                runs.items[n - 1].end = r.end;
            } else {
                runs.items[n] = r;
                n += 1;
            }
        }
        runs.items.len = n;
        for (runs.items, 0..) |*r, i| r.parent = i;
        const Range = struct { start: usize, end: usize };
        var rows: std.AutoHashMap([2]usize, Range) = .init(a);
        defer rows.deinit();
        var start: usize = 0;
        while (start < n) {
            const first = runs.items[start];
            var end = start + 1;
            while (end < n and runs.items[end].y == first.y and runs.items[end].z == first.z) : (end += 1) {}
            const keys = [2]?[2]usize{ if (first.y > 0) .{ first.y - 1, first.z } else null, if (first.z > 0) .{ first.y, first.z - 1 } else null };
            for (keys) |key| if (key) |k| {
                if (rows.get(k)) |previous| {
                    var p = previous.start;
                    var q = start;
                    while (p < previous.end and q < end) {
                        const l = runs.items[p];
                        const r = runs.items[q];
                        if (l.x < r.end and r.x < l.end) join(runs.items, p, q);
                        if (l.end < r.end) p += 1 else q += 1;
                    }
                }
            };
            try rows.put(.{ first.y, first.z }, .{ .start = start, .end = end });
            start = end;
        }
        var groups: std.AutoHashMap(usize, usize) = .init(a);
        defer groups.deinit();
        for (runs.items, 0..) |r, i| {
            const id = root(runs.items, i);
            const entry = try groups.getOrPut(id);
            const lo = e.add(stock.origin, .{ @as(f64, @floatFromInt(r.x)) * stock.h, @as(f64, @floatFromInt(r.y)) * stock.h, @as(f64, @floatFromInt(r.z)) * stock.h });
            const hi = e.add(stock.origin, .{ @as(f64, @floatFromInt(r.end)) * stock.h, @as(f64, @floatFromInt(r.y + 1)) * stock.h, @as(f64, @floatFromInt(r.z + 1)) * stock.h });
            if (!entry.found_existing) {
                entry.value_ptr.* = result.items.len;
                try result.append(a, .{ .kind = if (kind == 0) .excess else .missing, .voxels = 0, .volume_mm3 = 0, .bounds = .{ .lo = lo, .hi = hi } });
            }
            const region = &result.items[entry.value_ptr.*];
            region.voxels += r.end - r.x;
            for (0..3) |j| {
                region.bounds.lo[j] = @min(region.bounds.lo[j], lo[j]);
                region.bounds.hi[j] = @max(region.bounds.hi[j], hi[j]);
            }
        }
    }
    for (result.items) |*r| r.volume_mm3 = @as(f64, @floatFromInt(r.voxels)) * stock.h * stock.h * stock.h;
    return result.toOwnedSlice(a);
}
