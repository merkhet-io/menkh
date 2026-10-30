//! Final-surface provenance for monotone subtraction histories. A surviving
//! face was exposed when its empty neighbor was removed, not when its own
//! occupied voxel was last touched. Initial/world-boundary faces have ID zero.
const std = @import("std");
const c = @import("core.zig");
const surface = @import("surface.zig");
pub const Entry = extern struct { cell: u64, operation: u32, tool: u32 };
pub const Index = struct {
    allocator: std.mem.Allocator,
    grid: c.Grid,
    wanted: std.AutoHashMap(usize, c.Bits),
    entries: std.ArrayList(Entry) = .empty,
    pub fn init(a: std.mem.Allocator, g: c.Grid) !Index {
        var result = Index{ .allocator = a, .grid = g, .wanted = .init(a) };
        errdefer result.deinit();
        var quads = try surface.generate(a, g);
        defer quads.deinit(a);
        for (quads.items) |q| {
            const axis = q.axis;
            if ((!q.positive and q.p[axis] == 0) or (q.positive and q.p[axis] == g.n[axis])) continue;
            const u = (axis + @as(usize, 1)) % 3;
            const v = (axis + @as(usize, 2)) % 3;
            for (0..q.height) |y| for (0..q.width) |x| {
                var p = q.p;
                p[u] += x;
                p[v] += y;
                if (!q.positive) p[axis] -= 1;
                const bi = g.blockIndex(.{ p[0] / 8, p[1] / 8, p[2] / 8 });
                const entry = try result.wanted.getOrPut(bi);
                if (!entry.found_existing) entry.value_ptr.* = @splat(0);
                entry.value_ptr[p[2] % 8] |= @as(u64, 1) << @intCast(p[1] % 8 * 8 + p[0] % 8);
            };
        }
        return result;
    }
    pub fn deinit(s: *Index) void {
        s.wanted.deinit();
        s.entries.deinit(s.allocator);
    }
    fn get(comptime T: type, bytes: []const u8, cursor: *usize) !T {
        if (bytes.len - cursor.* < @sizeOf(T)) return error.CorruptHistory;
        const value = std.mem.readInt(T, bytes[cursor.*..][0..@sizeOf(T)], .little);
        cursor.* += @sizeOf(T);
        return value;
    }
    pub fn consume(s: *Index, bytes: []const u8, operation: u32, tool: u32) !void {
        if (operation == 0) return error.InvalidOperationId;
        var cursor: usize = 0;
        while (cursor < bytes.len) {
            const id = try get(u32, bytes, &cursor);
            if (id >= s.grid.blocks.len) return error.CorruptHistory;
            const old = try get(u32, bytes, &cursor);
            const new = try get(u32, bytes, &cursor);
            var masks: [2]c.Bits = undefined;
            for ([2]u32{ old, new }, 0..) |d, j| {
                masks[j] = if (d == c.full) s.grid.validBits(s.grid.blockCoords(id)) else @splat(0);
                if (d < c.full) {
                    if (d >= s.grid.blocks.len) return error.CorruptHistory;
                    for (&masks[j]) |*w| w.* = try get(u64, bytes, &cursor);
                }
            }
            for (masks[0], masks[1]) |before, after| if ((after & ~before) != 0) return error.NonMonotoneHistory;
            const wanted = s.wanted.getPtr(id) orelse continue;
            const b = s.grid.blockCoords(id);
            for (masks[0], masks[1], 0..) |before, after, z| {
                var removed = before & ~after & wanted[z];
                // Reserve before changing this candidate mask. Index is disposable
                // on failure; authoritative stock and history are never changed.
                try s.entries.ensureUnusedCapacity(s.allocator, @popCount(removed));
                wanted[z] &= ~removed;
                while (removed != 0) {
                    const bit = @ctz(removed);
                    removed &= removed - 1;
                    const p = [3]usize{ b[0] * 8 + bit % 8, b[1] * 8 + bit / 8, b[2] * 8 + z };
                    const key = (p[2] * s.grid.n[1] + p[1]) * s.grid.n[0] + p[0];
                    s.entries.appendAssumeCapacity(.{ .cell = @intCast(key), .operation = operation, .tool = tool });
                }
            }
        }
    }
    pub fn sort(s: *Index) void {
        std.mem.sort(Entry, s.entries.items, {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                return a.cell < b.cell;
            }
        }.less);
    }
};
