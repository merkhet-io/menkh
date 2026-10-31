const std = @import("std");
const e = @import("engine.zig");
const d = @import("raydexel.zig");
const jobs = @import("job.zig");
const core = @import("core.zig");
fn occupied(r: d.Result, col: d.Column, z: f64) bool {
    for (r.intervals.items[col.offset .. col.offset + col.count]) |span| {
        if (z < span.lo) return false;
        if (z <= span.hi) return true;
    }
    return false;
}
const Comparison = struct { reference_occupied: u64, sampled_occupied: u64, extra_removed: u64, extra_retained: u64 };
fn compare(a: std.mem.Allocator, r: d.Result, path: []const u8) !Comparison {
    const bytes = try std.fs.cwd().readFileAlloc(a, path, 1024 * 1024 * 1024);
    defer a.free(bytes);
    var grid = try @import("state.zig").decode(a, bytes);
    defer grid.deinit();
    if (grid.h != r.spacing or grid.n[0] != r.n[0] or grid.n[1] != r.n[1] or !std.mem.eql(f64, &grid.origin, &r.origin)) return error.IncompatibleComparisonGrid;
    var result = Comparison{ .reference_occupied = grid.stats().occupied, .sampled_occupied = 0, .extra_removed = 0, .extra_retained = 0 };
    var col_index: usize = 0;
    // Includes columns outside the initial cylinder, not just retained rays.
    for (0..grid.n[1]) |y| for (0..grid.n[0]) |x| {
        const col: ?d.Column = if (col_index < r.columns.items.len and r.columns.items[col_index].x == x and r.columns.items[col_index].y == y) blk: {
            const value = r.columns.items[col_index];
            col_index += 1;
            break :blk value;
        } else null;
        for (0..grid.n[2]) |z| {
            const actual = if (col) |column| occupied(r, column, grid.origin[2] + grid.center(z)) else false;
            const expected = grid.occupied(.{ x, y, z });
            result.sampled_occupied += @intFromBool(actual);
            result.extra_removed += @intFromBool(expected and !actual);
            result.extra_retained += @intFromBool(!expected and actual);
        }
    };
    return result;
}
fn section(a: std.mem.Allocator, dir: std.fs.Dir, r: d.Result, y_mm: f64, name: []const u8) !void {
    const width: usize = r.n[0];
    const height: usize = @intFromFloat(@ceil(40 / r.spacing));
    const y: u32 = @intFromFloat(std.math.clamp(@floor((y_mm - r.origin[1]) / r.spacing), 0, @as(f64, @floatFromInt(r.n[1] - 1))));
    const bytes = try a.alloc(u8, try std.math.mul(usize, try std.math.mul(usize, width, height), 3));
    defer a.free(bytes);
    for (0..width * height) |i| @memcpy(bytes[i * 3 ..][0..3], &[_]u8{ 212, 120, 64 });
    for (r.columns.items) |col| {
        if (col.y != y) continue;
        for (0..height) |z| if (occupied(r, col, r.origin[2] + (@as(f64, @floatFromInt(z)) + 0.5) * r.spacing)) {
            const offset = ((height - z - 1) * width + col.x) * 3;
            @memcpy(bytes[offset..][0..3], &[_]u8{ 70, 110, 182 });
        };
    }
    var file = try dir.createFile(name, .{});
    defer file.close();
    var header: [80]u8 = undefined;
    try file.writeAll(try std.fmt.bufPrint(&header, "P6\n{d} {d}\n255\n", .{ width, height }));
    try file.writeAll(bytes);
}
fn exportIntervals(a: std.mem.Allocator, dir: std.fs.Dir, r: d.Result) !void {
    const columns_bytes = try std.math.mul(usize, r.columns.items.len, 24);
    const spans_bytes = try std.math.mul(usize, r.intervals.items.len, 16);
    const bytes = try a.alloc(u8, try std.math.add(usize, columns_bytes, spans_bytes));
    defer a.free(bytes);
    for (r.columns.items, 0..) |col, i| {
        const b = bytes[i * 24 ..][0..24];
        std.mem.writeInt(u32, b[0..4], col.x, .little);
        std.mem.writeInt(u32, b[4..8], col.y, .little);
        std.mem.writeInt(u64, b[8..16], col.offset, .little);
        std.mem.writeInt(u64, b[16..24], col.count, .little);
    }
    for (r.intervals.items, 0..) |span, i| {
        const b = bytes[columns_bytes + i * 16 ..][0..16];
        std.mem.writeInt(u64, b[0..8], @bitCast(span.lo), .little);
        std.mem.writeInt(u64, b[8..16], @bitCast(span.hi), .little);
    }
    try dir.writeFile(.{ .sub_path = "intervals.bin", .data = bytes });
    try jobs.json(a, dir, "intervals.json", .{ .format = "menkh-experimental-z-rays-v1", .units = "mm", .origin = r.origin, .spacing_mm = r.spacing, .grid_xy = r.n, .columns = r.columns.items.len, .intervals = r.intervals.items.len, .file = "intervals.bin", .layout = "little endian: columns {u32 x,y; u64 interval_offset,count}, then {f64 lo,hi} world-Z intervals; no native viewer/history importer" });
}
pub fn run(a: std.mem.Allocator, args: []const [:0]u8) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var spacing: f64 = 0.1;
    var tolerance: f64 = 0.01;
    var out: []const u8 = "out/raydexel-screw";
    var check: ?[]const u8 = null;
    var limit: ?usize = null;
    var adaptive = false;
    var workers: usize = 1;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.MissingArgument;
        const key = args[i];
        const value = args[i + 1];
        if (std.mem.eql(u8, key, "--spacing")) spacing = try std.fmt.parseFloat(f64, value) else if (std.mem.eql(u8, key, "--tolerance")) tolerance = try std.fmt.parseFloat(f64, value) else if (std.mem.eql(u8, key, "--out")) out = value else if (std.mem.eql(u8, key, "--check-state")) check = value else if (std.mem.eql(u8, key, "--workers")) workers = try std.fmt.parseInt(usize, value, 10) else if (std.mem.eql(u8, key, "--method")) {
            if (std.mem.eql(u8, value, "adaptive")) adaptive = true else if (std.mem.eql(u8, value, "fixed")) adaptive = false else return error.UnknownRayMethod;
        } else if (std.mem.eql(u8, key, "--operations")) limit = try std.fmt.parseInt(usize, value, 10) else return error.UnknownOption;
    }
    if (workers < 1 or workers > 64) return error.InvalidWorkerCount;
    const job = try @import("grinding_demo.zig").makeJob(temp, spacing, tolerance, 128, false, null);
    try jobs.validate(temp, job);
    const count = limit orelse job.operations.len;
    if (count == 0 or count > job.operations.len) return error.InvalidOperationLimit;
    if (std.fs.path.dirname(out)) |parent| try std.fs.cwd().makePath(parent);
    try std.fs.cwd().makeDir(out);
    var dir = try std.fs.cwd().openDir(out, .{});
    defer dir.close();
    var recorded_job = job;
    recorded_job.operations = job.operations[0..count];
    recorded_job.workers = workers;
    try jobs.json(a, dir, "job.json", recorded_job);
    var total = try std.time.Timer.start();
    var timer = try std.time.Timer.start();
    const tool = job.tools[0].cutter;
    const profile = try d.Profile.init(a, tool);
    defer profile.deinit();
    var poses: std.ArrayList(d.Pose) = .empty;
    defer poses.deinit(a);
    var bound: f64 = 0;
    var guard: f64 = 0;
    const adaptive_module = @import("adaptive_raydexel.zig");
    var adaptive_plan: ?adaptive_module.Plan = null;
    defer if (adaptive_plan) |*p| p.deinit();
    if (adaptive) {
        adaptive_plan = try adaptive_module.Plan.init(a, profile, job.operations[0..count], tolerance);
        bound = tolerance;
        guard = adaptive_plan.?.guard;
    } else for (job.operations[0..count]) |op| {
        const added = try @import("raydexel_motion.zig").append(a, &poses, profile, tool, op.rotary.?, tolerance);
        bound = @max(bound, added.total_mm);
        guard = @max(guard, added.numerical_guard_mm);
    }
    const pose_count = if (adaptive_plan) |p| p.nodes.items.len else poses.items.len;
    const planning_ns = timer.lap();
    var tree = try d.Tree.init(a, profile, if (adaptive_plan) |p| p.roots.items else poses.items);
    defer tree.deinit();
    poses.clearAndFree(a);
    const hierarchy_ns = timer.lap();
    std.debug.print("Analytic Z rays ({s}): {d} operations, {d} prepared nodes/poses, {d} mm spacing, bound {d} mm\n", .{ if (adaptive) "adaptive" else "fixed", count, pose_count, spacing, bound });
    var adaptive_work: ?adaptive_module.Work = null;
    const finished = try @import("raydexel_parallel.zig").finish(a, profile, if (adaptive_plan) |*p| p else null, tree, .{ 0, 0, 0 }, 6, 40, spacing, workers);
    if (adaptive) adaptive_work = finished.work;
    var result = finished.material;
    defer result.deinit();
    const cut_ns = timer.lap();
    const volume = result.volume();
    const statistics_ns = timer.lap();
    const kernel_peak = try @import("platform.zig").peakResidentBytes();
    const kernel_total_ns = total.read();
    try exportIntervals(a, dir, result);
    try section(a, dir, result, 0, "section-y0.ppm");
    try section(a, dir, result, 3, "section-y3.ppm");
    const export_ns = timer.lap();
    const comparison = if (check) |path| try compare(a, result, path) else null;
    const comparison_ns = timer.lap();
    try jobs.json(a, dir, "report.json", .{ .format = "menkh-analytic-ray-experiment-v1", .zig = @import("builtin").zig_version_string, .mode = @tagName(@import("builtin").mode), .workers = workers, .method = if (adaptive) "adaptive" else "fixed", .adaptive_work = adaptive_work, .operations = count, .poses = pose_count, .spacing_mm = spacing, .requested_motion_tolerance_mm = tolerance, .motion_over_removal_bound_mm = bound, .offset_miter_factor = profile.miter, .floating_point_guard_mm = guard, .columns = result.columns.items.len, .intervals = result.intervals.items.len, .remaining_volume_mm3 = volume, .analytic_initial_volume_mm3 = std.math.pi * 36 * 40, .initial_volume_mm3 = @as(f64, @floatFromInt(result.columns.items.len)) * spacing * spacing * 40, .volume_is_transverse_ray_quadrature = true, .result_capacity_bytes = result.bytes(), .scratch_bytes = result.scratch_bytes, .hierarchy_bytes = tree.bytes() + (if (adaptive_plan) |p| p.bytes() else @as(usize, 0)), .peak_rss_before_export_and_oracle_bytes = kernel_peak, .process_peak_rss_bytes = try @import("platform.zig").peakResidentBytes(), .work = result.work, .timing = .{ .planning_ns = planning_ns, .hierarchy_ns = hierarchy_ns, .cut_including_stock_init_ns = cut_ns, .statistics_ns = statistics_ns, .kernel_total_ns = kernel_total_ns, .export_ns = export_ns, .comparison_ns = comparison_ns, .total_before_report_ns = total.read() }, .comparison = comparison, .note = "Experimental continuous Z intervals, convex profile only. Midpoint/conic offset semantics differ from production. No history, native viewer, engagement or resume. Kernel time is not end-to-end parity." });
    std.debug.print("Completed: {d:.3} s interval cutting, {d:.3} s kernel total; {d} intervals, {d} ray-pose tests\n", .{ @as(f64, @floatFromInt(cut_ns)) / 1e9, @as(f64, @floatFromInt(kernel_total_ns)) / 1e9, result.intervals.items.len, if (adaptive_work) |w| w.analytic_ray_tests else result.work.ray_pose_tests });
}
