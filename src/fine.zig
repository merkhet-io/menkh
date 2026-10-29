//! Dense compact block descriptors + sparse bits + reversible changes; no surface mesh.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core.zig");
const drill = @import("drill.zig");
const Op = drill.Operation;
const origin = [3]f64{ 24, 24, 0 };
const Coverage = enum { keep, remove, partial };
const Box = struct { lo: [3]usize, hi: [3]usize };
fn bounds(g: core.Grid, op: Op) Box {
    var low = [3]f64{ 24, 24, 0 };
    var high = [3]f64{ 36, 36, 60 };
    if (op == .capsule) {
        const c = op.capsule;
        for (0..3) |j| {
            low[j] = @max(low[j], origin[j] + @min(c.a[j], c.b[j]) - c.radius - core.tolerance);
            high[j] = @min(high[j], origin[j] + @max(c.a[j], c.b[j]) + c.radius + core.tolerance);
        }
    }
    if (op == .tip) low[2] = 54;
    var b: Box = undefined;
    for (0..3) |j| {
        b.lo[j] = @min(g.nb[j], @as(usize, @intFromFloat(@max(0, @floor(low[j] / g.h) - 1))) / 8);
        b.hi[j] = @min(g.nb[j], (@as(usize, @intFromFloat(@max(0, @ceil(high[j] / g.h) + 1))) + 7) / 8);
        b.hi[j] = @max(b.hi[j], b.lo[j]);
    }
    return b;
}
fn classify(g: core.Grid, b: [3]usize, op: Op) Coverage {
    const e = g.extent(b);
    var lo: [3]f64 = undefined;
    var hi: [3]f64 = undefined;
    for (0..3) |j| {
        lo[j] = g.center(b[j] * 8) - origin[j];
        hi[j] = g.center(b[j] * 8 + e[j] - 1) - origin[j];
    }
    const margin = 1e-8;
    switch (op) {
        .cylinder => {
            var min2: f64 = 0;
            var max2: f64 = 0;
            for (0..2) |j| {
                const mn = if (lo[j] > 6) lo[j] - 6 else if (hi[j] < 6) 6 - hi[j] else 0;
                const mx = @max(@abs(lo[j] - 6), @abs(hi[j] - 6));
                min2 += mn * mn;
                max2 += mx * mx;
            }
            if (max2 < 36 - margin) return .keep;
            if (min2 > 36 + margin) return .remove;
        },
        .tip => |angle| {
            const n = [3]f64{ @cos(angle), @sin(angle), 1 };
            var mn: f64 = 0;
            var mx: f64 = 0;
            for (0..3) |j| {
                mn += @min(n[j] * lo[j], n[j] * hi[j]);
                mx += @max(n[j] * lo[j], n[j] * hi[j]);
            }
            const d = 60 + 6 * (n[0] + n[1]) + core.tolerance;
            if (mx < d - margin) return .keep;
            if (mn > d + margin) return .remove;
        },
        .capsule => |c| {
            // Convexity: corner inclusion with clearance proves complete inclusion.
            var inner = c;
            inner.radius = @max(0, c.radius - margin);
            const inside = Op{ .capsule = inner };
            var all = true;
            for (0..8) |i| {
                const p = [3]f64{ if (i & 1 == 0) lo[0] else hi[0], if (i & 2 == 0) lo[1] else hi[1], if (i & 4 == 0) lo[2] else hi[2] };
                if (!inside.removes(p)) {
                    all = false;
                    break;
                }
            }
            if (all) return .remove;
            var center: [3]f64 = undefined;
            var rad2: f64 = 0;
            for (0..3) |j| {
                center[j] = (lo[j] + hi[j]) * 0.5;
                const d = (hi[j] - lo[j]) * 0.5;
                rad2 += d * d;
            }
            var outer = c;
            outer.radius += @sqrt(rad2) + margin;
            if (!(Op{ .capsule = outer }).removes(center)) return .keep;
        },
    }
    return .partial;
}
fn result(g: core.Grid, b: [3]usize, before: core.Bits, op: Op) core.Bits {
    var after = before;
    const e = g.extent(b);
    for (0..e[2]) |z| for (0..e[1]) |y| for (0..e[0]) |x| {
        const bit = @as(u64, 1) << @as(u6, @intCast(y * 8 + x));
        if (after[z] & bit != 0 and op.removes(.{ g.center(b[0] * 8 + x) - 24, g.center(b[1] * 8 + y) - 24, g.center(b[2] * 8 + z) })) after[z] &= ~bit;
    };
    return after;
}
fn count(bits: core.Bits) u64 {
    var n: u64 = 0;
    for (bits) |w| n += @popCount(w);
    return n;
}
pub fn cylinder(a: std.mem.Allocator, n: usize) !core.Grid {
    if (n < 32 or n > 4096 or n % 8 != 0) return error.GridMustBeMultipleOfEightBetween32And4096;
    var g = try core.Grid.init(a, .{ 60, 60, 60 }, 60 / @as(f64, @floatFromInt(n)));
    errdefer g.deinit();
    @memset(g.blocks, core.empty);
    const r = bounds(g, .cylinder);
    var partial: usize = 0;
    for (r.lo[1]..r.hi[1]) |y| for (r.lo[0]..r.hi[0]) |x| {
        if (classify(g, .{ x, y, 0 }, .cylinder) == .partial) partial += 1;
    };
    try g.pool.ensureTotalCapacityPrecise(a, try std.math.mul(usize, partial, g.nb[2]));
    for (r.lo[2]..r.hi[2]) |z| for (r.lo[1]..r.hi[1]) |y| for (r.lo[0]..r.hi[0]) |x| {
        const b = [3]usize{ x, y, z };
        const i = g.blockIndex(b);
        switch (classify(g, b, .cylinder)) {
            .remove => {},
            .keep => g.blocks[i] = core.full,
            .partial => {
                const bits = result(g, b, g.validBits(b), .cylinder);
                const occupied = count(bits);
                if (occupied == 0) continue;
                if (occupied == 512) {
                    g.blocks[i] = core.full;
                } else {
                    g.blocks[i] = @intCast(g.pool.items.len);
                    g.pool.appendAssumeCapacity(bits);
                }
            },
        }
    };
    return g;
}
pub const Changes = struct {
    bytes: std.ArrayList(u8) = .empty,
    removed: u64 = 0,
    blocks: usize = 0,
    pub fn deinit(c: *Changes, a: std.mem.Allocator) void {
        c.bytes.deinit(a);
    }
};
pub fn cut(g: *core.Grid, op: Op, changes: *Changes) !void {
    if (op == .cylinder) return error.InitializationOnly;
    if (op == .capsule) {
        const c = op.capsule;
        if (!std.math.isFinite(c.radius) or c.radius <= 0 or c.radius > 1e6) return error.InvalidTool;
        for (c.a ++ c.b) |v| if (!std.math.isFinite(v) or @abs(v) > 1e6) return error.InvalidCoordinate;
    }
    if (op == .tip and !std.math.isFinite(op.tip)) return error.InvalidCoordinate;
    const r = bounds(g.*, op);
    var needed: usize = 0;
    var candidates: usize = 0;
    for (r.lo[2]..r.hi[2]) |z| for (r.lo[1]..r.hi[1]) |y| for (r.lo[0]..r.hi[0]) |x| {
        const b = [3]usize{ x, y, z };
        const d = g.blocks[g.blockIndex(b)];
        if (d == core.empty) continue;
        const coverage = classify(g.*, b, op);
        if (coverage == .keep) continue;
        candidates += 1;
        if (d == core.full and coverage == .partial) needed += 1;
    };
    try changes.bytes.ensureTotalCapacityPrecise(g.allocator, try std.math.mul(usize, candidates, 140));
    const capacity = try std.math.add(usize, g.pool.items.len, needed);
    if (capacity >= core.full) return error.PoolTooLarge;
    try g.pool.ensureTotalCapacityPrecise(g.allocator, capacity);
    changes.bytes.clearRetainingCapacity();
    changes.removed = 0;
    changes.blocks = 0;
    for (r.lo[2]..r.hi[2]) |z| for (r.lo[1]..r.hi[1]) |y| for (r.lo[0]..r.hi[0]) |x| {
        const b = [3]usize{ x, y, z };
        const i = g.blockIndex(b);
        const d = g.blocks[i];
        if (d == core.empty) continue;
        const coverage = classify(g.*, b, op);
        if (coverage == .keep) continue;
        const before = g.bits(i);
        const after: core.Bits = if (coverage == .remove) @splat(0) else result(g.*, b, before, op);
        if (std.mem.eql(u64, &before, &after)) continue;
        const remaining = count(after);
        changes.removed += count(before) - remaining;
        changes.blocks += 1;
        if (remaining == 0) {
            g.blocks[i] = core.empty;
        } else if (d == core.full) {
            g.blocks[i] = @intCast(g.pool.items.len);
            g.pool.appendAssumeCapacity(after);
        } else {
            g.pool.items[d] = after;
        }
        var header: [12]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], @intCast(i), .little);
        std.mem.writeInt(u32, header[4..8], d, .little);
        std.mem.writeInt(u32, header[8..12], g.blocks[i], .little);
        changes.bytes.appendSliceAssumeCapacity(&header);
        if (d < core.full) changes.bytes.appendSliceAssumeCapacity(std.mem.asBytes(&before));
        if (g.blocks[i] < core.full) changes.bytes.appendSliceAssumeCapacity(std.mem.asBytes(&after));
    };
}
const Frame = struct { file: []const u8, stage: []const u8, occupied: u64, changed_blocks: usize, delta_bytes: usize, cut_ns: u64, write_ns: u64, tool: [3]f64 };
pub fn run(a: std.mem.Allocator, n: usize, out: []const u8) !void {
    var total = try std.time.Timer.start();
    var phase = try std.time.Timer.start();
    var g = try cylinder(a, n);
    defer g.deinit();
    const init_ns = phase.lap();
    var occupied = g.stats().occupied;
    const initial = occupied;
    const initial_stats_ns = phase.lap();
    try std.fs.cwd().makePath(out);
    var dir = try std.fs.cwd().openDir(out, .{});
    defer dir.close();
    try dir.writeFile(.{ .sub_path = "initial.blocks", .data = std.mem.sliceAsBytes(g.blocks) });
    try dir.writeFile(.{ .sub_path = "initial.pool", .data = std.mem.sliceAsBytes(g.pool.items) });
    const initial_slots = g.pool.items.len;
    const initial_write_ns = phase.lap();
    var history: std.ArrayList(Frame) = .empty;
    defer {
        for (history.items) |f| a.free(f.file);
        history.deinit(a);
    }
    try history.ensureTotalCapacityPrecise(a, 2 * drill.steps + drill.facets);
    var changes: Changes = .{};
    defer changes.deinit(a);
    std.debug.print("{d}³ ready: {d} occupied, {d} descriptor bytes; generating reversible history…\n", .{ n, occupied, g.blocks.len * 4 });
    for (0..2 * drill.steps + drill.facets) |step| {
        var op: Op = undefined;
        var tool: [3]f64 = undefined;
        var stage: []const u8 = undefined;
        if (step < 2 * drill.steps) {
            const f = step / drill.steps;
            const i = step % drill.steps;
            const from = drill.point(f, @as(f64, @floatFromInt(i)) / drill.steps);
            tool = drill.point(f, @as(f64, @floatFromInt(i + 1)) / drill.steps);
            op = .{ .capsule = .{ .a = from, .b = tool, .radius = drill.cutter_radius } };
            stage = if (f == 0) "Spannut 1" else "Spannut 2";
        } else {
            const angle = @as(f64, @floatFromInt(step - 2 * drill.steps)) / drill.facets * 2 * std.math.pi;
            op = .{ .tip = angle };
            tool = .{ 6 + 7 * @cos(angle), 6 + 7 * @sin(angle), 57 };
            stage = "Spitze";
        }
        phase.reset();
        try cut(&g, op, &changes);
        const cut_ns = phase.lap();
        occupied -= changes.removed;
        const name = try std.fmt.allocPrint(a, "step-{d:0>4}.delta", .{step});
        errdefer a.free(name);
        try dir.writeFile(.{ .sub_path = name, .data = changes.bytes.items });
        const write_ns = phase.lap();
        for (&tool, origin) |*v, o| v.* += o;
        history.appendAssumeCapacity(.{ .file = name, .stage = stage, .occupied = occupied, .changed_blocks = changes.blocks, .delta_bytes = changes.bytes.items.len, .cut_ns = cut_ns, .write_ns = write_ns, .tool = tool });
        if (step % 16 == 0 or step + 1 == 2 * drill.steps + drill.facets) std.debug.print("  {d}/224: {d:.1} ms cut, {d} changed blocks\n", .{ step + 1, @as(f64, @floatFromInt(cut_ns)) / 1e6, changes.blocks });
    }
    const stats = g.stats();
    if (stats.occupied != occupied) return error.HistoryCountMismatch;
    const report = try std.json.Stringify.valueAlloc(a, .{ .format = "menkh-voxel-history-v1", .zig = builtin.zig_version_string, .mode = @tagName(builtin.mode), .target_cpu = builtin.cpu.model.name, .grid = g.n, .block_grid = g.nb, .voxel_mm = g.h, .world_mm = 60, .stock_min = [3]f64{ 24, 24, 0 }, .stock_max = [3]f64{ 36, 36, 60 }, .initial_occupied = initial, .final_occupied = occupied, .initial_pool_slots = initial_slots, .pool_slots = g.pool.items.len, .descriptor_bytes = g.blocks.len * 4, .pool_capacity_bytes = g.pool.capacity * 64, .init_ns = init_ns, .initial_stats_ns = initial_stats_ns, .initial_write_ns = initial_write_ns, .total_ns = total.read(), .process_peak_rss_bytes = std.posix.getrusage(std.posix.rusage.SELF).maxrss, .workers = 1, .frames = history.items }, .{ .whitespace = .indent_2 });
    defer a.free(report);
    try dir.writeFile(.{ .sub_path = "voxel-animation.json", .data = report });
    std.debug.print("Complete: {d}³, {d:.3} µm, {d:.2} s; {s}/voxel-animation.json\n", .{ n, g.h * 1000, @as(f64, @floatFromInt(total.read())) / 1e9, out });
}
