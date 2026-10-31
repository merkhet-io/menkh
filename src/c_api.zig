//! A small synchronous C boundary around real supported operations. See menkh.h.
const std = @import("std");
const e = @import("engine.zig");
const c = @import("core.zig");
const state = @import("state.zig");
const motion = @import("motion.zig");
const allocator = std.heap.c_allocator;
const Status = enum(c_int) { ok = 0, invalid_argument = 1, out_of_memory = 2, unsupported = 3, invalid_state = 4, buffer_too_small = 5, resource_limit = 6 };
const Box = extern struct { origin: [3]f64, size: [3]f64, voxel_mm: f64 };
const Tool = extern struct { kind: u32, radius_mm: f64, length_mm: f64 };
const Pose = extern struct { position: [3]f64, axis: [3]f64 };
const XYZAC = extern struct { position: [3]f64, a_deg: f64, c_deg: f64 };
const Report = extern struct { removed_voxels: u64, remaining_voxels: u64, removed_volume_mm3: f64, motion_over_removal_bound_mm: f64, sweep_pieces: u64 };
const Handle = struct { grid: c.Grid, changes: e.Changes = .{}, occupied: u64 };
fn failure(err: anyerror) Status {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.OrientationChangeUnsupported, error.RotaryRequiresCylinder => .unsupported,
        error.MotionToleranceTooSmall, error.PoolTooLarge, error.Overflow, error.GridTooLargeOrEmpty => .resource_limit,
        else => .invalid_argument,
    };
}
fn tool(t: Tool) !e.Tool {
    const value = e.Tool{ .kind = switch (t.kind) {
        0 => .flat,
        1 => .ball,
        else => return error.RotaryRequiresCylinder,
    }, .radius = t.radius_mm, .length = t.length_mm };
    try value.validate();
    return value;
}
export fn menkh_abi_version() u32 {
    return 1;
}
export fn menkh_status_message(status: c_int) [*:0]const u8 {
    return switch (status) {
        0 => "success",
        1 => "invalid argument",
        2 => "allocation failed",
        3 => "unsupported operation",
        4 => "invalid material state",
        5 => "output buffer too small",
        6 => "resource or subdivision limit exceeded",
        else => "unknown status",
    };
}
export fn menkh_create_box_v1(input: ?*const Box, output: ?*?*Handle) Status {
    return createBox(allocator, input, output);
}
fn createBox(alloc: std.mem.Allocator, input: ?*const Box, output: ?*?*Handle) Status {
    const out = output orelse return .invalid_argument;
    out.* = null;
    const b = input orelse return .invalid_argument;
    e.validV(b.origin) catch |err| return failure(err);
    const bounds = e.Bounds{ .lo = b.origin, .hi = e.add(b.origin, b.size) };
    var g = e.stock(alloc, bounds, b.voxel_mm, &.{.{ .box = bounds }}) catch |err| return failure(err);
    const h = alloc.create(Handle) catch {
        g.deinit();
        return .out_of_memory;
    };
    h.* = .{ .grid = g, .occupied = g.stats().occupied };
    out.* = h;
    return .ok;
}
export fn menkh_destroy_v1(handle: ?*Handle) void {
    const h = handle orelse return;
    const alloc = h.grid.allocator;
    h.changes.deinit(alloc);
    h.grid.deinit();
    alloc.destroy(h);
}
fn cut(h: *Handle, shape: e.Shape, bound: f64, pieces: usize, report: *Report) Status {
    e.subtract(&h.grid, shape, &h.changes, false) catch |err| return failure(err);
    h.occupied -= h.changes.removed;
    report.* = .{ .removed_voxels = h.changes.removed, .remaining_voxels = h.occupied, .removed_volume_mm3 = @as(f64, @floatFromInt(h.changes.removed)) * h.grid.h * h.grid.h * h.grid.h, .motion_over_removal_bound_mm = bound, .sweep_pieces = pieces };
    return .ok;
}
export fn menkh_cut_line_v1(handle: ?*Handle, input: ?*const Tool, from: ?*const Pose, to: ?*const Pose, tolerance: f64, output: ?*Report) Status {
    const h = handle orelse return .invalid_argument;
    const t = input orelse return .invalid_argument;
    const p = from orelse return .invalid_argument;
    const q = to orelse return .invalid_argument;
    const report = output orelse return .invalid_argument;
    const cutter = tool(t.*) catch |err| return failure(err);
    const sweep = e.Sweep{ .tool = cutter, .a = .{ .position = p.position, .axis = p.axis }, .b = .{ .position = q.position, .axis = q.axis }, .tolerance_mm = tolerance };
    sweep.validate() catch |err| return failure(err);
    return cut(h, .{ .sweep = sweep }, sweep.errorBound(), 1, report);
}
export fn menkh_cut_xyzac_v1(handle: ?*Handle, input: ?*const Tool, from: ?*const XYZAC, to: ?*const XYZAC, tolerance: f64, output: ?*Report) Status {
    const h = handle orelse return .invalid_argument;
    const t = input orelse return .invalid_argument;
    const p = from orelse return .invalid_argument;
    const q = to orelse return .invalid_argument;
    const report = output orelse return .invalid_argument;
    const cutter = tool(t.*) catch |err| return failure(err);
    const plan = motion.rotary(h.grid.allocator, cutter, .{ .a = .{ .position = p.position, .a_deg = p.a_deg, .c_deg = p.c_deg }, .b = .{ .position = q.position, .a_deg = q.a_deg, .c_deg = q.c_deg } }, tolerance) catch |err| return failure(err);
    defer plan.deinit(h.grid.allocator);
    return cut(h, .{ .path = plan.segments }, plan.over_removal_bound_mm, plan.segments.len, report);
}
export fn menkh_query_v1(handle: ?*const Handle, position: ?*const [3]f64, output: ?*u32) Status {
    const h = handle orelse return .invalid_argument;
    const p = position orelse return .invalid_argument;
    const out = output orelse return .invalid_argument;
    e.validV(p.*) catch |err| return failure(err);
    out.* = @intFromBool(h.grid.query(p.*));
    return .ok;
}
export fn menkh_count_v1(handle: ?*const Handle, output: ?*u64) Status {
    const h = handle orelse return .invalid_argument;
    const out = output orelse return .invalid_argument;
    out.* = h.occupied;
    return .ok;
}
export fn menkh_state_write_v1(handle: ?*const Handle, buffer: ?[*]u8, capacity: usize, written: ?*usize) Status {
    const h = handle orelse return .invalid_argument;
    const out = written orelse return .invalid_argument;
    const descriptors = std.math.mul(usize, h.grid.blocks.len, 4) catch return .resource_limit;
    const pool = std.math.mul(usize, h.grid.pool.items.len, 64) catch return .resource_limit;
    const payload = std.math.add(usize, descriptors, pool) catch return .resource_limit;
    out.* = std.math.add(usize, 96, payload) catch return .resource_limit;
    if (capacity < out.*) return .buffer_too_small;
    const dest = buffer orelse return .invalid_argument;
    const bytes = state.encode(h.grid.allocator, h.grid) catch |err| return failure(err);
    defer h.grid.allocator.free(bytes);
    @memcpy(dest[0..bytes.len], bytes);
    return .ok;
}
export fn menkh_state_read_v1(buffer: ?[*]const u8, size: usize, output: ?*?*Handle) Status {
    return readState(allocator, buffer, size, output);
}
fn readState(alloc: std.mem.Allocator, buffer: ?[*]const u8, size: usize, output: ?*?*Handle) Status {
    const out = output orelse return .invalid_argument;
    out.* = null;
    const bytes = buffer orelse return .invalid_argument;
    if (size > 1024 * 1024 * 1024) return .resource_limit;
    var g = state.decode(alloc, bytes[0..size]) catch |err| return if (err == error.OutOfMemory) .out_of_memory else .invalid_state;
    const h = alloc.create(Handle) catch {
        g.deinit();
        return .out_of_memory;
    };
    h.* = .{ .grid = g, .occupied = g.stats().occupied };
    out.* = h;
    return .ok;
}

