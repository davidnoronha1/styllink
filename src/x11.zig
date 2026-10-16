//! Just enough of the X11 wire protocol to watch the screen for changes
//! (DAMAGE) and copy changed rectangles out of it (MIT-SHM, or GetImage over
//! the socket when shared memory is unavailable). No Xlib, no libc.

const std = @import("std");
const linux = std.os.linux;

pub const Rect = struct { x: i32, y: i32, w: u32, h: u32 };

pub const Error = error{ NoDisplay, Connect, Auth, Protocol, NoDamage, Unsupported, Closed };

const OP_GET_IMAGE = 73;
const OP_GET_INPUT_FOCUS = 43;
const OP_QUERY_EXTENSION = 98;
const Z_PIXMAP = 2;

pub const Conn = struct {
    fd: i32 = -1,
    seq: u16 = 0,
    root: u32 = 0,
    root_w: u32 = 0,
    root_h: u32 = 0,
    depth: u8 = 0,
    bpp: u8 = 0,
    red_mask: u32 = 0,
    id_base: u32 = 0,
    id_next: u32 = 0,
    damage_major: u8 = 0,
    damage_event: u8 = 0,
    damage: u32 = 0,
    shm_major: u8 = 0,
    shmseg: u32 = 0,
    shm: ?[]u8 = null,
    // Incoming bytes: events and replies. GetImage replies (no shared
    // memory) carry pixels and need a buffer the size of the image.
    in: []u8 = &.{},
    in_len: usize = 0,
    in_off: usize = 0,
    /// Called for every damaged rectangle (root window coordinates).
    on_damage: ?*const fn (ctx: *anyopaque, r: Rect) void = null,
    ctx: *anyopaque = undefined,
    image_dst: ?[]u8 = null,
    last_error_seq: u16 = 0,

    // ------------------------------------------------------------ setup

    pub fn open(self: *Conn, environ: std.process.Environ, in_buf: []u8) Error!void {
        self.in = in_buf;
        const display = environ.getPosix("DISPLAY") orelse return error.NoDisplay;
        const num = displayNumber(display) orelse return error.NoDisplay;
        self.fd = try connectUnix(num);
        errdefer self.close();

        var cookie: [16]u8 = undefined;
        const have_cookie = readCookie(environ, num, &cookie);
        var hello: [12 + 20 + 16]u8 = @splat(0);
        hello[0] = 'l';
        std.mem.writeInt(u16, hello[2..4], 11, .little);
        var n: usize = 12;
        if (have_cookie) {
            const name = "MIT-MAGIC-COOKIE-1";
            std.mem.writeInt(u16, hello[6..8], name.len, .little);
            std.mem.writeInt(u16, hello[8..10], 16, .little);
            @memcpy(hello[12..][0..name.len], name);
            @memcpy(hello[32..48], &cookie);
            n = hello.len;
        }
        if (!writeAll(self.fd, hello[0..n])) return error.Connect;

        var head: [8]u8 = undefined;
        try self.readExact(&head);
        const extra = @as(usize, std.mem.readInt(u16, head[6..8], .little)) * 4;
        if (extra > self.in.len) return error.Protocol;
        const body = self.in[0..extra];
        try self.readExact(body);
        if (head[0] != 1) {
            std.debug.print("styllink: X server refused the connection: {s}\n", .{body[0..@min(head[1], body.len)]});
            return error.Auth;
        }
        try self.parseSetup(body);
        self.seq = 0;
        _ = linux.fcntl(self.fd, linux.F.SETFL, 0o4000); // O_NONBLOCK
    }

    fn parseSetup(self: *Conn, b: []const u8) Error!void {
        // Offsets are relative to byte 8 of the reply (after the header).
        if (b.len < 32) return error.Protocol;
        self.id_base = std.mem.readInt(u32, b[4..8], .little);
        self.id_next = 1;
        const vendor_len = std.mem.readInt(u16, b[16..18], .little);
        const nformats = b[21];
        if (b[22] != 0) return error.Unsupported; // image byte order must be LSB first
        var off: usize = 32 + pad4(vendor_len);
        const formats_off = off;
        off += @as(usize, nformats) * 8;
        if (off + 40 > b.len) return error.Protocol;
        const scr = b[off..];
        self.root = std.mem.readInt(u32, scr[0..4], .little);
        self.root_w = std.mem.readInt(u16, scr[20..22], .little);
        self.root_h = std.mem.readInt(u16, scr[22..24], .little);
        const root_visual = std.mem.readInt(u32, scr[32..36], .little);
        self.depth = scr[38];
        for (0..nformats) |i| {
            const f = b[formats_off + i * 8 ..];
            if (f[0] == self.depth) self.bpp = f[1];
        }
        var d: usize = 40;
        for (0..scr[39]) |_| {
            if (d + 8 > scr.len) return error.Protocol;
            const nvis = std.mem.readInt(u16, scr[d + 2 ..][0..2], .little);
            var v = d + 8;
            for (0..nvis) |_| {
                if (v + 24 > scr.len) return error.Protocol;
                if (std.mem.readInt(u32, scr[v..][0..4], .little) == root_visual)
                    self.red_mask = std.mem.readInt(u32, scr[v + 8 ..][0..4], .little);
                v += 24;
            }
            d = v;
        }
        // Capture assumes 32-bit BGRX pixels, the norm for 24-bit desktops.
        if (self.bpp != 32 or self.depth < 24 or self.red_mask != 0x00ff0000) return error.Unsupported;
    }

    pub fn close(self: *Conn) void {
        if (self.shm) |m| {
            _ = linux.syscall1(.shmdt, @intFromPtr(m.ptr));
            self.shm = null;
        }
        if (self.fd >= 0) _ = linux.close(self.fd);
        self.fd = -1;
        self.in_len = 0;
        self.in_off = 0;
    }

    fn newId(self: *Conn) u32 {
        defer self.id_next += 1;
        return self.id_base | self.id_next;
    }

    // ------------------------------------------------------------ extensions

    /// Starts damage reporting on the root window and maps `shm_size` bytes
    /// of shared memory for captures (falls back to GetImage without it).
    pub fn startCapture(self: *Conn, shm_size: usize) Error!void {
        const xfixes = try self.queryExtension("XFIXES");
        if (xfixes.present) {
            var q: [12]u8 = undefined;
            req(&q, xfixes.major, 0, 3);
            std.mem.writeInt(u32, q[4..8], 5, .little);
            std.mem.writeInt(u32, q[8..12], 0, .little);
            try self.send(&q);
            _ = try self.waitReply(self.seq, null);
        }
        const dmg = try self.queryExtension("DAMAGE");
        if (!dmg.present) return error.NoDamage;
        self.damage_major = dmg.major;
        self.damage_event = dmg.event;
        var q: [12]u8 = undefined;
        req(&q, dmg.major, 0, 3); // DamageQueryVersion 1.1
        std.mem.writeInt(u32, q[4..8], 1, .little);
        std.mem.writeInt(u32, q[8..12], 1, .little);
        try self.send(&q);
        _ = try self.waitReply(self.seq, null);

        self.damage = self.newId();
        var c: [16]u8 = undefined;
        req(&c, dmg.major, 1, 4); // DamageCreate, DeltaRectangles
        std.mem.writeInt(u32, c[4..8], self.damage, .little);
        std.mem.writeInt(u32, c[8..12], self.root, .little);
        c[12] = 1;
        @memset(c[13..16], 0);
        try self.send(&c);

        const shm = try self.queryExtension("MIT-SHM");
        if (shm.present) self.attachShm(shm.major, shm_size) catch {};
        try self.sync();
    }

    fn attachShm(self: *Conn, major: u8, size: usize) Error!void {
        const IPC_CREAT = 0o1000;
        const IPC_RMID = 0;
        const id_rc = linux.syscall3(.shmget, 0, size, IPC_CREAT | 0o600);
        if (linux.errno(id_rc) != .SUCCESS) return error.Unsupported;
        const id: u32 = @intCast(id_rc);
        defer _ = linux.syscall3(.shmctl, id, IPC_RMID, 0); // freed once both sides detach
        const addr = linux.syscall3(.shmat, id, 0, 0);
        if (linux.errno(addr) != .SUCCESS) return error.Unsupported;
        const mem: [*]u8 = @ptrFromInt(addr);
        self.shm = mem[0..size];
        self.shm_major = major;
        self.shmseg = self.newId();
        var a: [16]u8 = undefined;
        req(&a, major, 1, 4); // ShmAttach
        std.mem.writeInt(u32, a[4..8], self.shmseg, .little);
        std.mem.writeInt(u32, a[8..12], id, .little);
        @memset(a[12..16], 0);
        try self.send(&a);
        const attach_seq = self.seq;
        // An X server that cannot see our memory (other host or container)
        // answers with an error; capture then goes over the socket.
        self.sync() catch |e| {
            self.dropShm();
            return e;
        };
        if (self.last_error_seq == attach_seq) {
            self.dropShm();
            return error.Unsupported;
        }
    }

    fn dropShm(self: *Conn) void {
        if (self.shm) |m| _ = linux.syscall1(.shmdt, @intFromPtr(m.ptr));
        self.shm = null;
    }

    /// Swaps in a bigger receive buffer (GetImage replies carry pixels).
    pub fn setInBuffer(self: *Conn, buf: []u8) void {
        const rest = self.in_len - self.in_off;
        std.mem.copyForwards(u8, buf[0..rest], self.in[self.in_off..self.in_len]);
        self.in = buf;
        self.in_off = 0;
        self.in_len = rest;
    }

    const Ext = struct { present: bool, major: u8, event: u8 };

    fn queryExtension(self: *Conn, name: []const u8) Error!Ext {
        var q: [32]u8 = @splat(0);
        const len = 8 + pad4(name.len);
        req(q[0..len], OP_QUERY_EXTENSION, 0, @intCast(len / 4));
        std.mem.writeInt(u16, q[4..6], @intCast(name.len), .little);
        @memcpy(q[8..][0..name.len], name);
        try self.send(q[0..len]);
        var r: [32]u8 = undefined;
        if (!try self.waitReply(self.seq, &r)) return .{ .present = false, .major = 0, .event = 0 };
        return .{ .present = r[8] != 0, .major = r[9], .event = r[10] };
    }

    // ------------------------------------------------------------ capture

    /// Clears the accumulated damage; changes after this are reported again.
    pub fn subtractDamage(self: *Conn) Error!void {
        var s: [16]u8 = undefined;
        req(&s, self.damage_major, 3, 4); // DamageSubtract, repair and parts None
        std.mem.writeInt(u32, s[4..8], self.damage, .little);
        std.mem.writeInt(u32, s[8..12], 0, .little);
        std.mem.writeInt(u32, s[12..16], 0, .little);
        try self.send(&s);
    }

    /// Queues a copy of `r` (root coordinates) into shared memory at `offset`
    /// as tightly packed BGRX rows. Returns the request's sequence number.
    pub fn shmGetImage(self: *Conn, r: Rect, offset: u32) Error!u16 {
        var g: [32]u8 = undefined;
        req(&g, self.shm_major, 4, 8);
        std.mem.writeInt(u32, g[4..8], self.root, .little);
        std.mem.writeInt(i16, g[8..10], @intCast(r.x), .little);
        std.mem.writeInt(i16, g[10..12], @intCast(r.y), .little);
        std.mem.writeInt(u16, g[12..14], @intCast(r.w), .little);
        std.mem.writeInt(u16, g[14..16], @intCast(r.h), .little);
        std.mem.writeInt(u32, g[16..20], 0xffffffff, .little);
        g[20] = Z_PIXMAP;
        @memset(g[21..24], 0);
        std.mem.writeInt(u32, g[24..28], self.shmseg, .little);
        std.mem.writeInt(u32, g[28..32], offset, .little);
        try self.send(&g);
        return self.seq;
    }

    /// Socket fallback: copies `r` into `dst` (tightly packed BGRX rows).
    pub fn getImage(self: *Conn, r: Rect, dst: []u8) Error!void {
        var g: [20]u8 = undefined;
        req(&g, OP_GET_IMAGE, Z_PIXMAP, 5);
        std.mem.writeInt(u32, g[4..8], self.root, .little);
        std.mem.writeInt(i16, g[8..10], @intCast(r.x), .little);
        std.mem.writeInt(i16, g[10..12], @intCast(r.y), .little);
        std.mem.writeInt(u16, g[12..14], @intCast(r.w), .little);
        std.mem.writeInt(u16, g[14..16], @intCast(r.h), .little);
        std.mem.writeInt(u32, g[16..20], 0xffffffff, .little);
        try self.send(&g);
        self.image_dst = dst;
        defer self.image_dst = null;
        if (!try self.waitReply(self.seq, null)) return error.Protocol;
    }

    /// Round trip: everything sent so far has been processed.
    pub fn sync(self: *Conn) Error!void {
        var q: [4]u8 = undefined;
        req(&q, OP_GET_INPUT_FOCUS, 0, 1);
        try self.send(&q);
        _ = try self.waitReply(self.seq, null);
    }

    // ------------------------------------------------------------ wire

    fn req(b: []u8, op: u8, minor: u8, words: u16) void {
        b[0] = op;
        b[1] = minor;
        std.mem.writeInt(u16, b[2..4], words, .little);
    }

    fn send(self: *Conn, b: []const u8) Error!void {
        if (!writeAll(self.fd, b)) return error.Closed;
        self.seq +%= 1;
    }

    fn readExact(self: *Conn, out: []u8) Error!void {
        var got: usize = 0;
        while (got < out.len) {
            const rc = linux.read(self.fd, out[got..].ptr, out.len - got);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return error.Closed;
                    got += rc;
                },
                .INTR => {},
                .AGAIN => waitReadable(self.fd),
                else => return error.Closed,
            }
        }
    }

    /// Reads whatever has arrived without blocking and dispatches events.
    pub fn pump(self: *Conn) Error!void {
        while (true) {
            if (try self.fill(false) == 0) return;
            _ = try self.dispatch(null, null);
        }
    }

    /// Reads until the reply (or error) to `seq` arrives, dispatching any
    /// events on the way. Returns false if the request failed.
    pub fn waitReply(self: *Conn, seq: u16, out: ?*[32]u8) Error!bool {
        while (true) {
            if (try self.dispatch(seq, out)) |ok| return ok;
            _ = try self.fill(true);
        }
    }

    fn fill(self: *Conn, block: bool) Error!usize {
        if (self.in_off == self.in_len) {
            self.in_off = 0;
            self.in_len = 0;
        } else if (self.in_off > 0 and self.in.len - self.in_len < 4096) {
            const rest = self.in_len - self.in_off;
            std.mem.copyForwards(u8, self.in[0..rest], self.in[self.in_off..self.in_len]);
            self.in_off = 0;
            self.in_len = rest;
        }
        if (self.in_len == self.in.len) return error.Protocol;
        while (true) {
            const rc = linux.read(self.fd, self.in[self.in_len..].ptr, self.in.len - self.in_len);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return error.Closed;
                    self.in_len += rc;
                    return rc;
                },
                .INTR => {},
                .AGAIN => if (block) waitReadable(self.fd) else return 0,
                else => return error.Closed,
            }
        }
    }

    /// Handles every complete message in the buffer. Returns non-null once
    /// the reply or error for `want` was seen.
    fn dispatch(self: *Conn, want: ?u16, out: ?*[32]u8) Error!?bool {
        while (self.in_len - self.in_off >= 32) {
            const m = self.in[self.in_off..self.in_len];
            const kind = m[0] & 0x7f;
            var total: usize = 32;
            if (m[0] == 1 or kind == 35) total += @as(usize, std.mem.readInt(u32, m[4..8], .little)) * 4;
            if (total > self.in.len) return error.Protocol;
            if (m.len < total) return null;
            self.in_off += total;
            const seq = std.mem.readInt(u16, m[2..4], .little);
            switch (m[0]) {
                0 => { // error
                    self.last_error_seq = seq;
                    if (want != null and seq == want.?) return false;
                    if (want == null or m[1] != 8) // BadMatch on a vanished rect is routine
                        std.debug.print("styllink: X error {d} (request {d}.{d})\n", .{ m[1], m[10], std.mem.readInt(u16, m[8..10], .little) });
                },
                1 => if (want != null and seq == want.?) {
                    if (out) |o| o.* = m[0..32].*;
                    if (self.image_dst) |dst| {
                        const data = m[32..total];
                        @memcpy(dst[0..@min(dst.len, data.len)], data[0..@min(dst.len, data.len)]);
                    }
                    return true;
                },
                else => if (kind == self.damage_event and self.damage_event != 0) {
                    if (self.on_damage) |f| f(self.ctx, .{
                        .x = std.mem.readInt(i16, m[16..18], .little),
                        .y = std.mem.readInt(i16, m[18..20], .little),
                        .w = std.mem.readInt(u16, m[20..22], .little),
                        .h = std.mem.readInt(u16, m[22..24], .little),
                    });
                },
            }
        }
        return null;
    }
};

