//! WebSocket and HTTP protocol handling, client socket management, and event pacing.

const std = @import("std");
const linux = std.os.linux;
const util = @import("util.zig");
const config = @import("config.zig");
const input = @import("input.zig");
const stats = @import("stats.zig");
const index_html = @import("page").html;

pub const MAX_CLIENTS = 16;
pub const LISTEN_TAG: u64 = std.math.maxInt(u64);
pub const TIMER_TAG: u64 = LISTEN_TAG - 1;
pub const PACE_TAG: u64 = LISTEN_TAG - 2;
pub const PLAY_TAG: u64 = LISTEN_TAG - 3;

pub const TICK_MS = stats.TICK_MS;
pub const BURST = stats.BURST;
pub const PING_EVERY = stats.PING_EVERY;
pub const REPORT_EVERY = stats.REPORT_EVERY;

pub const Client = struct {
    fd: i32 = -1,
    ws: bool = false,
    off: usize = 0,
    len: usize = 0,
    peer: [4]u8 = .{ 0, 0, 0, 0 },
    stats: stats.Stats = .{},
    buf: [16384]u8 = undefined,
};

pub var clients: [MAX_CLIENTS]Client = @splat(.{});
pub var epfd: i32 = -1;
pub var active_ws: usize = 0;
pub var newest_ws: ?usize = null;
pub var ticks: u64 = 0;
pub var cfg: config.Config = .{};

pub fn init(c: config.Config) void {
    cfg = c;
}

pub fn closeClient(c: *Client) void {
    if (c.ws) {
        active_ws -= 1;
        // Lift the pen whenever a drawing client goes away; never leave a
        // stuck button behind.
        input.playReset();
        input.pen.leave();
        input.pen.flush();
        stats.say("styllink: {d}.{d}.{d}.{d} disconnected ({d} connected)\n", .{ c.peer[0], c.peer[1], c.peer[2], c.peer[3], active_ws });
        stats.logJson("\"ev\":\"disconnect\",\"peer\":\"{f}\",\"stalls_total\":{d}", .{ stats.ip(c.peer), c.stats.stalls_total });
        if (newest_ws) |i| if (&clients[i] == c) {
            newest_ws = null;
        };
    }
    if (epfd != -1) _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, c.fd, null);
    _ = linux.close(c.fd);
    c.* = .{};
}

pub fn sendFrame(c: *Client, opcode: u8, payload: []const u8) void {
    var hdr: [4]u8 = undefined;
    var hl: usize = 2;
    hdr[0] = 0x80 | opcode;
    if (payload.len < 126) {
        hdr[1] = @intCast(payload.len);
    } else {
        hdr[1] = 126;
        std.mem.writeInt(u16, hdr[2..4], @intCast(payload.len), .big);
        hl = 4;
    }
    const iov = [_]std.posix.iovec_const{
        .{ .base = &hdr, .len = hl },
        .{ .base = payload.ptr, .len = payload.len },
    };
    _ = linux.writev(c.fd, &iov, 2);
}

pub fn sendPing(c: *Client, kind: u8) void {
    var b: [32]u8 = undefined;
    const msg = std.fmt.bufPrint(&b, "{c}{d}", .{ kind, util.nowNs() }) catch return;
    sendFrame(c, 0x1, msg);
}

pub fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name))
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

pub fn queryParam(target: []const u8, key: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |kv| {
        if (kv.len > key.len and std.mem.startsWith(u8, kv, key) and kv[key.len] == '=')
            return kv[key.len + 1 ..];
    }
    return null;
}

pub fn httpReply(c: *Client, status: []const u8, ctype: []const u8, body: []const u8) void {
    var hdr: [256]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n" ++
        "Cache-Control: no-store\r\nConnection: close\r\n\r\n", .{ status, ctype, body.len }) catch return;
    const iov = [_]std.posix.iovec_const{
        .{ .base = h.ptr, .len = h.len },
        .{ .base = body.ptr, .len = body.len },
    };
    _ = linux.writev(c.fd, &iov, 2);
}

