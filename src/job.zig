//! Versioned geometric jobs; no toolpath generation, controller, or machine kinematics.
const std = @import("std");
const builtin = @import("builtin");
const e = @import("engine.zig");
const c = @import("core.zig");
const state = @import("state.zig");
const inspect = @import("inspect.zig");
const surface = @import("surface.zig");
const motion = @import("motion.zig");
const stl = @import("mesh_input.zig");
pub const MeshSource = struct { path: []const u8, unit_scale_mm: f64, translation: e.V = .{ 0, 0, 0 } };
pub const Stock = struct { primitives: []const e.Primitive = &.{}, stl: ?MeshSource = null, state_file: ?[]const u8 = null };
pub const Noncutting = struct { radius: f64, length: f64, offset: f64 };
pub const Assembly = struct { cutter: e.Tool, shank: ?Noncutting = null, holder: ?Noncutting = null };
pub const Line = struct { a: e.Pose, b: e.Pose };
pub const Operation = struct { id: []const u8, tool: ?usize = null, line: ?Line = null, arc: ?motion.Arc = null, rotary: ?motion.RotaryLine = null, turning: ?motion.Turning = null, subtract: ?e.Primitive = null, feed_mm_min: ?f64 = null };
pub const Query = struct { point: e.V };
pub const Ray = struct { origin: e.V, direction: e.V, max_distance_mm: f64 };
pub const Job = struct {
    version: u32,
    units: []const u8,
    bounds: e.Bounds,
    voxel_mm: f64,
    stock: Stock,
    tools: []const Assembly = &.{},
    operations: []const Operation,
    motion_tolerance_mm: f64 = 0.02,
    target: ?Stock = null,
    fixtures: ?Stock = null,
    sections: []const inspect.Section = &.{},
    points: []const Query = &.{},
    rays: []const Ray = &.{},
    export_mesh: bool = true,
    export_defects: bool = false,
    export_provenance: bool = false,
    provenance_scope: enum { final_surface, all_frames } = .final_surface,
};
fn read(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(a, path, 1024 * 1024 * 1024);
}
pub const InputTiming = struct { read_ns: u64 = 0, parse_bvh_ns: u64 = 0, voxelization_ns: u64 = 0, state_decode_ns: u64 = 0, parse_validate_ns: u64 = 0, bvh_ns: u64 = 0, intersection_validate_ns: u64 = 0, ray_cache_ns: u64 = 0, ray_cache_bytes: usize = 0, uniform_blocks: u64 = 0, scanlines: u64 = 0, scanline_fallbacks: u64 = 0, scanline_scratch_bytes: usize = 0, point_queries: u64 = 0 };
pub fn initialize(a: std.mem.Allocator, j: Job, s: Stock, timing: *InputTiming, reference: bool) !c.Grid {
    var timer = try std.time.Timer.start();
    const sources = @as(usize, @intFromBool(s.primitives.len > 0)) + @intFromBool(s.stl != null) + @intFromBool(s.state_file != null);
    if (sources != 1) return error.ChooseOneStockSource;
    if (s.state_file) |path| {
        const bytes = try read(a, path);
        defer a.free(bytes);
        timing.read_ns += timer.lap();
        var g = try state.decode(a, bytes);
        timing.state_decode_ns += timer.lap();
        errdefer g.deinit();
        if (g.h != j.voxel_mm or !std.mem.eql(f64, &g.origin, &j.bounds.lo) or !std.mem.eql(f64, &g.size, &e.sub(j.bounds.hi, j.bounds.lo))) return error.GridMismatch;
        return g;
    }
    if (s.stl) |source| {
        const bytes = try read(a, source.path);
        defer a.free(bytes);
        timing.read_ns += timer.lap();
        var mesh = try stl.Mesh.parse(a, bytes, source.unit_scale_mm, source.translation);
        defer mesh.deinit();
        timing.parse_bvh_ns += timer.lap();
        timing.parse_validate_ns += mesh.parse_validate_ns;
        timing.bvh_ns += mesh.bvh_ns;
        timing.intersection_validate_ns += mesh.intersection_validate_ns;
        timing.ray_cache_ns += mesh.ray_cache_ns;
        timing.ray_cache_bytes += mesh.rayCacheBytes();
        const g = try mesh.voxelizeMode(a, j.bounds, j.voxel_mm, reference);
        timing.uniform_blocks += mesh.uniform_blocks;
        timing.point_queries += mesh.point_queries;
        timing.scanlines += mesh.scanlines;
        timing.scanline_fallbacks += mesh.scanline_fallbacks;
        timing.scanline_scratch_bytes += mesh.scanline_scratch_bytes;
        timing.voxelization_ns += timer.lap();
        return g;
    }
    const g = try e.stock(a, j.bounds, j.voxel_mm, s.primitives);
    timing.voxelization_ns += timer.lap();
    return g;
}
pub fn validate(a: std.mem.Allocator, j: Job) !void {
    if (j.version != 1) return error.UnsupportedJobVersion;
    if (!std.mem.eql(u8, j.units, "mm")) return error.UnitsMustBeMillimeters;
    try j.bounds.validate();
    if (j.export_defects and j.target == null) return error.DefectsRequireTarget;
    if (!std.math.isFinite(j.motion_tolerance_mm) or j.motion_tolerance_mm <= 0) return error.InvalidMotionTolerance;
    for (j.tools) |tool| {
        try tool.cutter.validate();
        for ([2]?Noncutting{ tool.shank, tool.holder }) |part| if (part) |p| {
            try (e.Tool{ .radius = p.radius, .length = p.length }).validate();
            if (!std.math.isFinite(p.offset) or p.offset < tool.cutter.length or p.offset > 1e6) return error.NoncuttingMustStartAboveCutter;
        };
    }
    for (j.operations, 0..) |op, index| {
        if (op.id.len == 0) return error.MissingOperationId;
        for (j.operations[0..index]) |previous| if (std.mem.eql(u8, op.id, previous.id)) return error.DuplicateOperationId;
        if (op.turning) |t| {
            if (op.subtract != null or op.tool != null or op.line != null or op.arc != null or op.rotary != null or op.feed_mm_min != null) return error.AmbiguousOperation;
            _ = try t.shape();
            continue;
        }
        if (op.subtract) |s| {
            if (op.tool != null or op.line != null or op.arc != null or op.rotary != null or op.feed_mm_min != null) return error.AmbiguousOperation;
            try s.validate();
        } else {
            const tool = op.tool orelse return error.MissingTool;
            if (tool >= j.tools.len) return error.InvalidToolIndex;
            if (op.rotary) |rotary_input| {
                if (op.line != null or op.arc != null or op.feed_mm_min != null or j.tools[tool].shank != null or j.tools[tool].holder != null) return error.RotaryAssemblyOrFeedUnsupported;
                const plan = try motion.rotary(a, j.tools[tool].cutter, rotary_input, j.motion_tolerance_mm);
                plan.deinit(a);
                continue;
            }
            if (op.arc) |arc_input| {
                if (op.line != null or op.feed_mm_min != null or j.tools[tool].shank != null or j.tools[tool].holder != null) return error.ArcAssemblyOrFeedUnsupported;
                const plan = try motion.arc(a, j.tools[tool].cutter, arc_input, j.motion_tolerance_mm);
                plan.deinit(a);
                continue;
            }
            const line = op.line orelse return error.MissingMotion;
            try (e.Sweep{ .tool = j.tools[tool].cutter, .a = line.a, .b = line.b, .tolerance_mm = j.motion_tolerance_mm }).validate();
        }
        if (op.feed_mm_min) |f| if (!std.math.isFinite(f) or f <= 0) return error.InvalidFeed;
    }
}
const Step = struct { file: []const u8, stage: []const u8, occupied: u64, changed_blocks: usize, delta_bytes: usize, tool: e.V, axis: e.V = .{ 0, 0, 1 }, shank: ?Noncutting = null, holder: ?Noncutting = null, cutter: ?e.Tool = null };
const OpReport = struct { work: e.Work, id: []const u8, removed_voxels: u64, engagement_volume_mm3: f64, remaining_voxels: u64, affected_region: ?e.Bounds, motion_over_removal_bound_mm: f64, sweep_pieces: usize, cut_ns: u64, collision_ns: u64, history_write_ns: u64, shank_stock: inspect.Contact, holder_stock: inspect.Contact, shank_fixture: inspect.Contact, holder_fixture: inspect.Contact, cutter_fixture: inspect.Contact, geometric_feed_time_min: ?f64, average_removal_mm3_min: ?f64 };
fn contact(g: c.Grid, line: Line, p: ?Noncutting) !inspect.Contact {
    const part = p orelse return .{};
    const shape = e.Shape{ .sweep = .{ .tool = .{ .radius = part.radius, .length = part.length }, .a = .{ .position = e.add(line.a.position, e.scale(line.a.axis, part.offset)), .axis = line.a.axis }, .b = .{ .position = e.add(line.b.position, e.scale(line.b.axis, part.offset)), .axis = line.b.axis } } };
    return inspect.collision(g, shape);
}
pub fn json(a: std.mem.Allocator, dir: std.fs.Dir, name: []const u8, value: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{ .whitespace = .indent_2 });
    defer a.free(bytes);
    try dir.writeFile(.{ .sub_path = name, .data = bytes });
}
pub const Hooks = struct {
    context: ?*anyopaque,
    callback: *const fn (?*anyopaque, u32, u64, u64) callconv(.c) u32,
};
const Progress = struct {
    allocator: std.mem.Allocator,
    file: ?std.fs.File,
    total: usize,
    hooks: ?Hooks = null,
    fn emit(p: Progress, phase: []const u8, completed: usize, operation: ?[]const u8) !void {
        if (p.file) |file| {
            const line = try std.json.Stringify.valueAlloc(p.allocator, .{ .version = 1, .phase = phase, .completed_operations = completed, .total_operations = p.total, .operation = operation }, .{});
            defer p.allocator.free(line);
            try file.writeAll(line);
            try file.writeAll("\n");
        }
        if (p.hooks) |hooks| {
            const code: u32 = if (std.mem.eql(u8, phase, "initializing_stock")) 0 else if (std.mem.eql(u8, phase, "initializing_target")) 1 else if (std.mem.eql(u8, phase, "initializing_fixtures")) 2 else if (std.mem.eql(u8, phase, "cutting")) 3 else if (std.mem.eql(u8, phase, "finalizing")) 4 else if (std.mem.eql(u8, phase, "complete")) 5 else 6;
            const cancel = hooks.callback(hooks.context, code, completed, p.total);
            if (cancel != 0 and code != 5) return error.Cancelled;
        }
    }
};
pub fn run(a: std.mem.Allocator, path: []const u8, out: []const u8, reference: bool, voxel_override: ?f64, progress_path: ?[]const u8) !void {
    return runControlled(a, path, out, reference, voxel_override, progress_path, null, null);
}
fn resolveSource(a: std.mem.Allocator, source: *Stock, base: []const u8) !void {
    if (source.state_file) |p| source.state_file = try std.fs.path.resolve(a, &.{ base, p });
    if (source.stl) |*mesh| mesh.path = try std.fs.path.resolve(a, &.{ base, mesh.path });
}
pub fn runControlled(a: std.mem.Allocator, path: []const u8, out: []const u8, reference: bool, voxel_override: ?f64, progress_path: ?[]const u8, working_dir: ?[]const u8, hooks: ?Hooks) !void {
    var total = try std.time.Timer.start();
    const bytes = try read(a, path);
    defer a.free(bytes);
    const parsed = try std.json.parseFromSlice(Job, a, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    var j = parsed.value;
    if (working_dir) |base| {
        const paths = parsed.arena.allocator();
        try resolveSource(paths, &j.stock, base);
        if (j.target) |*source| try resolveSource(paths, source, base);
        if (j.fixtures) |*source| try resolveSource(paths, source, base);
    }
    if (voxel_override) |h| {
        if (!std.math.isFinite(h) or h <= 0) return error.InvalidVoxelSize;
        j.voxel_mm = h;
    }
    try validate(a, j);
    var progress = Progress{ .allocator = a, .file = null, .total = j.operations.len, .hooks = hooks };
    if (progress_path) |p| {
        try std.fs.cwd().makePath(std.fs.path.dirname(p) orelse ".");
        progress.file = try std.fs.cwd().createFile(p, .{});
    }
    defer if (progress.file) |file| file.close();
    try progress.emit("initializing_stock", 0, null);
    const job_parse_validate_ns = total.read();
    var timer = try std.time.Timer.start();
    var stock_input: InputTiming = .{};
    var auxiliary_input: InputTiming = .{};
    var g = try initialize(a, j, j.stock, &stock_input, reference);
    defer g.deinit();
    const init_ns = timer.lap();
    var target: ?c.Grid = null;
    defer if (target) |*v| v.deinit();
    try progress.emit("initializing_target", 0, null);
    if (j.target) |t| target = try initialize(a, j, t, &auxiliary_input, reference);
    var fixtures: ?c.Grid = null;
    defer if (fixtures) |*v| v.deinit();
    try progress.emit("initializing_fixtures", 0, null);
    if (j.fixtures) |f| fixtures = try initialize(a, j, f, &auxiliary_input, reference);
    const auxiliary_ns = timer.lap();
    try std.fs.cwd().makePath(out);
    var dir = try std.fs.cwd().openDir(out, .{});
    defer dir.close();
    for ([_][]const u8{ "voxel-animation.json", "report.json", "defects.json", "surface-provenance.json", "surface-provenance.bin" }) |name| dir.deleteFile(name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    if (target) |t| {
        try dir.writeFile(.{ .sub_path = "target.blocks", .data = std.mem.sliceAsBytes(t.blocks) });
        try dir.writeFile(.{ .sub_path = "target.pool", .data = std.mem.sliceAsBytes(t.pool.items) });
    }
    if (fixtures) |f| {
        try dir.writeFile(.{ .sub_path = "fixture.blocks", .data = std.mem.sliceAsBytes(f.blocks) });
        try dir.writeFile(.{ .sub_path = "fixture.pool", .data = std.mem.sliceAsBytes(f.pool.items) });
    }
    if (target == null) {
        dir.deleteFile("target.blocks") catch |err| {
            if (err != error.FileNotFound) return err;
        };
        dir.deleteFile("target.pool") catch |err| {
            if (err != error.FileNotFound) return err;
        };
    }
    if (fixtures == null) {
        dir.deleteFile("fixture.blocks") catch |err| {
            if (err != error.FileNotFound) return err;
        };
        dir.deleteFile("fixture.pool") catch |err| {
            if (err != error.FileNotFound) return err;
        };
    }
    const initial = g.stats().occupied;
    const initial_slots = g.pool.items.len;
    try dir.writeFile(.{ .sub_path = "initial.blocks", .data = std.mem.sliceAsBytes(g.blocks) });
    try dir.writeFile(.{ .sub_path = "initial.pool", .data = std.mem.sliceAsBytes(g.pool.items) });
    const initial_write_ns = timer.lap();
    const reports = try a.alloc(OpReport, j.operations.len);
    defer a.free(reports);
    const frames = try a.alloc(Step, j.operations.len);
    defer a.free(frames);
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |name| a.free(name);
        names.deinit(a);
    }
    try names.ensureTotalCapacityPrecise(a, j.operations.len);
    var changes: e.Changes = .{};
    defer changes.deinit(a);
    var occupied = initial;
    var history_bytes: usize = 0;
    var playback_provenance = @import("provenance.zig").Index.initAllFrames(a, g);
    defer playback_provenance.deinit();
    var provenance_extract_ns: u64 = 0;
    var provenance_capacity_bytes: usize = 0;
    var provenance_entries: usize = 0;
    try progress.emit("ready", 0, null);
    for (j.operations, 0..) |op, index| {
        var shape: e.Shape = undefined;
        var toolpos: e.V = .{ 0, 0, 0 };
        var bound: f64 = 0;
        var shank: inspect.Contact = .{};
        var holder: inspect.Contact = .{};
        var sf: inspect.Contact = .{};
        var hf: inspect.Contact = .{};
        var cf: inspect.Contact = .{};
        var minutes: ?f64 = null;
        var arc_plan: ?motion.Plan = null;
        defer if (arc_plan) |plan| plan.deinit(a);
        timer.reset();
        if (op.turning) |t| {
            shape = try t.shape();
        } else if (op.rotary) |rotary_input| {
            const cutter = j.tools[op.tool.?].cutter;
            arc_plan = try motion.rotary(a, cutter, rotary_input, j.motion_tolerance_mm);
            shape = .{ .path = arc_plan.?.segments };
            bound = arc_plan.?.over_removal_bound_mm;
            toolpos = rotary_input.b.pose(cutter.length).position;
            if (fixtures) |f| cf = try inspect.collision(f, shape);
        } else if (op.arc) |arc_input| {
            arc_plan = try motion.arc(a, j.tools[op.tool.?].cutter, arc_input, j.motion_tolerance_mm);
            shape = .{ .path = arc_plan.?.segments };
            bound = arc_plan.?.over_removal_bound_mm;
            toolpos = motion.point(arc_input, 1);
            if (fixtures) |f| cf = try inspect.collision(f, shape);
        } else if (op.subtract) |p| {
            shape = .{ .primitive = p };
        } else {
            const tool = j.tools[op.tool.?];
            const line = op.line.?;
            const sweep = e.Sweep{ .tool = tool.cutter, .a = line.a, .b = line.b, .tolerance_mm = j.motion_tolerance_mm };
            shape = .{ .sweep = sweep };
            bound = sweep.errorBound();
            toolpos = line.b.position;
            shank = try contact(g, line, tool.shank);
            holder = try contact(g, line, tool.holder);
            if (fixtures) |f| {
                sf = try contact(f, line, tool.shank);
                hf = try contact(f, line, tool.holder);
                cf = try inspect.collision(f, shape);
            }
            if (op.feed_mm_min) |feed| minutes = e.norm(e.sub(line.b.position, line.a.position)) / feed;
        }
        const collision_ns = timer.lap();
        try e.subtract(&g, shape, &changes, reference);
        const cut_ns = timer.lap();
        if (j.export_provenance and j.provenance_scope == .all_frames)
            try playback_provenance.consumeFrame(g, changes.bytes.items, @intCast(index + 1), if (op.tool) |t| @intCast(t + 1) else 0);
        provenance_extract_ns += timer.lap();
        occupied -= changes.removed;
        const name = try std.fmt.allocPrint(a, "step-{d:0>4}.delta", .{index});
        names.appendAssumeCapacity(name);
        try dir.writeFile(.{ .sub_path = name, .data = changes.bytes.items });
        const history_ns = timer.lap();
        history_bytes += changes.bytes.items.len;
        const volume = @as(f64, @floatFromInt(changes.removed)) * g.h * g.h * g.h;
        reports[index] = .{ .work = changes.work, .id = op.id, .removed_voxels = changes.removed, .engagement_volume_mm3 = volume, .remaining_voxels = occupied, .affected_region = changes.affected, .motion_over_removal_bound_mm = bound, .sweep_pieces = if (arc_plan) |plan| plan.segments.len else 1, .cut_ns = cut_ns, .collision_ns = collision_ns, .history_write_ns = history_ns, .shank_stock = shank, .holder_stock = holder, .shank_fixture = sf, .holder_fixture = hf, .cutter_fixture = cf, .geometric_feed_time_min = minutes, .average_removal_mm3_min = if (minutes != null and minutes.? > 0) volume / minutes.? else null };
        frames[index] = .{ .file = name, .stage = op.id, .occupied = occupied, .changed_blocks = changes.blocks, .delta_bytes = changes.bytes.items.len, .tool = toolpos, .axis = if (op.line) |l| l.b.axis else if (op.arc) |arc| arc.axis else if (op.rotary) |r| r.b.axis() else .{ 0, 0, 1 }, .shank = if (op.tool) |t| j.tools[t].shank else null, .holder = if (op.tool) |t| j.tools[t].holder else null, .cutter = if (op.tool) |t| j.tools[t].cutter else null };
        if (hooks == null) std.debug.print("{s}: removed {d} voxels, {d:.3} ms\n", .{ op.id, changes.removed, @as(f64, @floatFromInt(cut_ns)) / 1e6 });
        try progress.emit("cutting", index + 1, op.id);
    }
    try progress.emit("finalizing", j.operations.len, null);
    timer.reset();
    const stats = g.stats();
    if (stats.occupied != occupied) return error.HistoryCountMismatch;
    const comparison = if (target) |t| try inspect.compare(g, t) else null;
    const stats_ns = timer.lap();
    if (j.export_defects) {
        const t = target orelse return error.DefectsRequireTarget;
        try writeDefects(a, dir, j, g, t);
    }
    const defects_ns = timer.lap();
    // Final-only extraction intersects final neighbors with recorded deltas.
    // Playback extraction already collected newly exposed neighbors per operation.
    if (j.export_provenance) {
        var final_provenance = if (j.provenance_scope == .final_surface) try @import("provenance.zig").Index.init(a, g) else @import("provenance.zig").Index.initAllFrames(a, g);
        defer final_provenance.deinit();
        const provenance = if (j.provenance_scope == .all_frames) &playback_provenance else &final_provenance;
        if (j.provenance_scope == .final_surface) for (names.items, j.operations, 0..) |name, op, index| {
            const delta = try dir.readFileAlloc(a, name, 1024 * 1024 * 1024);
            defer a.free(delta);
            try provenance.consume(delta, @intCast(index + 1), if (op.tool) |t| @intCast(t + 1) else 0);
        };
        provenance.sort();
        provenance_entries = provenance.entries.items.len;
        provenance_capacity_bytes = provenance.entries.capacity * @sizeOf(@import("provenance.zig").Entry);
        // Explicit little-endian wire encoding, independent of host struct padding.
        const provenance_bytes = try a.alloc(u8, try std.math.mul(usize, provenance.entries.items.len, 16));
        defer a.free(provenance_bytes);
        for (provenance.entries.items, 0..) |entry, i| {
            std.mem.writeInt(u64, provenance_bytes[i * 16 ..][0..8], entry.cell, .little);
            std.mem.writeInt(u32, provenance_bytes[i * 16 + 8 ..][0..4], entry.operation, .little);
            std.mem.writeInt(u32, provenance_bytes[i * 16 + 12 ..][0..4], entry.tool, .little);
        }
        try dir.writeFile(.{ .sub_path = "surface-provenance.bin", .data = provenance_bytes });
        try json(a, dir, "surface-provenance.json", .{ .format = "menkh-surface-provenance-v1", .scope = @tagName(j.provenance_scope), .grid = g.n, .origin_mm = g.origin, .voxel_mm = g.h, .final_occupied = occupied, .operations = j.operations, .entries = provenance.entries.items.len, .bytes = provenance_bytes.len, .record_bytes = 16, .initial_id = 0 });
    }
    const provenance_finalize_ns = timer.lap();
    const provenance_ns = provenance_finalize_ns + provenance_extract_ns;
    const point_results = try a.alloc(bool, j.points.len);
    defer a.free(point_results);
    for (j.points, 0..) |p, i| {
        try e.validV(p.point);
        point_results[i] = g.query(p.point);
    }
    const ray_results = try a.alloc(?inspect.Hit, j.rays.len);
    defer a.free(ray_results);
    for (j.rays, 0..) |r, i| ray_results[i] = try inspect.ray(g, r.origin, r.direction, r.max_distance_mm);
    for (j.sections, 0..) |s, i| {
        const pixels = try inspect.section(a, g, s);
        defer a.free(pixels);
        const name = try std.fmt.allocPrint(a, "section-{d}.ppm", .{i});
        defer a.free(name);
        var f = try dir.createFile(name, .{});
        defer f.close();
        var buf: [128]u8 = undefined;
        try f.writeAll(try std.fmt.bufPrint(&buf, "P6\n{d} {d}\n255\n", .{ s.width, s.height }));
        try f.writeAll(pixels);
    }
    const inspection_ns = timer.lap();
    var mesh: std.ArrayList(surface.Quad) = .empty;
    defer mesh.deinit(a);
    if (j.export_mesh) mesh = try surface.generate(a, g);
    const surface_ns = timer.lap();
    var surface_deviation: ?struct { samples: usize, max_abs_distance_mm: f64, mean_abs_distance_mm: f64, sampled_estimate: bool = true } = null;
    if (j.target) |t| if (t.primitives.len == 1 and mesh.items.len > 0) {
        var maximum: f64 = 0;
        var sum: f64 = 0;
        var samples: usize = 0;
        for (mesh.items) |q| {
            const u = (@as(usize, q.axis) + 1) % 3;
            const v = (@as(usize, q.axis) + 2) % 3;
            for ([_][2]f64{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 }, .{ 0.5, 0.5 } }) |offset| {
                var p: e.V = undefined;
                for (0..3) |axis| p[axis] = g.origin[axis] + @as(f64, @floatFromInt(q.p[axis])) * g.h;
                p[u] += offset[0] * @as(f64, @floatFromInt(q.width)) * g.h;
                p[v] += offset[1] * @as(f64, @floatFromInt(q.height)) * g.h;
                const d = @abs(t.primitives[0].distance(p));
                maximum = @max(maximum, d);
                sum += d;
                samples += 1;
            }
        }
        surface_deviation = .{ .samples = samples, .max_abs_distance_mm = maximum, .mean_abs_distance_mm = sum / @as(f64, @floatFromInt(samples)) };
    };
    const surface_analysis_ns = timer.lap();
    if (j.export_mesh) try surface.obj(g, mesh.items, dir);
    try surface.ppm(a, g, dir);
    const image_export_ns = timer.lap();
    const encoded = try state.encode(a, g);
    defer a.free(encoded);
    const checkpoint_encode_ns = timer.lap();
    try dir.writeFile(.{ .sub_path = "final.menkh", .data = encoded });
    const checkpoint_write_ns = timer.lap();
    const export_ns = image_export_ns + checkpoint_encode_ns + checkpoint_write_ns;
    try json(a, dir, "voxel-animation.json", .{ .format = "menkh-voxel-history-v1", .grid = g.n, .block_grid = g.nb, .origin_mm = g.origin, .voxel_mm = g.h, .stock_min = j.bounds.lo, .stock_max = j.bounds.hi, .initial_occupied = initial, .final_occupied = occupied, .initial_pool_slots = initial_slots, .pool_slots = g.pool.items.len, .motion_tolerance_mm = j.motion_tolerance_mm, .frames = frames });
    try json(a, dir, "report.json", .{ .format = "menkh-job-report-v1", .zig = builtin.zig_version_string, .mode = @tagName(builtin.mode), .workers = 1, .reference = reference, .input_voxel_mm = parsed.value.voxel_mm, .voxel_override_mm = voxel_override, .voxel_mm = g.h, .origin_mm = g.origin, .bounds = j.bounds, .raster_approximation = true, .initial_occupied = initial, .remaining_occupied = occupied, .remaining_volume_mm3 = @as(f64, @floatFromInt(occupied)) * g.h * g.h * g.h, .stats = stats, .history_bytes = history_bytes, .provenance_capacity_bytes = provenance_capacity_bytes, .provenance_entries = provenance_entries, .provenance_scope = if (j.export_provenance) @tagName(j.provenance_scope) else null, .cut_scratch_capacity_bytes = changes.coverage.capacity * @sizeOf(e.Coverage) + changes.flat_columns.capacity * @sizeOf(e.FlatColumn) + changes.bytes.capacity, .process_peak_rss_bytes = try @import("platform.zig").peakResidentBytes(), .timing = .{ .job_parse_validate_ns = job_parse_validate_ns, .image_export_ns = image_export_ns, .checkpoint_encode_ns = checkpoint_encode_ns, .checkpoint_write_ns = checkpoint_write_ns, .metadata_write_ns = timer.read(), .init_ns = init_ns, .stock_input = stock_input, .auxiliary_input = auxiliary_input, .auxiliary_voxelization_ns = auxiliary_ns, .initial_history_write_ns = initial_write_ns, .statistics_ns = stats_ns, .defects_ns = defects_ns, .provenance_ns = provenance_ns, .provenance_extract_ns = provenance_extract_ns, .provenance_finalize_ns = provenance_finalize_ns, .inspection_ns = inspection_ns, .surface_ns = surface_ns, .surface_analysis_ns = surface_analysis_ns, .export_ns = export_ns, .total_ns = total.read() }, .operations = reports, .target_comparison = comparison, .target_surface_deviation = surface_deviation, .point_occupancy = point_results, .ray_hits = ray_results });
    try progress.emit("complete", j.operations.len, null);
}

