//! Remote screen: the mapped desktop region streamed to the tablet on its own
//! WebSocket (/video) and its own thread, so a big frame never queues in
//! front of a pen sample.
//!
//! The tablet opens with what it can show ("h": display size, refresh rate,
//! pixel formats, tile encodings, codecs, USB or Wi-Fi) and the server answers
//! with what it picked ("c"). Two codecs:
//!
//!  * tiles: X DAMAGE says which areas changed; only those are copied out of
//!    the X server (MIT-SHM), compared 32x32 tile by tile against the last
//!    frame, and the tiles that really changed go out as rectangles (LZ4 or
//!    raw, BGRX or RGB565). A pen stroke costs a few small rectangles.
//!  * h264: the same damage-driven capture feeds an external encoder
//!    (--video-encoder, x264 by default), or a command captures and encodes on
//!    its own (--video-source, e.g. Wayland or a hardware pipeline).
//!
//! Latency comes first: a frame is captured the moment damage arrives (up to
//! the frame rate cap), each rectangle is written to the socket as soon as it
//! is encoded, and capture waits while the tablet hasn't acknowledged
//! `inflight` frames. Damage keeps accumulating meanwhile, so a slow link
//! skips stale intermediate frames instead of queueing them.

const std = @import("std");
const linux = std.os.linux;
const util = @import("util.zig");
const config = @import("config.zig");
const stats = @import("stats.zig");
const x11 = @import("x11.zig");
const lz4 = @import("lz4.zig");
const ws = @import("ws.zig");

pub const TILE = 32;
const MAX_TX = 256; // up to 8192 px wide streams
const MAX_TY = 256;
const RECT_ROWS = 4; // tile rows per rectangle: bounded buffers, earlier decode
const RECT_HDR = 24;
const H264_HDR = 16;
const MAX_WS_HDR = 10;
const AU_CAP = 8 << 20;

const T_HANDOFF: u64 = 1;
const T_CLIENT: u64 = 2;
const T_X: u64 = 3;
const T_PACE: u64 = 4;
const T_STAT: u64 = 5;
const T_ENC_IN: u64 = 6;
const T_ENC_OUT: u64 = 7;

pub const DEFAULT_ENCODER = "ffmpeg -hide_banner -loglevel error -probesize 32 -analyzeduration 0 -fflags +nobuffer " ++
    "-f rawvideo -pix_fmt bgr0 -video_size {w}x{h} -framerate {fps} -i - -an -fps_mode passthrough " ++
    "-c:v libx264 -preset ultrafast -tune zerolatency -bf 0 -g 600 " ++
    "-x264-params aud=1:slices=1:intra-refresh=1:repeat-headers=1 -pix_fmt yuv420p " ++
    "-f h264 -flush_packets 1 -avioflags direct -";

const Pix = enum(u8) { bgrx = 0, rgb565 = 1 };
const Enc = enum(u8) { raw = 0, lz4 = 1 };
const Codec = enum { tiles, h264 };

pub const Caps = struct {
    w: u32 = 0,
    h: u32 = 0,
    hz: u32 = 60,
    bgrx: bool = false,
    rgb565: bool = false,
    lz4: bool = false,
    raw: bool = false,
    tiles: bool = false,
    h264: bool = false,
    usb: bool = false,
};

pub const Session = struct {
    codec: Codec = .tiles,
    pix: Pix = .bgrx,
    enc: Enc = .lz4,
    scale: u32 = 1,
    sw: u32 = 0, // stream size
    sh: u32 = 0,
    tw: u32 = 0, // tiles
    th: u32 = 0,
    fps: u32 = 60,
    inflight: u32 = 2,
    source: bool = false, // h264 from --video-source: no X capture

    fn bpp(s: Session) u32 {
        return if (s.pix == .rgb565) 2 else 4;
    }
};

var cfg: config.Config = .{};
var environ: std.process.Environ = undefined;
var handoff: [2]i32 = .{ -1, -1 };
var epfd: i32 = -1;
var pace_fd: i32 = -1;
var stat_fd: i32 = -1;

// The one video client (a newer one replaces it).
var fd: i32 = -1;
var peer: [4]u8 = .{ 0, 0, 0, 0 };
var rx: [8192]u8 = undefined;
var rx_len: usize = 0;
var caps: Caps = .{};
var ses: Session = .{};
var streaming = false;
var out_armed = false;

var wire: []u8 = &.{};
var wire_off: usize = 0;
var wire_len: usize = 0;

// Region actually captured (the mapped region clipped to the X screen).
var rx0: i32 = 0;
var ry0: i32 = 0;
var rw: u32 = 0;
var rh: u32 = 0;

var xc: x11.Conn = .{};
var x_small: [65536]u8 = undefined;
var x_big: []u8 = &.{};
var cap: []u8 = &.{}; // captured pixels (the shared memory segment when available)
var cap_own: []u8 = &.{};
var prev: []u8 = &.{}; // what the tablet shows, in stream pixels
var scratch: []u8 = &.{};
var zbuf: []u8 = &.{};
var comp: lz4.Compressor = .{};
var dirty: [MAX_TY][MAX_TX]bool = @splat(@splat(false));
var snap: [MAX_TY][MAX_TX]bool = @splat(@splat(false));
var changed: [MAX_TY][MAX_TX]bool = @splat(@splat(false));
var any_dirty = false;
var force_key = false;

var frame_id: u32 = 0;
var inflight: u32 = 0;
var last_frame_ns: u64 = 0;
var pace_armed = false;
var sent_ns: [64]u64 = @splat(0);

// Per-second counters for the log, and per-session totals.
const Counters = struct {
    frames: u64 = 0,
    rects: u64 = 0,
    bytes: u64 = 0,
    raw_bytes: u64 = 0,
    lat_sum_us: u64 = 0,
    lat_n: u64 = 0,
    lat_max_us: u64 = 0,
    work_max_us: u64 = 0,
    work_sum_us: u64 = 0,
};
var sec: Counters = .{};
var total: Counters = .{};
var session_start_ns: u64 = 0;

// H.264 encoder or source process.
var enc_pid: i32 = 0;
var enc_in: i32 = -1;
var enc_out: i32 = -1;
var enc_in_off: usize = 0;
var enc_in_len: usize = 0;
// Frames inside the encoder, oldest first. Encoders hold frames back (ffmpeg
// keeps one in its pipeline whatever the flags), so after a real frame the
// same picture is fed again until the real one comes out; those duplicates
// encode to tiny skip frames that change nothing on screen.
const Fed = struct { ns: u64, dup: bool };
var enc_q: [16]Fed = undefined;
var enc_q_head: usize = 0;
var enc_q_len: usize = 0;
var enc_real: usize = 0; // real frames still inside
var au: []u8 = &.{};
var au_len: usize = 0;
var enc_fresh = false; // nothing fed since it started: already begins with a key frame

