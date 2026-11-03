//! Platform-independent clocks and secure random bytes.

const std = @import("std");

/// Monotonic nanoseconds excluding suspend time.
pub fn nowNs(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).toNanoseconds());
}

pub fn randomBytes(io: std.Io, out: []u8) void {
    std.Io.randomSecure(io, out) catch |err|
        std.debug.panic("secure random bytes: {t}", .{err});
}

test "nowNs shares a clock domain across threads" {
    const Worker = struct {
        fn read(io: std.Io, out: *u64) void {
            out.* = nowNs(io);
        }
    };
    const io = std.testing.io;
    const before = nowNs(io);
    var worker_time: u64 = undefined;
    const thread = try std.Thread.spawn(.{}, Worker.read, .{ io, &worker_time });
    thread.join();
    try std.testing.expect(before <= worker_time and worker_time <= nowNs(io));
}

pub fn fatal(err: anyerror, operation: []const u8) noreturn {
    std.debug.print("styllink: {s}: {t}\n", .{ operation, err });
    std.process.exit(1);
}
