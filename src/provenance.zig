//! Surface provenance for monotone subtraction histories. A surviving
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
    all_frames: bool = false,
    last_operation: u32 = 0,
    max_entries: usize = 67108864, // Matches the readers' 1 GiB wire limit.
    pub fn initAllFrames(a: std.mem.Allocator, g: c.Grid) Index {
        return .{ .allocator = a, .grid = g, .wanted = .init(a), .all_frames = true };
    }
    pub fn consumeFrame(s: *Index, g: c.Grid, bytes: []const u8, operation: u32, tool: u32) !void {
        if (!s.all_frames) return error.InvalidProvenanceScope;
        s.grid = g; // Pool storage can move between operations.
        try s.consume(bytes, operation, tool);
    }
    fn adjacent(s: Index, b: [3]usize) c.Bits {
        var neighbors: [6]c.Bits = @splat(@splat(0));
        for (0..3) |axis| {
            var p = b;
            if (b[axis] > 0) {
                p[axis] = b[axis] - 1;
                neighbors[axis * 2] = s.grid.bits(s.grid.blockIndex(p));
            }
            p = b;
            if (b[axis] + 1 < s.grid.nb[axis]) {
                p[axis] = b[axis] + 1;
                neighbors[axis * 2 + 1] = s.grid.bits(s.grid.blockIndex(p));
            }
        }
        const own = s.grid.bits(s.grid.blockIndex(b));
        var result: c.Bits = undefined;
        for (0..8) |z| {
            result[z] = ((own[z] << 1) & 0xfefefefefefefefe) |
                ((own[z] >> 1) & 0x7f7f7f7f7f7f7f7f) |
                (own[z] << 8) | (own[z] >> 8) |
                ((neighbors[0][z] & 0x8080808080808080) >> 7) |
                ((neighbors[1][z] & 0x0101010101010101) << 7) |
                (neighbors[2][z] >> 56) | (neighbors[3][z] << 56) |
                (if (z > 0) own[z - 1] else neighbors[4][7]) |
                (if (z < 7) own[z + 1] else neighbors[5][0]);
        }
        return result;
    }
    fn reserve(s: *Index, count: usize) !void {
        const needed = try std.math.add(usize, s.entries.items.len, count);
        if (needed > s.max_entries) return error.ProvenanceTooLarge;
        if (needed > s.entries.capacity) try s.entries.ensureTotalCapacityPrecise(s.allocator, @min(s.max_entries, @max(needed, @max(64, s.entries.capacity * 2))));
    }
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
        if (operation == 0 or operation <= s.last_operation) return error.InvalidOperationId;
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
            const b = s.grid.blockCoords(id);
            var boundary = if (s.all_frames) s.adjacent(b) else @as(c.Bits, @splat(0));
            const wanted = if (s.all_frames) &boundary else s.wanted.getPtr(id) orelse continue;
            for (masks[0], masks[1], 0..) |before, after, z| {
                var removed = before & ~after & wanted[z];
                // Reserve before changing this candidate mask. Index is disposable
                // on failure; authoritative stock and history are never changed.
                try s.reserve(@popCount(removed));
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
        s.last_operation = operation;
    }
    pub fn sort(s: *Index) void {
        std.mem.sort(Entry, s.entries.items, {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                return a.cell < b.cell;
            }
        }.less);
    }
};
