//! Experimental quantized Z dexels. One column per initially occupied XY sample;
//! sorted, disjoint half-open integer intervals. No per-volume-cell descriptors.
//! This benchmark backend has no history/viewer/state-file integration yet.
const std = @import("std");
const e = @import("engine.zig");
const c = @import("core.zig");
const Interval = struct { lo: u32, hi: u32 };
const Column = struct { key: u64, offset: u32, len: u32 };
pub const Work = struct { interval_tests: u64 = 0, center_tests: u64 = 0, removed_whole_intervals: u64 = 0 };
pub const Dexels = struct {
    allocator: std.mem.Allocator,
    origin: e.V,
    h: f64,
    n: [3]u32,
    columns: []Column,
    scratch_columns: []Column,
    pool: std.ArrayList(Interval) = .empty,
    scratch: std.ArrayList(Interval) = .empty,

    pub fn initCylinder(a: std.mem.Allocator, bounds: e.Bounds, h: f64, base: e.V, radius: f64, length: f64) !Dexels {
        try e.validV(bounds.lo);
        try e.validV(bounds.hi);
        try e.validV(base);
        if (!std.math.isFinite(h) or h <= 0 or !std.math.isFinite(radius) or radius <= 0 or radius > 1e6 or !std.math.isFinite(length) or length <= 0 or length > 1e6) return error.InvalidDexelDimensions;
        var n: [3]u32 = undefined;
        for (0..3) |k| {
            const size = bounds.hi[k] - bounds.lo[k];
            const count = @ceil(size / h - 0.5);
            if (!std.math.isFinite(count) or count < 1 or count > 0x7fffffff) return error.InvalidDexelDimensions;
            n[k] = @intFromFloat(count);
            while (n[k] > 0 and (@as(f64, @floatFromInt(n[k] - 1)) + 0.5) * h >= size) n[k] -= 1;
            while ((@as(f64, @floatFromInt(n[k])) + 0.5) * h < size) n[k] += 1;
            if (n[k] == 0 or n[k] > 0x7fffffff) return error.InvalidDexelDimensions;
        }
        _ = try std.math.mul(u64, try std.math.mul(u64, n[0], n[1]), n[2]);
        const low = [3]u32{ indexLow(base[0] - radius - c.tolerance, bounds.lo[0], h, n[0]), indexLow(base[1] - radius - c.tolerance, bounds.lo[1], h, n[1]), indexLow(base[2] - c.tolerance, bounds.lo[2], h, n[2]) };
        const high = [3]u32{ indexHigh(base[0] + radius + c.tolerance, bounds.lo[0], h, n[0]), indexHigh(base[1] + radius + c.tolerance, bounds.lo[1], h, n[1]), indexHigh(base[2] + length + c.tolerance, bounds.lo[2], h, n[2]) };
        var count: usize = 0;
        if (low[2] < high[2]) for (low[1]..high[1]) |y| for (low[0]..high[0]) |x| {
            if (initialRun(bounds.lo, h, x, y, base, radius, length, n[2]) != null) count = try std.math.add(usize, count, 1);
        };
        if (count > std.math.maxInt(u32)) return error.DexelCapacityExceeded;
        const columns = try a.alloc(Column, count);
        errdefer a.free(columns);
        const scratch_columns = try a.alloc(Column, count);
        errdefer a.free(scratch_columns);
        var pool: std.ArrayList(Interval) = .empty;
        errdefer pool.deinit(a);
        try pool.ensureTotalCapacity(a, count);
        var i: usize = 0;
        if (low[2] < high[2]) for (low[1]..high[1]) |y| for (low[0]..high[0]) |x| {
            const run = initialRun(bounds.lo, h, x, y, base, radius, length, n[2]) orelse continue;
            columns[i] = .{ .key = @as(u64, y) * n[0] + x, .offset = @intCast(i), .len = 1 };
            pool.appendAssumeCapacity(run);
            i += 1;
        };
        return .{ .allocator = a, .origin = bounds.lo, .h = h, .n = n, .columns = columns, .scratch_columns = scratch_columns, .pool = pool };
    }
    pub fn deinit(d: *Dexels) void {
        d.allocator.free(d.columns);
        d.allocator.free(d.scratch_columns);
        d.pool.deinit(d.allocator);
        d.scratch.deinit(d.allocator);
    }
    fn center(d: Dexels, i: u32, axis: usize) f64 {
        return d.origin[axis] + (@as(f64, @floatFromInt(i)) + 0.5) * d.h;
    }
    fn spans(d: Dexels, col: Column) []const Interval {
        return d.pool.items[col.offset .. @as(usize, col.offset) + col.len];
    }
    pub fn occupiedCount(d: Dexels) u64 {
        var count: u64 = 0;
        for (d.pool.items) |run| count += run.hi - run.lo;
        return count;
    }
    pub fn bytes(d: Dexels) usize {
        return (d.columns.len + d.scratch_columns.len) * @sizeOf(Column) + (d.pool.capacity + d.scratch.capacity) * @sizeOf(Interval);
    }
    // Dry-run the exact output count, reserve scratch, write, then atomically
    // publish the new column/pool pair. Failure leaves authoritative data intact.
    // The two buffers are recycled: no retained obsolete intervals or snapshots.
    pub fn subtract(d: *Dexels, shape: e.Shape) !Work {
        try shape.validate();
        const box = shape.cuttingBounds();
        var dry = Sink{};
        var work = Work{};
        for (d.columns) |col| {
            dry.beginColumn();
            for (d.spans(col)) |run| d.visit(col, run, shape, box, &dry, &work);
        }
        if (dry.count > std.math.maxInt(u32)) return error.DexelCapacityExceeded;
        try d.scratch.ensureTotalCapacity(d.allocator, dry.count);
        d.scratch.clearRetainingCapacity();
        var sink = Sink{ .output = &d.scratch };
        for (d.columns, 0..) |col, i| {
            sink.beginColumn();
            const start = sink.count;
            for (d.spans(col)) |run| d.visit(col, run, shape, box, &sink, &work);
            d.scratch_columns[i] = .{ .key = col.key, .offset = @intCast(start), .len = @intCast(sink.count - start) };
        }
        std.debug.assert(sink.count == dry.count);
        std.mem.swap([]Column, &d.columns, &d.scratch_columns);
        std.mem.swap(std.ArrayList(Interval), &d.pool, &d.scratch);
        return work;
    }
    fn visit(d: Dexels, col: Column, run: Interval, shape: e.Shape, bounds: e.Bounds, sink: *Sink, work: *Work) void {
        const x = d.center(@intCast(col.key % d.n[0]), 0);
        const y = d.center(@intCast(col.key / d.n[0]), 1);
        const box = e.Bounds{ .lo = .{ x, y, d.center(run.lo, 2) }, .hi = .{ x, y, d.center(run.hi - 1, 2) } };
        for (0..3) |k| if (box.hi[k] < bounds.lo[k] or box.lo[k] > bounds.hi[k]) {
            sink.emit(run);
            return;
        };
        work.interval_tests += 1;
        switch (shape.classify(box)) {
            .outside => sink.emit(run),
            .inside => work.removed_whole_intervals += 1,
            .partial => {
                if (run.hi - run.lo == 1) {
                    work.center_tests += 1;
                    if (!shape.contains(box.lo)) sink.emit(run);
                } else {
                    const mid = run.lo + (run.hi - run.lo) / 2;
                    d.visit(col, .{ .lo = run.lo, .hi = mid }, shape, bounds, sink, work);
                    d.visit(col, .{ .lo = mid, .hi = run.hi }, shape, bounds, sink, work);
                }
            },
        }
    }
    pub fn compareGrid(d: Dexels, g: c.Grid) !void {
        if (d.h != g.h or !std.mem.eql(f64, &d.origin, &g.origin)) return error.DexelMismatch;
        for (d.n, g.n) |x, y| if (x != y) return error.DexelMismatch;
        if (d.occupiedCount() != g.stats().occupied) return error.DexelMismatch;
        for (d.columns) |col| {
            const x: usize = @intCast(col.key % d.n[0]);
            const y: usize = @intCast(col.key / d.n[0]);
            const runs = d.spans(col);
            var next: usize = 0;
            for (0..d.n[2]) |z| {
                while (next < runs.len and z >= runs[next].hi) next += 1;
                const occupied = next < runs.len and z >= runs[next].lo;
                if (g.occupied(.{ x, y, z }) != occupied) return error.DexelMismatch;
            }
        }
    }
};
const Sink = struct {
    count: usize = 0,
    last_hi: ?u32 = null,
    output: ?*std.ArrayList(Interval) = null,
    fn beginColumn(s: *Sink) void {
        s.last_hi = null;
    }
    fn emit(s: *Sink, run: Interval) void {
        if (s.last_hi != null and s.last_hi.? == run.lo) {
            if (s.output) |out| out.items[out.items.len - 1].hi = run.hi;
        } else {
            s.count += 1;
            if (s.output) |out| out.appendAssumeCapacity(run);
        }
        s.last_hi = run.hi;
    }
};
fn indexLow(v: f64, origin: f64, h: f64, n: u32) u32 {
    return @intFromFloat(std.math.clamp(@ceil((v - origin) / h - 0.5), 0, @as(f64, @floatFromInt(n))));
}
fn indexHigh(v: f64, origin: f64, h: f64, n: u32) u32 {
    return @intFromFloat(std.math.clamp(@floor((v - origin) / h - 0.5) + 1, 0, @as(f64, @floatFromInt(n))));
}
fn initialRun(origin: e.V, h: f64, x: usize, y: usize, base: e.V, radius: f64, length: f64, nz: u32) ?Interval {
    const px = origin[0] + (@as(f64, @floatFromInt(x)) + 0.5) * h;
    const py = origin[1] + (@as(f64, @floatFromInt(y)) + 0.5) * h;
    const dx = px - base[0];
    const dy = py - base[1];
    if (@sqrt(dx * dx + dy * dy) > radius + c.tolerance) return null;
    var run = Interval{ .lo = indexLow(base[2] - c.tolerance, origin[2], h, nz), .hi = indexHigh(base[2] + length + c.tolerance, origin[2], h, nz) };
    const cylinder = e.Primitive{ .cylinder = .{ .base = base, .radius = radius, .length = length } };
    while (run.lo < run.hi and cylinder.distance(.{ px, py, origin[2] + (@as(f64, @floatFromInt(run.lo)) + 0.5) * h }) > c.tolerance) run.lo += 1;
    while (run.lo < run.hi and cylinder.distance(.{ px, py, origin[2] + (@as(f64, @floatFromInt(run.hi - 1)) + 0.5) * h }) > c.tolerance) run.hi -= 1;
    return if (run.lo < run.hi) run else null;
}
