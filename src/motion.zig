//! Bounded planar circular/helical centerlines at fixed tool orientation.
const std = @import("std");
const e = @import("engine.zig");
pub const Arc = struct { center: e.V, u: e.V = .{ 1, 0, 0 }, v: e.V = .{ 0, 1, 0 }, radius: f64, start_angle: f64, sweep_angle: f64, rise: f64 = 0, axis: e.V = .{ 0, 0, 1 } };
pub const Plan = struct {
    segments: []e.Sweep,
    over_removal_bound_mm: f64,
    chord_error_mm: f64,
    pub fn deinit(p: Plan, a: std.mem.Allocator) void {
        a.free(p.segments);
    }
};
pub fn arc(a: std.mem.Allocator, tool: e.Tool, input: Arc, tolerance: f64) !Plan {
    try tool.validate();
    try e.validV(input.center);
    try e.unit(input.u);
    try e.unit(input.v);
    try e.unit(input.axis);
    if (@abs(e.dot(input.u, input.v)) > 1e-10 or !std.math.isFinite(input.radius) or input.radius <= 0 or input.radius > 1e6 or !std.math.isFinite(input.start_angle) or @abs(input.start_angle) > 1e6 or !std.math.isFinite(input.sweep_angle) or @abs(input.sweep_angle) > 64 * std.math.pi or input.sweep_angle == 0 or !std.math.isFinite(input.rise) or @abs(input.rise) > 1e6 or !std.math.isFinite(tolerance) or tolerance <= 0) return error.InvalidArc;
    // chord <= tolerance/4; additive pose bound <= tolerance/4. For flat tools
    // radial+axial dilation overestimates Euclidean dilation by at most sqrt(2).
    const angle = @min(@as(f64, std.math.pi / 4.0), 2 * std.math.acos(std.math.clamp(1 - tolerance / (4 * input.radius), -1, 1)));
    if (angle == 0) return error.MotionToleranceTooSmall;
    const count_f = @ceil(@abs(input.sweep_angle) / angle);
    if (count_f > 100000) return error.MotionToleranceTooSmall;
    const n: usize = @max(1, @as(usize, @intFromFloat(count_f)));
    const chord = input.radius * (1 - @cos(@abs(input.sweep_angle) / (2 * @as(f64, @floatFromInt(n)))));
    const segments = try a.alloc(e.Sweep, n);
    errdefer a.free(segments);
    var bound: f64 = 0;
    for (segments, 0..) |*s, i| {
        s.* = .{ .tool = tool, .a = .{ .position = point(input, @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n))), .axis = input.axis }, .b = .{ .position = point(input, @as(f64, @floatFromInt(i + 1)) / @as(f64, @floatFromInt(n))), .axis = input.axis }, .tolerance_mm = tolerance / 4, .dilation_mm = chord };
        try s.validate();
        bound = @max(bound, s.errorBound() + chord);
    }
    return .{ .segments = segments, .over_removal_bound_mm = bound, .chord_error_mm = chord };
}
pub fn point(p: Arc, t: f64) e.V {
    const angle = p.start_angle + t * p.sweep_angle;
    return e.add(p.center, e.add(e.scale(p.u, p.radius * @cos(angle)), e.add(e.scale(p.v, p.radius * @sin(angle)), e.scale(e.cross(p.u, p.v), p.rise * t))));
}
pub const Turning = struct {
    spindle_origin: e.V,
    spindle_axis: e.V = .{ 0, 0, 1 },
    mode: enum { longitudinal, facing },
    radial_start: f64,
    radial_end: f64,
    axial_start: f64,
    axial_end: f64,
    insert_radial_width: f64,
    insert_axial_width: f64,
    pub fn shape(t: Turning) !e.Shape {
        try e.validV(t.spindle_origin);
        try e.unit(t.spindle_axis);
        for ([_]f64{ t.radial_start, t.radial_end, t.axial_start, t.axial_end, t.insert_radial_width, t.insert_axial_width }) |v| if (!std.math.isFinite(v) or @abs(v) > 1e6) return error.InvalidTurning;
        if (t.radial_start < 0 or t.radial_end < 0 or t.insert_radial_width <= 0 or t.insert_axial_width <= 0) return error.InvalidTurning;
        switch (t.mode) {
            .longitudinal => if (t.radial_start != t.radial_end) return error.UnsupportedTurningMotion,
            .facing => if (t.axial_start != t.axial_end) return error.UnsupportedTurningMotion,
        }
        const low = @min(t.axial_start, t.axial_end);
        const high = @max(t.axial_start, t.axial_end) + t.insert_axial_width;
        const s = e.Shape{ .primitive = .{ .annulus = .{ .base = e.add(t.spindle_origin, e.scale(t.spindle_axis, low)), .axis = t.spindle_axis, .inner = @min(t.radial_start, t.radial_end), .outer = @max(t.radial_start, t.radial_end) + t.insert_radial_width, .length = high - low } } };
        try s.validate();
        return s;
    }
};