fn statusOrError(s: Status) !void {
    if (s == .out_of_memory) return error.OutOfMemory;
    try std.testing.expectEqual(Status.ok, s);
}
fn allocationCase(alloc: std.mem.Allocator) !void {
    var h: ?*Handle = null;
    const box = Box{ .origin = .{ 0, 0, 0 }, .size = .{ 4, 3, 1 }, .voxel_mm = 0.1 };
    try statusOrError(createBox(alloc, &box, &h));
    defer menkh_destroy_v1(h);
    const cutter = Tool{ .kind = 0, .radius_mm = 0.3, .length_mm = 1 };
    const from = Pose{ .position = .{ 1, 1.5, 0.6 }, .axis = .{ 0, 0, 1 } };
    const to = Pose{ .position = .{ 3, 1.5, 0.6 }, .axis = .{ 0, 0, 1 } };
    var report: Report = undefined;
    const status = menkh_cut_line_v1(h, &cutter, &from, &to, 0.01, &report);
    if (status != .ok) {
        try std.testing.expectEqual(@as(u64, 12000), h.?.grid.stats().occupied);
        try statusOrError(status);
    }
    var size: usize = 0;
    try std.testing.expectEqual(Status.buffer_too_small, menkh_state_write_v1(h, null, 0, &size));
    const bytes = try alloc.alloc(u8, size);
    defer alloc.free(bytes);
    try statusOrError(menkh_state_write_v1(h, bytes.ptr, size, &size));
    var resumed: ?*Handle = null;
    try statusOrError(readState(alloc, bytes.ptr, size, &resumed));
    defer menkh_destroy_v1(resumed);
    try std.testing.expectEqual(h.?.occupied, resumed.?.occupied);
}
test "C boundary allocations and failed-cut atomicity" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
