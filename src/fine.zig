//! Dense compact block descriptors + sparse bits + reversible changes; no surface mesh.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core.zig");
const drill = @import("drill.zig");
const Op = drill.Operation;
const origin = [3]f64{ 24, 24, 0 };
const engine = @import("engine.zig");
pub const Changes = engine.Changes;
pub fn cylinder(a: std.mem.Allocator, n: usize) !core.Grid {
    if (n < 32 or n > 4096 or n % 8 != 0) return error.GridMustBeMultipleOfEightBetween32And4096;
    return engine.stock(a, .{ .lo = .{ 0, 0, 0 }, .hi = .{ 60, 60, 60 } }, 60 / @as(f64, @floatFromInt(n)), &.{.{ .cylinder = .{ .base = .{ 30, 30, 0 }, .radius = 6, .length = 60 } }});
}
pub fn cut(g: *core.Grid, op: Op, changes: *Changes) !void {
    try engine.subtract(g, try drill.shape(op, origin), changes, false);
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