// ---------------------------------------------------------------- main thread side

pub fn start(c: config.Config, env: std.process.Environ) void {
    cfg = c;
    environ = env;
    if (!cfg.video) return;
    // Writes to a vanished tablet or encoder must fail, not kill the server.
    const ign = linux.Sigaction{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(.PIPE, &ign, null);
    if (linux.errno(linux.pipe2(&handoff, .{ .CLOEXEC = true })) != .SUCCESS) return;
    const t = std.Thread.spawn(.{ .stack_size = 1 << 20 }, run, .{}) catch {
        std.debug.print("styllink: no remote screen (thread)\n", .{});
        return;
    };
    t.detach();
}

pub fn enabled() bool {
    return cfg.video and handoff[1] != -1;
}

/// Hands an upgraded /video connection to the video thread.
pub fn adopt(client_fd: i32) void {
    if (!enabled()) {
        _ = linux.close(client_fd);
        return;
    }
    const v: i32 = client_fd;
    if (linux.write(handoff[1], std.mem.asBytes(&v), 4) != 4) _ = linux.close(client_fd);
}

// ---------------------------------------------------------------- thread

fn run() void {
    // The pen thread may run SCHED_FIFO (--realtime); video must never
    // compete with it, so this thread drops back to normal scheduling.
    const param = linux.sched_param{ .priority = 0 };
    _ = linux.sched_setscheduler(0, .{ .mode = .NORMAL }, &param);

    epfd = @intCast(util.check(linux.epoll_create1(linux.EPOLL.CLOEXEC), "epoll_create1"));
    pace_fd = @intCast(util.check(linux.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true }), "timerfd_create"));
    stat_fd = @intCast(util.check(linux.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true }), "timerfd_create"));
    const second = linux.timespec{ .sec = 1, .nsec = 0 };
    const spec = linux.itimerspec{ .it_interval = second, .it_value = second };
    _ = linux.timerfd_settime(stat_fd, .{}, &spec, null);
    watch(handoff[0], linux.EPOLL.IN, T_HANDOFF);
    watch(pace_fd, linux.EPOLL.IN, T_PACE);
    watch(stat_fd, linux.EPOLL.IN, T_STAT);

    var events: [8]linux.epoll_event = undefined;
    while (true) {
        const rc = linux.epoll_wait(epfd, &events, events.len, -1);
        if (linux.errno(rc) == .INTR) continue;
        if (linux.errno(rc) != .SUCCESS) return;
        for (events[0..rc]) |e| handle(e);
        tryFrame();
    }
}

fn handle(e: linux.epoll_event) void {
    switch (e.data.u64) {
        T_HANDOFF => {
            var v: i32 = -1;
            if (linux.read(handoff[0], std.mem.asBytes(&v), 4) != 4) return;
            if (fd != -1) endSession("replaced by a new connection");
            accept(v);
        },
        T_CLIENT => {
            if (fd == -1) return;
            if (e.events & linux.EPOLL.OUT != 0) flush();
            if (fd == -1) return;
            if (e.events & linux.EPOLL.IN != 0) {
                if (!readClient()) return endSession("disconnected");
            } else if (e.events & (linux.EPOLL.HUP | linux.EPOLL.ERR | linux.EPOLL.RDHUP) != 0) {
                return endSession("disconnected");
            }
        },
        T_X => xc.pump() catch endSession("lost the X server"),
        T_PACE => {
            var n: u64 = 0;
            _ = linux.read(pace_fd, std.mem.asBytes(&n), 8);
            pace_armed = false;
        },
        T_STAT => {
            var n: u64 = 0;
            _ = linux.read(stat_fd, std.mem.asBytes(&n), 8);
            onSecond();
        },
        T_ENC_IN => writeEncoder(),
        T_ENC_OUT => readEncoder(),
        else => {},
    }
}

fn watch(f: i32, events: u32, tag: u64) void {
    var ev = linux.epoll_event{ .events = events, .data = .{ .u64 = tag } };
    _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, f, &ev);
}

fn rewatch(f: i32, events: u32, tag: u64) void {
    var ev = linux.epoll_event{ .events = events, .data = .{ .u64 = tag } };
    _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_MOD, f, &ev);
}

fn accept(v: i32) void {
    fd = v;
    rx_len = 0;
    caps = .{};
    var sa: linux.sockaddr.in = undefined;
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    peer = if (linux.errno(linux.getpeername(fd, @ptrCast(&sa), &len)) == .SUCCESS) @bitCast(sa.addr) else .{ 0, 0, 0, 0 };
    // Video rides the Wi-Fi video queue (DSCP AF41), below the pen's voice
    // queue, and gets a send buffer big enough for whole frames.
    const tos: i32 = 0x88;
    _ = linux.setsockopt(fd, linux.IPPROTO.IP, 1, std.mem.asBytes(&tos), 4);
    const sndbuf: i32 = 2 << 20;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.SNDBUF, std.mem.asBytes(&sndbuf), 4);
    _ = linux.fcntl(fd, linux.F.SETFL, 0o4000); // O_NONBLOCK
    out_armed = false;
    watch(fd, linux.EPOLL.IN | linux.EPOLL.RDHUP, T_CLIENT);
}

// ---------------------------------------------------------------- client messages

fn readClient() bool {
    const rc = linux.read(fd, rx[rx_len..].ptr, rx.len - rx_len);
    switch (linux.errno(rc)) {
        .SUCCESS => if (rc == 0) return false,
        .AGAIN, .INTR => return true,
        else => return false,
    }
    rx_len += rc;
    var off: usize = 0;
    defer {
        std.mem.copyForwards(u8, rx[0 .. rx_len - off], rx[off..rx_len]);
        rx_len -= off;
    }
    while (true) {
        const b = rx[off..rx_len];
        if (b.len < 2) return true;
        if (b[1] & 0x80 == 0) return false; // clients must mask
        var plen: usize = b[1] & 0x7f;
        var hl: usize = 2;
        if (plen == 126) {
            if (b.len < 4) return true;
            plen = std.mem.readInt(u16, b[2..4], .big);
            hl = 4;
        } else if (plen == 127) return false;
        if (hl + 4 + plen > rx.len) return false;
        if (b.len < hl + 4 + plen) return true;
        const payload = b[hl + 4 ..][0..plen];
        ws.unmask(payload, b[hl..][0..4]);
        off += hl + 4 + plen;
        switch (b[0] & 0x0f) {
            0x1 => if (payload.len > 0) if (!onText(payload)) return false,
            0x9 => sendWs(0xA, payload),
            0x8 => return false,
            else => {},
        }
        if (fd == -1) return true;
    }
}

fn onText(p: []const u8) bool {
    switch (p[0]) {
        'h' => {
            if (streaming) return true;
            caps = parseCaps(p[1..]);
            return startSession();
        },
        'a' => onAck(std.fmt.parseInt(u32, p[1..], 10) catch return true),
        'k' => requestKey(),
        'p' => sendWs(0x1, p), // the tablet's own RTT ping on this socket
        else => {},
    }
    return true;
}

