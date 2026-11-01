//! One worker team per complete batch job, disjoint transverse ray rows.
const std = @import("std");
const e = @import("engine.zig");
const d = @import("raydexel.zig");
const adaptive = @import("adaptive_raydexel.zig");
const swept = @import("swept_raydexel.zig");
pub const Output = struct { material: d.Result, work: adaptive.Work = .{}, sweep_work: swept.Work = .{} };
const Task = struct {
    continuous: ?*const swept.Plan,
    allocator: std.mem.Allocator,
    profile: d.Profile,
    plan: ?*const adaptive.Plan,
    tree: d.Tree,
    base: e.V,
    radius: f64,
    length: f64,
    spacing: f64,
    rows: [2]u32,
    result: ?Output = null,
    failure: ?anyerror = null,
    fn run(task: *Task) void {
        task.result = task.calculate() catch |err| {
            task.failure = err;
            return;
        };
    }
    fn calculate(task: *Task) !Output {
        if (task.continuous) |plan| {
            const result = try swept.finishRows(task.allocator, task.profile, plan, task.tree, task.base, task.radius, task.length, task.spacing, false, task.rows);
            return .{ .material = result.material, .sweep_work = result.work };
        }
        if (task.plan) |plan| {
            const result = try adaptive.finishRows(task.allocator, task.profile, plan, task.tree, task.base, task.radius, task.length, task.spacing, task.rows);
            return .{ .material = result.material, .work = result.work };
        }
        return .{ .material = try d.finishCylinderRows(task.allocator, task.profile, task.tree, task.base, task.radius, task.length, task.spacing, false, task.rows), .work = .{} };
    }
};
pub fn finish(a: std.mem.Allocator, profile: d.Profile, plan: ?*const adaptive.Plan, tree: d.Tree, base: e.V, radius: f64, length: f64, spacing: f64, workers: usize) !Output {
    return finishImpl(a, profile, plan, null, tree, base, radius, length, spacing, workers);
}
pub fn finishContinuous(a: std.mem.Allocator, profile: d.Profile, plan: *const swept.Plan, tree: d.Tree, base: e.V, radius: f64, length: f64, spacing: f64, workers: usize) !Output {
    return finishImpl(a, profile, null, plan, tree, base, radius, length, spacing, workers);
}
fn finishImpl(a: std.mem.Allocator, profile: d.Profile, plan: ?*const adaptive.Plan, continuous: ?*const swept.Plan, tree: d.Tree, base: e.V, radius: f64, length: f64, spacing: f64, workers: usize) !Output {
    if (workers < 1 or workers > 64) return error.InvalidWorkerCount;
    if (!std.math.isFinite(spacing) or spacing <= 0 or !std.math.isFinite(radius) or radius <= 0) return error.InvalidRayResolution;
    const nf = @ceil(2 * radius / spacing - 0.5);
    if (!std.math.isFinite(nf) or nf < 1 or nf > 65536) return error.InvalidRayResolution;
    const n: u32 = @intFromFloat(nf);
    const count = @min(workers, n);
    // Wrap the supplied allocator rather than assuming it is thread safe.
    var safe = std.heap.ThreadSafeAllocator{ .child_allocator = a };
    var tasks: [64]Task = undefined;
    for (tasks[0..count], 0..) |*task, i| task.* = .{ .continuous = continuous, .allocator = safe.allocator(), .profile = profile, .plan = plan, .tree = tree, .base = base, .radius = radius, .length = length, .spacing = spacing, .rows = .{ @intCast(@as(usize, n) * i / count), @intCast(@as(usize, n) * (i + 1) / count) } };
    defer for (tasks[0..count]) |*task| if (task.result) |*result| {
        result.material.deinit();
    };
    var threads: [63]std.Thread = undefined;
    var started: usize = 0;
    {
        defer for (threads[0..started]) |thread| thread.join();
        for (tasks[0 .. count - 1], 0..) |*task, i| {
            threads[i] = try std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, Task.run, .{task});
            started += 1;
        }
        tasks[count - 1].run();
    }
    var columns: usize = 0;
    var intervals: usize = 0;
    for (tasks[0..count]) |task| {
        if (task.failure) |err| return err;
        columns = try std.math.add(usize, columns, task.result.?.material.columns.items.len);
        intervals = try std.math.add(usize, intervals, task.result.?.material.intervals.items.len);
    }
    var output = Output{ .material = .{ .allocator = a, .origin = .{ base[0] - radius, base[1] - radius, base[2] }, .spacing = spacing, .n = .{ n, n } }, .work = .{} };
    errdefer output.material.deinit();
    try output.material.columns.ensureTotalCapacityPrecise(a, columns);
    try output.material.intervals.ensureTotalCapacityPrecise(a, intervals);
    for (tasks[0..count]) |task| {
        const part = task.result.?;
        const offset = output.material.intervals.items.len;
        output.material.intervals.appendSliceAssumeCapacity(part.material.intervals.items);
        for (part.material.columns.items) |col| output.material.columns.appendAssumeCapacity(.{ .x = col.x, .y = col.y, .offset = col.offset + offset, .count = col.count });
        inline for (std.meta.fields(d.Work)) |field| @field(output.material.work, field.name) += @field(part.material.work, field.name);
        inline for (std.meta.fields(adaptive.Work)) |field| @field(output.work, field.name) += @field(part.work, field.name);
        inline for (std.meta.fields(swept.Work)) |field| @field(output.sweep_work, field.name) += @field(part.sweep_work, field.name);
        output.material.scratch_bytes += part.material.scratch_bytes;
    }
    return output;
}
