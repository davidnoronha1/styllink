//! Common Linux syscall wrappers and utilities for styllink.

const std = @import("std");
const linux = std.os.linux;

pub fn check(rc: usize, what: []const u8) usize {
    const e = linux.errno(rc);
    if (e != .SUCCESS) {
        std.debug.print("styllink: {s} failed: {s}\n", .{ what, @tagName(e) });
        if (std.mem.eql(u8, what, "open /dev/uinput"))
            std.debug.print("  -> run ./install-uinput-access.sh once (needs sudo)\n", .{});
        linux.exit(1);
    }
    return rc;
}

pub fn writeAll(fd: i32, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const rc = linux.write(fd, data.ptr + off, data.len - off);
        switch (linux.errno(rc)) {
            .SUCCESS => off += rc,
            .INTR => {},
            else => return false,
        }
    }
    return true;
}

pub fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Primary LAN address: "connect" a UDP socket (sends nothing) and read back
/// the source address the kernel picked.
pub fn lanAddr() ?[4]u8 {
    const fd: i32 = @intCast(check(linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0), "socket"));
    defer _ = linux.close(fd);
    var dst = linux.sockaddr.in{ .port = std.mem.nativeToBig(u16, 53), .addr = @bitCast([4]u8{ 1, 1, 1, 1 }) };
    if (linux.errno(linux.connect(fd, @ptrCast(&dst), @sizeOf(linux.sockaddr.in))) != .SUCCESS) return null;
    var me: linux.sockaddr.in = undefined;
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    if (linux.errno(linux.getsockname(fd, @ptrCast(&me), &len)) != .SUCCESS) return null;
    return @bitCast(me.addr);
}