pub fn parseCaps(s: []const u8) Caps {
    var c: Caps = .{};
    var it = std.mem.splitScalar(u8, s, ';');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        const k = kv[0..eq];
        const v = kv[eq + 1 ..];
        if (std.mem.eql(u8, k, "w")) c.w = std.fmt.parseInt(u32, v, 10) catch 0;
        if (std.mem.eql(u8, k, "h")) c.h = std.fmt.parseInt(u32, v, 10) catch 0;
        if (std.mem.eql(u8, k, "hz")) c.hz = std.math.clamp(std.fmt.parseInt(u32, v, 10) catch 60, 1, 1000);
        if (std.mem.eql(u8, k, "link")) c.usb = std.mem.eql(u8, v, "usb");
        var items = std.mem.splitScalar(u8, v, ',');
        while (items.next()) |item| {
            if (std.mem.eql(u8, k, "pix")) {
                if (std.mem.eql(u8, item, "bgrx")) c.bgrx = true;
                if (std.mem.eql(u8, item, "rgb565")) c.rgb565 = true;
            } else if (std.mem.eql(u8, k, "enc")) {
                if (std.mem.eql(u8, item, "lz4")) c.lz4 = true;
                if (std.mem.eql(u8, item, "raw")) c.raw = true;
            } else if (std.mem.eql(u8, k, "codec")) {
                if (std.mem.eql(u8, item, "tiles")) c.tiles = true;
                if (std.mem.eql(u8, item, "h264")) c.h264 = true;
            }
        }
    }
    if (!c.bgrx and !c.rgb565) c.bgrx = true;
    if (!c.lz4 and !c.raw) c.raw = true;
    if (!c.tiles and !c.h264) c.tiles = true;
    return c;
}

/// Picks the stream format for a tablet. `w`/`h` is the captured region.
pub fn negotiate(c: config.Config, k: Caps, w: u32, h: u32) ?Session {
    var s: Session = .{ .inflight = c.video_inflight };
    if (c.video_source.len > 0) {
        if (!k.h264) return null;
        s.codec = .h264;
        s.source = true;
    } else if (c.video_codec == .h264) {
        s.codec = if (k.h264) .h264 else if (k.tiles) .tiles else return null;
    } else {
        s.codec = if (k.tiles) .tiles else if (k.h264) .h264 else return null;
    }
    s.fps = if (c.video_fps > 0) @min(c.video_fps, k.hz) else k.hz;

    // Half resolution only pays off when the tablet couldn't show the extra
    // pixels anyway (or nearly so, on Wi-Fi where bandwidth is scarce).
    s.scale = c.video_scale;
    if (s.scale == 0) {
        s.scale = 1;
        if (k.w > 0 and k.h > 0) {
            const need: u64 = if (k.usb) 100 else 75; // percent of the tablet's pixels
            if (@as(u64, w / 2) * 100 >= k.w * need and @as(u64, h / 2) * 100 >= k.h * need) s.scale = 2;
        }
    }
    s.sw = w / s.scale;
    s.sh = h / s.scale;

    if (s.codec == .h264) {
        s.pix = .bgrx; // what the encoder reads
        s.enc = .raw;
        s.sw &= ~@as(u32, 1); // 4:2:0 needs even sizes
        s.sh &= ~@as(u32, 1);
    } else {
        s.pix = switch (c.video_pix) {
            .bgrx => if (k.bgrx) .bgrx else .rgb565,
            .rgb565 => if (k.rgb565) .rgb565 else .bgrx,
            // True color over USB; half the bytes over Wi-Fi.
            .auto => if (k.usb and k.bgrx) .bgrx else if (k.rgb565) .rgb565 else .bgrx,
        };
        s.enc = switch (c.video_enc) {
            .raw => if (k.raw) .raw else .lz4,
            .lz4, .auto => if (k.lz4) .lz4 else .raw,
        };
    }
    s.tw = (s.sw + TILE - 1) / TILE;
    s.th = (s.sh + TILE - 1) / TILE;
    if (s.sw == 0 or s.sh == 0 or s.tw > MAX_TX or s.th > MAX_TY) return null;
    return s;
}

fn fail(msg: []const u8) bool {
    var b: [160]u8 = undefined;
    const m = std.fmt.bufPrint(&b, "e{s}", .{msg}) catch return false;
    sendWs(0x1, m);
    stats.say("styllink: screen for {f}: {s}\n", .{ stats.ip(peer), msg });
    return false;
}

fn startSession() bool {
    const env_region = cfg.region;
    rx0 = @intCast(env_region[0]);
    ry0 = @intCast(env_region[1]);
    rw = env_region[2];
    rh = env_region[3];
    const capture = cfg.video_source.len == 0;
    if (capture) {
        if (!openX()) return false;
    }
    ses = negotiate(cfg, caps, rw, rh) orelse return fail("no stream format this tablet can decode");
    if (capture and !allocBuffers()) return fail("out of memory");
    if (ses.codec == .h264) {
        if (au.len == 0) au = alloc(AU_CAP);
        if (wire.len < AU_CAP + 65536) {
            free(&wire);
            wire = alloc(AU_CAP + 65536);
        }
        if (au.len == 0 or wire.len == 0) return fail("out of memory");
        if (!spawnEncoder()) return fail("could not start the H.264 encoder");
    }
    var b: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&b, "ccodec={t};w={d};h={d};pix={t};enc={t};scale={d};fps={d};inflight={d};tile={d}", .{
        ses.codec, ses.sw, ses.sh, ses.pix, ses.enc, ses.scale, ses.fps, ses.inflight, TILE,
    }) catch return false;
    sendWs(0x1, msg);
    streaming = true;
    session_start_ns = util.nowNs();
    total = .{};
    sec = .{};
    frame_id = 0;
    inflight = 0;
    requestKey();
    stats.say("styllink: screen -> {f}: {d}x{d} {s} ({s}{s}), up to {d} fps\n", .{
        stats.ip(peer),                                   ses.sw, ses.sh,
        if (ses.codec == .h264) "h264" else "tiles",      if (ses.codec == .h264) "" else @tagName(ses.pix),
        if (ses.codec == .h264) (if (ses.source) "external capture" else "damage-driven") else if (ses.enc == .lz4) " lz4" else " raw",
        ses.fps,
    });
    stats.logJson("\"ev\":\"video\",\"peer\":\"{f}\",\"codec\":\"{t}\",\"w\":{d},\"h\":{d},\"pix\":\"{t}\",\"enc\":\"{t}\",\"scale\":{d},\"fps\":{d},\"usb\":{}", .{
        stats.ip(peer), ses.codec, ses.sw, ses.sh, ses.pix, ses.enc, ses.scale, ses.fps, caps.usb,
    });
    return true;
}

