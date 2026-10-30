const std = @import("std");
const core = @import("core.zig");
pub const Quad = struct { p: [3]usize, axis: u2, positive: bool, width: usize, height: usize };
pub fn generate(a: std.mem.Allocator, g: core.Grid) !std.ArrayList(Quad) {
    var out: std.ArrayList(Quad) = .empty;
    errdefer out.deinit(a);
    for (g.blocks, 0..) |d, bi| {
        if (d == core.empty) continue;
        const b = g.blockCoords(bi);
        const e = g.extent(b);
        for (0..3) |axis| {
            const u = (axis + 1) % 3;
            const v = (axis + 2) % 3;
            for ([_]bool{ false, true }) |positive| {
                const start = if (d == core.full and positive) e[axis] - 1 else 0;
                const end = if (d == core.full and !positive) 1 else e[axis];
                for (start..end) |plane| {
                    // Full neighbor blocks hide an entire block face; avoid 64 point queries.
                    if (d == core.full) {
                        var neighbor = b;
                        if ((positive and b[axis] + 1 < g.nb[axis]) or (!positive and b[axis] > 0)) {
                            if (positive) neighbor[axis] += 1 else neighbor[axis] -= 1;
                            if (g.blocks[g.blockIndex(neighbor)] == core.full) continue;
                        }
                    }
                    var mask: [8]u8 = @splat(0);
                    for (0..e[v]) |j| for (0..e[u]) |i| {
                        var p: [3]usize = .{ b[0] * 8, b[1] * 8, b[2] * 8 };
                        p[axis] += plane;
                        p[u] += i;
                        p[v] += j;
                        if (!g.occupied(p)) continue;
                        var q = p;
                        var outside = false;
                        if (positive) {
                            q[axis] += 1;
                        } else if (q[axis] == 0) {
                            outside = true;
                        } else {
                            q[axis] -= 1;
                        }
                        if (outside or !g.occupied(q)) mask[j] |= @as(u8, 1) << @as(u3, @intCast(i));
                    };
                    for (0..e[v]) |j| {
                        var i: usize = 0;
                        while (i < e[u]) {
                            if (mask[j] & (@as(u8, 1) << @as(u3, @intCast(i))) == 0) {
                                i += 1;
                                continue;
                            }
                            var w: usize = 1;
                            while (i + w < e[u] and mask[j] & (@as(u8, 1) << @as(u3, @intCast(i + w))) != 0) : (w += 1) {}
                            const strip: u8 = @intCast(((@as(u16, 1) << @as(u4, @intCast(w))) - 1) << @as(u4, @intCast(i)));
                            var h: usize = 1;
                            while (j + h < e[v] and mask[j + h] & strip == strip) : (h += 1) {}
                            for (j..j + h) |row| mask[row] &= ~strip;
                            var p: [3]usize = .{ b[0] * 8, b[1] * 8, b[2] * 8 };
                            p[axis] += plane + @intFromBool(positive);
                            p[u] += i;
                            p[v] += j;
                            try out.append(a, .{ .p = p, .axis = @intCast(axis), .positive = positive, .width = w, .height = h });
                            i += w;
                        }
                    }
                }
            }
        }
    }
    return out;
}
pub fn ppm(a: std.mem.Allocator, g: core.Grid, dir: std.fs.Dir) !void {
    const pixels = try std.math.mul(usize, g.n[0], g.n[1]);
    const rgb = try a.alloc(u8, try std.math.mul(usize, pixels, 3));
    defer a.free(rgb);
    @memset(rgb, 0);
    // Resolve 64 XY columns together. Each block descriptor is visited once
    // per column tile; each occupied layer resolves all its topmost bits.
    for (0..g.nb[1]) |by| for (0..g.nb[0]) |bx| {
        var unresolved = g.validBits(.{ bx, by, 0 })[0];
        var bz = g.nb[2];
        while (bz > 0 and unresolved != 0) {
            bz -= 1;
            const b = [3]usize{ bx, by, bz };
            const index = g.blockIndex(b);
            if (g.blocks[index] == core.empty) continue;
            const bits = g.bits(index);
            var z = g.extent(b)[2];
            while (z > 0 and unresolved != 0) {
                z -= 1;
                var hits = bits[z] & unresolved;
                unresolved &= ~hits;
                const value: u8 = @intFromFloat(255 * @as(f64, @floatFromInt(bz * 8 + z + 1)) / @as(f64, @floatFromInt(g.n[2])));
                while (hits != 0) {
                    const bit = @ctz(hits);
                    hits &= hits - 1;
                    const x = bx * 8 + bit % 8;
                    const y = by * 8 + bit / 8;
                    const pixel = ((g.n[1] - 1 - y) * g.n[0] + x) * 3;
                    @memset(rgb[pixel..][0..3], value);
                }
            }
        }
    };
    var file = try dir.createFile("height.ppm", .{});
    defer file.close();
    var buf: [128]u8 = undefined;
    try file.writeAll(try std.fmt.bufPrint(&buf, "P6\n{d} {d}\n255\n", .{ g.n[0], g.n[1] }));
    try file.writeAll(rgb);
}
pub fn obj(g: core.Grid, quads: []const Quad, dir: std.fs.Dir) !void {
    var file = try dir.createFile("surface.obj", .{});
    defer file.close();
    var storage: [65536]u8 = undefined;
    var used: usize = 0;
    try file.writeAll("# menkh voxel surface, millimeters; no smoothing\ns off\n");
    for (quads, 0..) |q, idx| {
        var textbuf: [1024]u8 = undefined;
        var len: usize = 0;
        const u = (@as(usize, q.axis) + 1) % 3;
        const v = (@as(usize, q.axis) + 2) % 3;
        for ([_][2]usize{ .{ 0, 0 }, .{ q.width, 0 }, .{ q.width, q.height }, .{ 0, q.height } }) |offset| {
            var p = q.p;
            p[u] += offset[0];
            p[v] += offset[1];
            const s = try std.fmt.bufPrint(textbuf[len..], "v {d:.8} {d:.8} {d:.8}\n", .{ g.origin[0] + @as(f64, @floatFromInt(p[0])) * g.h, g.origin[1] + @as(f64, @floatFromInt(p[1])) * g.h, g.origin[2] + @as(f64, @floatFromInt(p[2])) * g.h });
            len += s.len;
        }
        const base = idx * 4 + 1;
        const face = if (q.positive) [4]usize{ base, base + 1, base + 2, base + 3 } else [4]usize{ base + 3, base + 2, base + 1, base };
        len += (try std.fmt.bufPrint(textbuf[len..], "f {d} {d} {d} {d}\n", .{ face[0], face[1], face[2], face[3] })).len;
        if (used + len > storage.len) {
            try file.writeAll(storage[0..used]);
            used = 0;
        }
        @memcpy(storage[used..][0..len], textbuf[0..len]);
        used += len;
    }
    try file.writeAll(storage[0..used]);
}