/// Returns false if the client should be closed.
pub fn handleHttp(c: *Client) bool {
    const end = std.mem.indexOf(u8, c.buf[0..c.len], "\r\n\r\n") orelse
        return c.len < c.buf.len; // wait for the rest of the headers
    const head = c.buf[0..end];
    var parts = std.mem.splitScalar(u8, head[0 .. std.mem.indexOf(u8, head, "\r\n") orelse head.len], ' ');
    const method = parts.next() orelse return false;
    const target = parts.next() orelse return false;
    if (!std.mem.eql(u8, method, "GET")) {
        httpReply(c, "405 Method Not Allowed", "text/plain", "GET only\n");
        return false;
    }
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];

    if (std.mem.eql(u8, path, "/ws")) {
        const key = headerValue(head, "Sec-WebSocket-Key") orelse {
            httpReply(c, "400 Bad Request", "text/plain", "expected websocket\n");
            return false;
        };
        if (cfg.token.len > 0) {
            const t = queryParam(target, "t") orelse "";
            if (!std.mem.eql(u8, t, cfg.token)) {
                httpReply(c, "403 Forbidden", "text/plain", "bad token\n");
                stats.say("styllink: rejected {d}.{d}.{d}.{d}: wrong token\n", .{ c.peer[0], c.peer[1], c.peer[2], c.peer[3] });
                return false;
            }
        }
        var sha = std.crypto.hash.Sha1.init(.{});
        sha.update(key);
        sha.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
        var digest: [20]u8 = undefined;
        sha.final(&digest);
        var accept: [28]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&accept, &digest);

        var resp: [256]u8 = undefined;
        const r = std.fmt.bufPrint(&resp, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" ++
            "Connection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept}) catch return false;
        if (!util.writeAll(c.fd, r)) return false;

        c.ws = true;
        active_ws += 1;
        newest_ws = (@intFromPtr(c) - @intFromPtr(&clients[0])) / @sizeOf(Client);
        stats.say("styllink: {d}.{d}.{d}.{d} connected ({d} connected), benchmarking link...\n", .{ c.peer[0], c.peer[1], c.peer[2], c.peer[3], active_ws });
        stats.logJson("\"ev\":\"connect\",\"peer\":\"{f}\",\"origin\":{f}", .{ stats.ip(c.peer), std.json.fmt(headerValue(head, "Origin") orelse "", .{}) });
        var hello: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&hello, "{{\"w\":{d},\"h\":{d}}}", .{ cfg.region[2], cfg.region[3] }) catch return false;
        sendFrame(c, 0x1, msg);

        const rest = c.len - (c.off + end + 4);
        if (rest > 0) std.mem.copyForwards(u8, c.buf[0..rest], c.buf[c.off + end + 4 .. c.len]);
        c.off = 0;
        c.len = rest;
        return handleWs(c);
    }

    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
        httpReply(c, "200 OK", "text/html; charset=utf-8", index_html);
    } else {
        httpReply(c, "404 Not Found", "text/plain", "not found\n");
    }
    return false;
}

pub fn unmask(payload: []u8, mask: *const [4]u8) void {
    const m32: u64 = std.mem.readInt(u32, mask, .native);
    const mask64: u64 = m32 | (m32 << 32);
    var i: usize = 0;
    while (i + 8 <= payload.len) : (i += 8) {
        const chunk = payload[i..][0..8];
        const word = std.mem.readInt(u64, chunk, .native) ^ mask64;
        std.mem.writeInt(u64, chunk, word, .native);
    }
    while (i < payload.len) : (i += 1) {
        payload[i] ^= mask[i & 3];
    }
}