fn endSession(why: []const u8) void {
    if (fd == -1) return;
    if (streaming) {
        const secs = @max(1, (util.nowNs() - session_start_ns) / std.time.ns_per_s);
        stats.say("styllink: screen for {f} stopped ({s}): {d} frames, {d} KB/s, latency avg {d} ms\n", .{
            stats.ip(peer),                     why,                                                                  total.frames,
            total.bytes / 1024 / secs, if (total.lat_n > 0) total.lat_sum_us / total.lat_n / 1000 else 0,
        });
    }
    _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, fd, null);
    _ = linux.close(fd);
    fd = -1;
    streaming = false;
    wire_off = 0;
    wire_len = 0;
    stopEncoder();
    closeX();
    freeBuffers();
}

fn requestKey() void {
    if (!streaming) return;
    if (ses.codec == .h264) {
        // A restarted encoder starts with SPS/PPS and an IDR frame.
        if (!ses.source and enc_pid != 0 and !enc_fresh) {
            stopEncoder();
            if (!spawnEncoder()) return endSession("H.264 encoder failed");
        }
        if (ses.source) return;
    }
    force_key = true;
    for (0..ses.th) |ty| @memset(dirty[ty][0..ses.tw], true);
    any_dirty = true;
}

fn onAck(id: u32) void {
    inflight -|= 1;
    const lat = (util.nowNs() -| sent_ns[id % sent_ns.len]) / 1000;
    for ([_]*Counters{ &sec, &total }) |c| {
        c.lat_sum_us += lat;
        c.lat_n += 1;
        c.lat_max_us = @max(c.lat_max_us, lat);
    }
}

fn onSecond() void {
    if (!streaming) return;
    stats.logJson("\"ev\":\"vstat\",\"fps\":{d},\"rects\":{d},\"kb\":{d},\"raw_kb\":{d},\"lat_avg_ms\":{d:.1},\"lat_max_ms\":{d:.1},\"work_avg_ms\":{d:.2},\"work_max_ms\":{d:.2},\"pix\":\"{t}\"", .{
        sec.frames,                                                                                                    sec.rects,
        sec.bytes / 1024,                                                                                              sec.raw_bytes / 1024,
        if (sec.lat_n > 0) @as(f64, @floatFromInt(sec.lat_sum_us / sec.lat_n)) / 1000 else 0,                         @as(f64, @floatFromInt(sec.lat_max_us)) / 1000,
        if (sec.frames > 0) @as(f64, @floatFromInt(sec.work_sum_us / sec.frames)) / 1000 else 0, @as(f64, @floatFromInt(sec.work_max_us)) / 1000,
        ses.pix,
    });
    // True color that the link can't carry fast enough: halve the bytes.
    if (cfg.video_pix == .auto and ses.codec == .tiles and ses.pix == .bgrx and caps.rgb565 and
        sec.lat_n >= 5 and sec.lat_sum_us / sec.lat_n > 40_000)
    {
        ses.pix = .rgb565;
        var b: [256]u8 = undefined;
        if (std.fmt.bufPrint(&b, "ccodec=tiles;w={d};h={d};pix=rgb565;enc={t};scale={d};fps={d};inflight={d};tile={d}", .{
            ses.sw, ses.sh, ses.enc, ses.scale, ses.fps, ses.inflight, TILE,
        })) |msg| sendWs(0x1, msg) else |_| {}
        stats.say("styllink: screen: frames took {d} ms on average; switching to rgb565\n", .{sec.lat_sum_us / sec.lat_n / 1000});
        requestKey();
    }
    sec = .{};
}

// ---------------------------------------------------------------- X capture

fn openX() bool {
    xc = .{};
    xc.on_damage = onDamage;
    xc.ctx = @ptrCast(&xc);
    xc.open(environ, &x_small) catch |e| {
        return fail(switch (e) {
            error.NoDisplay => "no X display (DISPLAY unset or remote); on Wayland use --video-source",
            error.Unsupported => "the X screen is not 24-bit BGRX",
            error.Auth => "the X server refused access (XAUTHORITY?)",
            else => "cannot connect to the X server",
        });
    };
    // Capture the part of the mapped region that is on the X screen.
    const x1 = @min(rx0 + @as(i32, @intCast(rw)), @as(i32, @intCast(xc.root_w)));
    const y1 = @min(ry0 + @as(i32, @intCast(rh)), @as(i32, @intCast(xc.root_h)));
    if (x1 <= rx0 or y1 <= ry0) {
        xc.close();
        return fail("the mapped region is outside the X screen");
    }
    rw = @intCast(x1 - rx0);
    rh = @intCast(y1 - ry0);
    const full = @as(usize, rw) * rh * 4;
    xc.startCapture(full) catch {
        xc.close();
        return fail("the X server has no DAMAGE extension");
    };
    if (xc.shm) |m| {
        cap = m;
    } else {
        cap_own = alloc(full);
        x_big = alloc(full + 65536);
        if (cap_own.len == 0 or x_big.len == 0) {
            xc.close();
            return fail("out of memory");
        }
        cap = cap_own;
        xc.setInBuffer(x_big);
        stats.say("styllink: screen: no MIT-SHM, capturing over the X socket (slower)\n", .{});
    }
    watch(xc.fd, linux.EPOLL.IN, T_X);
    return true;
}

fn closeX() void {
    if (xc.fd >= 0) {
        _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, xc.fd, null);
        xc.close();
    }
    cap = &.{};
    free(&cap_own);
    free(&x_big);
}

fn onDamage(_: *anyopaque, r: x11.Rect) void {
    if (!streaming or ses.source) return;
    const span: i32 = @intCast(TILE * ses.scale);
    const x0 = @max(r.x, rx0) - rx0;
    const y0 = @max(r.y, ry0) - ry0;
    const x1 = @min(r.x + @as(i32, @intCast(r.w)), rx0 + @as(i32, @intCast(rw))) - rx0;
    const y1 = @min(r.y + @as(i32, @intCast(r.h)), ry0 + @as(i32, @intCast(rh))) - ry0;
    if (x1 <= x0 or y1 <= y0) return;
    const tx0: usize = @intCast(@divTrunc(x0, span));
    const ty0: usize = @intCast(@divTrunc(y0, span));
    const tx1: usize = @min(@as(usize, @intCast(@divTrunc(x1 - 1, span))), ses.tw - 1);
    const ty1: usize = @min(@as(usize, @intCast(@divTrunc(y1 - 1, span))), ses.th - 1);
    if (tx0 > tx1 or ty0 > ty1) return;
    for (ty0..ty1 + 1) |ty| @memset(dirty[ty][tx0 .. tx1 + 1], true);
    any_dirty = true;
}

