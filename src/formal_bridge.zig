//! Differential checks against the executable Lean specification. These tests
//! connect the model to production APIs; they are not a formal Zig refinement.
const std = @import("std");
const core = @import("core.zig");
const engine = @import("engine.zig");

test "Lean corpus agrees with Zig masks, addresses, subtraction and exact rational sweeps" {
    const a = std.testing.allocator;
    const data = try std.fs.cwd().readFileAlloc(a, "out/formal-oracle.txt", 8 * 1024 * 1024);
    defer a.free(data);
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    var counts = [_]usize{ 0, 0, 0, 0 };
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const tag = fields.next() orelse return error.InvalidCorpus;
        if (std.mem.eql(u8, tag, "M")) {
            const ex = try number(usize, &fields);
            const ey = try number(usize, &fields);
            const ez = try number(usize, &fields);
            const z = try number(usize, &fields);
            const expected = try number(u64, &fields);
            var g = try core.Grid.init(a, .{ @floatFromInt(ex), @floatFromInt(ey), @floatFromInt(ez) }, 1);
            defer g.deinit();
            try std.testing.expectEqual(expected, g.validBits(.{ 0, 0, 0 })[z]);
            // Full descriptors and materialized descriptors must agree, including edges.
            const bits = g.bits(0);
            try g.pool.append(a, bits);
            g.blocks[0] = 0;
            try std.testing.expectEqual(@as(u64, @intCast(ex * ey * ez)), g.stats().occupied);
            for (0..8) |x| for (0..8) |y| {
                try std.testing.expectEqual(x < ex and y < ey and z < ez, g.occupied(.{ x, y, z }));
            };
            counts[0] += 1;
        } else if (std.mem.eql(u8, tag, "B")) {
            _ = try number(usize, &fields);
            const z = try number(usize, &fields);
            const word = try number(u64, &fields);
            const mask = try number(u64, &fields);
            const expected = try number(u64, &fields);
            try std.testing.expectEqual(expected, word & ~mask);
            var pop: u64 = 0;
            for (0..64) |bit| pop += (expected >> @as(u6, @intCast(bit))) & 1;
            try std.testing.expectEqual(pop, @as(u64, @popCount(word & ~mask)));
            var g = try core.Grid.init(a, .{ 8, 8, 8 }, 1);
            defer g.deinit();
            var bits: core.Bits = @splat(0);
            bits[z] = expected;
            try g.pool.append(a, bits);
            g.blocks[0] = 0;
            try std.testing.expectEqual(pop, g.stats().occupied);
            counts[1] += 1;
        } else if (std.mem.eql(u8, tag, "I")) {
            const i = try number(usize, &fields);
            const block = try number(usize, &fields);
            const local = try number(usize, &fields);
            try std.testing.expectEqual(i, block * 8 + local);
            try std.testing.expectEqual(block, i / 8);
            try std.testing.expectEqual(local, i % 8);
            counts[2] += 1;
        } else if (std.mem.eql(u8, tag, "G")) {
            var v: [6]f64 = undefined;
            for (&v) |*x| x.* = @as(f64, @floatFromInt(try number(i32, &fields))) / 4;
            const hit = (try number(u8, &fields)) == 1;
            const s = engine.Sweep{ .tool = .{ .radius = 2, .length = 3 }, .a = .{ .position = .{ 0, 0, 0 } }, .b = .{ .position = .{ v[3], v[4], v[5] } } };
            try s.validate();
            try std.testing.expectEqual(hit, s.flatContains(.{ v[0], v[1], v[2] }, 0));
            if (engine.FlatZ.init(s)) |kernel| {
                const got = kernel.contains8(.{ @splat(v[0]), @splat(v[1]), @splat(v[2]) });
                for (0..8) |lane| try std.testing.expectEqual(hit, got[lane]);
            }
            counts[3] += 1;
        } else return error.InvalidCorpus;
        if (fields.next() != null) return error.InvalidCorpus;
    }
    try std.testing.expectEqualSlices(usize, &.{ 4096, 4096, 8192, 4096 }, &counts);
}
fn number(comptime T: type, fields: anytype) !T {
    return std.fmt.parseInt(T, fields.next() orelse return error.InvalidCorpus, 10);
}
