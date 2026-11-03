//! Common video session operations.

const std = @import("std");
const platform = @import("../platform.zig");
const util = @import("../util.zig");
const stats = @import("../stats.zig");
const formats = @import("formats.zig");
const TILE = formats.TILE;
const AU_CAP = formats.AU_CAP;

const state = @import("state.zig");
const capture_ops = @import("capture.zig");
const transport = @import("transport.zig");
const encoder = @import("encoder.zig");
const memory = @import("../memory.zig");

pub fn onText(p: []const u8) bool {
    switch (p[0]) {
        'h' => {
            if (state.streaming) return true;
            state.caps = formats.parseCaps(p[1..]);
            return startSession();
        },
        'a' => onAck(std.fmt.parseInt(u32, p[1..], 10) catch return true),
        'k' => requestKey(),
        'p' => transport.sendWs(0x1, p), // the tablet's own RTT ping on this socket
        else => {},
    }
    return true;
}

pub fn fail(msg: []const u8) bool {
    var b: [160]u8 = undefined;
    const m = std.fmt.bufPrint(&b, "e{s}", .{msg}) catch return false;
    transport.sendWs(0x1, m);
    stats.say("styllink: screen for {f}: {s}\n", .{ stats.ip(state.peer), msg });
    return false;
}

pub fn startSession() bool {
    const env_region = state.cfg.display.region;
    state.rx0 = @intCast(env_region[0]);
    state.ry0 = @intCast(env_region[1]);
    state.rw = env_region[2];
    state.rh = env_region[3];
    const capture = state.cfg.video.source.len == 0;
    if (capture) {
        if (!capture_ops.openCapture()) return false;
    }
    state.ses = formats.negotiate(state.cfg, state.caps, state.rw, state.rh) orelse return fail("no stream format this tablet can decode");
    if (capture) capture_ops.allocBuffers() catch return fail("out of memory");
    if (state.ses.codec == .h264) {
        if (state.au.len == 0) state.au = state.allocator.alloc(u8, AU_CAP) catch return fail("out of memory");
        if (state.wire.len < AU_CAP + 65536) {
            memory.free(state.allocator, &state.wire);
            state.wire = state.allocator.alloc(u8, AU_CAP + 65536) catch return fail("out of memory");
        }
        if (state.au.len == 0 or state.wire.len == 0) return fail("out of memory");
        if (!encoder.spawnEncoder()) return fail("could not start the H.264 encoder");
    }
    var b: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&b, "ccodec={t};w={d};h={d};pix={t};enc={t};scale={d};fps={d};inflight={d};tile={d}", .{
        state.ses.codec, state.ses.sw, state.ses.sh, state.ses.pix, state.ses.enc, state.ses.scale, state.ses.fps, state.ses.inflight, TILE,
    }) catch return false;
    transport.sendWs(0x1, msg);
    state.streaming = true;
    state.session_start_ns = util.nowNs(state.io);
    state.total = .{};
    state.sec = .{};
    state.frame_id = 0;
    state.inflight = 0;
    requestKey();
    stats.say("styllink: screen -> {f}: {d}x{d} {s} ({s}{s}), up to {d} fps\n", .{
        stats.ip(state.peer),                              state.ses.sw,                                                  state.ses.sh,
        if (state.ses.codec == .h264) "h264" else "tiles", if (state.ses.codec == .h264) "" else @tagName(state.ses.pix), if (state.ses.codec == .h264) (if (state.ses.source) "external capture" else "damage-driven") else if (state.ses.enc == .lz4) " lz4" else " raw",
        state.ses.fps,
    });
    stats.logJson("\"ev\":\"video\",\"peer\":\"{f}\",\"codec\":\"{t}\",\"w\":{d},\"h\":{d},\"pix\":\"{t}\",\"enc\":\"{t}\",\"scale\":{d},\"fps\":{d},\"usb\":{}", .{
        stats.ip(state.peer), state.ses.codec, state.ses.sw, state.ses.sh, state.ses.pix, state.ses.enc, state.ses.scale, state.ses.fps, state.caps.usb,
    });
    return true;
}

