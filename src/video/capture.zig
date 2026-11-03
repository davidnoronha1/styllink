//! Common video capture operations.

const std = @import("std");
const platform = @import("../platform.zig");
const util = @import("../util.zig");
const lz4 = @import("../lz4.zig");
const formats = @import("formats.zig");
const pixels = @import("pixels.zig");
const tiles = @import("tiles.zig");
const TILE = formats.TILE;
const MAX_TY = formats.MAX_TY;
const RECT_ROWS = formats.RECT_ROWS;
const RECT_HDR = formats.RECT_HDR;
const MAX_WS_HDR = formats.MAX_WS_HDR;
const Enc = formats.Enc;
const Rect = tiles.Rect;

const state = @import("state.zig");
const runtime = @import("runtime.zig");
const session_ops = @import("session.zig");
const transport = @import("transport.zig");
const encoder = @import("encoder.zig");
const memory = @import("../memory.zig");

pub fn openCapture() bool {
    state.capture.open(state.io, state.allocator, state.environ, .{ .x = state.rx0, .y = state.ry0, .w = state.rw, .h = state.rh }, &state.capture, onDamage) catch |err| {
        return session_ops.fail(switch (err) {
            error.NoDisplay => "screen sharing requires a local display",
            error.Unsupported => "screen capture does not support this pixel format",
            error.Auth => "screen capture access was refused",
            error.InvalidRegion => "the mapped region is outside the screen",
            error.OutOfMemory => "out of memory",
            else => "cannot start screen capture",
        });
    };
    state.rw = state.capture.region.w;
    state.rh = state.capture.region.h;
    state.cap = state.capture.pixels;
    runtime.watch(state.capture.source(), .{ .readable = true }, .capture);
    if (state.capture.needsCursorPolling()) state.cursor_timer.arm(8 * std.time.ns_per_ms, 8 * std.time.ns_per_ms);
    return true;
}

pub fn closeCapture() void {
    state.cursor_timer.arm(0, 0);
    if (state.capture.source() != platform.invalid_handle) state.reactor.remove(state.capture.source());
    state.capture.close();
    state.cap = &.{};
}

pub fn onDamage(_: *anyopaque, r: platform.types.Region) void {
    if (!state.streaming or state.ses.source) return;
    const span: i32 = @intCast(TILE * state.ses.scale);
    const x0 = @max(r.x, state.rx0) - state.rx0;
    const y0 = @max(r.y, state.ry0) - state.ry0;
    const x1 = @min(r.x + @as(i32, @intCast(r.w)), state.rx0 + @as(i32, @intCast(state.rw))) - state.rx0;
    const y1 = @min(r.y + @as(i32, @intCast(r.h)), state.ry0 + @as(i32, @intCast(state.rh))) - state.ry0;
    if (x1 <= x0 or y1 <= y0) return;
    const tx0: usize = @intCast(@divTrunc(x0, span));
    const ty0: usize = @intCast(@divTrunc(y0, span));
    const tx1: usize = @min(@as(usize, @intCast(@divTrunc(x1 - 1, span))), state.ses.tw - 1);
    const ty1: usize = @min(@as(usize, @intCast(@divTrunc(y1 - 1, span))), state.ses.th - 1);
    if (tx0 > tx1 or ty0 > ty1) return;
    for (ty0..ty1 + 1) |ty| @memset(state.dirty[ty][tx0 .. tx1 + 1], true);
    state.any_dirty = true;
}

pub fn allocBuffers() std.mem.Allocator.Error!void {
    freeBuffers();
    errdefer freeBuffers();
    const frame = @as(usize, state.ses.sw) * state.ses.sh * 4;
    const rect = @as(usize, state.ses.sw) * TILE * RECT_ROWS * 4;
    state.prev = try state.allocator.alloc(u8, frame);
    @memset(state.prev, 0);
    state.scratch = try state.allocator.alloc(u8, rect);
    state.zbuf = try state.allocator.alloc(u8, lz4.bound(rect));
    state.wire = try state.allocator.alloc(u8, frame + @as(usize, state.ses.tw) * state.ses.th * (RECT_HDR + MAX_WS_HDR) + 65536);
}

pub fn freeBuffers() void {
    memory.free(state.allocator, &state.prev);
    memory.free(state.allocator, &state.scratch);
    memory.free(state.allocator, &state.zbuf);
    memory.free(state.allocator, &state.wire);
    memory.free(state.allocator, &state.au);
}

