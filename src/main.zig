const std = @import("std");
const builtin = @import("builtin");
const core = @import("core.zig");
const surface = @import("surface.zig");
const drill = @import("drill.zig");
const fine = @import("fine.zig");
const scenario = core.Move{ .a = .{ 10, 15, 6 }, .b = .{ 30, 15, 6 }, .radius = 3, .length = 10 };
const analytic = (2 * 3 * 20 + std.math.pi * 3 * 3) * 4;
const Timing = struct { init_ns: u64, cut_ns: u64, stats_ns: u64, surface_ns: u64, export_ns: u64 };
const Report = struct {
    zig: []const u8 = builtin.zig_version_string,
    mode: []const u8 = @tagName(builtin.mode),
    workers: u32 = 1,
    target_cpu: []const u8 = builtin.cpu.model.name,
    process_peak_rss_bytes: usize,
    stock_mm: [3]f64 = .{ 40, 30, 10 },
    voxel_mm: f64,
    motion: core.Move = scenario,
    raster_approximation: bool = true,
    stats: core.Stats,
    grid_bytes: usize,
    mesh_capacity_bytes: usize,
    occupied_volume_mm3: f64,
    removed_volume_mm3: f64,
    analytic_removed_mm3: f64 = analytic,
    error_mm3: f64,
    quads: usize,
    timing: Timing,
};
fn saveJson(a: std.mem.Allocator, dir: std.fs.Dir, name: []const u8, value: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(a, value, .{ .whitespace = .indent_2 });
    defer a.free(json);
    try dir.writeFile(.{ .sub_path = name, .data = json });
}
fn run(a: std.mem.Allocator, h: f64, reference: bool, dir: ?std.fs.Dir, mesh: bool) !Report {
    var timer = try std.time.Timer.start();
    var g = try core.Grid.init(a, .{ 40, 30, 10 }, h);
    defer g.deinit();
    const init_ns = timer.lap();
    try g.cut(scenario, reference);
    const cut_ns = timer.lap();
    const s = g.stats();
    const stats_ns = timer.lap();
    var quads: std.ArrayList(surface.Quad) = .empty;
    defer quads.deinit(a);
    if (mesh) quads = try surface.generate(a, g);
    const surface_ns = timer.lap();
    if (dir) |d| {
        try surface.ppm(a, g, d);
        if (mesh) try surface.obj(g, quads.items, d);
    }
    const export_ns = timer.lap();
    const initial = g.n[0] * g.n[1] * g.n[2];
    const removed = @as(f64, @floatFromInt(initial - s.occupied)) * h * h * h;
    // Independent column oracle for this axis-aligned scenario; validates every XY column count.
    var columns: u64 = 0;
    var layers: u64 = 0;
    for (0..g.n[1]) |y| for (0..g.n[0]) |x| {
        if (scenario.xy(g.center(x), g.center(y), 0)) columns += 1;
    };
    for (0..g.n[2]) |z| {
        const p = g.center(z);
        if (p >= 6 - core.tolerance and p <= 16 + core.tolerance) layers += 1;
    }
    if (initial - s.occupied != columns * layers) return error.InvalidBenchmarkResult;
    return .{ .process_peak_rss_bytes = try @import("platform.zig").peakResidentBytes(), .voxel_mm = h, .stats = s, .grid_bytes = s.descriptor_bytes + s.pool_bytes, .mesh_capacity_bytes = quads.capacity * @sizeOf(surface.Quad), .occupied_volume_mm3 = @as(f64, @floatFromInt(s.occupied)) * h * h * h, .removed_volume_mm3 = removed, .error_mm3 = removed - analytic, .quads = quads.items.len, .timing = .{ .init_ns = init_ns, .cut_ns = cut_ns, .stats_ns = stats_ns, .surface_ns = surface_ns, .export_ns = export_ns } };
}
const Distribution = struct { min_ns: u64, median_ns: u64, max_ns: u64 };
fn distribution(values: []u64) Distribution {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    const mid = values.len / 2;
    const median = if (values.len % 2 == 1) values[mid] else values[mid - 1] + (values[mid] - values[mid - 1]) / 2;
    return .{ .min_ns = values[0], .median_ns = median, .max_ns = values[values.len - 1] };
}
const Bench = struct { implementation: []const u8, repetitions: usize, warmups: usize = 1, init: Distribution, cut: Distribution, stats: Distribution, surface: Distribution, export_io: Distribution, last: Report };
fn benchmark(a: std.mem.Allocator, h: f64, reference: bool, repeats: usize, dir: std.fs.Dir) !Bench {
    const warmup = try run(a, h, reference, dir, true);
    const samples = try a.alloc([5]u64, repeats);
    defer a.free(samples);
    var last: Report = undefined;
    for (samples) |*s| {
        last = try run(a, h, reference, dir, true);
        if (last.stats.occupied != warmup.stats.occupied) return error.UnstableBenchmarkResult;
        s.* = .{ last.timing.init_ns, last.timing.cut_ns, last.timing.stats_ns, last.timing.surface_ns, last.timing.export_ns };
    }
    var ds: [5]Distribution = undefined;
    const values = try a.alloc(u64, repeats);
    defer a.free(values);
    for (0..5) |i| {
        for (samples, 0..) |s, j| values[j] = s[i];
        ds[i] = distribution(values);
    }
    return .{ .implementation = if (reference) "scalar" else "block_masks", .repetitions = repeats, .init = ds[0], .cut = ds[1], .stats = ds[2], .surface = ds[3], .export_io = ds[4], .last = last };
}
fn verifyExact(a: std.mem.Allocator, h: f64) !void {
    var reference = try core.Grid.init(a, .{ 40, 30, 10 }, h);
    defer reference.deinit();
    var optimized = try core.Grid.init(a, .{ 40, 30, 10 }, h);
    defer optimized.deinit();
    try reference.cut(scenario, true);
    try optimized.cut(scenario, false);
    for (0..reference.blocks.len) |i| {
        if (!std.mem.eql(u64, &reference.bits(i), &optimized.bits(i))) return error.ReferenceMismatch;
    }
}
pub fn main() void {
    execute() catch |err| {
        std.debug.print("menkh: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}
fn execute() !void {
    const a = std.heap.page_allocator;
    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);
    if (args.len < 2 or std.mem.eql(u8, args[1], "--help")) {
        std.debug.print("menkh scene FILE --out NEW_DIR\nmenkh dexel-bench [--voxel MM] [--out DIR] [--check-state FILE] [--operations N] [--world-grid N] (experimental, no history/viewer)\nmenkh grinding-demo [--out NEW_DIR] [--voxel MM] [--tolerance MM] [--steps-per-turn N] [--workers N] [--world-grid N] [--generate-only] [--no-provenance]\nmenkh inspect-defects JOB STATE OUT_DIR\nmenkh inspect-state FILE\nmenkh job FILE [--provenance all_frames|final_surface|off] [--no-provenance] [--voxel MM] [--out DIR] [--progress FILE] [--reference]\nmenkh demo|export|bench|drill [--voxel MM] [--grid N] [--out DIR] [--repeats N] [--reference] [--no-mesh]\n", .{});
        return;
    }
    const command = args[1];
    if (std.mem.eql(u8, command, "inspect-defects")) {
        if (args.len != 5) return error.ExpectedJobStateOutput;
        return @import("job.zig").inspectDefects(a, args[2], args[3], args[4]);
    }
    if (std.mem.eql(u8, command, "inspect-state")) {
        if (args.len != 3) return error.ExpectedInputState;
        var timer = try std.time.Timer.start();
        const data = try std.fs.cwd().readFileAlloc(a, args[2], 1024 * 1024 * 1024);
        defer a.free(data);
        var g = try @import("state.zig").decode(a, data);
        defer g.deinit();
        const load_ns = timer.lap();
        const stats = g.stats();
        const stats_ns = timer.lap();
        const boundary = surface.boundaryCounts(g);
        const boundary_ns = timer.lap();
        const json = try std.json.Stringify.valueAlloc(a, .{
            .format = "menkh-state-inspection-v1",
            .grid = g.n,
            .voxel_mm = g.h,
            .occupied_voxels = stats.occupied,
            .boundary = boundary,
            .definition = "Occupied voxels with at least one empty face-neighbor; outside grid is empty; enclosed cavities included. Exposed faces counted separately. No mesh generated.",
            .load_ns = load_ns,
            .statistics_ns = stats_ns,
            .boundary_ns = boundary_ns,
        }, .{ .whitespace = .indent_2 });
        defer a.free(json);
        try std.fs.File.stdout().writeAll(json);
        try std.fs.File.stdout().writeAll("\n");
        return;
    }
    if (std.mem.eql(u8, command, "compact-state")) {
        if (args.len != 4) return error.ExpectedInputAndOutputState;
        const data = try std.fs.cwd().readFileAlloc(a, args[2], 1024 * 1024 * 1024);
        defer a.free(data);
        var g = try @import("state.zig").decode(a, data);
        defer g.deinit();
        const before = g.stats();
        try @import("engine.zig").compact(&g);
        const encoded = try @import("state.zig").encode(a, g);
        defer a.free(encoded);
        try std.fs.cwd().writeFile(.{ .sub_path = args[3], .data = encoded });
        std.debug.print("Checkpoint compacted: {d} -> {d} pool bytes; {d} occupied voxels. Start new history from this checkpoint.\n", .{ before.pool_used_bytes, g.stats().pool_used_bytes, g.stats().occupied });
        return;
    }
    if (std.mem.eql(u8, command, "dexel-bench")) {
        try @import("dexel_bench.zig").run(a, args[2..]);
        return;
    }
    if (std.mem.eql(u8, command, "grinding-demo")) {
        try @import("grinding_demo.zig").run(a, args[2..]);
        return;
    }
    if (std.mem.eql(u8, command, "sparse-bench")) {
        if (args.len != 3) return error.ExpectedOutputDirectory;
        try @import("sparse.zig").benchmark(a, args[2]);
        return;
    }
    if (std.mem.eql(u8, command, "tiles-bench")) {
        if (args.len != 3) return error.ExpectedOutputDirectory;
        try @import("tiles.zig").benchmark(a, args[2]);
        return;
    }
    if (std.mem.eql(u8, command, "scene")) {
        if (args.len != 5 or !std.mem.eql(u8, args[3], "--out")) return error.SceneUsage;
        try @import("scene.zig").run(a, args[2], args[4]);
        return;
    }
    if (std.mem.eql(u8, command, "job")) {
        if (args.len < 3) return error.MissingJobFile;
        var output: []const u8 = "out/job";
        var ref = false;
        var voxel_override: ?f64 = null;
        var provenance_override: ?@import("job.zig").ProvenanceMode = null;
        var progress_path: ?[]const u8 = null;
        var j: usize = 3;
        while (j < args.len) : (j += 1) {
            if (std.mem.eql(u8, args[j], "--reference")) {
                ref = true;
                continue;
            }
            if (std.mem.eql(u8, args[j], "--no-provenance")) {
                provenance_override = .off;
                continue;
            }
            if (std.mem.eql(u8, args[j], "--provenance")) {
                if (j + 1 >= args.len) return error.MissingArgument;
                j += 1;
                provenance_override = std.meta.stringToEnum(@import("job.zig").ProvenanceMode, args[j]) orelse return error.InvalidProvenanceMode;
                continue;
            }
            if (std.mem.eql(u8, args[j], "--progress")) {
                if (j + 1 >= args.len) return error.MissingArgument;
                j += 1;
                progress_path = args[j];
                continue;
            }
            if (std.mem.eql(u8, args[j], "--voxel")) {
                if (j + 1 >= args.len) return error.MissingArgument;
                j += 1;
                voxel_override = try std.fmt.parseFloat(f64, args[j]);
                continue;
            }
            if (!std.mem.eql(u8, args[j], "--out")) return error.UnknownOption;
            if (j + 1 >= args.len) return error.MissingArgument;
            j += 1;
            output = args[j];
        }
        try @import("job.zig").run(a, args[2], output, ref, voxel_override, progress_path, provenance_override);
        return;
    }
    if (!std.mem.eql(u8, command, "demo") and !std.mem.eql(u8, command, "export") and !std.mem.eql(u8, command, "bench") and !std.mem.eql(u8, command, "drill")) return error.InvalidCommand;
    var h: f64 = 0.25;
    var out: []const u8 = if (std.mem.eql(u8, command, "drill")) "out/drill" else "out/demo";
    var repeats: usize = 5;
    var grid: ?usize = null;
    var voxel_explicit = false;
    var reference = false;
    var mesh = true;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--reference")) {
            reference = true;
            continue;
        }
        if (std.mem.eql(u8, args[i], "--no-mesh")) {
            mesh = false;
            continue;
        }
        if (i + 1 >= args.len) return error.MissingArgument;
        const key = args[i];
        i += 1;
        if (std.mem.eql(u8, key, "--voxel")) {
            h = try std.fmt.parseFloat(f64, args[i]);
            voxel_explicit = true;
        } else if (std.mem.eql(u8, key, "--grid")) grid = try std.fmt.parseInt(usize, args[i], 10) else if (std.mem.eql(u8, key, "--out")) out = args[i] else if (std.mem.eql(u8, key, "--repeats")) repeats = try std.fmt.parseInt(usize, args[i], 10) else return error.UnknownOption;
    }
    if (std.mem.eql(u8, command, "drill")) {
        if (reference or !mesh) return error.UnsupportedDrillOption;
        if (grid) |n| {
            if (voxel_explicit) return error.ChooseGridOrVoxel;
            try fine.run(a, n, out);
        } else try drill.run(a, h, out);
        return;
    }
    if (grid != null) return error.GridOptionOnlyForDrill;
    if (repeats < 2 or repeats > 1000) return error.InvalidRepetitions;
    try std.fs.cwd().makePath(out);
    var dir = try std.fs.cwd().openDir(out, .{});
    defer dir.close();
    if (std.mem.eql(u8, command, "bench")) {
        if (!mesh or reference) return error.BenchmarkAlwaysComparesBothWithMesh;
        try verifyExact(a, h);
        const baseline = try benchmark(a, h, true, repeats, dir);
        const optimized = try benchmark(a, h, false, repeats, dir);
        if (baseline.last.stats.occupied != optimized.last.stats.occupied) return error.ReferenceMismatch;
        try saveJson(a, dir, "benchmark.json", .{ .voxel_exact_reference_check = true, .scalar = baseline, .optimized = optimized });
        std.debug.print("voxel={d} mm scalar={d:.3} ms optimized={d:.3} ms grid={d} bytes error={d:.6} mm3\n", .{ h, @as(f64, @floatFromInt(baseline.cut.median_ns)) / 1e6, @as(f64, @floatFromInt(optimized.cut.median_ns)) / 1e6, optimized.last.grid_bytes, optimized.last.error_mm3 });
    } else {
        const report = try run(a, h, reference, dir, mesh);
        try saveJson(a, dir, "report.json", report);
        std.debug.print("{s}: occupied={d}, cut={d:.3} ms, grid={d} bytes, quads={d}\n", .{ out, report.stats.occupied, @as(f64, @floatFromInt(report.timing.cut_ns)) / 1e6, report.grid_bytes, report.quads });
    }
}
