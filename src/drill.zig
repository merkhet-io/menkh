//! Standalone demonstration primitives. The original constant-Z end mill is unchanged.
const std = @import("std");
const core = @import("core.zig");
const surface = @import("surface.zig");
pub const steps = 96;
pub const facets = 32;
pub const cutter_radius = 3.3;
pub const Operation = union(enum) {
    cylinder,
    capsule: struct { a: [3]f64, b: [3]f64, radius: f64 },
    tip: f64,
    pub fn removes(op: Operation, p: [3]f64) bool {
        switch (op) {
            .cylinder => {
                const x = p[0] - 6;
                const y = p[1] - 6;
                return x * x + y * y > 36;
            },
            .tip => |angle| return (p[0] - 6) * @cos(angle) + (p[1] - 6) * @sin(angle) > 60 - p[2] + core.tolerance,
            .capsule => |c| {
                var length2: f64 = 0;
                var dot: f64 = 0;
                for (0..3) |i| {
                    const d = c.b[i] - c.a[i];
                    length2 += d * d;
                    dot += (p[i] - c.a[i]) * d;
                }
                const t = if (length2 == 0) 0 else std.math.clamp(dot / length2, 0, 1);
                var distance2: f64 = 0;
                for (0..3) |i| {
                    const d = p[i] - (c.a[i] + t * (c.b[i] - c.a[i]));
                    distance2 += d * d;
                }
                return distance2 <= (c.radius + core.tolerance) * (c.radius + core.tolerance);
            },
        }
    }
};
const engine = @import("engine.zig");
pub fn shape(op: Operation, offset: [3]f64) !engine.Shape {
    if (op == .capsule and (!std.math.isFinite(op.capsule.radius) or op.capsule.radius <= 0 or op.capsule.radius > 1e6)) return error.InvalidTool;
    return switch (op) {
        .cylinder => error.InitializationOnly,
        .capsule => |c| .{ .primitive = .{ .capsule = .{ .a = engine.add(c.a, offset), .b = engine.add(c.b, offset), .radius = c.radius } } },
        .tip => |angle| blk: {
            if (!std.math.isFinite(angle)) return error.InvalidCoordinate;
            const n = [3]f64{ @cos(angle), @sin(angle), 1 };
            const length = engine.norm(n);
            break :blk .{ .primitive = .{ .halfspace = .{ .normal = engine.scale(n, 1 / length), .offset = (60 + 6 * (n[0] + n[1]) + engine.dot(n, offset) + 4 * core.tolerance) / length } } };
        },
    };
}
pub fn apply(g: *core.Grid, op: Operation) !void {
    if (op == .cylinder) {
        var replacement = try engine.stock(g.allocator, .{ .lo = g.origin, .hi = engine.add(g.origin, g.size) }, g.h, &.{.{ .cylinder = .{ .base = .{ 6, 6, 0 }, .radius = 6, .length = 60 } }});
        std.mem.swap(core.Grid, g, &replacement);
        replacement.deinit();
        return;
    }
    var changes: engine.Changes = .{};
    defer changes.deinit(g.allocator);
    try engine.subtract(g, try shape(op, .{ 0, 0, 0 }), &changes, false);
}
pub fn point(flute: usize, t: f64) [3]f64 {
    const z = 16 + 46 * t;
    const angle = (z - 16) / 32 * 2 * std.math.pi + @as(f64, @floatFromInt(flute)) * std.math.pi;
    return .{ 6 + 5.4 * @cos(angle), 6 + 5.4 * @sin(angle), z };
}
const Frame = struct { file: []const u8, stage: []const u8, occupied: u64, tool: [3]f64, quads: usize };
fn saveFrame(a: std.mem.Allocator, g: core.Grid, dir: std.fs.Dir, index: usize, stage: []const u8, tool: [3]f64) !Frame {
    var mesh = try surface.generate(a, g);
    defer mesh.deinit(a);
    const name = try std.fmt.allocPrint(a, "frame-{d:0>4}.mq", .{index});
    errdefer a.free(name);
    const bytes = try a.alloc(u8, try std.math.mul(usize, mesh.items.len, 12));
    defer a.free(bytes);
    for (mesh.items, 0..) |q, i| {
        const row = bytes[i * 12 ..][0..12];
        const values = [5]usize{ q.p[0], q.p[1], q.p[2], q.width, q.height };
        for (values, 0..) |v, j| {
            if (v > 65535) return error.MeshTooLarge;
            std.mem.writeInt(u16, row[j * 2 ..][0..2], @intCast(v), .little);
        }
        row[10] = q.axis;
        row[11] = @intFromBool(q.positive);
    }
    try dir.writeFile(.{ .sub_path = name, .data = bytes });
    return .{ .file = name, .stage = stage, .occupied = g.stats().occupied, .tool = tool, .quads = mesh.items.len };
}
pub fn run(a: std.mem.Allocator, h: f64, out: []const u8) !void {
    if (!std.math.isFinite(h) or h < 0.1 or h > 0.5) return error.DemoVoxelRangeIsPointOneToPointFive;
    var timer = try std.time.Timer.start();
    var g = try core.Grid.init(a, .{ 12, 12, 60 }, h);
    defer g.deinit();
    try apply(&g, .cylinder);
    try std.fs.cwd().makePath(out);
    var dir = try std.fs.cwd().openDir(out, .{});
    defer dir.close();
    var frames: std.ArrayList(Frame) = .empty;
    defer {
        for (frames.items) |f| a.free(f.file);
        frames.deinit(a);
    }
    try frames.ensureTotalCapacityPrecise(a, 1 + 2 * steps + facets);
    frames.appendAssumeCapacity(try saveFrame(a, g, dir, 0, "Zylindrisches Rohteil", point(0, 0)));
    for (0..2) |flute| for (0..steps) |i| {
        const from = point(flute, @as(f64, @floatFromInt(i)) / steps);
        const to = point(flute, @as(f64, @floatFromInt(i + 1)) / steps);
        try apply(&g, .{ .capsule = .{ .a = from, .b = to, .radius = cutter_radius } });
        frames.appendAssumeCapacity(try saveFrame(a, g, dir, frames.items.len, if (flute == 0) "Spannut 1 fräsen" else "Spannut 2 fräsen", to));
    };
    for (0..facets) |i| {
        const angle = @as(f64, @floatFromInt(i)) / facets * 2 * std.math.pi;
        try apply(&g, .{ .tip = angle });
        frames.appendAssumeCapacity(try saveFrame(a, g, dir, frames.items.len, "Spitze facettieren", .{ 6 + 7 * @cos(angle), 6 + 7 * @sin(angle), 57 }));
    }
    for (frames.items[1..], frames.items[0 .. frames.items.len - 1]) |next, previous| if (next.occupied > previous.occupied) return error.MaterialIncreased;
    var mesh = try surface.generate(a, g);
    defer mesh.deinit(a);
    try surface.obj(g, mesh.items, dir);
    const manifest = try std.json.Stringify.valueAlloc(a, .{ .format = "menkh-quads-v1", .voxel_mm = h, .radius_mm = 6, .length_mm = 60, .cutter_radius_mm = cutter_radius, .fps = 12, .geometric_demo = true, .description = "Voxelabtrag: zwei helikale Nuten mit kugelförmigem Fräskopf, danach 32 ebene Spitzen-Facetten. Keine NC-/Schneidenfreigabe.", .generation_ns = timer.read(), .grid_bytes = g.stats().descriptor_bytes + g.stats().pool_bytes, .frames = frames.items }, .{ .whitespace = .indent_2 });
    defer a.free(manifest);
    try dir.writeFile(.{ .sub_path = "animation.json", .data = manifest });
    std.debug.print("Drill demo: {d} frames, {d} occupied voxels, {d:.2} s, {s}/animation.json\n", .{ frames.items.len, g.stats().occupied, @as(f64, @floatFromInt(timer.read())) / 1e9, out });
}