pub fn armPace(ns: u64) void {
    if (state.pace_armed) return;
    state.pace_timer.arm(@max(ns, 1000), 0);
    state.pace_armed = true;
}

pub fn tryFrame() void {
    if (!state.streaming or state.ses.source or !state.any_dirty) return;
    if (state.wire_len != state.wire_off) return; // last frame still leaving
    if (state.inflight >= state.ses.inflight) return; // wait for the tablet
    if (state.ses.codec == .h264 and (state.enc_in_off < state.enc_in_len or state.enc_real > 0)) return;
    const now = util.nowNs(state.io);
    // A frame cap only adds delay while the link keeps up: by default
    // capture may run at twice the display rate, so a change right after a
    // frame still makes the next refresh. An explicit internal fps setting caps capture.
    const gap = std.time.ns_per_s / (if (state.cfg.video.fps > 0) state.ses.fps else state.ses.fps * 2);
    if (now - state.last_frame_ns < gap) return armPace(state.last_frame_ns + gap - now);
    state.last_frame_ns = now;
    captureFrame(now) catch session_ops.endSession("lost the screen capture");
}

pub fn captureFrame(now: u64) !void {
    // Take this frame's damage; anything drawn from here on is reported anew.
    try state.capture.beginFrame();
    const key = state.force_key;
    state.force_key = false;
    state.any_dirty = false;
    for (0..state.ses.th) |ty| {
        state.snap[ty] = state.dirty[ty];
        @memset(state.dirty[ty][0..state.ses.tw], false);
    }

    // Damaged tiles -> a few capture bands: consecutive tile rows with
    // overlapping spans share one shared-memory copy.
    var nb: usize = 0;
    for (0..state.ses.th) |ty| {
        const row = state.snap[ty][0..state.ses.tw];
        const first = std.mem.indexOfScalar(bool, row, true) orelse continue;
        const last = std.mem.lastIndexOfScalar(bool, row, true).?;
        const t: u32 = @intCast(ty);
        if (nb > 0 and state.bands[nb - 1].ty1 + 1 == t and first <= state.bands[nb - 1].tx1 and last >= state.bands[nb - 1].tx0) {
            const b = &state.bands[nb - 1];
            b.ty1 = t;
            b.tx0 = @min(b.tx0, @as(u32, @intCast(first)));
            b.tx1 = @max(b.tx1, @as(u32, @intCast(last)));
        } else {
            state.bands[nb] = .{ .tx0 = @intCast(first), .tx1 = @intCast(last), .ty0 = t, .ty1 = t };
            nb += 1;
        }
    }
    if (nb == 0) return;

    const sc = state.ses.scale;
    var off: usize = 0;
    var requests: [MAX_TY]platform.types.CaptureBand = undefined;
    for (state.bands[0..nb], requests[0..nb]) |*b, *request| {
        const px0 = b.tx0 * TILE * sc;
        const px1 = @min((b.tx1 + 1) * TILE, state.ses.sw) * sc;
        const py0 = b.ty0 * TILE * sc;
        const py1 = @min((b.ty1 + 1) * TILE, state.ses.sh) * sc;
        const region: platform.types.Region = .{
            .x = state.rx0 + @as(i32, @intCast(px0)),
            .y = state.ry0 + @as(i32, @intCast(py0)),
            .w = px1 - px0,
            .h = py1 - py0,
        };
        b.off = off;
        b.stride = @as(usize, region.w) * 4;
        request.* = .{ .region = region, .off = off, .stride = b.stride };
        off += b.stride * region.h;
    }
    try state.capture.readBands(requests[0..nb]);

    const captured_ns = util.nowNs(state.io);
    // Which tiles really changed (damage is often a whole window).
    var n_changed: usize = 0;
    for (state.bands[0..nb]) |b| {
        for (b.ty0..b.ty1 + 1) |ty| {
            for (b.tx0..b.tx1 + 1) |tx| {
                if (!state.snap[ty][tx]) continue;
                const c = diffTile(b, @intCast(tx), @intCast(ty)) or key;
                state.changed[ty][tx] = c;
                if (c) n_changed += 1;
            }
        }
    }
    if (n_changed == 0) return;

    if (state.ses.codec == .h264) return encoder.feedEncoder(now);

    const diffed_ns = util.nowNs(state.io);
    const nr = tiles.buildRects(state.ses, &state.changed, &state.rects);
    const id = state.frame_id;
    state.frame_id +%= 1;
    state.sent_ns[id % state.sent_ns.len] = now;
    var bytes: usize = 0;
    var raw_bytes: usize = 0;
    for (state.rects[0..nr], 0..) |r, i| {
        const sent = sendRect(r, id, now, i + 1 == nr, key);
        if (state.fd == platform.invalid_handle) return; // the send failed and ended the session
        bytes += sent[0];
        raw_bytes += sent[1];
    }
    state.inflight += 1;
    const work = (util.nowNs(state.io) - now) / 1000;
    for ([_]*state.Counters{ &state.sec, &state.total }) |c| {
        c.frames += 1;
        c.rects += nr;
        c.bytes += bytes;
        c.raw_bytes += raw_bytes;
        c.tile_frames += 1;
        c.capture_sum_us += (captured_ns - now) / 1000;
        c.diff_sum_us += (diffed_ns - captured_ns) / 1000;
        c.encode_sum_us += work -| ((diffed_ns - now) / 1000);
        c.work_sum_us += work;
        c.work_max_us = @max(c.work_max_us, work);
    }
}