fn pad4(n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}

fn waitReadable(fd: i32) void {
    var p = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN }};
    _ = linux.poll(&p, 1, 1000);
}

fn writeAll(fd: i32, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const rc = linux.write(fd, data.ptr + off, data.len - off);
        switch (linux.errno(rc)) {
            .SUCCESS => off += rc,
            .INTR => {},
            .AGAIN => {
                var p = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT }};
                _ = linux.poll(&p, 1, 1000);
            },
            else => return false,
        }
    }
    return true;
}

/// ":0", ":1.0", "unix:0" -> display number. Remote (TCP) displays are not
/// supported: capture needs a local X server anyway.
pub fn displayNumber(d: []const u8) ?u32 {
    const colon = std.mem.lastIndexOfScalar(u8, d, ':') orelse return null;
    const host = d[0..colon];
    if (host.len != 0 and !std.mem.eql(u8, host, "unix")) return null;
    const rest = d[colon + 1 ..];
    const end = std.mem.indexOfScalar(u8, rest, '.') orelse rest.len;
    return std.fmt.parseInt(u32, rest[0..end], 10) catch null;
}

fn connectUnix(num: u32) Error!i32 {
    var path: [108]u8 = @splat(0);
    const p = std.fmt.bufPrint(path[1..], "/tmp/.X11-unix/X{d}", .{num}) catch return error.Connect;
    // Abstract socket first (what Xorg listens on), then the file.
    for ([_]bool{ true, false }) |abstract| {
        const fd_rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(fd_rc) != .SUCCESS) return error.Connect;
        const fd: i32 = @intCast(fd_rc);
        var addr = linux.sockaddr.un{ .path = @splat(0) };
        const len: usize = if (abstract) blk: {
            @memcpy(addr.path[0 .. p.len + 1], path[0 .. p.len + 1]);
            break :blk p.len + 1;
        } else blk: {
            @memcpy(addr.path[0..p.len], p);
            break :blk p.len;
        };
        const sl: linux.socklen_t = @intCast(@sizeOf(linux.sa_family_t) + len);
        if (linux.errno(linux.connect(fd, @ptrCast(&addr), sl)) == .SUCCESS) return fd;
        _ = linux.close(fd);
    }
    return error.Connect;
}

