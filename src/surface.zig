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
    for (0..g.n[1]) |y| for (0..g.n[0]) |x| {
        var z = g.n[2];
        while (z > 0 and !g.occupied(.{ x, y, z - 1 })) {
            const b = [3]usize{ x / 8, y / 8, (z - 1) / 8 };
            if (g.blocks[g.blockIndex(b)] == core.empty) z = b[2] * 8 else z -= 1;
        }
        const value: u8 = @intFromFloat(255 * @as(f64, @floatFromInt(z)) / @as(f64, @floatFromInt(g.n[2])));
        const index = ((g.n[1] - 1 - y) * g.n[0] + x) * 3;
        @memset(rgb[index..][0..3], value);
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
            const s = try std.fmt.bufPrint(textbuf[len..], "v {d:.8} {d:.8} {d:.8}\n", .{ @as(f64, @floatFromInt(p[0])) * g.h, @as(f64, @floatFromInt(p[1])) * g.h, @as(f64, @floatFromInt(p[2])) * g.h });
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
