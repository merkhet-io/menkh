//! Experimental persistent octree for issue #11. Uniform full/empty regions stay
//! implicit; mixed leaves retain the existing 8^3 bit semantics. Not job storage.
//! Subtraction preflights exact appended node/leaf capacity, then publishes one
//! root. Retained roots remain valid (no reuse); release by destroying the arena.
const std = @import("std");
const e = @import("engine.zig");
const c = @import("core.zig");
const Node = [8]u32;
pub const Tree = struct {
    allocator: std.mem.Allocator,
    origin: e.V,
    h: f64,
    n: u32,
    root: u32 = c.full,
    nodes: std.ArrayList(Node) = .empty,
    leaves: std.ArrayList(c.Bits) = .empty,
    pub fn init(a: std.mem.Allocator, origin: e.V, h: f64, n: u32) !Tree {
        try e.validV(origin);
        if (!std.math.isFinite(h) or h <= 0 or n < 8 or n > 65536 or !std.math.isPowerOfTwo(n) or h * @as(f64, @floatFromInt(n)) > 1e6) return error.InvalidSparseGrid;
        return .{ .allocator = a, .origin = origin, .h = h, .n = n };
    }
    pub fn deinit(t: *Tree) void {
        t.nodes.deinit(t.allocator);
        t.leaves.deinit(t.allocator);
    }
    pub fn bytes(t: Tree) usize {
        return t.nodes.capacity * @sizeOf(Node) + t.leaves.capacity * @sizeOf(c.Bits);
    }
    pub fn occupied(t: Tree, root: u32, p: [3]u32) bool {
        for (p) |v| if (v >= t.n) return false;
        var d = root;
        var size = t.n;
        while (size > 8 and d < c.full) {
            size /= 2;
            const index = ((p[0] / size) & 1) | (((p[1] / size) & 1) << 1) | (((p[2] / size) & 1) << 2);
            d = t.nodes.items[d][index];
        }
        if (d >= c.full) return d == c.full;
        return t.leaves.items[d][p[2] % 8] & (@as(u64, 1) << @as(u6, @intCast((p[1] % 8) * 8 + p[0] % 8))) != 0;
    }
    pub fn count(t: Tree, root: u32) u64 {
        return t.countAt(root, t.n);
    }
    fn countAt(t: Tree, d: u32, size: u32) u64 {
        if (d == c.empty) return 0;
        if (d == c.full) return @as(u64, size) * size * size;
        var total: u64 = 0;
        if (size == 8) {
            for (t.leaves.items[d]) |word| total += @popCount(word);
        } else for (t.nodes.items[d]) |child| {
            total += t.countAt(child, size / 2);
        }
        return total;
    }
    const Need = struct { nodes: usize = 0, leaves: usize = 0 };
    const Result = struct { descriptor: u32, changed: bool };
    pub fn subtract(t: *Tree, shape: e.Shape) !void {
        try shape.validate();
        var need: Need = .{};
        _ = t.visit(shape, t.root, .{ 0, 0, 0 }, t.n, false, &need);
        const nn = try std.math.add(usize, t.nodes.items.len, need.nodes);
        const nl = try std.math.add(usize, t.leaves.items.len, need.leaves);
        if (nn >= c.full or nl >= c.full) return error.SparseCapacityExceeded;
        try t.nodes.ensureTotalCapacity(t.allocator, nn);
        try t.leaves.ensureTotalCapacity(t.allocator, nl);
        // No remaining fallible operations; root/occupancy unchanged on reserve failure.
        t.root = t.visit(shape, t.root, .{ 0, 0, 0 }, t.n, true, &need).descriptor;
    }
    fn visit(t: *Tree, shape: e.Shape, d: u32, p: [3]u32, size: u32, write: bool, need: *Need) Result {
        if (d == c.empty) return .{ .descriptor = d, .changed = false };
        var bounds: e.Bounds = undefined;
        for (0..3) |k| {
            bounds.lo[k] = t.origin[k] + (@as(f64, @floatFromInt(p[k])) + 0.5) * t.h;
            bounds.hi[k] = t.origin[k] + (@as(f64, @floatFromInt(p[k] + size)) - 0.5) * t.h;
        }
        const sb = shape.bounds();
        for (0..3) |k| if (bounds.lo[k] > sb.hi[k] + c.tolerance or bounds.hi[k] < sb.lo[k] - c.tolerance) return .{ .descriptor = d, .changed = false };
        switch (shape.classify(bounds)) {
            .outside => return .{ .descriptor = d, .changed = false },
            .inside => return .{ .descriptor = c.empty, .changed = true },
            .partial => {},
        }
        if (size == 8) {
            const before: c.Bits = if (d == c.full) @splat(std.math.maxInt(u64)) else t.leaves.items[d];
            var after = before;
            for (0..8) |z| for (0..8) |y| for (0..8) |x| {
                const mask = @as(u64, 1) << @as(u6, @intCast(y * 8 + x));
                if (after[z] & mask == 0) continue;
                const point: e.V = .{ t.origin[0] + (@as(f64, @floatFromInt(p[0] + x)) + 0.5) * t.h, t.origin[1] + (@as(f64, @floatFromInt(p[1] + y)) + 0.5) * t.h, t.origin[2] + (@as(f64, @floatFromInt(p[2] + z)) + 0.5) * t.h };
                if (shape.contains(point)) after[z] &= ~mask;
            };
            if (std.mem.eql(u64, &before, &after)) return .{ .descriptor = d, .changed = false };
            if (std.mem.allEqual(u64, &after, 0)) return .{ .descriptor = c.empty, .changed = true };
            if (!write) {
                need.leaves += 1;
                return .{ .descriptor = 0, .changed = true };
            }
            const id: u32 = @intCast(t.leaves.items.len);
            t.leaves.appendAssumeCapacity(after);
            return .{ .descriptor = id, .changed = true };
        }
        // Copy before recursive appends (which may invalidate item pointers).
        var children: Node = if (d == c.full) @splat(c.full) else t.nodes.items[d];
        var changed = false;
        for (&children, 0..) |*child, i| {
            const offset: [3]u32 = .{ @intCast(i & 1), @intCast((i >> 1) & 1), @intCast((i >> 2) & 1) };
            var q = p;
            for (0..3) |k| q[k] += offset[k] * (size / 2);
            const result = t.visit(shape, child.*, q, size / 2, write, need);
            child.* = result.descriptor;
            changed = changed or result.changed;
        }
        if (!changed) return .{ .descriptor = d, .changed = false };
        if (std.mem.allEqual(u32, &children, c.empty)) return .{ .descriptor = c.empty, .changed = true };
        if (!write) {
            need.nodes += 1;
            return .{ .descriptor = 0, .changed = true };
        }
        const id: u32 = @intCast(t.nodes.items.len);
        t.nodes.appendAssumeCapacity(children);
        return .{ .descriptor = id, .changed = true };
    }
};

