//! Reproducible screw-grinding workload; generator and runner work on both platforms.
const std = @import("std");
const e = @import("engine.zig");
const motion = @import("motion.zig");
const jobs = @import("job.zig");
pub const profile = [_]e.ProfilePoint{ .{ .z = 0, .radius = 7 }, .{ .z = 0.8, .radius = 8 }, .{ .z = 1.2, .radius = 8 }, .{ .z = 2, .radius = 7 } };
pub fn pose(t: f64, start: usize) motion.XYZAC {
    const degrees = 1440 * t + @as(f64, @floatFromInt(start)) * 180;
    const theta = degrees * (std.math.pi / 180.0);
    return .{ .position = .{ 12 * @cos(theta), 12 * @sin(theta), 4 + 32 * t }, .a_deg = std.math.atan(@as(f64, 8.0 / (2 * std.math.pi * 5))) * (180.0 / std.math.pi), .c_deg = degrees };
}
pub fn makeJob(a: std.mem.Allocator, h: f64, tolerance: f64, steps: usize, provenance: bool, world: ?u32) !jobs.Job {
    if (!std.math.isFinite(h) or h <= 0 or !std.math.isFinite(tolerance) or tolerance <= 0 or steps < 16 or steps > 1024) return error.InvalidGrindingOptions;
    var bounds = e.Bounds{ .lo = .{ -6, -6, 0 }, .hi = .{ 6, 6, 40 } };
    if (world) |n| {
        if (!std.math.isPowerOfTwo(n) or n < 8 or n > 65536) return error.InvalidVirtualGrid;
        const extent = @as(f64, @floatFromInt(n)) * h;
        if (!std.math.isFinite(extent) or extent < 40 or extent > 1e6) return error.InvalidVirtualGridExtent;
        bounds = .{ .lo = .{ -extent / 2, -extent / 2, 0 }, .hi = .{ extent / 2, extent / 2, extent } };
    }
    const per_start = try std.math.mul(usize, steps, 4);
    const operations = try a.alloc(jobs.Operation, try std.math.mul(usize, per_start, 2));
    for (0..2) |start| for (0..per_start) |i| {
        operations[start * per_start + i] = .{ .id = try std.fmt.allocPrint(a, "start-{d}-cut-{d:0>4}", .{ start + 1, i + 1 }), .tool = 0, .rotary = .{ .a = pose(@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(per_start)), start), .b = pose(@as(f64, @floatFromInt(i + 1)) / @as(f64, @floatFromInt(per_start)), start) } };
    };
    return .{ .version = 1, .units = "mm", .bounds = bounds, .voxel_mm = h, .stock = .{ .primitives = &.{.{ .cylinder = .{ .base = .{ 0, 0, 0 }, .radius = 6, .length = 40 } }} }, .tools = &.{.{ .cutter = .{ .kind = .profile, .radius = 8, .length = 2, .profile = &profile } }}, .motion_tolerance_mm = tolerance, .export_mesh = false, .export_provenance = provenance, .provenance_scope = .all_frames, .operations = operations };
}
pub fn run(parent: std.mem.Allocator, args: []const [:0]u8) !void {
    var arena = std.heap.ArenaAllocator.init(parent);
    defer arena.deinit();
    const a = arena.allocator();
    var out: []const u8 = "out/screw-grinding";
    var h: f64 = 0.1;
    var tolerance: f64 = 0.01;
    var steps: usize = 128;
    var world: ?u32 = null;
    var generate_only = false;
    var provenance = true;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const option = args[i];
        if (std.mem.eql(u8, option, "--generate-only")) {
            generate_only = true;
            continue;
        }
        if (std.mem.eql(u8, option, "--no-provenance")) {
            provenance = false;
            continue;
        }
        if (i + 1 >= args.len) return error.MissingArgument;
        i += 1;
        if (std.mem.eql(u8, option, "--out")) out = args[i] else if (std.mem.eql(u8, option, "--voxel")) h = try std.fmt.parseFloat(f64, args[i]) else if (std.mem.eql(u8, option, "--tolerance")) tolerance = try std.fmt.parseFloat(f64, args[i]) else if (std.mem.eql(u8, option, "--steps-per-turn")) steps = try std.fmt.parseInt(usize, args[i], 10) else if (std.mem.eql(u8, option, "--world-grid")) world = try std.fmt.parseInt(u32, args[i], 10) else return error.UnknownOption;
    }
    const job = try makeJob(a, h, tolerance, steps, provenance, world);
    try jobs.validate(a, job);
    if (std.fs.path.dirname(out)) |path| try std.fs.cwd().makePath(path);
    try std.fs.cwd().makeDir(out);
    var dir = try std.fs.cwd().openDir(out, .{});
    defer dir.close();
    try jobs.json(a, dir, "job.json", job);
    try jobs.json(a, dir, "protocol.json", .{ .format = "menkh-screw-grinding-protocol-v1", .starts = 2, .turns_per_start = 4, .lead_mm = 8, .blank_diameter_mm = 12, .blank_length_mm = 40, .nominal_root_radius_mm = 4, .wheel_max_radius_mm = 8, .wheel_width_mm = 2, .steps_per_turn = steps, .operations = job.operations.len, .voxel_mm = h, .motion_tolerance_mm = tolerance, .centerline_chord_bound_mm = 12 * (1 - @cos(std.math.pi / @as(f64, @floatFromInt(steps)))), .virtual_grid = world, .export_provenance = provenance, .note = "Continuous piecewise-linear XYZAC grinding. Nominal screw dimensions describe the path, not a certified thread profile. Chord error, motion approximation and voxelization are separate." });
    const file = try std.fs.path.join(a, &.{ out, "job.json" });
    std.debug.print("Screw workload: {d} operations, {d} mm voxels, {d} mm motion tolerance. Job: {s}\n", .{ job.operations.len, h, tolerance, file });
    if (!generate_only) try jobs.run(parent, file, try std.fs.path.join(a, &.{ out, "result" }), false, null, null, null);
}
