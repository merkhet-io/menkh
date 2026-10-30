//! Portable little-endian state checkpoint and strict transactional delta replay.
const std = @import("std");
const c = @import("core.zig");
const e = @import("engine.zig");
const magic = "MENKHST1";
pub fn encode(a: std.mem.Allocator, g: c.Grid) ![]u8 {
    const len = try std.math.add(usize, 96, try std.math.add(usize, try std.math.mul(usize, g.blocks.len, 4), try std.math.mul(usize, g.pool.items.len, 64)));
    const data = try a.alloc(u8, len);
    @memset(data, 0);
    @memcpy(data[0..8], magic);
    for (g.origin, 0..) |v, i| put(u64, data, 8 + i * 8, @bitCast(v));
    for (g.size, 0..) |v, i| put(u64, data, 32 + i * 8, @bitCast(v));
    put(u64, data, 56, @bitCast(g.h));
    put(u64, data, 64, g.blocks.len);
    put(u64, data, 72, g.pool.items.len);
    for (g.blocks, 0..) |v, i| put(u32, data, 96 + i * 4, v);
    const offset = 96 + g.blocks.len * 4;
    for (g.pool.items, 0..) |bits, i| for (bits, 0..) |w, z| put(u64, data, offset + i * 64 + z * 8, w);
    put(u64, data, 80, std.hash.Wyhash.hash(0, data[96..]));
    put(u64, data, 88, std.hash.Wyhash.hash(0, data[0..80]));
    return data;
}
fn put(comptime T: type, bytes: []u8, at: usize, v: T) void {
    std.mem.writeInt(T, bytes[at..][0..@sizeOf(T)], v, .little);
}
fn get(comptime T: type, bytes: []const u8, at: usize) T {
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}
pub fn decode(a: std.mem.Allocator, data: []const u8) !c.Grid {
    if (data.len < 96 or !std.mem.eql(u8, data[0..8], magic)) return error.InvalidState;
    if (get(u64, data, 88) != std.hash.Wyhash.hash(0, data[0..80]) or get(u64, data, 80) != std.hash.Wyhash.hash(0, data[96..])) return error.ChecksumMismatch;
    const blocks = get(u64, data, 64);
    const slots = get(u64, data, 72);
    if (blocks >= c.full or slots >= c.full) return error.InvalidState;
    if (try std.math.add(u64, 96, try std.math.add(u64, try std.math.mul(u64, blocks, 4), try std.math.mul(u64, slots, 64))) != data.len) return error.InvalidState;
    var size: e.V = undefined;
    var origin: e.V = undefined;
    for (0..3) |j| {
        origin[j] = @bitCast(get(u64, data, 8 + j * 8));
        size[j] = @bitCast(get(u64, data, 32 + j * 8));
    }
    try e.validV(origin);
    var g = try c.Grid.init(a, size, @bitCast(get(u64, data, 56)));
    errdefer g.deinit();
    g.origin = origin;
    if (g.blocks.len != blocks) return error.InvalidState;
    try g.pool.resize(a, @intCast(slots));
    for (g.pool.items, 0..) |*bits, i| for (bits, 0..) |*w, z| {
        w.* = get(u64, data, 96 + g.blocks.len * 4 + i * 64 + z * 8);
    };
    // Reject slot aliases: mutating an aliased mixed block would change unrelated material.
    const seen = try a.alloc(bool, @intCast(slots));
    defer a.free(seen);
    @memset(seen, false);
    for (g.blocks, 0..) |*d, i| {
        d.* = get(u32, data, 96 + i * 4);
        if (d.* < c.full) {
            if (d.* >= slots or seen[d.*]) return error.InvalidState;
            seen[d.*] = true;
            const valid = g.validBits(g.blockCoords(i));
            for (g.pool.items[d.*], valid) |w, v| if (w & ~v != 0) return error.InvalidState;
        }
    }
    return g;
}
pub fn replay(g: *c.Grid, bytes: []const u8, forward: bool) !void {
    // IDs must be strictly increasing, as emitted by the X-fastest traversal.
    var cursor: usize = 0;
    var previous: ?u32 = null;
    var max_slot = g.pool.items.len;
    while (cursor < bytes.len) {
        if (bytes.len - cursor < 12) return error.CorruptHistory;
        const id = get(u32, bytes, cursor);
        const old = get(u32, bytes, cursor + 4);
        const new = get(u32, bytes, cursor + 8);
        cursor += 12;
        if (id >= g.blocks.len or (previous != null and id <= previous.?)) return error.CorruptHistory;
        previous = id;
        var before: c.Bits = @splat(0);
        var after: c.Bits = @splat(0);
        for ([2]u32{ old, new }, 0..) |d, j| if (d < c.full) {
            if (d >= g.blocks.len or bytes.len - cursor < 64) return error.CorruptHistory;
            max_slot = @max(max_slot, @as(usize, d) + 1);
            for (0..8) |z| {
                const w = get(u64, bytes, cursor + z * 8);
                if (w & ~g.validBits(g.blockCoords(id))[z] != 0) return error.CorruptHistory;
                if (j == 0) before[z] = w else after[z] = w;
            }
            cursor += 64;
        };
        const expected = if (forward) old else new;
        if (g.blocks[id] != expected) return error.HistoryStateMismatch;
        if (expected < c.full and !std.mem.eql(u64, &g.bits(id), if (forward) &before else &after)) return error.HistoryStateMismatch;
    }
    const owners = try g.allocator.alloc(u32, max_slot);
    defer g.allocator.free(owners);
    @memset(owners, c.empty);
    for (g.blocks, 0..) |d, i| if (d < c.full) {
        if (d >= g.pool.items.len or owners[d] != c.empty) return error.CorruptHistory;
        owners[d] = @intCast(i);
    };
    cursor = 0;
    while (cursor < bytes.len) {
        const id = get(u32, bytes, cursor);
        const old = get(u32, bytes, cursor + 4);
        const new = get(u32, bytes, cursor + 8);
        cursor += 12;
        const current = if (forward) old else new;
        const target = if (forward) new else old;
        if (current < c.full) owners[current] = c.empty;
        if (target < c.full) {
            if (owners[target] != c.empty) return error.CorruptHistory;
            owners[target] = id;
        }
        if (old < c.full) cursor += 64;
        if (new < c.full) cursor += 64;
    }
    // Capacity may grow on load, but every validation failure above precedes mutation.
    const old_len = g.pool.items.len;
    try g.pool.resize(g.allocator, max_slot);
    for (g.pool.items[old_len..]) |*bits| bits.* = @splat(0);
    cursor = 0;
    while (cursor < bytes.len) {
        const id = get(u32, bytes, cursor);
        const old = get(u32, bytes, cursor + 4);
        const new = get(u32, bytes, cursor + 8);
        cursor += 12;
        for ([2]u32{ old, new }, 0..) |d, j| if (d < c.full) {
            if ((forward and j == 1) or (!forward and j == 0)) for (0..8) |z| {
                g.pool.items[d][z] = get(u64, bytes, cursor + z * 8);
            };
            cursor += 64;
        };
        g.blocks[id] = if (forward) new else old;
    }
}
