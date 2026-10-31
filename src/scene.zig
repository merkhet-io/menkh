//! Static scene ownership and placement. Material remains in ordinary job grids.
const std = @import("std");
const e = @import("engine.zig");
const jobs = @import("job.zig");
pub const Geometry = struct { id: []const u8, source: jobs.Stock };
pub const Tool = struct { id: []const u8, assembly: jobs.Assembly };
pub const Role = enum { workpiece, fixture, target };
pub const Object = struct {
    id: []const u8,
    role: Role,
    geometry: []const u8,
    translation_mm: e.V = .{ 0, 0, 0 },
    bounds: ?e.Bounds = null, // workpiece-local grid bounds
    target: ?[]const u8 = null,
    fixtures: []const []const u8 = &.{},
};
pub const Operation = struct {
    id: []const u8,
    workpiece: []const u8,
    tool: ?[]const u8 = null,
    line: ?jobs.Line = null, // scene coordinates; fixed orientation
    subtract: ?e.Primitive = null, // scene coordinates
};
pub const Scene = struct {
    format: []const u8,
    version: u32,
    units: []const u8,
    voxel_mm: f64,
    motion_tolerance_mm: f64 = 0.02,
    geometries: []const Geometry,
    objects: []const Object,
    tools: []const Tool = &.{},
    operations: []const Operation,
    export_mesh: bool = false,
    export_provenance: bool = true,
    provenance_scope: @FieldType(jobs.Job, "provenance_scope") = .all_frames,
};
pub const Compiled = struct { object_id: []const u8, translation_mm: e.V, job: jobs.Job };
fn index(items: anytype, id: []const u8) !usize {
    for (items, 0..) |item, i| if (std.mem.eql(u8, item.id, id)) return i;
    return error.UnknownSceneId;
}
fn ids(items: anytype) !void {
    for (items, 0..) |item, i| {
        if (item.id.len == 0 or item.id.len > 128 or !std.unicode.utf8ValidateSlice(item.id)) return error.InvalidSceneId;
        for (items[0..i]) |old| if (std.mem.eql(u8, old.id, item.id)) return error.DuplicateSceneId;
    }
}
pub fn translated(p: e.Primitive, delta: e.V) !e.Primitive {
    try p.validate();
    try e.validV(delta);
    var result = p;
    switch (result) {
        .box => |*v| {
            v.lo = e.add(v.lo, delta);
            v.hi = e.add(v.hi, delta);
        },
        .sphere => |*v| v.center = e.add(v.center, delta),
        .cylinder => |*v| v.base = e.add(v.base, delta),
        .annulus => |*v| v.base = e.add(v.base, delta),
        .capsule => |*v| {
            v.a = e.add(v.a, delta);
            v.b = e.add(v.b, delta);
        },
        .halfspace => |*v| v.offset += e.dot(v.normal, delta),
    }
    try result.validate();
    return result;
}
fn source(a: std.mem.Allocator, value: jobs.Stock, delta: e.V) !jobs.Stock {
    var result = value;
    if (value.primitives.len > 0) {
        const primitives = try a.alloc(e.Primitive, value.primitives.len);
        for (value.primitives, primitives) |p, *out| out.* = try translated(p, delta);
        result.primitives = primitives;
    }
    if (result.stl) |*mesh| {
        mesh.translation = e.add(mesh.translation, delta);
        try e.validV(mesh.translation);
    }
    if (result.state_file != null and !std.mem.eql(f64, &delta, &e.V{ 0, 0, 0 })) return error.TranslatedAuxiliaryStateUnsupported;
    return result;
}
/// Allocations belong to the caller's arena. No grids are created or mutated here.
pub fn compile(a: std.mem.Allocator, s: Scene) ![]Compiled {
    if (!std.mem.eql(u8, s.format, "menkh-scene-v1") or s.version != 1) return error.UnsupportedSceneVersion;
    if (!std.mem.eql(u8, s.units, "mm")) return error.UnitsMustBeMillimeters;
    if (!std.math.isFinite(s.voxel_mm) or s.voxel_mm <= 0) return error.InvalidVoxelSize;
    try ids(s.objects);
    try ids(s.geometries);
    try ids(s.tools);
    try ids(s.operations);
    for (s.geometries) |geometry| {
        const v = geometry.source;
        if (@as(usize, @intFromBool(v.primitives.len > 0)) + @intFromBool(v.stl != null) + @intFromBool(v.state_file != null) != 1) return error.ChooseOneStockSource;
        for (v.primitives) |p| try p.validate();
    }
    var count: usize = 0;
    for (s.objects) |object| {
        try e.validV(object.translation_mm);
        _ = try index(s.geometries, object.geometry);
        if (object.role == .workpiece) {
            try (object.bounds orelse return error.WorkpieceBoundsRequired).validate();
            count += 1;
        } else if (object.bounds != null or object.target != null or object.fixtures.len != 0) return error.InvalidSceneComponents;
    }
    if (count == 0) return error.SceneNeedsWorkpiece;
    for (s.operations) |op| {
        if (s.objects[try index(s.objects, op.workpiece)].role != .workpiece) return error.OperationNeedsWorkpiece;
        if (op.tool) |id| _ = try index(s.tools, id);
    }
    const tools = try a.alloc(jobs.Assembly, s.tools.len);
    for (s.tools, tools) |t, *out| out.* = t.assembly;
    const result = try a.alloc(Compiled, count);
    var cursor: usize = 0;
    for (s.objects) |object| {
        if (object.role != .workpiece) continue;
        var j = jobs.Job{ .version = 1, .units = "mm", .bounds = object.bounds.?, .voxel_mm = s.voxel_mm, .stock = s.geometries[try index(s.geometries, object.geometry)].source, .tools = tools, .operations = &.{}, .motion_tolerance_mm = s.motion_tolerance_mm, .export_mesh = s.export_mesh, .export_provenance = s.export_provenance, .provenance_scope = s.provenance_scope };
        if (object.target) |id| {
            const target = s.objects[try index(s.objects, id)];
            if (target.role != .target) return error.TargetRoleRequired;
            j.target = try source(a, s.geometries[try index(s.geometries, target.geometry)].source, e.sub(target.translation_mm, object.translation_mm));
        }
        var fixtures: std.ArrayList(e.Primitive) = .empty;
        for (object.fixtures, 0..) |id, i| {
            for (object.fixtures[0..i]) |previous| if (std.mem.eql(u8, id, previous)) return error.DuplicateFixtureBinding;
            const fixture = s.objects[try index(s.objects, id)];
            if (fixture.role != .fixture) return error.FixtureRoleRequired;
            const geometry = s.geometries[try index(s.geometries, fixture.geometry)].source;
            if (geometry.primitives.len == 0) return error.SceneFixtureRequiresPrimitives;
            const delta = e.sub(fixture.translation_mm, object.translation_mm);
            for (geometry.primitives) |p| {
                const placed = try translated(p, delta);
                const bounds = placed.bounds();
                for (0..3) |axis| if (bounds.lo[axis] < j.bounds.lo[axis] or bounds.hi[axis] > j.bounds.hi[axis]) return error.FixtureOutsideWorkpieceGrid;
                try fixtures.append(a, placed);
            }
        }
        if (fixtures.items.len > 0) j.fixtures = .{ .primitives = fixtures.items };
        var operations: std.ArrayList(jobs.Operation) = .empty;
        for (s.operations) |op| {
            if (!std.mem.eql(u8, op.workpiece, object.id)) continue;
            var local = jobs.Operation{ .id = op.id, .tool = if (op.tool) |id| try index(s.tools, id) else null, .line = op.line };
            if (local.line) |*line| {
                try e.validV(line.a.position);
                try e.validV(line.b.position);
                line.a.position = e.sub(line.a.position, object.translation_mm);
                line.b.position = e.sub(line.b.position, object.translation_mm);
            }
            if (op.subtract) |p| local.subtract = try translated(p, e.scale(object.translation_mm, -1));
            try operations.append(a, local);
        }
        j.operations = operations.items;
        try jobs.validate(a, j);
        result[cursor] = .{ .object_id = object.id, .translation_mm = object.translation_mm, .job = j };
        cursor += 1;
    }
    return result;
}
fn writeJson(a: std.mem.Allocator, dir: std.fs.Dir, name: []const u8, value: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{ .whitespace = .indent_2 });
    defer a.free(bytes);
    try dir.writeFile(.{ .sub_path = name, .data = bytes });
}
pub fn run(parent: std.mem.Allocator, input: []const u8, output: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(parent);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try std.fs.cwd().readFileAlloc(a, input, 64 * 1024 * 1024);
    const parsed = try std.json.parseFromSlice(Scene, a, bytes, .{});
    defer parsed.deinit();
    const compiled = try compile(a, parsed.value);
    // A failed scene never leaves an apparently complete scene manifest. Earlier
    // object runs remain inspectable, but the scene itself is not transactional.
    if (std.fs.path.dirname(output)) |parent_path| try std.fs.cwd().makePath(parent_path);
    try std.fs.cwd().makeDir(output);
    var dir = try std.fs.cwd().openDir(output, .{});
    defer dir.close();
    const base = try std.fs.path.resolve(a, &.{std.fs.path.dirname(input) orelse "."});
    const Result = struct { object_id: []const u8, translation_mm: e.V, history: []const u8, state: []const u8 };
    const results = try a.alloc(Result, compiled.len);
    for (compiled, results, 0..) |item, *result, i| {
        const name = try std.fmt.allocPrint(a, "workpiece-{d:0>4}", .{i});
        const job_name = try std.fmt.allocPrint(a, "{s}.json", .{name});
        try writeJson(a, dir, job_name, item.job);
        const path = try std.fs.path.join(a, &.{ output, job_name });
        const destination = try std.fs.path.join(a, &.{ output, name });
        try jobs.runControlled(parent, path, destination, false, null, null, base, null, null);
        result.* = .{ .object_id = item.object_id, .translation_mm = item.translation_mm, .history = try std.fmt.allocPrint(a, "{s}/voxel-animation.json", .{name}), .state = try std.fmt.allocPrint(a, "{s}/final.menkh", .{name}) };
    }
    try writeJson(a, dir, "scene.json", .{ .format = "menkh-scene-result-v1", .units = "mm", .objects = parsed.value.objects, .tools = parsed.value.tools, .operations = parsed.value.operations, .results = results });
}
