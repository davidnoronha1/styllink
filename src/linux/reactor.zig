//! Readiness primitives for the allocation-free pen/video loops. std.Io's
//! stream API has no readiness-only poll operation; epoll/timerfd stay here.
const std = @import("std");
const linux = std.os.linux;
const types = @import("../platform/types.zig");
pub const Handle = std.Io.File.Handle;
pub const invalid_handle: Handle = -1;

pub const Reactor = struct {
    fd: Handle = invalid_handle,
    pub fn init() !Reactor {
        const rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return error.CreateReactor;
        return .{ .fd = @intCast(rc) };
    }
    fn flags(interest: types.Interest) u32 {
        return (if (interest.readable) @as(u32, linux.EPOLL.IN | linux.EPOLL.RDHUP) else 0) |
            (if (interest.writable) @as(u32, linux.EPOLL.OUT) else 0);
    }
    pub fn add(self: Reactor, handle: Handle, interest: types.Interest, tag: u64) void {
        var ev = linux.epoll_event{ .events = flags(interest), .data = .{ .u64 = tag } };
        _ = linux.epoll_ctl(self.fd, linux.EPOLL.CTL_ADD, handle, &ev);
    }
    pub fn modify(self: Reactor, handle: Handle, interest: types.Interest, tag: u64) void {
        var ev = linux.epoll_event{ .events = flags(interest), .data = .{ .u64 = tag } };
        _ = linux.epoll_ctl(self.fd, linux.EPOLL.CTL_MOD, handle, &ev);
    }
    pub fn remove(self: Reactor, handle: Handle) void {
        if (self.fd >= 0) _ = linux.epoll_ctl(self.fd, linux.EPOLL.CTL_DEL, handle, null);
    }
    pub fn wait(self: Reactor, events: []types.Event, busy: bool) ![]types.Event {
        var raw: [64]linux.epoll_event = undefined;
        const rc = linux.epoll_wait(self.fd, &raw, @intCast(@min(raw.len, events.len)), if (busy) 0 else -1);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => return events[0..0],
            else => return error.WaitReactor,
        }
        for (raw[0..rc], events[0..rc]) |e, *out| out.* = .{
            .tag = e.data.u64,
            .readable = e.events & linux.EPOLL.IN != 0,
            .writable = e.events & linux.EPOLL.OUT != 0,
            .closed = e.events & (linux.EPOLL.HUP | linux.EPOLL.ERR | linux.EPOLL.RDHUP) != 0,
        };
        return events[0..rc];
    }
    pub fn deinit(self: *Reactor, io: std.Io) void {
        if (self.fd >= 0) (std.Io.File{ .handle = self.fd, .flags = .{ .nonblocking = false } }).close(io);
        self.fd = invalid_handle;
    }
};

pub const Timer = struct {
    handle: Handle = invalid_handle,
    pub fn init() !Timer {
        const rc = linux.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true });
        if (linux.errno(rc) != .SUCCESS) return error.CreateTimer;
        return .{ .handle = @intCast(rc) };
    }
    pub fn arm(self: Timer, delay_ns: u64, repeat_ns: u64) void {
        const spec = linux.itimerspec{
            .it_interval = .{ .sec = @intCast(repeat_ns / std.time.ns_per_s), .nsec = @intCast(repeat_ns % std.time.ns_per_s) },
            .it_value = .{ .sec = @intCast(delay_ns / std.time.ns_per_s), .nsec = @intCast(delay_ns % std.time.ns_per_s) },
        };
        _ = linux.timerfd_settime(self.handle, .{}, &spec, null);
    }
    pub fn consume(self: Timer, io: std.Io) void {
        var count: u64 = 0;
        const file = std.Io.File{ .handle = self.handle, .flags = .{ .nonblocking = true } };
        _ = file.readStreaming(io, &.{std.mem.asBytes(&count)}) catch {};
    }
    pub fn deinit(self: *Timer, io: std.Io) void {
        if (self.handle >= 0) (std.Io.File{ .handle = self.handle, .flags = .{ .nonblocking = true } }).close(io);
        self.handle = invalid_handle;
    }
};

test "reactor reports timer and channel readiness through portable events" {
    const io = std.testing.io;
    const Channel = @import("io.zig").Channel;
    var reactor = try Reactor.init();
    defer reactor.deinit(io);
    var timer = try Timer.init();
    defer timer.deinit(io);
    reactor.add(timer.handle, .{ .readable = true }, 7);
    timer.arm(std.time.ns_per_ms, 0);
    var events: [2]types.Event = undefined;
    var ready = try reactor.wait(&events, false);
    try std.testing.expectEqual(@as(usize, 1), ready.len);
    try std.testing.expectEqual(@as(u64, 7), ready[0].tag);
    try std.testing.expect(ready[0].readable);
    timer.consume(io);
    reactor.remove(timer.handle);
    var channel = try Channel.init();
    defer channel.deinit(io);
    reactor.add(channel.read_handle, .{ .readable = true }, 11);
    try std.testing.expect(channel.send(io, 42));
    ready = try reactor.wait(&events, false);
    try std.testing.expectEqual(@as(u64, 11), ready[0].tag);
    try std.testing.expectEqual(@as(Handle, 42), try channel.receive(io));
}