pub fn diffTile(b: state.Band, tx: u32, ty: u32) bool {
    const sx0 = tx * TILE;
    const sy0 = ty * TILE;
    const w = @min(TILE, state.ses.sw - sx0);
    const h = @min(TILE, state.ses.sh - sy0);
    const bpp = state.ses.bpp();
    const sc = state.ses.scale;
    var diff: u32 = 0;
    for (0..h) |r| {
        const cy = (sy0 + r - b.ty0 * TILE) * sc;
        const cx = (sx0 - b.tx0 * TILE) * sc;
        const src = state.cap[b.off + cy * b.stride + cx * 4 ..];
        const dst = state.prev[((sy0 + r) * state.ses.sw + sx0) * bpp ..][0 .. w * bpp];
        const below = if (sc == 2) state.cap[b.off + (cy + 1) * b.stride + cx * 4 ..] else src;
        diff |= switch (state.ses.pix) {
            .bgrx => if (sc == 2) pixels.convRow(.bgrx, true, src, below, dst, w) else pixels.convRow(.bgrx, false, src, src, dst, w),
            .rgb565 => if (sc == 2) pixels.convRow(.rgb565, true, src, below, dst, w) else pixels.convRow(.rgb565, false, src, src, dst, w),
        };
    }
    return diff != 0;
}

pub fn sendRect(r: Rect, id: u32, now: u64, last: bool, key: bool) [2]usize {
    const bpp = state.ses.bpp();
    const x = r.tx0 * TILE;
    const y = r.ty0 * TILE;
    const w = @min((r.tx1 + 1) * TILE, state.ses.sw) - x;
    const h = @min((r.ty1 + 1) * TILE, state.ses.sh) - y;
    const row = @as(usize, w) * bpp;
    const raw_len = row * h;
    for (0..h) |i| @memcpy(state.scratch[i * row ..][0..row], state.prev[((y + i) * state.ses.sw + x) * bpp ..][0..row]);
    var payload: []const u8 = state.scratch[0..raw_len];
    var enc: Enc = .raw;
    if (state.ses.enc == .lz4) {
        const n = state.comp.compress(payload, state.zbuf);
        if (n < raw_len) {
            payload = state.zbuf[0..n];
            enc = .lz4;
        }
    }
    var hdr: [RECT_HDR]u8 = undefined;
    hdr[0] = 'T';
    hdr[1] = @as(u8, if (last) 1 else 0) | @as(u8, if (key) 2 else 0);
    hdr[2] = @backingInt(enc);
    hdr[3] = @backingInt(state.ses.pix);
    std.mem.writeInt(u32, hdr[4..8], id, .little);
    std.mem.writeInt(u32, hdr[8..12], @truncate(now / 100_000), .little);
    std.mem.writeInt(u16, hdr[12..14], @intCast(x), .little);
    std.mem.writeInt(u16, hdr[14..16], @intCast(y), .little);
    std.mem.writeInt(u16, hdr[16..18], @intCast(w), .little);
    std.mem.writeInt(u16, hdr[18..20], @intCast(h), .little);
    std.mem.writeInt(u32, hdr[20..24], @intCast(raw_len), .little);
    transport.queue(0x2, &hdr, payload);
    transport.flush(); // start sending while the next rectangle is encoded
    return .{ payload.len + RECT_HDR, raw_len };
}

test "video buffers release every partial allocation on failure" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            state.allocator = allocator;
            state.ses = .{ .sw = 64, .sh = 64, .tw = 2, .th = 2 };
            defer freeBuffers();
            try allocBuffers();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}
