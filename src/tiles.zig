//! Immutable inspection snapshot: dense coarse directory, allocated nonempty 8^3-block tiles.
//! Deliberately separate from the mutable engine/history format pending benchmark evidence.
const std = @import("std");
const c = @import("core.zig");
pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    n: [3]usize,
    nt: [3]usize,
    directory: []u32,
    tiles: std.ArrayList([512]u32) = .empty,
    pool: std.ArrayList(c.Bits) = .empty,
    pub fn deinit(s: *Snapshot) void {
        s.allocator.free(s.directory);
        s.tiles.deinit(s.allocator);
        s.pool.deinit(s.allocator);
    }
    pub fn init(a: std.mem.Allocator, g: c.Grid) !Snapshot {
        const nt = [3]usize{ (g.nb[0] + 7) / 8, (g.nb[1] + 7) / 8, (g.nb[2] + 7) / 8 };
        const count = try std.math.mul(usize, try std.math.mul(usize, nt[0], nt[1]), nt[2]);
        const dir = try a.alloc(u32, count);
        @memset(dir, c.empty);
        var s = Snapshot{ .allocator = a, .n = g.n, .nt = nt, .directory = dir };
        errdefer s.deinit();
        var needed: usize = 0;
        for (g.blocks, 0..) |d, i| {
            if (d == c.empty) continue;
            const b = g.blockCoords(i);
            const tile = ((b[2] / 8) * nt[1] + b[1] / 8) * nt[0] + b[0] / 8;
            if (dir[tile] == c.empty) {
                dir[tile] = 0;
                needed += 1;
            }
        }
        try s.tiles.ensureTotalCapacityPrecise(a, needed);
        try s.pool.ensureTotalCapacityPrecise(a, g.stats().mixed_blocks);
        @memset(dir, c.empty);
        for (g.blocks, 0..) |d, i| {
            if (d == c.empty) continue;
            const b = g.blockCoords(i);
            const tile = ((b[2] / 8) * nt[1] + b[1] / 8) * nt[0] + b[0] / 8;
            if (dir[tile] == c.empty) {
                dir[tile] = @intCast(s.tiles.items.len);
                s.tiles.appendAssumeCapacity(@splat(c.empty));
            }
            const local = (b[2] % 8 * 8 + b[1] % 8) * 8 + b[0] % 8;
            var descriptor = d;
            if (d < c.full) {
                descriptor = @intCast(s.pool.items.len);
                s.pool.appendAssumeCapacity(g.pool.items[d]);
            }
            s.tiles.items[dir[tile]][local] = descriptor;
        }
        return s;
    }
    pub fn occupied(s: Snapshot, p: [3]usize) bool {
        for (p, s.n) |v, n| if (v >= n) return false;
        const b = [3]usize{ p[0] / 8, p[1] / 8, p[2] / 8 };
        const tile = ((b[2] / 8) * s.nt[1] + b[1] / 8) * s.nt[0] + b[0] / 8;
        const id = s.directory[tile];
        if (id == c.empty) return false;
        const d = s.tiles.items[id][(b[2] % 8 * 8 + b[1] % 8) * 8 + b[0] % 8];
        return switch (d) {
            c.empty => false,
            c.full => true,
            else => s.pool.items[d][p[2] % 8] & (@as(u64, 1) << @as(u6, @intCast(p[1] % 8 * 8 + p[0] % 8))) != 0,
        };
    }
    pub fn bytes(s: Snapshot) usize {
        return s.directory.len * 4 + s.tiles.capacity * 2048 + s.pool.capacity * 64;
    }
};
pub fn benchmark(a: std.mem.Allocator, out: []const u8) !void {
    try std.fs.cwd().makePath(out);
    var dir = try std.fs.cwd().openDir(out, .{});
    defer dir.close();
    const Record = struct { case: []const u8, dense_bytes: usize, tiled_bytes: usize, convert_ns: u64, dense_query_ns: u64, tiled_query_ns: u64, hits: u64, peak_rss_bytes: usize };
    var records: [10]Record = undefined;
    for (0..2) |scene| for (0..5) |rep| {
        var g = if (scene == 0) try @import("fine.zig").cylinder(a, 4096) else try c.Grid.init(a, .{ 60, 60, 60 }, 60.0 / 4096.0);
        defer g.deinit();
        var timer = try std.time.Timer.start();
        var s = try Snapshot.init(a, g);
        defer s.deinit();
        const convert = timer.lap();
        var dense: u64 = 0;
        var tiled: u64 = 0;
        var rng = std.Random.DefaultPrng.init(42);
        var random = rng.random();
        for (0..1000000) |_| {
            const p = [3]usize{ random.intRangeLessThan(usize, 0, 4096), random.intRangeLessThan(usize, 0, 4096), random.intRangeLessThan(usize, 0, 4096) };
            dense += @intFromBool(g.occupied(p));
        }
        const dt = timer.lap();
        rng = std.Random.DefaultPrng.init(42);
        random = rng.random();
        for (0..1000000) |_| {
            const p = [3]usize{ random.intRangeLessThan(usize, 0, 4096), random.intRangeLessThan(usize, 0, 4096), random.intRangeLessThan(usize, 0, 4096) };
            tiled += @intFromBool(s.occupied(p));
        }
        const tt = timer.lap();
        if (dense != tiled) return error.TiledMismatch;
        const stats = g.stats();
        records[scene * 5 + rep] = .{ .case = if (scene == 0) "sparse-cylinder-4096" else "full-cube-4096", .dense_bytes = stats.descriptor_bytes + stats.pool_bytes, .tiled_bytes = s.bytes(), .convert_ns = convert, .dense_query_ns = dt, .tiled_query_ns = tt, .hits = tiled, .peak_rss_bytes = try @import("platform.zig").peakResidentBytes() };
    };
    try @import("job.zig").json(a, dir, "tiles.json", .{ .warmups_per_scene = 1, .measured_repetitions = 4, .samples_including_warmup = records });
}
