//! Common video transport operations.

const std = @import("std");
const platform = @import("../platform.zig");
const ws = @import("../ws.zig");
const formats = @import("formats.zig");
const MAX_WS_HDR = formats.MAX_WS_HDR;

const state = @import("state.zig");
const runtime = @import("runtime.zig");
const session_ops = @import("session.zig");

pub fn readClient() bool {
    const rc = platform.IO.read(state.io, state.fd, state.rx[state.rx_len..]) catch |err| switch (err) {
        error.WouldBlock => return true,
        else => return false,
    };
    if (rc == 0) return false;
    state.rx_len += rc;
    var off: usize = 0;
    defer {
        std.mem.copyForwards(u8, state.rx[0 .. state.rx_len - off], state.rx[off..state.rx_len]);
        state.rx_len -= off;
    }
    while (true) {
        const b = state.rx[off..state.rx_len];
        if (b.len < 2) return true;
        if (b[1] & 0x80 == 0) return false; // clients must mask
        var plen: usize = b[1] & 0x7f;
        var hl: usize = 2;
        if (plen == 126) {
            if (b.len < 4) return true;
            plen = std.mem.readInt(u16, b[2..4], .big);
            hl = 4;
        } else if (plen == 127) return false;
        if (hl + 4 + plen > state.rx.len) return false;
        if (b.len < hl + 4 + plen) return true;
        const payload = b[hl + 4 ..][0..plen];
        ws.unmask(payload, b[hl..][0..4]);
        off += hl + 4 + plen;
        switch (b[0] & 0x0f) {
            0x1 => if (payload.len > 0) if (!session_ops.onText(payload)) return false,
            0x9 => sendWs(0xA, payload),
            0x8 => return false,
            else => {},
        }
        if (state.fd == platform.invalid_handle) return true;
    }
}

pub fn queue(opcode: u8, head: []const u8, body: []const u8) void {
    const n = head.len + body.len;
    if (state.wire_off > 0 and state.wire.len - state.wire_len < n + MAX_WS_HDR) {
        const rest = state.wire_len - state.wire_off;
        std.mem.copyForwards(u8, state.wire[0..rest], state.wire[state.wire_off..state.wire_len]);
        state.wire_off = 0;
        state.wire_len = rest;
    }
    if (state.wire.len - state.wire_len < n + MAX_WS_HDR) return session_ops.endSession("frame larger than the send buffer");
    var w = state.wire[state.wire_len..];
    w[0] = 0x80 | opcode;
    var hl: usize = 2;
    if (n < 126) {
        w[1] = @intCast(n);
    } else if (n < 65536) {
        w[1] = 126;
        std.mem.writeInt(u16, w[2..4], @intCast(n), .big);
        hl = 4;
    } else {
        w[1] = 127;
        std.mem.writeInt(u64, w[2..10], n, .big);
        hl = 10;
    }
    @memcpy(w[hl..][0..head.len], head);
    @memcpy(w[hl + head.len ..][0..body.len], body);
    state.wire_len += hl + n;
}

pub fn flush() void {
    while (state.wire_off < state.wire_len) {
        const count = platform.IO.write(state.io, state.fd, state.wire[state.wire_off..state.wire_len]) catch |err| switch (err) {
            error.WouldBlock => {
                if (!state.out_armed) runtime.rewatch(state.fd, .{ .readable = true, .writable = true }, .client);
                state.out_armed = true;
                return;
            },
            else => return session_ops.endSession("send failed"),
        };
        if (count == 0) return session_ops.endSession("send closed");
        state.wire_off += count;
    }
    state.wire_off = 0;
    state.wire_len = 0;
    if (state.out_armed) runtime.rewatch(state.fd, .{ .readable = true }, .client);
    state.out_armed = false;
}

pub fn sendWs(opcode: u8, payload: []const u8) void {
    if (state.fd == platform.invalid_handle) return;
    if (state.wire.len == 0) {
        // Before buffers exist (negotiation errors): write directly.
        var h: [4]u8 = undefined;
        h[0] = 0x80 | opcode;
        var hl: usize = 2;
        if (payload.len < 126) h[1] = @intCast(payload.len) else {
            h[1] = 126;
            std.mem.writeInt(u16, h[2..4], @intCast(payload.len), .big);
            hl = 4;
        }
        _ = platform.IO.writeParts(state.io, state.fd, h[0..hl], payload) catch {};
        return;
    }
    queue(opcode, "", payload);
    flush();
}
