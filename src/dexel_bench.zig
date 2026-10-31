//! Experimental storage/cutting comparison, deliberately separate from job/viewer.
const std = @import("std");
const e = @import("engine.zig");
const d = @import("dexel.zig");
pub fn run(a: std.mem.Allocator, args: []const [:0]u8) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var h: f64 = 0.1;
    var tolerance: f64 = 0.01;
    var steps: usize = 128;
    var world: ?u32 = null;
    var out: []const u8 = "out/dexel-screw";
    var check: ?[]const u8 = null;
    var limit: ?usize = null;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.MissingArgument;
        const key = args[i];
        const value = args[i + 1];
        if (std.mem.eql(u8, key, "--voxel")) h = try std.fmt.parseFloat(f64, value) else if (std.mem.eql(u8, key, "--tolerance")) tolerance = try std.fmt.parseFloat(f64, value) else if (std.mem.eql(u8, key, "--steps-per-turn")) steps = try std.fmt.parseInt(usize, value, 10) else if (std.mem.eql(u8, key, "--world-grid")) world = try std.fmt.parseInt(u32, value, 10) else if (std.mem.eql(u8, key, "--out")) out = value else if (std.mem.eql(u8, key, "--check-state")) check = value else if (std.mem.eql(u8, key, "--operations")) limit = try std.fmt.parseInt(usize, value, 10) else return error.UnknownOption;
    }
    const job = try @import("grinding_demo.zig").makeJob(temp, h, tolerance, steps, false, world);
    try @import("job.zig").validate(temp, job);
    if (limit) |n| if (n == 0 or n > job.operations.len) return error.InvalidOperationLimit;
    if (std.fs.path.dirname(out)) |path| try std.fs.cwd().makePath(path);
    try std.fs.cwd().makeDir(out);
    var dir = try std.fs.cwd().openDir(out, .{});
    defer dir.close();
    var timer = try std.time.Timer.start();
    var grid = try d.Dexels.initCylinder(a, job.bounds, h, .{ 0, 0, 0 }, 6, 40);
    defer grid.deinit();
    const init_ns = timer.lap();
    const initial = grid.occupiedCount();
    const Record = struct { cut_ns: u64, occupied: u64, intervals: usize, allocated_bytes: usize, work: d.Work };
    const count = limit orelse job.operations.len;
    const reports = try a.alloc(Record, count);
    defer a.free(reports);
    var total_cut_ns: u64 = 0;
    for (job.operations[0..count], 0..) |op, index| {
        timer.reset();
        const plan = try @import("motion.zig").rotary(a, job.tools[0].cutter, op.rotary.?, tolerance);
        defer plan.deinit(a);
        const work = try grid.subtract(.{ .path = plan.segments });
        const cut_ns = timer.lap();
        total_cut_ns += cut_ns;
        reports[index] = .{ .cut_ns = cut_ns, .occupied = grid.occupiedCount(), .intervals = grid.pool.items.len, .allocated_bytes = grid.bytes(), .work = work };
        std.debug.print("dexel {d}/{d}: {d:.3} ms, {d} intervals\n", .{ index + 1, count, @as(f64, @floatFromInt(cut_ns)) / 1e6, grid.pool.items.len });
    }
    const peak_rss = try @import("platform.zig").peakResidentBytes();
    const count_before_check = grid.occupiedCount();
    if (check) |file| {
        const bytes = try std.fs.cwd().readFileAlloc(a, file, 1024 * 1024 * 1024);
        defer a.free(bytes);
        var oracle = try @import("state.zig").decode(a, bytes);
        defer oracle.deinit();
        try grid.compareGrid(oracle);
    }
    try @import("job.zig").json(a, dir, "report.json", .{ .format = "menkh-experimental-quantized-dexels-v1", .zig = @import("builtin").zig_version_string, .mode = @tagName(@import("builtin").mode), .workers = 1, .grid = grid.n, .origin = grid.origin, .voxel_mm = h, .motion_tolerance_mm = tolerance, .columns = grid.columns.len, .intervals = grid.pool.items.len, .allocated_bytes = grid.bytes(), .initial_occupied = initial, .remaining_occupied = count_before_check, .init_ns = init_ns, .cut_ns = total_cut_ns, .peak_rss_before_oracle_bytes = peak_rss, .exact_grid_comparison = check != null, .operations = reports, .note = "Experimental quantized Z-column cutting, no history/export/viewer integration. Two compacted buffers, transactional preflight. Timings are not the full voxel job pipeline. --operations explicitly selects a prefix." });
}
