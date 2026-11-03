//! Linux scheduling and signal setup for the event loops.
const std = @import("std");
const linux = std.os.linux;

pub fn prepare() void {
    const ign = linux.Sigaction{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(.PIPE, &ign, null);
}
pub fn normalPriority() void {
    const param = linux.sched_param{ .priority = 0 };
    _ = linux.sched_setscheduler(0, .{ .mode = .NORMAL }, &param);
}

pub fn setRealtime() void {
    const param = linux.sched_param{ .priority = 50 };
    const sched_rc = linux.sched_setscheduler(0, .{ .mode = .FIFO }, &param);
    if (linux.errno(sched_rc) == .SUCCESS) {
        std.debug.print("styllink: priority set to SCHED_FIFO 50\n", .{});
        return;
    }
    const prio_rc = linux.syscall3(.setpriority, 0, 0, @as(usize, @bitCast(@as(isize, -20))));
    if (linux.errno(prio_rc) == .SUCCESS) {
        std.debug.print("styllink: priority set to nice -20\n", .{});
        return;
    }
    std.debug.print("styllink: notice: unable to set realtime or high priority (run with CAP_SYS_NICE or sudo)\n", .{});
}
