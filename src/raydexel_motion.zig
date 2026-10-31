//! Continuous-motion coverage for the experimental conic interval solver.
const std = @import("std");
const e = @import("engine.zig");
const d = @import("raydexel.zig");
const motion = @import("motion.zig");
pub const Bound = struct { total_mm: f64 = 0, numerical_guard_mm: f64, poses: usize = 0 };
pub fn append(a: std.mem.Allocator, poses: *std.ArrayList(d.Pose), profile: d.Profile, tool: e.Tool, line: motion.RotaryLine, tolerance: f64) !Bound {
    const guard = (1 + tool.radius + tool.length) * 1e-8;
    if (!std.math.isFinite(tolerance) or tolerance <= guard * profile.miter) return error.MotionToleranceTooSmall;
    const planning_tolerance = (tolerance - guard * profile.miter) / profile.miter;
    const plan = try motion.rotary(a, tool, line, planning_tolerance);
    defer plan.deinit(a);
    var count: usize = 0;
    for (plan.segments) |s| count = try std.math.add(usize, count, s.samples());
    if (try std.math.add(usize, poses.items.len, count) > 5_000_000) return error.TooManyRayPoses;
    try poses.ensureUnusedCapacity(a, count);
    var bound = Bound{ .numerical_guard_mm = guard, .poses = count };
    for (plan.segments) |s| {
        const n = s.samples();
        const movement = e.sub(s.b.position, s.a.position);
        const half_gap = e.norm(movement) / (2 * @as(f64, @floatFromInt(n)));
        const offset = s.dilation_mm + half_gap + guard;
        // A midpoint-offset tool contains the whole local translation/rotation.
        // Its distance to the actual midpoint-oriented cutter is <= miter*offset;
        // restoring the true midpoint orientation costs at most dilation again.
        bound.total_mm = @max(bound.total_mm, s.dilation_mm + profile.miter * offset);
        for (0..n) |i| {
            const t = (@as(f64, @floatFromInt(i)) + 0.5) / @as(f64, @floatFromInt(n));
            poses.appendAssumeCapacity(try d.Pose.init(profile, .{ .position = e.add(s.a.position, e.scale(movement, t)), .axis = s.a.axis }, offset));
        }
    }
    if (bound.total_mm > tolerance + 1e-12) return error.MotionBudgetExceeded;
    return bound;
}

/// Direct true-time midpoint poses. Axis path speed of a solid of revolution
/// is sqrt(A'² + sin²(A)*C'²); spin about that axis has no geometric effect.
/// Every true pose is within delta of its interval midpoint pose. Therefore
/// its conic offset covers continuous motion and over-removes by <= miter*delta.
pub fn appendAxisymmetric(a: std.mem.Allocator, poses: *std.ArrayList(d.Pose), profile: d.Profile, tool: e.Tool, line: motion.RotaryLine, tolerance: f64) !Bound {
    try tool.validate();
    try line.a.validate();
    try line.b.validate();
    const guard = (1 + tool.radius + tool.length) * 1e-8;
    if (!std.math.isFinite(tolerance) or tolerance <= guard * profile.miter) return error.MotionToleranceTooSmall;
    const radians = std.math.pi / 180.0;
    const da = @abs(line.b.a_deg - line.a.a_deg) * radians;
    const dc = @abs(line.b.c_deg - line.a.c_deg) * radians;
    const lo = @min(line.a.a_deg, line.b.a_deg) * radians;
    const hi = @max(line.a.a_deg, line.b.a_deg) * radians;
    var max_sin = @max(@abs(@sin(lo)), @abs(@sin(hi)));
    if (@ceil((lo - std.math.pi / 2.0) / std.math.pi) <= @floor((hi - std.math.pi / 2.0) / std.math.pi)) max_sin = 1;
    const angular = @sqrt(da * da + max_sin * max_sin * dc * dc);
    const rho = @sqrt(tool.radius * tool.radius + tool.length * tool.length / 4);
    const displacement = rho * angular + e.norm(e.sub(line.b.position, line.a.position));
    const nf = @ceil(profile.miter * displacement / (2 * (tolerance - guard * profile.miter)));
    if (!std.math.isFinite(nf) or nf > 5_000_000) return error.TooManyRayPoses;
    const n = @max(@as(usize, 1), @as(usize, @intFromFloat(nf)));
    if (try std.math.add(usize, poses.items.len, n) > 5_000_000) return error.TooManyRayPoses;
    const offset = displacement / (2 * @as(f64, @floatFromInt(n))) + guard;
    const bound = Bound{ .total_mm = profile.miter * offset, .numerical_guard_mm = guard, .poses = n };
    if (bound.total_mm > tolerance + 1e-12) return error.MotionBudgetExceeded;
    try poses.ensureUnusedCapacity(a, n);
    for (0..n) |i| {
        const actual = line.at((@as(f64, @floatFromInt(i)) + 0.5) / @as(f64, @floatFromInt(n)));
        const axis = actual.axis();
        poses.appendAssumeCapacity(try d.Pose.init(profile, .{ .position = e.sub(actual.position, e.scale(axis, tool.length / 2)), .axis = axis }, offset));
    }
    return bound;
}