/// Parse as many complete frames as are buffered. Returns false to close.
pub fn handleWs(c: *Client) bool {
    var pen_msgs: u32 = 0; // pen messages handled in this one read = burst size
    defer {
        c.stats.burst_max = @max(c.stats.burst_max, pen_msgs);
        input.playDrain();
        const rest = c.len - c.off;
        if (c.off > 0 and c.buf.len - c.len < 4096) {
            if (rest > 0) std.mem.copyForwards(u8, c.buf[0..rest], c.buf[c.off..c.len]);
            c.off = 0;
            c.len = rest;
        } else if (c.off == c.len) {
            c.off = 0;
            c.len = 0;
        }
    }
    while (true) {
        const b = c.buf[c.off..c.len];
        if (b.len < 2) return true;
        const opcode = b[0] & 0x0f;
        if (b[1] & 0x80 == 0) return false; // clients must mask
        var plen: usize = b[1] & 0x7f;
        var hl: usize = 2;
        if (plen == 126) {
            if (b.len < 4) return true;
            plen = std.mem.readInt(u16, b[2..4], .big);
            hl = 4;
        } else if (plen == 127) {
            return false; // never needed; refuse giant frames
        }
        if (hl + 4 + plen > c.buf.len) return false;
        if (b.len < hl + 4 + plen) return true;
        const mask = b[hl..][0..4];
        const payload = c.buf[c.off + hl + 4 ..][0..plen];
        unmask(payload, mask);
        c.off += hl + 4 + plen;

        switch (opcode) {
            0x2 => { // binary: u32 client timestamp + batch of pen samples
                if (payload.len < 4) continue;
                const excess = c.stats.uplink(std.mem.readInt(u32, payload[0..4], .little));
                // When this message would have arrived with no network delay.
                const arrival = util.nowNs();
                const on_time = (arrival -| @as(u64, excess) * std.time.ns_per_us) + @as(u64, cfg.jitter_ms) * std.time.ns_per_ms;
                var active = false;
                var i: usize = 4;
                while (i + input.SAMPLE_SIZE <= payload.len) : (i += input.SAMPLE_SIZE) {
                    if (payload[i + 8] & input.F_IN_RANGE != 0) {
                        c.stats.samples += 1;
                        active = true;
                    }
                    const age_ns = @as(u64, payload[i + 9]) * 500 * std.time.ns_per_us;
                    c.stats.age_max_us = @max(c.stats.age_max_us, @as(u32, @intCast(age_ns / 1000)));
                    c.stats.age_sum_us += age_ns / 1000;
                    c.stats.age_n += 1;
                    input.playEnqueue(payload[i..][0..input.SAMPLE_SIZE], on_time -| age_ns, arrival);
                }
                pen_msgs += 1;
                c.stats.arrival(c.fd, c.peer, active, excess);
            },
            0x1 => if (payload.len > 0) switch (payload[0]) {
                'p' => sendFrame(c, 0x1, payload), // page's own RTT ping: echo
                'b', 's' => c.stats.pong(payload), // our ping coming back
                'i' => stats.reportCaps(c.peer, &c.stats, payload, cfg.port), // page capabilities
                else => {},
            },
            0x9 => sendFrame(c, 0xA, payload),
            0x8 => {
                sendFrame(c, 0x8, "");
                return false;
            },
            else => {},
        }
    }
}

/// `n` new bytes landed at c.buf[c.len..]. Returns false to close the client.
pub fn onData(c: *Client, n: usize) bool {
    if (n == 0) return false;
    c.len += n;
    if (c.ws) {
        // ACK the tablet's packets right away instead of Linux's delayed ACK
        // (up to 40 ms); a sender waiting on ACKs sends in bunches. The flag
        // isn't sticky, so it's re-armed after every read.
        const one: i32 = 1;
        _ = linux.setsockopt(c.fd, linux.IPPROTO.TCP, linux.TCP.QUICKACK, std.mem.asBytes(&one), 4);
    }
    return if (c.ws) handleWs(c) else handleHttp(c);
}

pub fn tuneSocket(fd: i32) void {
    const one: i32 = 1;
    _ = linux.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, std.mem.asBytes(&one), 4);
    // DSCP EF: on Wi-Fi (WMM) this maps our packets/ACKs to the voice queue.
    const tos: i32 = 0xb8;
    _ = linux.setsockopt(fd, linux.IPPROTO.IP, 1, std.mem.asBytes(&tos), 4); // IP_TOS
    const buf_size: i32 = 65536;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVBUF, std.mem.asBytes(&buf_size), 4);
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.SNDBUF, std.mem.asBytes(&buf_size), 4);
}

pub fn claimSlot(fd: i32) ?usize {
    for (&clients, 0..) |*c, i| {
        if (c.fd != -1) continue;
        c.* = .{ .fd = fd };
        var sa: linux.sockaddr.in = undefined;
        var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
        if (linux.errno(linux.getpeername(fd, @ptrCast(&sa), &len)) == .SUCCESS) c.peer = @bitCast(sa.addr);
        return i;
    }
    _ = linux.close(fd); // full
    return null;
}