/// MIT-MAGIC-COOKIE-1 for display `num` from $XAUTHORITY or ~/.Xauthority.
fn readCookie(environ: std.process.Environ, num: u32, out: *[16]u8) bool {
    var pb: [512]u8 = undefined;
    const path = if (environ.getPosix("XAUTHORITY")) |x|
        std.fmt.bufPrintSentinel(&pb, "{s}", .{x}, 0) catch return false
    else if (environ.getPosix("HOME")) |h|
        std.fmt.bufPrintSentinel(&pb, "{s}/.Xauthority", .{h}, 0) catch return false
    else
        return false;
    const fd_rc = linux.open(path, .{ .CLOEXEC = true }, 0);
    if (linux.errno(fd_rc) != .SUCCESS) return false;
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);
    var buf: [16384]u8 = undefined;
    var n: usize = 0;
    while (n < buf.len) {
        const rc = linux.read(fd, buf[n..].ptr, buf.len - n);
        if (linux.errno(rc) != .SUCCESS or rc == 0) break;
        n += rc;
    }
    var numbuf: [10]u8 = undefined;
    const want = std.fmt.bufPrint(&numbuf, "{d}", .{num}) catch return false;
    return findCookie(buf[0..n], want, out);
}

fn findCookie(b: []const u8, want: []const u8, out: *[16]u8) bool {
    var i: usize = 0;
    var found = false;
    while (i + 2 <= b.len) {
        i += 2; // family
        var fields: [4][]const u8 = undefined;
        for (&fields) |*f| {
            if (i + 2 > b.len) return found;
            const len = std.mem.readInt(u16, b[i..][0..2], .big);
            i += 2;
            if (i + len > b.len) return found;
            f.* = b[i..][0..len];
            i += len;
        }
        const number, const name, const data = .{ fields[1], fields[2], fields[3] };
        if (!std.mem.eql(u8, name, "MIT-MAGIC-COOKIE-1") or data.len != 16) continue;
        if (number.len != 0 and !std.mem.eql(u8, number, want)) continue;
        out.* = data[0..16].*;
        found = true;
        if (number.len != 0) return true; // an exact display match beats a wildcard
    }
    return found;
}