pub const BoundaryCounts = struct { surface_voxels: u64 = 0, exposed_faces: u64 = 0 };
// A surface voxel is occupied and has at least one empty face-neighbor.
// Outside the finite grid is empty; enclosed cavities are included.
pub fn boundaryCounts(g: core.Grid) BoundaryCounts {
    var result: BoundaryCounts = .{};
    for (g.blocks, 0..) |descriptor, i| {
        if (descriptor == core.empty) continue;
        const b = g.blockCoords(i);
        var neighbors: [6]core.Bits = undefined;
        for (0..3) |axis| {
            var p = b;
            neighbors[axis * 2] = @splat(0);
            neighbors[axis * 2 + 1] = @splat(0);
            if (b[axis] > 0) {
                p[axis] -= 1;
                neighbors[axis * 2] = g.bits(g.blockIndex(p));
            }
            p = b;
            if (b[axis] + 1 < g.nb[axis]) {
                p[axis] += 1;
                neighbors[axis * 2 + 1] = g.bits(g.blockIndex(p));
            }
        }
        const bits = g.bits(i);
        for (bits, 0..) |w, z| {
            if (w == 0) continue;
            const adjacent = [6]u64{
                ((w << 1) & 0xfefefefefefefefe) | ((neighbors[0][z] >> 7) & 0x0101010101010101),
                ((w >> 1) & 0x7f7f7f7f7f7f7f7f) | ((neighbors[1][z] << 7) & 0x8080808080808080),
                (w << 8) | (neighbors[2][z] >> 56),
                (w >> 8) | (neighbors[3][z] << 56),
                if (z == 0) neighbors[4][7] else bits[z - 1],
                if (z == 7) neighbors[5][0] else bits[z + 1],
            };
            var boundary: u64 = 0;
            for (adjacent) |other| {
                const exposed = w & ~other;
                boundary |= exposed;
                result.exposed_faces += @popCount(exposed);
            }
            result.surface_voxels += @popCount(boundary);
        }
    }
    return result;
}
