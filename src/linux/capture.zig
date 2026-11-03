//! X11 capture implementation. The core supplies regions and receives BGRX
//! pixels and damage callbacks; it knows nothing about X11 requests or SHM.
const std = @import("std");
const x11 = @import("x11.zig");
const types = @import("../platform/types.zig");
const linux = std.os.linux;

pub const Capture = struct {
    conn: x11.Conn = .{},
    allocator: std.mem.Allocator = undefined,
    region: types.Region = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    pixels: []u8 = &.{},
    owned_pixels: []u8 = &.{},
    socket_buffer: []u8 = &.{},
    small: [256 * 256 * 4 + 65536]u8 = undefined,
    context: *anyopaque = undefined,
    on_damage: *const fn (*anyopaque, types.Region) void = undefined,

    pub fn open(self: *Capture, io: std.Io, allocator: std.mem.Allocator, environ: std.process.Environ, region: types.Region, context: *anyopaque, on_damage: *const fn (*anyopaque, types.Region) void) !void {
        self.allocator = allocator;
        self.context = context;
        self.on_damage = on_damage;
        self.conn = .{};
        self.conn.ctx = self;
        self.conn.on_damage = damage;
        try self.conn.open(io, environ, &self.small);
        errdefer self.close();
        const x1 = @min(region.x + @as(i32, @intCast(region.w)), @as(i32, @intCast(self.conn.root_w)));
        const y1 = @min(region.y + @as(i32, @intCast(region.h)), @as(i32, @intCast(self.conn.root_h)));
        if (x1 <= region.x or y1 <= region.y) return error.InvalidRegion;
        self.region = .{ .x = region.x, .y = region.y, .w = @intCast(x1 - region.x), .h = @intCast(y1 - region.y) };
        const full = @as(usize, self.region.w) * self.region.h * 4;
        try self.conn.startCapture(full);
        if (self.conn.shm) |memory| {
            self.pixels = memory;
        } else {
            self.owned_pixels = try allocator.alloc(u8, full);
            self.socket_buffer = try allocator.alloc(u8, full + 65536);
            self.pixels = self.owned_pixels;
            self.conn.setInBuffer(self.socket_buffer);
        }
    }
    fn damage(context: *anyopaque, region: x11.Rect) void {
        const self: *Capture = @ptrCast(@alignCast(context));
        self.on_damage(self.context, .{ .x = region.x, .y = region.y, .w = region.w, .h = region.h });
    }
    pub fn source(self: *const Capture) std.Io.File.Handle {
        return self.conn.fd;
    }
    pub fn needsCursorPolling(self: *const Capture) bool {
        return self.conn.xfixes_major != 0;
    }
    pub fn handleEvents(self: *Capture) !void {
        try self.conn.pump();
    }
    pub fn pollCursor(self: *Capture) !void {
        try self.conn.pollCursor();
    }
    pub fn beginFrame(self: *Capture) !void {
        try self.conn.subtractDamage();
    }
    pub fn readBands(self: *Capture, bands: []const types.CaptureBand) !void {
        var last: u16 = 0;
        for (bands) |b| {
            const r = x11.Rect{ .x = b.region.x, .y = b.region.y, .w = b.region.w, .h = b.region.h };
            if (self.conn.shm != null) {
                last = try self.conn.shmGetImage(r, @intCast(b.off));
            } else {
                try self.conn.getImage(r, self.pixels[b.off..][0 .. b.stride * r.h]);
            }
        }
        if (self.conn.shm != null and bands.len > 0) _ = try self.conn.waitReply(last, null);
        for (bands) |b| {
            const r = x11.Rect{ .x = b.region.x, .y = b.region.y, .w = b.region.w, .h = b.region.h };
            self.conn.compositeCursor(r, self.pixels[b.off..][0 .. b.stride * r.h]);
        }
    }
    pub fn close(self: *Capture) void {
        self.conn.close();
        if (self.owned_pixels.len > 0) self.allocator.free(self.owned_pixels);
        if (self.socket_buffer.len > 0) self.allocator.free(self.socket_buffer);
        self.pixels = &.{};
        self.owned_pixels = &.{};
        self.socket_buffer = &.{};
    }
};