test "displayNumber parses local displays only" {
    const testing = std.testing;
    try testing.expectEqual(@as(?u32, 0), displayNumber(":0"));
    try testing.expectEqual(@as(?u32, 1), displayNumber(":1.0"));
    try testing.expectEqual(@as(?u32, 2), displayNumber("unix:2"));
    try testing.expectEqual(@as(?u32, null), displayNumber("host:0"));
}

test "findCookie picks the entry for our display" {
    const testing = std.testing;
    var b: [200]u8 = undefined;
    var n: usize = 0;
    for ([_][]const u8{ "7", "1" }, [_]u8{ 0xaa, 0xbb }) |num, fill| {
        for ([_][]const u8{ "host", num, "MIT-MAGIC-COOKIE-1", &(@as([16]u8, @splat(fill))) }, 0..) |f, k| {
            if (k == 0) {
                std.mem.writeInt(u16, b[n..][0..2], 256, .big);
                n += 2;
            }
            std.mem.writeInt(u16, b[n..][0..2], @intCast(f.len), .big);
            n += 2;
            @memcpy(b[n..][0..f.len], f);
            n += f.len;
        }
    }
    var out: [16]u8 = undefined;
    try testing.expect(findCookie(b[0..n], "1", &out));
    try testing.expectEqual(@as(u8, 0xbb), out[0]);
}