fn alloc(n: usize) []u8 {
    const rc = linux.mmap(null, n, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    if (linux.errno(rc) != .SUCCESS) return &.{};
    const p: [*]u8 = @ptrFromInt(rc);
    return p[0..n];
}

fn free(b: *[]u8) void {
    if (b.len > 0) _ = linux.munmap(b.ptr, b.len);
    b.* = &.{};
}

fn allocBuffers() bool {
    freeBuffers();
    const frame = @as(usize, ses.sw) * ses.sh * 4;
    const rect = @as(usize, ses.sw) * TILE * RECT_ROWS * 4;
    prev = alloc(frame);
    scratch = alloc(rect);
    zbuf = alloc(lz4.bound(rect));
    wire = alloc(frame + @as(usize, ses.tw) * ses.th * (RECT_HDR + MAX_WS_HDR) + 65536);
    return prev.len > 0 and scratch.len > 0 and zbuf.len > 0 and wire.len > 0;
}

fn freeBuffers() void {
    free(&prev);
    free(&scratch);
    free(&zbuf);
    free(&wire);
    free(&au);
}

// ---------------------------------------------------------------- frames

fn armPace(ns: u64) void {
    if (pace_armed) return;
    const spec = linux.itimerspec{
        .it_interval = .{ .sec = 0, .nsec = 0 },
        .it_value = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(@max(ns % std.time.ns_per_s, 1000)) },
    };
    _ = linux.timerfd_settime(pace_fd, .{}, &spec, null);
    pace_armed = true;
}

fn tryFrame() void {
    if (!streaming or ses.source or !any_dirty) return;
    if (wire_len != wire_off) return; // last frame still leaving
    if (inflight >= ses.inflight) return; // wait for the tablet
    if (ses.codec == .h264 and (enc_in_off < enc_in_len or enc_real > 0)) return;
    const now = util.nowNs();
    // A frame cap only adds delay while the link keeps up: by default
    // capture may run at twice the display rate, so a change right after a
    // frame still makes the next refresh. --video-fps sets a hard cap.
    const gap = std.time.ns_per_s / (if (cfg.video_fps > 0) ses.fps else ses.fps * 2);
    if (now - last_frame_ns < gap) return armPace(last_frame_ns + gap - now);
    last_frame_ns = now;
    captureFrame(now) catch endSession("lost the X server");
}

const Band = struct { tx0: u32, tx1: u32, ty0: u32, ty1: u32, off: usize = 0, stride: usize = 0 };
const Rect = struct { tx0: u32, tx1: u32, ty0: u32, ty1: u32 };

var bands: [MAX_TY]Band = undefined;
var rects: [MAX_TX * MAX_TY]Rect = undefined;

fn captureFrame(now: u64) x11.Error!void {
    // Take this frame's damage; anything drawn from here on is reported anew.
    try xc.subtractDamage();
    const key = force_key;
    force_key = false;
    any_dirty = false;
    for (0..ses.th) |ty| {
        snap[ty] = dirty[ty];
        @memset(dirty[ty][0..ses.tw], false);
    }

    // Damaged tiles -> a few capture bands: consecutive tile rows with
    // overlapping spans share one shared-memory copy.
    var nb: usize = 0;
    for (0..ses.th) |ty| {
        const row = snap[ty][0..ses.tw];
        const first = std.mem.indexOfScalar(bool, row, true) orelse continue;
        const last = std.mem.lastIndexOfScalar(bool, row, true).?;
        const t: u32 = @intCast(ty);
        if (nb > 0 and bands[nb - 1].ty1 + 1 == t and first <= bands[nb - 1].tx1 and last >= bands[nb - 1].tx0) {
            const b = &bands[nb - 1];
            b.ty1 = t;
            b.tx0 = @min(b.tx0, @as(u32, @intCast(first)));
            b.tx1 = @max(b.tx1, @as(u32, @intCast(last)));
        } else {
            bands[nb] = .{ .tx0 = @intCast(first), .tx1 = @intCast(last), .ty0 = t, .ty1 = t };
            nb += 1;
        }
    }
    if (nb == 0) return;

    const sc = ses.scale;
    var off: usize = 0;
    var last_seq: u16 = 0;
    for (bands[0..nb]) |*b| {
        const px0 = b.tx0 * TILE * sc;
        const px1 = @min((b.tx1 + 1) * TILE, ses.sw) * sc;
        const py0 = b.ty0 * TILE * sc;
        const py1 = @min((b.ty1 + 1) * TILE, ses.sh) * sc;
        const r = x11.Rect{ .x = rx0 + @as(i32, @intCast(px0)), .y = ry0 + @as(i32, @intCast(py0)), .w = px1 - px0, .h = py1 - py0 };
        b.off = off;
        b.stride = @as(usize, r.w) * 4;
        if (xc.shm != null) {
            last_seq = try xc.shmGetImage(r, @intCast(off));
        } else {
            try xc.getImage(r, cap[off..][0 .. b.stride * r.h]);
        }
        off += b.stride * r.h;
    }
    if (xc.shm != null) _ = try xc.waitReply(last_seq, null);

    // Which tiles really changed (damage is often a whole window).
    var n_changed: usize = 0;
    for (bands[0..nb]) |b| {
        for (b.ty0..b.ty1 + 1) |ty| {
            for (b.tx0..b.tx1 + 1) |tx| {
                if (!snap[ty][tx]) continue;
                const c = diffTile(b, @intCast(tx), @intCast(ty)) or key;
                changed[ty][tx] = c;
                if (c) n_changed += 1;
            }
        }
    }
    if (n_changed == 0) return;

    if (ses.codec == .h264) return feedEncoder(now);

    const nr = buildRects();
    const id = frame_id;
    frame_id +%= 1;
    sent_ns[id % sent_ns.len] = now;
    var bytes: usize = 0;
    var raw_bytes: usize = 0;
    for (rects[0..nr], 0..) |r, i| {
        const sent = sendRect(r, id, now, i + 1 == nr, key);
        if (fd == -1) return; // the send failed and ended the session
        bytes += sent[0];
        raw_bytes += sent[1];
    }
    inflight += 1;
    const work = (util.nowNs() - now) / 1000;
    for ([_]*Counters{ &sec, &total }) |c| {
        c.frames += 1;
        c.rects += nr;
        c.bytes += bytes;
        c.raw_bytes += raw_bytes;
        c.work_sum_us += work;
        c.work_max_us = @max(c.work_max_us, work);
    }
}

