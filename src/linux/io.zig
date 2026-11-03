//! Nonblocking descriptor adapters for the readiness loop. Use std.Io files
//! here because std.Io.net.Stream assumes blocking streams and treats EAGAIN
//! as an error in its backend. All error translation stays below the core.
const std = @import("std");
const linux = std.os.linux;
pub const Handle = std.Io.File.Handle;
// Keep the core independent of whether an OS uses the same representation
// for files and sockets (Linux does; Windows need not).
pub fn socketHandle(handle: std.Io.net.Socket.Handle) Handle {
    return handle;
}
pub fn fileHandle(handle: std.Io.File.Handle) Handle {
    return handle;
}
fn file(handle: Handle) std.Io.File {
    return .{ .handle = handle, .flags = .{ .nonblocking = true } };
}
pub fn read(io: std.Io, handle: Handle, bytes: []u8) !usize {
    return file(handle).readStreaming(io, &.{bytes}) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => return err,
    };
}
pub fn write(io: std.Io, handle: Handle, bytes: []const u8) !usize {
    return file(handle).writeStreaming(io, &.{}, &.{bytes}, 1);
}
pub fn writeParts(io: std.Io, handle: Handle, header: []const u8, body: []const u8) !usize {
    return file(handle).writeStreaming(io, header, &.{body}, 1);
}
pub fn writeAll(io: std.Io, handle: Handle, bytes: []const u8) bool {
    file(handle).writeStreamingAll(io, bytes) catch return false;
    return true;
}
pub fn close(io: std.Io, handle: Handle) void {
    if (handle >= 0) file(handle).close(io);
}
pub fn nonblocking(handle: Handle) void {
    const flags = linux.fcntl(handle, linux.F.GETFL, 0);
    if (linux.errno(flags) == .SUCCESS) _ = linux.fcntl(handle, linux.F.SETFL, flags | 0o4000);
}
pub fn tunePipe(handle: Handle) void {
    nonblocking(handle);
    _ = linux.fcntl(handle, 1031, 1 << 20); // F_SETPIPE_SZ
}
pub const Channel = struct {
    read_handle: Handle = -1,
    write_handle: Handle = -1,
    pub fn init() !Channel {
        var pair: [2]Handle = undefined;
        if (linux.errno(linux.pipe2(&pair, .{ .CLOEXEC = true })) != .SUCCESS) return error.CreateChannel;
        return .{ .read_handle = pair[0], .write_handle = pair[1] };
    }
    pub fn send(self: Channel, io: std.Io, handle: Handle) bool {
        return writeAll(io, self.write_handle, std.mem.asBytes(&handle));
    }
    pub fn receive(self: Channel, io: std.Io) !Handle {
        var handle: Handle = -1;
        if (try read(io, self.read_handle, std.mem.asBytes(&handle)) != @sizeOf(Handle)) return error.ClosedChannel;
        return handle;
    }
    pub fn deinit(self: *Channel, io: std.Io) void {
        close(io, self.read_handle);
        close(io, self.write_handle);
        self.* = .{};
    }
};
