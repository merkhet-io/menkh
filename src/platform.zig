//! OS memory accounting kept outside the simulation core.
const std = @import("std");
const builtin = @import("builtin");
pub fn peakResidentBytes() !usize {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        return (try windows.GetProcessMemoryInfo(windows.GetCurrentProcess())).PeakWorkingSetSize;
    }
    const rss: usize = @intCast(std.posix.getrusage(std.posix.rusage.SELF).maxrss);
    return if (builtin.os.tag == .macos) rss else try std.math.mul(usize, rss, 1024);
}