/// Converts one tile from the capture into stream pixels, stores it in
/// `prev` and reports whether anything differed.
fn diffTile(b: Band, tx: u32, ty: u32) bool {
    const sx0 = tx * TILE;
    const sy0 = ty * TILE;
    const w = @min(TILE, ses.sw - sx0);
    const h = @min(TILE, ses.sh - sy0);
    const bpp = ses.bpp();
    const sc = ses.scale;
    var diff: u32 = 0;
    for (0..h) |r| {
        const cy = (sy0 + r - b.ty0 * TILE) * sc;
        const cx = (sx0 - b.tx0 * TILE) * sc;
        const src = cap[b.off + cy * b.stride + cx * 4 ..];
        const dst = prev[((sy0 + r) * ses.sw + sx0) * bpp ..][0 .. w * bpp];
        const below = if (sc == 2) cap[b.off + (cy + 1) * b.stride + cx * 4 ..] else src;
        diff |= switch (ses.pix) {
            .bgrx => if (sc == 2) convRow(.bgrx, true, src, below, dst, w) else convRow(.bgrx, false, src, src, dst, w),
            .rgb565 => if (sc == 2) convRow(.rgb565, true, src, below, dst, w) else convRow(.rgb565, false, src, src, dst, w),
        };
    }
    return diff != 0;
}

fn avg(a: u32, b: u32) u32 {
    return (a & b) +% (((a ^ b) & 0xfefefefe) >> 1);
}

fn convRow(comptime pix: Pix, comptime half: bool, src: []const u8, below: []const u8, dst: []u8, w: usize) u32 {
    var diff: u32 = 0;
    for (0..w) |i| {
        var p: u32 = undefined;
        if (half) {
            const a = std.mem.readInt(u32, src[i * 8 ..][0..4], .little);
            const b = std.mem.readInt(u32, src[i * 8 + 4 ..][0..4], .little);
            const c = std.mem.readInt(u32, below[i * 8 ..][0..4], .little);
            const d = std.mem.readInt(u32, below[i * 8 + 4 ..][0..4], .little);
            p = avg(avg(a, b), avg(c, d));
        } else {
            p = std.mem.readInt(u32, src[i * 4 ..][0..4], .little);
        }
        switch (pix) {
            .bgrx => {
                const v = p | 0xff000000; // the pad byte is undefined
                const o = dst[i * 4 ..][0..4];
                diff |= std.mem.readInt(u32, o, .little) ^ v;
                std.mem.writeInt(u32, o, v, .little);
            },
            .rgb565 => {
                const v: u16 = @truncate(((p >> 8) & 0xf800) | ((p >> 5) & 0x07e0) | ((p >> 3) & 0x001f));
                const o = dst[i * 2 ..][0..2];
                diff |= std.mem.readInt(u16, o, .little) ^ v;
                std.mem.writeInt(u16, o, v, .little);
            },
        }
    }
    return diff;
}

/// Changed tiles -> rectangles: runs along each tile row, stacked with the
/// identical run of the rows below (up to RECT_ROWS).
fn buildRects() usize {
    var n: usize = 0;
    var above: usize = 0; // first rectangle that can still end on the row above
    for (0..ses.th) |ty| {
        const row_start = n;
        var tx: usize = 0;
        while (tx < ses.tw) {
            if (!changed[ty][tx]) {
                tx += 1;
                continue;
            }
            const x0 = tx;
            while (tx < ses.tw and changed[ty][tx]) : (tx += 1) changed[ty][tx] = false;
            const x1 = tx - 1;
            for (rects[above..row_start]) |*r| {
                if (r.tx0 == x0 and r.tx1 == x1 and r.ty1 + 1 == ty and r.ty1 - r.ty0 + 1 < RECT_ROWS) {
                    r.ty1 = @intCast(ty);
                    break;
                }
            } else {
                rects[n] = .{ .tx0 = @intCast(x0), .tx1 = @intCast(x1), .ty0 = @intCast(ty), .ty1 = @intCast(ty) };
                n += 1;
            }
        }
        while (above < n and rects[above].ty1 < ty) above += 1;
    }
    return n;
}

/// Encodes one rectangle and puts it on the wire. Returns {sent, raw} bytes.
fn sendRect(r: Rect, id: u32, now: u64, last: bool, key: bool) [2]usize {
    const bpp = ses.bpp();
    const x = r.tx0 * TILE;
    const y = r.ty0 * TILE;
    const w = @min((r.tx1 + 1) * TILE, ses.sw) - x;
    const h = @min((r.ty1 + 1) * TILE, ses.sh) - y;
    const row = @as(usize, w) * bpp;
    const raw_len = row * h;
    for (0..h) |i| @memcpy(scratch[i * row ..][0..row], prev[((y + i) * ses.sw + x) * bpp ..][0..row]);
    var payload: []const u8 = scratch[0..raw_len];
    var enc: Enc = .raw;
    if (ses.enc == .lz4) {
        const n = comp.compress(payload, zbuf);
        if (n < raw_len) {
            payload = zbuf[0..n];
            enc = .lz4;
        }
    }
    var hdr: [RECT_HDR]u8 = undefined;
    hdr[0] = 'T';
    hdr[1] = @as(u8, if (last) 1 else 0) | @as(u8, if (key) 2 else 0);
    hdr[2] = @intFromEnum(enc);
    hdr[3] = @intFromEnum(ses.pix);
    std.mem.writeInt(u32, hdr[4..8], id, .little);
    std.mem.writeInt(u32, hdr[8..12], @truncate(now / 100_000), .little);
    std.mem.writeInt(u16, hdr[12..14], @intCast(x), .little);
    std.mem.writeInt(u16, hdr[14..16], @intCast(y), .little);
    std.mem.writeInt(u16, hdr[16..18], @intCast(w), .little);
    std.mem.writeInt(u16, hdr[18..20], @intCast(h), .little);
    std.mem.writeInt(u32, hdr[20..24], @intCast(raw_len), .little);
    queue(0x2, &hdr, payload);
    flush(); // start sending while the next rectangle is encoded
    return .{ payload.len + RECT_HDR, raw_len };
}

// ---------------------------------------------------------------- wire

/// Appends one binary WebSocket message (header + body) to the wire.
fn queue(opcode: u8, head: []const u8, body: []const u8) void {
    const n = head.len + body.len;
    if (wire_off > 0 and wire.len - wire_len < n + MAX_WS_HDR) {
        const rest = wire_len - wire_off;
        std.mem.copyForwards(u8, wire[0..rest], wire[wire_off..wire_len]);
        wire_off = 0;
        wire_len = rest;
    }
    if (wire.len - wire_len < n + MAX_WS_HDR) return endSession("frame larger than the send buffer");
    var w = wire[wire_len..];
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
    wire_len += hl + n;
}

fn flush() void {
    while (wire_off < wire_len) {
        const rc = linux.write(fd, wire[wire_off..].ptr, wire_len - wire_off);
        switch (linux.errno(rc)) {
            .SUCCESS => wire_off += rc,
            .INTR => {},
            .AGAIN => {
                if (!out_armed) rewatch(fd, linux.EPOLL.IN | linux.EPOLL.OUT | linux.EPOLL.RDHUP, T_CLIENT);
                out_armed = true;
                return;
            },
            else => return endSession("send failed"),
        }
    }
    wire_off = 0;
    wire_len = 0;
    if (out_armed) rewatch(fd, linux.EPOLL.IN | linux.EPOLL.RDHUP, T_CLIENT);
    out_armed = false;
}