pub fn onTick() void {
    ticks += 1;
    for (&clients, 0..) |*c, i| {
        if (c.fd == -1 or !c.ws) continue;
        const st = &c.stats;
        if (st.burst_sent < BURST) {
            sendPing(c, 'b');
            st.burst_sent += 1;
            if (st.burst_sent == BURST) st.burst_at = ticks;
        } else {
            if (ticks % PING_EVERY == 0) sendPing(c, 's');
            if (!st.burst_reported and (st.burst.n == BURST or ticks - st.burst_at > 50)) stats.reportBurst(c.peer, st);
        }
        if (ticks % (5 * REPORT_EVERY) == 0) { // rotate the uplink baseline window
            st.up_min_prev = st.up_min_cur;
            st.up_min_cur = std.math.maxInt(i32);
        }
        if (ticks % REPORT_EVERY == 0) {
            if (st.burst_reported and newest_ws == i) stats.reportLive(st, ticks);
            stats.logStat(c.fd, c.peer, st, ticks, input.play_lag_max_ns);
            input.play_lag_max_ns = 0;
            st.samples = 0;
            st.msgs = 0;
        }
    }
}

test "headerValue and queryParam parse headers and parameters" {
    const testing = std.testing;
    const head = "GET /ws?t=mysecret HTTP/1.1\r\nHost: localhost:8080\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n";
    try testing.expectEqualStrings("dGhlIHNhbXBsZSBub25jZQ==", headerValue(head, "Sec-WebSocket-Key").?);
    try testing.expect(headerValue(head, "Non-Existent") == null);
    try testing.expectEqualStrings("mysecret", queryParam("/ws?t=mysecret&other=1", "t").?);
    try testing.expectEqualStrings("1", queryParam("/ws?t=mysecret&other=1", "other").?);
    try testing.expect(queryParam("/ws?t=mysecret", "missing") == null);
}

test "vectorized unmask matches byte-by-byte for all lengths" {
    const testing = std.testing;
    const mask = [4]u8{ 0x37, 0xfa, 0x21, 0x9d };
    const lengths = [_]usize{ 0, 1, 2, 3, 4, 5, 7, 8, 9, 13, 16, 17, 31, 32, 33, 64, 100 };

    for (lengths) |len| {
        var buf_actual: [128]u8 = undefined;
        var buf_expected: [128]u8 = undefined;
        for (0..len) |i| {
            const b: u8 = @truncate(i * 37 + 11);
            buf_actual[i] = b;
            buf_expected[i] = b ^ mask[i & 3];
        }

        unmask(buf_actual[0..len], &mask);
        try testing.expectEqualSlices(u8, buf_expected[0..len], buf_actual[0..len]);
    }
}

test "handleWs zero-memmove cursor and compaction" {
    const testing = std.testing;
    var client = Client{ .fd = -1, .ws = true };

    // Incomplete frame with lots of space remaining: off should not shift to 0
    client.off = 10;
    client.len = 15;
    client.buf[10..15].* = .{ 0x82, 0x80, 0x11, 0x22, 0x33 }; // 5 bytes < 6-byte minimum masked frame
    _ = handleWs(&client);
    try testing.expectEqual(@as(usize, 10), client.off);
    try testing.expectEqual(@as(usize, 15), client.len);

    // Incomplete frame when free space at the end is low (< 4096): shifts to 0
    client.off = 13000;
    client.len = 13005;
    client.buf[13000..13005].* = .{ 0x82, 0x80, 0x11, 0x22, 0x33 };
    _ = handleWs(&client);
    try testing.expectEqual(@as(usize, 0), client.off);
    try testing.expectEqual(@as(usize, 5), client.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0x80, 0x11, 0x22, 0x33 }, client.buf[0..5]);

    // All bytes consumed: resets off and len to 0
    client.off = 20;
    client.len = 20;
    _ = handleWs(&client);
    try testing.expectEqual(@as(usize, 0), client.off);
    try testing.expectEqual(@as(usize, 0), client.len);
}

