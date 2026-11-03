//! Error handling for the Linux-specific operations without an Io equivalent.

const std = @import("std");
const linux = std.os.linux;
pub const nowNs = @import("../util.zig").nowNs;

pub fn checkErrno(rc: usize, what: []const u8) usize {
    const e = linux.errno(rc);
    if (e != .SUCCESS) {
        std.debug.print("styllink: {s} failed: {s}\n", .{ what, @tagName(e) });
        if (std.mem.eql(u8, what, "open /dev/uinput"))
            std.debug.print("  -> run make install-uinput-access once (needs sudo)\n", .{});
        std.process.exit(1);
    }
    return rc;
}

test "nowNs stays monotonic in the Linux timer clock domain" {
    var before: linux.timespec = undefined;
    var after: linux.timespec = undefined;
    _ = checkErrno(linux.clock_gettime(.MONOTONIC, &before), "test monotonic clock");
    const first = nowNs(std.testing.io);
    const second = nowNs(std.testing.io);
    _ = checkErrno(linux.clock_gettime(.MONOTONIC, &after), "test monotonic clock");
    const lower = @as(u64, @intCast(before.sec)) * std.time.ns_per_s + @as(u64, @intCast(before.nsec));
    const upper = @as(u64, @intCast(after.sec)) * std.time.ns_per_s + @as(u64, @intCast(after.nsec));
    try std.testing.expect(lower <= first and first <= second and second <= upper);
}