/// Small control messages; they go through the wire so they never cut into
/// a frame that is half sent.
fn sendWs(opcode: u8, payload: []const u8) void {
    if (fd == -1) return;
    if (wire.len == 0) {
        // Before buffers exist (negotiation errors): write directly.
        var h: [4]u8 = undefined;
        h[0] = 0x80 | opcode;
        var hl: usize = 2;
        if (payload.len < 126) h[1] = @intCast(payload.len) else {
            h[1] = 126;
            std.mem.writeInt(u16, h[2..4], @intCast(payload.len), .big);
            hl = 4;
        }
        const iov = [_]std.posix.iovec_const{ .{ .base = &h, .len = hl }, .{ .base = payload.ptr, .len = payload.len } };
        _ = linux.writev(fd, &iov, 2);
        return;
    }
    queue(opcode, "", payload);
    flush();
}

// ---------------------------------------------------------------- H.264

fn spawnEncoder() bool {
    var cmd_buf: [4096]u8 = undefined;
    const template = if (ses.source) cfg.video_source else if (cfg.video_encoder.len > 0) cfg.video_encoder else DEFAULT_ENCODER;
    const cmd = expand(template, &cmd_buf) orelse return false;

    var out_pipe: [2]i32 = undefined;
    var in_pipe: [2]i32 = .{ -1, -1 };
    if (linux.errno(linux.pipe2(&out_pipe, .{ .CLOEXEC = true })) != .SUCCESS) return false;
    if (!ses.source and linux.errno(linux.pipe2(&in_pipe, .{ .CLOEXEC = true })) != .SUCCESS) {
        _ = linux.close(out_pipe[0]);
        _ = linux.close(out_pipe[1]);
        return false;
    }
    const argv = [_:null]?[*:0]const u8{ "sh", "-c", cmd.ptr };
    const pid_rc = linux.fork();
    if (linux.errno(pid_rc) != .SUCCESS) return false;
    if (pid_rc == 0) {
        // Child: only raw syscalls until exec.
        if (in_pipe[0] != -1) {
            _ = linux.dup2(in_pipe[0], 0);
        } else {
            const nul = linux.open("/dev/null", .{}, 0);
            _ = linux.dup2(@intCast(nul), 0);
        }
        _ = linux.dup2(out_pipe[1], 1);
        _ = linux.execve("/bin/sh", &argv, environ.block.slice.ptr);
        linux.exit_group(127);
    }
    enc_pid = @intCast(pid_rc);
    _ = linux.close(out_pipe[1]);
    enc_out = out_pipe[0];
    _ = linux.fcntl(enc_out, linux.F.SETFL, 0o4000);
    _ = linux.fcntl(enc_out, 1031, 1 << 20); // F_SETPIPE_SZ: a whole frame per write
    watch(enc_out, linux.EPOLL.IN, T_ENC_OUT);
    if (in_pipe[0] != -1) {
        _ = linux.close(in_pipe[0]);
        enc_in = in_pipe[1];
        _ = linux.fcntl(enc_in, linux.F.SETFL, 0o4000);
        _ = linux.fcntl(enc_in, 1031, 1 << 20);
        watch(enc_in, 0, T_ENC_IN);
    }
    enc_fresh = true;
    enc_in_off = 0;
    enc_in_len = 0;
    enc_q_len = 0;
    enc_q_head = 0;
    enc_real = 0;
    au_len = 0;
    return true;
}

/// Fills {x} {y} {w} {h} {fps} into an encoder/source command line.
fn expand(template: []const u8, buf: *[4096]u8) ?[:0]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '{') if (std.mem.indexOfScalarPos(u8, template, i, '}')) |end| {
            const key = template[i + 1 .. end];
            const val: ?u32 = if (std.mem.eql(u8, key, "w")) ses.sw else if (std.mem.eql(u8, key, "h")) ses.sh else if (std.mem.eql(u8, key, "fps")) ses.fps else if (std.mem.eql(u8, key, "x")) @intCast(rx0) else if (std.mem.eql(u8, key, "y")) @intCast(ry0) else null;
            if (val) |v| {
                const s = std.fmt.bufPrint(buf[n..], "{d}", .{v}) catch return null;
                n += s.len;
                i = end + 1;
                continue;
            }
        };
        if (n + 1 >= buf.len) return null;
        buf[n] = template[i];
        n += 1;
        i += 1;
    }
    buf[n] = 0;
    return buf[0..n :0];
}

fn stopEncoder() void {
    if (enc_pid == 0) return;
    for ([_]*i32{ &enc_in, &enc_out }) |f| if (f.* != -1) {
        _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, f.*, null);
        _ = linux.close(f.*);
        f.* = -1;
    };
    _ = linux.kill(enc_pid, if (ses.source) .TERM else .KILL);
    var status: i32 = 0;
    var tries: usize = 0;
    while (linux.waitpid(enc_pid, &status, 1) == 0) : (tries += 1) { // WNOHANG
        if (tries == 50) _ = linux.kill(enc_pid, .KILL);
        const ts = linux.timespec{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts, null);
    }
    enc_pid = 0;
}

fn feedEncoder(now: u64) void {
    enc_fresh = false;
    enc_real += 1;
    pushFrame(.{ .ns = now, .dup = false });
}

fn pushFrame(f: Fed) void {
    if (enc_q_len == enc_q.len) return;
    enc_q[(enc_q_head + enc_q_len) % enc_q.len] = f;
    enc_q_len += 1;
    enc_in_off = 0;
    enc_in_len = @as(usize, ses.sw) * ses.sh * 4;
    writeEncoder();
}

/// Pushes the last real frame out of the encoder's pipeline.
fn nudgeEncoder() void {
    if (enc_real > 0 and enc_in_off == enc_in_len and enc_q_len < 8)
        pushFrame(.{ .ns = util.nowNs(), .dup = true });
}

fn writeEncoder() void {
    while (enc_in_off < enc_in_len) {
        const rc = linux.write(enc_in, prev[enc_in_off..].ptr, enc_in_len - enc_in_off);
        switch (linux.errno(rc)) {
            .SUCCESS => enc_in_off += rc,
            .INTR => {},
            .AGAIN => return rewatch(enc_in, linux.EPOLL.OUT, T_ENC_IN),
            else => return endSession("the H.264 encoder stopped reading"),
        }
    }
    rewatch(enc_in, 0, T_ENC_IN);
    // One duplicate right behind a real frame; more only if the encoder
    // turns out to hold several (readEncoder nudges again per output).
    if (enc_q_len > 0 and !enc_q[(enc_q_head + enc_q_len - 1) % enc_q.len].dup) nudgeEncoder();
}