test "mutable sparse uniform cube, dense differential and retained roots" {
    const a = std.testing.allocator;
    var t = try Tree.init(a, .{ -1, -1, -1 }, 0.1, 32);
    defer t.deinit();
    const box = e.Bounds{ .lo = .{ -1, -1, -1 }, .hi = .{ 2.2, 2.2, 2.2 } };
    var dense = try e.stock(a, box, 0.1, &.{.{ .box = box }});
    defer dense.deinit();
    var changes: e.Changes = .{};
    defer changes.deinit(a);
    const original = t.root;
    var rng = std.Random.DefaultPrng.init(11);
    for (0..12) |_| {
        const shape = e.Shape{ .primitive = .{ .sphere = .{ .center = .{ rng.random().float(f64) * 3 - 1, rng.random().float(f64) * 3 - 1, rng.random().float(f64) * 3 - 1 }, .radius = 0.65 } } };
        const previous = t.root;
        const count = t.count(previous);
        try t.subtract(shape);
        try e.subtract(&dense, shape, &changes, true);
        try std.testing.expectEqual(count, t.count(previous));
        try std.testing.expectEqual(dense.stats().occupied, t.count(t.root));
        for (0..32) |z| for (0..32) |y| for (0..32) |x| {
            try std.testing.expectEqual(dense.occupied(.{ x, y, z }), t.occupied(t.root, .{ @intCast(x), @intCast(y), @intCast(z) }));
            try std.testing.expect(t.occupied(original, .{ @intCast(x), @intCast(y), @intCast(z) }));
        };
        const bytes = t.bytes();
        const root = t.root;
        try t.subtract(shape);
        try std.testing.expectEqual(root, t.root);
        try std.testing.expectEqual(bytes, t.bytes());
    }
}

test "65536 sparse world cuts and allocation failure atomicity" {
    var t = try Tree.init(std.testing.allocator, .{ 0, 0, 0 }, 0.01, 65536);
    defer t.deinit();
    try std.testing.expectEqual(@as(u64, 1) << 48, t.count(t.root));
    try std.testing.expectEqual(@as(usize, 0), t.bytes());
    const shape = e.Shape{ .primitive = .{ .sphere = .{ .center = .{ 0.16, 0.16, 0.16 }, .radius = 0.1 } } };
    const initial = t.root;
    t.allocator = std.testing.failing_allocator;
    try std.testing.expectError(error.OutOfMemory, t.subtract(shape));
    try std.testing.expectEqual(initial, t.root);
    t.allocator = std.testing.allocator;
    try t.subtract(shape);
    try std.testing.expect(!t.occupied(t.root, .{ 16, 16, 16 }));
    try std.testing.expect(t.occupied(initial, .{ 16, 16, 16 }));
    try std.testing.expect(t.occupied(t.root, .{ 65535, 65535, 65535 }));
    try std.testing.expect(t.bytes() < 100000);
}