pub fn endSession(why: []const u8) void {
    if (state.fd == platform.invalid_handle) return;
    if (state.streaming) {
        const secs = @max(1, (util.nowNs(state.io) - state.session_start_ns) / std.time.ns_per_s);
        stats.say("styllink: screen for {f} stopped ({s}): {d} frames, {d} KB/s, latency avg {d} ms\n", .{
            stats.ip(state.peer),            why,                                                                                 state.total.frames,
            state.total.bytes / 1024 / secs, if (state.total.lat_n > 0) state.total.lat_sum_us / state.total.lat_n / 1000 else 0,
        });
    }
    state.reactor.remove(state.fd);
    platform.IO.close(state.io, state.fd);
    state.fd = platform.invalid_handle;
    state.streaming = false;
    state.wire_off = 0;
    state.wire_len = 0;
    encoder.stopEncoder();
    capture_ops.closeCapture();
    capture_ops.freeBuffers();
}

pub fn requestKey() void {
    if (!state.streaming) return;
    if (state.ses.codec == .h264) {
        // A restarted encoder starts with SPS/PPS and an IDR frame.
        if (!state.ses.source and state.child != null and !state.enc_fresh) {
            encoder.stopEncoder();
            if (!encoder.spawnEncoder()) return endSession("H.264 encoder failed");
        }
        if (state.ses.source) return;
    }
    state.force_key = true;
    for (0..state.ses.th) |ty| @memset(state.dirty[ty][0..state.ses.tw], true);
    state.any_dirty = true;
}

pub fn onAck(id: u32) void {
    state.inflight -|= 1;
    const lat = (util.nowNs(state.io) -| state.sent_ns[id % state.sent_ns.len]) / 1000;
    for ([_]*state.Counters{ &state.sec, &state.total }) |c| {
        c.lat_sum_us += lat;
        c.lat_n += 1;
        c.lat_max_us = @max(c.lat_max_us, lat);
    }
}

pub fn stageMs(us: u64, n: u64) f64 {
    return if (n > 0) @as(f64, @floatFromInt(us)) / @as(f64, @floatFromInt(n)) / 1000 else 0;
}

pub fn onSecond() void {
    if (!state.streaming) return;
    stats.logJson("\"ev\":\"vstat\",\"fps\":{d},\"rects\":{d},\"kb\":{d},\"raw_kb\":{d},\"lat_avg_ms\":{d:.1},\"lat_max_ms\":{d:.1},\"work_avg_ms\":{d:.2},\"work_max_ms\":{d:.2},\"pix\":\"{t}\",\"capture_avg_ms\":{d:.2},\"diff_avg_ms\":{d:.2},\"encode_avg_ms\":{d:.2}", .{
        state.sec.frames,                                                                                          state.sec.rects,
        state.sec.bytes / 1024,                                                                                    state.sec.raw_bytes / 1024,
        if (state.sec.lat_n > 0) @as(f64, @floatFromInt(state.sec.lat_sum_us / state.sec.lat_n)) / 1000 else 0,    @as(f64, @floatFromInt(state.sec.lat_max_us)) / 1000,
        if (state.sec.frames > 0) @as(f64, @floatFromInt(state.sec.work_sum_us / state.sec.frames)) / 1000 else 0, @as(f64, @floatFromInt(state.sec.work_max_us)) / 1000,
        state.ses.pix,                                                                                             stageMs(state.sec.capture_sum_us, state.sec.tile_frames),
        stageMs(state.sec.diff_sum_us, state.sec.tile_frames),                                                     stageMs(state.sec.encode_sum_us, state.sec.tile_frames),
    });
    // True color that the link can't carry fast enough: halve the bytes.
    if (state.cfg.video.preset != .quality and state.cfg.video.pix == .auto and state.ses.codec == .tiles and state.ses.pix == .bgrx and state.caps.rgb565 and
        state.sec.lat_n >= 5 and state.sec.lat_sum_us / state.sec.lat_n > 40_000)
    {
        state.ses.pix = .rgb565;
        var b: [256]u8 = undefined;
        if (std.fmt.bufPrint(&b, "ccodec=tiles;w={d};h={d};pix=rgb565;enc={t};scale={d};fps={d};inflight={d};tile={d}", .{
            state.ses.sw, state.ses.sh, state.ses.enc, state.ses.scale, state.ses.fps, state.ses.inflight, TILE,
        })) |msg| transport.sendWs(0x1, msg) else |_| {}
        stats.say("styllink: screen: frames took {d} ms on average; switching to rgb565\n", .{state.sec.lat_sum_us / state.sec.lat_n / 1000});
        requestKey();
    }
    state.sec = .{};
}