fn readEncoder() void {
    while (au_len < au.len) {
        const rc = linux.read(enc_out, au[au_len..].ptr, au.len - au_len);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return endSession("the H.264 encoder exited");
                au_len += rc;
            },
            .INTR => {},
            .AGAIN => break,
            else => return endSession("the H.264 encoder failed"),
        }
    }
    // The encoder writes each access unit in one write (avioflags direct,
    // 1 MB pipe), so a drained pipe ends on a frame boundary. AUDs split
    // several frames that arrived together.
    var starts: [64]usize = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i + 4 <= au_len and n < starts.len) : (i += 1) {
        if (au[i] == 0 and au[i + 1] == 0 and au[i + 2] == 1 and au[i + 3] & 0x1f == 9) {
            starts[n] = if (i > 0 and au[i - 1] == 0) i - 1 else i;
            n += 1;
            i += 3;
        }
    }
    if (n == 0 or starts[0] != 0) {
        // No delimiters (custom encoder): one frame per drained read.
        if (n == 0) {
            starts[0] = 0;
            n = 1;
        } else starts[0] = 0;
    }
    for (0..n) |k| {
        const end = if (k + 1 < n) starts[k + 1] else au_len;
        sendAu(au[starts[k]..end]);
        if (fd == -1) return;
    }
    au_len = 0;
    nudgeEncoder();
}

fn sendAu(data: []const u8) void {
    var key = false;
    var i: usize = 0;
    while (i + 3 < data.len) : (i += 1) {
        if (data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1) {
            const t = data[i + 3] & 0x1f;
            if (t == 5 or t == 7) key = true;
            i += 3;
        }
    }
    const now = util.nowNs();
    var cap_ns = now;
    var dup = false;
    if (enc_q_len > 0) {
        const f = enc_q[enc_q_head];
        enc_q_head = (enc_q_head + 1) % enc_q.len;
        enc_q_len -= 1;
        cap_ns = f.ns;
        dup = f.dup;
        if (!dup) enc_real -|= 1;
    }
    const id = frame_id;
    frame_id +%= 1;
    sent_ns[id % sent_ns.len] = cap_ns;
    var hdr: [H264_HDR]u8 = @splat(0);
    hdr[0] = 'H';
    // bit 2: a duplicate; decode it but don't acknowledge (nothing changed).
    hdr[1] = 1 | @as(u8, if (key) 2 else 0) | @as(u8, if (dup) 4 else 0);
    std.mem.writeInt(u32, hdr[4..8], id, .little);
    std.mem.writeInt(u32, hdr[8..12], @truncate(cap_ns / 100_000), .little);
    std.mem.writeInt(u32, hdr[12..16], @intCast(@min((now - cap_ns) / 1000, std.math.maxInt(u32))), .little);
    queue(0x2, &hdr, data);
    flush();
    if (dup) return;
    inflight += 1;
    const work = (now - cap_ns) / 1000;
    for ([_]*Counters{ &sec, &total }) |c| {
        c.frames += 1;
        c.bytes += data.len + H264_HDR;
        c.work_sum_us += work;
        c.work_max_us = @max(c.work_max_us, work);
    }
}

// ---------------------------------------------------------------- tests

test "negotiate picks formats from tablet caps and the link" {
    const testing = std.testing;
    const c: config.Config = .{};
    const usb = parseCaps("w=2560;h=1600;hz=120;pix=bgrx,rgb565;enc=lz4,raw;codec=tiles,h264;link=usb");
    const s = negotiate(c, usb, 1920, 1080).?;
    try testing.expectEqual(Codec.tiles, s.codec);
    try testing.expectEqual(Pix.bgrx, s.pix);
    try testing.expectEqual(Enc.lz4, s.enc);
    try testing.expectEqual(@as(u32, 1), s.scale);
    try testing.expectEqual(@as(u32, 120), s.fps);
    try testing.expectEqual(@as(u32, 60), s.tw);
    try testing.expectEqual(@as(u32, 34), s.th);

    const wifi = parseCaps("w=1280;h=800;hz=60;pix=bgrx,rgb565;enc=lz4;codec=tiles;link=wifi");
    const s2 = negotiate(c, wifi, 3840, 2160).?;
    try testing.expectEqual(Pix.rgb565, s2.pix);
    try testing.expectEqual(@as(u32, 2), s2.scale);
    try testing.expectEqual(@as(u32, 1920), s2.sw);

    var h: config.Config = .{};
    h.video_codec = .h264;
    const s3 = negotiate(h, usb, 1921, 1081).?;
    try testing.expectEqual(Codec.h264, s3.codec);
    try testing.expectEqual(@as(u32, 1920), s3.sw);
    try testing.expectEqual(@as(u32, 1080), s3.sh);
    try testing.expect(negotiate(h, parseCaps("codec=h264"), 640, 480) != null);
    var src: config.Config = .{};
    src.video_source = "cat";
    try testing.expect(negotiate(src, wifi, 640, 480) == null);
}

test "convRow converts, halves and reports changes" {
    const testing = std.testing;
    var src: [16]u8 = .{ 0x10, 0x20, 0x30, 0, 0x30, 0x40, 0x50, 0, 0x10, 0x20, 0x30, 0, 0x30, 0x40, 0x50, 0 };
    var dst: [8]u8 = @splat(0);
    try testing.expect(convRow(.bgrx, false, &src, &src, &dst, 2) != 0);
    try testing.expectEqualSlices(u8, &.{ 0x10, 0x20, 0x30, 0xff, 0x30, 0x40, 0x50, 0xff }, &dst);
    try testing.expect(convRow(.bgrx, false, &src, &src, &dst, 2) == 0);
    var half: [4]u8 = undefined;
    _ = convRow(.bgrx, true, &src, &src, &half, 1);
    try testing.expectEqualSlices(u8, &.{ 0x20, 0x30, 0x40, 0xff }, &half);
    var px: [2]u8 = undefined;
    const white = [4]u8{ 0xff, 0xff, 0xff, 0 };
    _ = convRow(.rgb565, false, &white, &white, &px, 1);
    try testing.expectEqual(@as(u16, 0xffff), std.mem.readInt(u16, &px, .little));
}

test "buildRects merges runs into bounded rectangles" {
    const testing = std.testing;
    ses = .{ .tw = 8, .th = 8, .sw = 256, .sh = 256 };
    for (0..6) |ty| {
        changed[ty][1] = true;
        changed[ty][2] = true;
    }
    changed[0][5] = true;
    const n = buildRects();
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(Rect{ .tx0 = 1, .tx1 = 2, .ty0 = 0, .ty1 = 3 }, rects[0]);
    try testing.expectEqual(Rect{ .tx0 = 5, .tx1 = 5, .ty0 = 0, .ty1 = 0 }, rects[1]);
    try testing.expectEqual(Rect{ .tx0 = 1, .tx1 = 2, .ty0 = 4, .ty1 = 5 }, rects[2]);
    for (0..8) |ty| try testing.expect(std.mem.indexOfScalar(bool, changed[ty][0..8], true) == null);
}