fn writeDefects(a: std.mem.Allocator, dir: std.fs.Dir, j: Job, g: c.Grid, target: c.Grid) !void {
    const regions = try @import("defects.zig").regions(a, g, target);
    defer a.free(regions);
    try json(a, dir, "defects.json", .{ .format = "menkh-defects-v1", .voxel_mm = g.h, .origin_mm = g.origin, .grid = g.n, .remaining_occupied = g.stats().occupied, .motion_tolerance_mm = j.motion_tolerance_mm, .connectivity = 6, .regions = regions });
}
// Reinspect a saved material state without rerunning any cuts or rewriting history.
pub fn inspectDefects(a: std.mem.Allocator, path: []const u8, input: []const u8, out: []const u8) !void {
    const bytes = try read(a, path);
    defer a.free(bytes);
    const parsed = try std.json.parseFromSlice(Job, a, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const j = parsed.value;
    try validate(a, j);
    const source = j.target orelse return error.DefectsRequireTarget;
    var timing: InputTiming = .{};
    var g = try initialize(a, j, .{ .state_file = input }, &timing, false);
    defer g.deinit();
    var target = try initialize(a, j, source, &timing, false);
    defer target.deinit();
    try std.fs.cwd().makePath(out);
    var dir = try std.fs.cwd().openDir(out, .{});
    defer dir.close();
    try writeDefects(a, dir, j, g, target);
}
