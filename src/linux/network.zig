//! Linux socket tuning and optional diagnostics. Protocols live in the core.
const std = @import("std");
const linux = std.os.linux;
const types = @import("../platform/types.zig");
const handles = @import("io.zig");
pub fn peer(fd: handles.Handle) [4]u8 {
    var sa: linux.sockaddr.in = undefined;
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    return if (linux.errno(linux.getpeername(fd, @ptrCast(&sa), &len)) == .SUCCESS) @bitCast(sa.addr) else .{ 0, 0, 0, 0 };
}
/// Io's reuse_address also enables SO_REUSEPORT. The public Io API cannot
/// request REUSEADDR alone, so this adapter preserves exclusive port ownership
/// and hands the resulting socket back to Io for accepting and cleanup.
pub fn listen(io: std.Io, port: u16) !std.Io.net.Server {
    const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.CreateListener;
    const fd: handles.Handle = @intCast(rc);
    errdefer handles.close(io, fd);
    const one: i32 = 1;
    if (linux.errno(linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), 4)) != .SUCCESS) return error.ConfigureListener;
    var address = linux.sockaddr.in{ .port = std.mem.nativeToBig(u16, port), .addr = 0 };
    switch (linux.errno(linux.bind(fd, @ptrCast(&address), @sizeOf(linux.sockaddr.in)))) {
        .SUCCESS => {},
        .ADDRINUSE => return error.AddressInUse,
        else => return error.BindListener,
    }
    while (true) switch (linux.errno(linux.listen(fd, 128))) {
        .SUCCESS => break,
        .INTR => continue,
        .ADDRINUSE => return error.AddressInUse,
        else => return error.Listen,
    };
    return .{ .socket = .{ .handle = fd, .address = try std.Io.net.IpAddress.parseIp4("0.0.0.0", port) }, .options = {} };
}

pub fn tunePen(fd: handles.Handle) void {
    const one: i32 = 1;
    _ = linux.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, std.mem.asBytes(&one), 4);
    const tos: i32 = 0xb8;
    _ = linux.setsockopt(fd, linux.IPPROTO.IP, 1, std.mem.asBytes(&tos), 4);
    const size: i32 = 65536;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVBUF, std.mem.asBytes(&size), 4);
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.SNDBUF, std.mem.asBytes(&size), 4);
}
pub fn tuneVideo(fd: handles.Handle) void {
    const tos: i32 = 0x88;
    _ = linux.setsockopt(fd, linux.IPPROTO.IP, 1, std.mem.asBytes(&tos), 4);
    const size: i32 = 2 << 20;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.SNDBUF, std.mem.asBytes(&size), 4);
    handles.nonblocking(fd);
}
pub fn quickAck(fd: handles.Handle) void {
    const one: i32 = 1;
    _ = linux.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.QUICKACK, std.mem.asBytes(&one), 4);
}

pub fn tcpInfo(fd: handles.Handle) ?types.TcpInfo {
    var raw: [256]u8 align(8) = @splat(0);
    var len: linux.socklen_t = raw.len;
    if (linux.errno(linux.getsockopt(fd, linux.IPPROTO.TCP, linux.TCP.INFO, &raw, &len)) != .SUCCESS) return null;
    if (len < 228) return null;
    const r = struct {
        fn u(b: *const [256]u8, off: usize) u32 {
            return std.mem.readInt(u32, b[off..][0..4], .little);
        }
    }.u;
    return .{ .rto_us = r(&raw, 8), .rtt_us = r(&raw, 68), .total_retrans = r(&raw, 100), .segs_in = r(&raw, 140), .ooo = r(&raw, 224) };
}

// Route discovery requires the local socket endpoint, absent from Io.net.
pub fn lanAddr(io: std.Io) ?[4]u8 {
    const address = std.Io.net.IpAddress.parseIp4("1.1.1.1", 53) catch return null;
    const stream = address.connect(io, .{ .mode = .dgram, .protocol = .udp }) catch return null;
    defer stream.close(io);
    var me: linux.sockaddr.in = undefined;
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    if (linux.errno(linux.getsockname(stream.socket.handle, @ptrCast(&me), &len)) != .SUCCESS) return null;
    return @bitCast(me.addr);
}
