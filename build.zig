const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_arch = .aarch64, .os_tag = .macos, .cpu_model = .native } });
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{ .name = "menkh", .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize }) });
    b.installArtifact(exe);
    const viewer = b.addSystemCommand(&.{ "sh", "scripts/build-viewer.sh" });
    b.step("viewer", "Build standalone native macOS viewer (requires Apple Swift)").dependOn(&viewer.step);
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/tests.zig"), .target = target, .optimize = optimize }) });
    b.step("test", "Run core and surface tests").dependOn(&b.addRunArtifact(tests).step);
    inline for (.{ "demo", "bench", "export", "drill" }) |name| {
        const run = b.addRunArtifact(exe);
        run.addArg(name);
        if (b.args) |args| run.addArgs(args);
        b.step(name, "Run " ++ name).dependOn(&run.step);
    }
}
