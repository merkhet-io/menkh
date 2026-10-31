//! Completed-operation windows. Locks lease lazy history files to readers.
//! Publication is optional; neither slots nor control files affect occupancy.
const std = @import("std");
const c = @import("core.zig");
const provenance = @import("provenance.zig");
pub const Options = struct {
    start_paused: bool = false,
    history_operations: usize = 32,
    publish_every_operations: usize = 8,
    min_publish_ms: u64 = 100,
    max_snapshot_bytes: usize = 128 * 1024 * 1024,
    max_provenance_bytes: usize = 32 * 1024 * 1024,
    max_asset_bytes: usize = 256 * 1024 * 1024,
    pub fn validate(o: Options) !void {
        if (o.max_provenance_bytes < 16 or o.max_provenance_bytes > 1024 * 1024 * 1024 or o.max_asset_bytes < 16 or o.max_asset_bytes > 1024 * 1024 * 1024) return error.InvalidLiveOptions;
        if (o.history_operations == 0 or o.history_operations > 256 or o.publish_every_operations == 0 or o.publish_every_operations > o.history_operations or o.min_publish_ms > 60000 or o.max_snapshot_bytes < 4096 or o.max_snapshot_bytes > 1024 * 1024 * 1024) return error.InvalidLiveOptions;
    }
};
pub const Publisher = struct {
    a: std.mem.Allocator,
    dir: std.fs.Dir,
    options: Options,
    blocks: []u8 = &.{},
    pool: std.ArrayList(u8) = .empty,
    base: usize = 0,
    occupied: u64 = 0,
    slot: ?usize = null,
    sequence: usize = 0,
    skipped: usize = 0,
    write_ns: u64 = 0,
    peak_payload_bytes: usize = 0,
    clock: std.time.Timer,
    exposure: ?provenance.Index = null,
    tool_count: usize = 0,
    asset_bytes: usize = 0,
    exposure_ns: u64 = 0,
    encoding_peak_bytes: usize = 0,

    pub fn init(a: std.mem.Allocator, parent: std.fs.Dir, options: Options, g: c.Grid, occupied: u64) !Publisher {
        try options.validate();
        // A prior reader may still lease files: never reuse another run's channel.
        try parent.makeDir("live");
        const clock = try std.time.Timer.start();
        var p: Publisher = .{ .a = a, .dir = try parent.openDir("live", .{}), .options = options, .clock = clock };
        errdefer p.deinit();
        try p.rebase(g, 0, occupied);
        if (options.start_paused) try p.dir.writeFile(.{ .sub_path = "pause", .data = "" });
        return p;
    }
    pub fn deinit(p: *Publisher) void {
        if (p.exposure) |*index| index.deinit();
        p.a.free(p.blocks);
        p.pool.deinit(p.a);
        p.dir.close();
    }
    fn rebase(p: *Publisher, g: c.Grid, completed: usize, occupied: u64) !void {
        const blocks = std.mem.sliceAsBytes(g.blocks);
        const pool = std.mem.sliceAsBytes(g.pool.items);
        if (try std.math.add(usize, blocks.len, pool.len) > p.options.max_snapshot_bytes) return error.LiveSnapshotTooLarge;
        if (p.blocks.len == 0) p.blocks = try p.a.alloc(u8, blocks.len);
        try p.pool.ensureTotalCapacityPrecise(p.a, pool.len);
        p.pool.items.len = pool.len;
        @memcpy(p.blocks, blocks);
        @memcpy(p.pool.items, pool);
        p.base = completed;
        p.occupied = occupied;
        if (p.exposure) |*index| index.retainBoundary(g);
    }
    pub fn configure(p: *Publisher, g: c.Grid, colors: bool, tools: usize, target: ?c.Grid, fixtures: ?c.Grid) !void {
        p.tool_count = tools;
        if (colors) {
            p.exposure = provenance.Index.initAllFrames(p.a, g);
            p.exposure.?.max_entries = p.options.max_provenance_bytes / 16;
        }
        for ([_]?c.Grid{ target, fixtures }) |grid| if (grid) |v| {
            p.asset_bytes = try std.math.add(usize, p.asset_bytes, try std.math.add(usize, try std.math.mul(usize, v.blocks.len, 4), try std.math.mul(usize, v.pool.items.len, 64)));
        };
        if (p.asset_bytes > p.options.max_asset_bytes) return error.LiveAssetsTooLarge;
        if (target == null and fixtures == null) return;
        var dest = try p.dir.makeOpenPath("assets", .{});
        defer dest.close();
        for ([_]?c.Grid{ target, fixtures }, [_][]const u8{ "target", "fixture" }) |grid, name| if (grid) |v| {
            const block_name = try std.fmt.allocPrint(p.a, "{s}.blocks", .{name});
            defer p.a.free(block_name);
            const pool_name = try std.fmt.allocPrint(p.a, "{s}.pool", .{name});
            defer p.a.free(pool_name);
            try dest.writeFile(.{ .sub_path = block_name, .data = std.mem.sliceAsBytes(v.blocks) });
            try dest.writeFile(.{ .sub_path = pool_name, .data = std.mem.sliceAsBytes(v.pool.items) });
        };
    }
    pub fn observe(p: *Publisher, g: c.Grid, bytes: []const u8, operation: usize, tool: usize, occupied: u64) !void {
        var timer = try std.time.Timer.start();
        defer p.exposure_ns += timer.read();
        if (operation - p.base > p.options.history_operations) try p.rebase(g, operation, occupied);
        if (p.exposure) |*index| try index.consumeFrame(g, bytes, @intCast(operation), @intCast(tool));
    }
    pub fn exists(p: Publisher, name: []const u8) !bool {
        p.dir.access(name, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }
    pub fn control(p: *Publisher, completed: usize, total: usize, hooks: anytype) !void {
        const paused = try p.exists("pause");
        if (paused) try atomicJson(p.a, p.dir, "status.json", .{ .state = "paused", .completed_operations = completed });
        while (true) {
            if (try p.exists("cancel")) return error.Cancelled;
            if (!try p.exists("pause")) {
                if (paused) try atomicJson(p.a, p.dir, "status.json", .{ .state = "running", .completed_operations = completed });
                return;
            }
            if (hooks) |h| if (h.callback(h.context, if (completed == 0) 6 else 3, completed, total) != 0) return error.Cancelled;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }
    pub fn publish(p: *Publisher, parent: std.fs.Dir, g: c.Grid, frames: anytype, reports: anytype, occupied: u64, tolerance: f64, total: usize, force: bool) !void {
        var timer = try std.time.Timer.start();
        defer p.write_ns += timer.read();
        const completed = frames.len;
        if (completed - p.base > p.options.history_operations) try p.rebase(g, completed, occupied);
        if (!force and (completed % p.options.publish_every_operations != 0 or p.clock.read() / std.time.ns_per_ms < p.options.min_publish_ms)) return;
        var payload = try std.math.add(usize, p.blocks.len, p.pool.items.len);
        for (frames[p.base..]) |frame| payload = try std.math.add(usize, payload, frame.delta_bytes);
        // Retention is shortened explicitly in the published operation range.
        if (payload > p.options.max_snapshot_bytes) {
            try p.rebase(g, completed, occupied);
            payload = p.blocks.len + p.pool.items.len;
        }
        for (0..3) |slot| {
            if (p.slot == slot) continue; // Keep the last completed publication intact.
            var name_buf: [32]u8 = undefined;
            const lock_name = try std.fmt.bufPrint(&name_buf, "slot-{d}.lock", .{slot});
            // Acquire while opening: Zig 0.15.2 File.tryLock has an invalid
            // Windows .none return branch. CreateFlags supports both platforms.
            const lock = p.dir.createFile(lock_name, .{ .read = true, .truncate = false, .lock = .exclusive, .lock_nonblocking = true }) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            defer lock.close();
            var slot_buf: [32]u8 = undefined;
            const slot_name = try std.fmt.bufPrint(&slot_buf, "slot-{d}", .{slot});
            try removeSlot(p.dir, slot_name);
            var dest = try p.dir.makeOpenPath(slot_name, .{});
            defer dest.close();
            try dest.writeFile(.{ .sub_path = "initial.blocks", .data = p.blocks });
            try dest.writeFile(.{ .sub_path = "initial.pool", .data = p.pool.items });
            for (frames[p.base..]) |frame| try parent.copyFile(frame.file, dest, frame.file, .{});
            const findings = try std.json.Stringify.valueAlloc(p.a, .{ .format = "menkh-job-report-v1", .voxel_mm = g.h, .origin_mm = g.origin, .remaining_occupied = occupied, .first_operation = p.base, .operations = reports[p.base..] }, .{});
            defer p.a.free(findings);
            payload = try std.math.add(usize, payload, findings.len);
            try dest.writeFile(.{ .sub_path = "report.json", .data = findings });
            if (p.exposure) |*index| {
                index.sort();
                const bytes = try p.a.alloc(u8, try std.math.mul(usize, index.entries.items.len, 16));
                defer p.a.free(bytes);
                p.encoding_peak_bytes = @max(p.encoding_peak_bytes, bytes.len);
                for (index.entries.items, 0..) |entry, i| {
                    std.mem.writeInt(u64, bytes[i * 16 ..][0..8], entry.cell, .little);
                    std.mem.writeInt(u32, bytes[i * 16 + 8 ..][0..4], entry.operation, .little);
                    std.mem.writeInt(u32, bytes[i * 16 + 12 ..][0..4], entry.tool, .little);
                }
                const header = try std.json.Stringify.valueAlloc(p.a, .{ .format = "menkh-live-provenance-v1", .scope = "all_frames", .grid = g.n, .origin_mm = g.origin, .voxel_mm = g.h, .final_occupied = occupied, .entries = index.entries.items.len, .bytes = bytes.len, .record_bytes = 16, .initial_id = 0, .first_operation = p.base, .completed_operations = completed, .tool_count = p.tool_count }, .{});
                defer p.a.free(header);
                payload = try std.math.add(usize, payload, try std.math.add(usize, bytes.len, header.len));
                if (payload > p.options.max_snapshot_bytes) return error.LiveSnapshotTooLarge;
                try dest.writeFile(.{ .sub_path = "surface-provenance.bin", .data = bytes });
                try dest.writeFile(.{ .sub_path = "surface-provenance.json", .data = header });
            }
            const metadata = .{ .format = "menkh-voxel-history-v1", .grid = g.n, .block_grid = g.nb, .origin_mm = g.origin, .voxel_mm = g.h, .stock_min = g.origin, .stock_max = @import("engine.zig").add(g.origin, g.size), .initial_occupied = p.occupied, .final_occupied = occupied, .initial_pool_slots = p.pool.items.len / 64, .pool_slots = g.pool.items.len, .motion_tolerance_mm = tolerance, .frames = frames[p.base..], .live_sequence = p.sequence + 1, .live_assets = p.asset_bytes > 0, .first_operation = p.base, .completed_operations = completed, .total_operations = total };
            const encoded = try std.json.Stringify.valueAlloc(p.a, metadata, .{});
            defer p.a.free(encoded);
            payload = try std.math.add(usize, payload, encoded.len);
            if (payload > p.options.max_snapshot_bytes) return error.LiveSnapshotTooLarge;
            try atomicBytes(dest, "voxel-animation.json", encoded);
            try atomicJson(p.a, p.dir, "latest.json", .{ .version = 1, .sequence = p.sequence + 1, .slot = slot, .first_operation = p.base, .completed_operations = completed, .total_operations = total, .payload_bytes = payload, .base_capacity_bytes = p.blocks.len + p.pool.capacity, .asset_bytes = p.asset_bytes, .provenance_capacity_bytes = if (p.exposure) |index| index.entries.capacity * 16 else 0, .skipped_publications = p.skipped });
            p.slot = slot;
            p.sequence += 1;
            p.peak_payload_bytes = @max(p.peak_payload_bytes, payload);
            p.clock.reset();
            return;
        }
        p.skipped += 1; // All reusable slots leased: bounded, nonblocking backpressure.
    }
};
// Slots contain only regular files. Zig 0.15.2 deleteTree reserves sixteen
// directory iterators on the stack (>1 MiB on Windows), overflowing a default
// MSVC worker thread. One iterator avoids that cost and never follows a nested
// directory or symlink. The caller holds the exclusive slot lease.
fn removeSlot(parent: std.fs.Dir, name: []const u8) !void {
    {
        var dir = parent.openDir(name, .{ .iterate = true, .no_follow = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) return error.InvalidLiveSlotContents;
            try dir.deleteFile(entry.name);
        }
    }
    try parent.deleteDir(name);
}

test "live slot cleanup is flat and rejects nested contents" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try removeSlot(temp.dir, "absent");
    try temp.dir.makeDir("slot");
    try temp.dir.writeFile(.{ .sub_path = "slot/initial.blocks", .data = "data" });
    try temp.dir.writeFile(.{ .sub_path = "slot/temporary", .data = "partial" });
    try removeSlot(temp.dir, "slot");
    try std.testing.expectError(error.FileNotFound, temp.dir.access("slot", .{}));
    try temp.dir.makePath("slot/unexpected");
    try temp.dir.writeFile(.{ .sub_path = "slot/unexpected/keep", .data = "intact" });
    try std.testing.expectError(error.InvalidLiveSlotContents, removeSlot(temp.dir, "slot"));
    try temp.dir.access("slot/unexpected/keep", .{});
}

pub fn atomicJson(a: std.mem.Allocator, dir: std.fs.Dir, name: []const u8, value: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
    defer a.free(bytes);
    try atomicBytes(dir, name, bytes);
}
fn atomicBytes(dir: std.fs.Dir, name: []const u8, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var file = try dir.atomicFile(name, .{ .write_buffer = &buffer });
    defer file.deinit();
    try file.file_writer.interface.writeAll(bytes);
    try file.flush();
    var retries: usize = 0;
    while (true) {
        const renamed = if (@import("builtin").os.tag == .windows) renameWindows(&file) else file.renameIntoPlace();
        renamed catch |err| {
            // Windows readers may briefly open a pointer without DELETE sharing.
            // Keep the old pointer intact and bound retries; persistent errors fail.
            if (@import("builtin").os.tag == .windows and (err == error.AccessDenied or err == error.WouldBlock) and retries < 20) {
                retries += 1;
                std.Thread.sleep(std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        break;
    }
}

// Zig 0.15.2 renameatW maps STATUS_SHARING_VIOLATION to Unexpected.
// Keep directory-relative NT paths, but expose that specific retryable status.
// Never retry an arbitrary Unexpected error or resolve against the process CWD.
fn renameWindows(file: *std.fs.AtomicFile) !void {
    const w = std.os.windows;
    if (file.file_open) {
        file.file_writer.file.close();
        file.file_open = false;
    }
    const temporary = std.fmt.hex(file.random_integer);
    const source = try w.sliceToPrefixedFileW(file.dir.fd, &temporary);
    const destination = try w.sliceToPrefixedFileW(file.dir.fd, file.dest_basename);
    const handle = try w.OpenFile(source.span(), .{
        .dir = file.dir.fd,
        .access_mask = w.SYNCHRONIZE | w.GENERIC_WRITE | w.DELETE,
        .creation = w.FILE_OPEN,
    });
    defer w.CloseHandle(handle);
    // These internal destination basenames are latest.json, status.json or
    // voxel-animation.json; retain an explicit bound rather than truncating.
    var storage: [@sizeOf(w.FILE_RENAME_INFORMATION) + 255 * 2]u8 align(@alignOf(w.FILE_RENAME_INFORMATION)) = undefined;
    if (destination.len > 255) return error.NameTooLong;
    const info: *w.FILE_RENAME_INFORMATION = @ptrCast(&storage);
    info.* = .{ .Flags = w.TRUE, .RootDirectory = file.dir.fd, .FileNameLength = @intCast(destination.len * 2), .FileName = undefined };
    @memcpy((&info.FileName).ptr, destination.span());
    var io: w.IO_STATUS_BLOCK = undefined;
    const status = w.ntdll.NtSetInformationFile(handle, &io, info, @intCast(@sizeOf(w.FILE_RENAME_INFORMATION) - 1 + destination.len * 2), .FileRenameInformation);
    switch (status) {
        .SUCCESS => file.file_exists = false,
        .SHARING_VIOLATION => return error.WouldBlock,
        .ACCESS_DENIED => return error.AccessDenied,
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => return error.FileNotFound,
        .OBJECT_NAME_COLLISION => return error.PathAlreadyExists,
        else => return w.unexpectedStatus(status),
    }
}

test "Windows pointer replacement preserves old file during a sharing conflict" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const w = std.os.windows;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try atomicBytes(temp.dir, "latest.json", "old");
    var buffer: [32]u8 = undefined;
    var pending = try temp.dir.atomicFile("latest.json", .{ .write_buffer = &buffer });
    defer pending.deinit();
    try pending.file_writer.interface.writeAll("new");
    try pending.flush();
    {
        const held = try w.OpenFile(std.unicode.utf8ToUtf16LeStringLiteral("latest.json"), .{
            .dir = temp.dir.fd,
            .access_mask = w.GENERIC_READ | w.SYNCHRONIZE,
            .share_access = w.FILE_SHARE_READ | w.FILE_SHARE_WRITE,
            .creation = w.FILE_OPEN,
        });
        defer w.CloseHandle(held);
        if (renameWindows(&pending)) |_| {
            return error.ExpectedSharingConflict;
        } else |err| {
            try std.testing.expect(err == error.WouldBlock or err == error.AccessDenied);
        }
        const old = try temp.dir.readFileAlloc(a, "latest.json", 16);
        defer a.free(old);
        try std.testing.expectEqualStrings("old", old);
        try std.testing.expect(pending.file_exists);
    }
    try renameWindows(&pending);
    try std.testing.expect(!pending.file_exists);
    const new = try temp.dir.readFileAlloc(a, "latest.json", 16);
    defer a.free(new);
    try std.testing.expectEqualStrings("new", new);
}
