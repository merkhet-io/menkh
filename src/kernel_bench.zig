//! Cache-resident predicate microbenchmark, NOT material-removal throughput.
//! Tests every point against every selected pose/sweep; no block culling.
const std = @import("std");
const builtin = @import("builtin");
const e = @import("engine.zig");
const lanes = 8;
const batches = 8192; // 65,536 points, 1.5 MiB; identical data in every mode.
const rounds = 4096; // 268,435,456 point/tool tests per repetition.
const Batch = [3]e.FlatZ.F;
const Worker = struct {
    points: []const Batch,
    tools: *const [16]e.FlatZ,
    simd: bool,
    checksum: u64 = 0,
    fn run(w: *Worker) void {
        var hits: u64 = 0;
        for (0..rounds) |round| {
            const tool = w.tools[round % 16];
            for (w.points) |points| {
                if (w.simd) {
                    const bits: u8 = @bitCast(tool.contains8(points));
                    hits += @popCount(bits);
                } else {
                    for (0..lanes) |lane| {
                        hits += @intFromBool(tool.sweep.flatContains(.{ points[0][lane], points[1][lane], points[2][lane] }, 0));
                    }
                }
            }
            std.mem.doNotOptimizeAway(hits);
        }
        w.checksum = hits;
    }
};
const Sample = struct { ns: u64, tests_per_second: f64, checksum: u64 };
const Result = struct { motion: []const u8, implementation: []const u8, workers: usize, warmup: Sample, samples: [5]Sample };
fn run(points: []const Batch, tools: *const [16]e.FlatZ, simd: bool, workers: usize) !Sample {
    var work: [8]Worker = undefined;
    var threads: [8]std.Thread = undefined;
    var spawned: usize = 0;
    // A spawn failure joins already-running workers before stack storage expires.
    errdefer for (threads[0..spawned]) |thread| thread.join();
    var timer = try std.time.Timer.start();
    for (0..workers) |i| {
        work[i] = .{ .points = points[i * points.len / workers .. (i + 1) * points.len / workers], .tools = tools, .simd = simd };
        if (workers > 1) {
            threads[i] = try std.Thread.spawn(.{}, Worker.run, .{&work[i]});
            spawned += 1;
        } else Worker.run(&work[i]);
    }
    for (threads[0..spawned]) |thread| thread.join();
    const ns = timer.read();
    var checksum: u64 = 0;
    for (work[0..workers]) |w| checksum += w.checksum;
    return .{ .ns = ns, .tests_per_second = @as(f64, @floatFromInt(points.len * lanes * rounds)) * 1e9 / @as(f64, @floatFromInt(ns)), .checksum = checksum };
}
pub fn main() !void {
    const alloc = std.heap.page_allocator;
    const points = try alloc.alloc(Batch, batches);
    defer alloc.free(points);
    var rng = std.Random.DefaultPrng.init(0x471274);
    for (points) |*batch| for (0..lanes) |lane| {
        batch[0][lane] = rng.random().float(f64) * 7 - 3;
        batch[1][lane] = rng.random().float(f64) * 7 - 3;
        batch[2][lane] = rng.random().float(f64) * 8 - 1;
    };
    var results: [8]Result = undefined;
    var idx: usize = 0;
    for ([_]bool{ false, true }) |moving| {
        var tools: [16]e.FlatZ = undefined;
        for (&tools, 0..) |*tool, i| {
            const x = @as(f64, @floatFromInt(i)) / 100;
            tool.* = e.FlatZ.init(.{ .tool = .{ .radius = 2, .length = 5 }, .a = .{ .position = .{ x, 0, 0 } }, .b = .{ .position = .{ x + (if (moving) @as(f64, 0.65) else 0), if (moving) @as(f64, 0.2) else 0, 0 } } }).?;
        }
        // Validate every SIMD lane, not merely an aggregate hit count.
        var one_cycle: u64 = 0;
        for (tools) |tool| for (points) |batch| {
            const hit = tool.contains8(batch);
            for (0..lanes) |lane| {
                const oracle = tool.sweep.flatContains(.{ batch[0][lane], batch[1][lane], batch[2][lane] }, 0);
                if (hit[lane] != oracle) return error.PredicateMismatch;
                one_cycle += @intFromBool(oracle);
            }
        };
        const expected = one_cycle * (rounds / tools.len);
        for ([_]bool{ false, true }) |simd| for ([_]usize{ 1, 8 }) |workers| {
            var result = Result{ .motion = if (moving) "continuous_xy_segment" else "stationary_pose", .implementation = if (simd) "simd_f64" else "scalar_f64", .workers = workers, .warmup = try run(points, &tools, simd, workers), .samples = undefined };
            if (result.warmup.checksum != expected) return error.InvalidBenchmarkResult;
            for (&result.samples) |*s| {
                s.* = try run(points, &tools, simd, workers);
                if (s.checksum != expected) return error.InvalidBenchmarkResult;
            }
            results[idx] = result;
            idx += 1;
        };
    }
    const data = try std.json.Stringify.valueAlloc(alloc, .{
        .format = "menkh-predicate-bench-v1",
        .zig = builtin.zig_version_string,
        .mode = @tagName(builtin.mode),
        .cpu = builtin.cpu.model.name,
        .definition = "Every point tested against one stationary finite cylinder or continuous XY finite-cylinder sweep. f64, closed expanded boundaries. Cache-resident SoA input; no occupancy updates, culling, history, surface generation or rendering. Thread spawn/join included. Not an end-to-end machining benchmark.",
        .input_bytes = points.len * @sizeOf(Batch),
        .tests_per_repetition = batches * lanes * rounds,
        .results = results,
    }, .{ .whitespace = .indent_2 });
    defer alloc.free(data);
    try std.fs.File.stdout().writeAll(data);
    try std.fs.File.stdout().writeAll("\n");
}