pub fn benchmark(a: std.mem.Allocator, out: []const u8) !void {
    try std.fs.cwd().makePath(out);
    var dir = try std.fs.cwd().openDir(out, .{});
    defer dir.close();
    const Record = struct { n: u32, repetition: usize, warmup: bool, init_ns: u64, cut_ns: u64, count_ns: u64, retained_capacity_bytes: usize, root_history_bytes: usize, remaining: u64, dense_init_ns: ?u64, dense_cut_ns: ?u64, dense_bytes: ?usize, peak_rss_bytes: usize };
    var records: [10]Record = undefined;
    for ([_]u32{ 4096, 65536 }, 0..) |n, scene| for (0..5) |rep| {
        var timer = try std.time.Timer.start();
        var tree = try Tree.init(a, .{ 0, 0, 0 }, 0.01, n);
        defer tree.deinit();
        const init_ns = timer.lap();
        var roots: [25]u32 = undefined;
        roots[0] = tree.root;
        var shapes: [24]e.Shape = undefined;
        for (&shapes, 0..) |*shape, i| {
            const base = if (i % 2 == 0) @as(f64, 0.3) else @as(f64, @floatFromInt(n)) * 0.01 - 0.6;
            shape.* = .{ .primitive = .{ .sphere = .{ .center = .{ base + @as(f64, @floatFromInt(i / 2)) * 0.015, base, base }, .radius = 0.12 } } };
        }
        timer.reset();
        for (shapes, 0..) |shape, i| {
            try tree.subtract(shape);
            roots[i + 1] = tree.root;
        }
        const cut_ns = timer.lap();
        const remaining = tree.count(tree.root);
        // Backward/forward root selection restores the immutable material exactly.
        for (roots, 0..) |root, i| {
            if (tree.count(root) < remaining or (i > 0 and tree.count(root) > tree.count(roots[i - 1]))) return error.SparseHistoryMismatch;
        }
        if (tree.count(roots[0]) != @as(u64, n) * n * n or tree.count(roots[24]) != remaining) return error.SparseHistoryMismatch;
        const count_ns = timer.lap();
        var dense_init: ?u64 = null;
        var dense_cut: ?u64 = null;
        var dense_bytes: ?usize = null;
        if (n == 4096) {
            timer.reset();
            var dense = try c.Grid.init(a, @splat(@as(f64, @floatFromInt(n)) * 0.01), 0.01);
            defer dense.deinit();
            dense_init = timer.lap();
            var changes: e.Changes = .{};
            defer changes.deinit(a);
            for (shapes) |shape| try e.subtract(&dense, shape, &changes, false);
            dense_cut = timer.lap();
            const stats = dense.stats();
            if (stats.occupied != remaining) return error.SparseDenseMismatch;
            dense_bytes = stats.descriptor_bytes + stats.pool_bytes;
        }
        records[scene * 5 + rep] = .{ .n = n, .repetition = rep, .warmup = rep == 0, .init_ns = init_ns, .cut_ns = cut_ns, .count_ns = count_ns, .retained_capacity_bytes = tree.bytes(), .root_history_bytes = @sizeOf(@TypeOf(roots)), .remaining = remaining, .dense_init_ns = dense_init, .dense_cut_ns = dense_cut, .dense_bytes = dense_bytes, .peak_rss_bytes = try @import("platform.zig").peakResidentBytes() };
    };
    try @import("job.zig").json(a, dir, "sparse.json", .{ .experimental = true, .voxel_mm = 0.01, .operations = 24, .warmups = 1, .measured_repetitions = 4, .records = records, .note = "Uniform full cube with small internal cavities at both ends; not the 2^32-face qualification. Retained roots include all allocated nodes/leaves; process RSS is cumulative high-water including dense comparison." });
}

fn allocationScenario(a: std.mem.Allocator) !void {
    var t = try Tree.init(a, .{ 0, 0, 0 }, 0.1, 32);
    defer t.deinit();
    const first = e.Shape{ .primitive = .{ .sphere = .{ .center = .{ 0.8, 0.8, 0.8 }, .radius = 0.3 } } };
    const old = t.root;
    t.subtract(first) catch |err| {
        try std.testing.expectEqual(old, t.root);
        try std.testing.expectEqual(@as(u64, 32768), t.count(old));
        return err;
    };
    const cut = t.root;
    const count = t.count(cut);
    const second = e.Shape{ .primitive = .{ .sphere = .{ .center = .{ 2, 2, 2 }, .radius = 0.6 } } };
    t.subtract(second) catch |err| {
        try std.testing.expectEqual(cut, t.root);
        try std.testing.expectEqual(count, t.count(cut));
        return err;
    };
    try std.testing.expectEqual(count, t.count(cut));
}
test "sparse every allocation failure preserves published material and old history" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}
