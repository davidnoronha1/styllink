//! styllink: receive stylus samples from a browser over WebSocket and replay
//! them on this machine as a virtual pen tablet via /dev/uinput.
//!
//! Single-threaded epoll loop, raw Linux syscalls, no allocations on the hot
//! path. Each binary WebSocket frame is a batch of 10-byte samples which are
//! translated into one write() of input_events.

const std = @import("std");
const linux = std.os.linux;

const qr = @import("qr.zig");

const index_html = @import("page").html;

// ---------------------------------------------------------------- config

const Io = enum { uring, epoll };

const Config = struct {
    port: u16 = 8080,
    token: []const u8 = "",
    token_set: bool = false,
    // Target rectangle on the desktop, and the full desktop size. libinput maps
    // the tablet's full range onto the whole desktop, so a region is reached
    // by scaling into a sub-range.
    region: [4]u32 = .{ 0, 0, 1920, 1080 },
    desktop: [2]u32 = .{ 1920, 1080 },
    io: Io = .epoll,
    busy: bool = false,
    uinput: bool = true,
    usb_qr: bool = false,
    // Frames per pen sample; cancels libinput's 4-frame tablet smoothing.
    // 1 = off (e.g. once AttrTabletSmoothing=0 is active in X).
    unsmooth: usize = 4,
    // Hosted copy of web/index.html; "" = only use the page served by us.
    web_url: []const u8 = DEFAULT_WEB_URL,
    // JSON-lines log of connections, per-second link stats and stalls.
    log_path: [:0]const u8 = "styllink.log",
    // Burst smoothing: samples that arrive late in a bunch are replayed with
    // their original spacing at `catchup` x real speed (0 = no smoothing,
    // just write them at once). `jitter_ms` adds a fixed playout delay that
    // absorbs that much network jitter completely.
    catchup: f64 = 2.0,
    jitter_ms: u32 = 0,
};

const DEFAULT_WEB_URL = "https://styllink.vercel.app";

var cfg: Config = .{};

fn usage() noreturn {
    std.debug.print(
        \\usage: styllink [options]
        \\  --port N            listen port (default 8080)
        \\  --token STR         access token (default: random); "" disables the check
        \\  --region X,Y,W,H    desktop rectangle to map the pad onto
        \\  --desktop W,H       full desktop size (for --region)
        \\  --io epoll|uring    event loop backend (default epoll; uring benchmarked no faster)
        \\  --busy              spin instead of sleeping: lowest wake-up latency, burns a core
        \\  --unsmooth N        frames per sample to cancel libinput smoothing (default 4, 1 = off)
        \\  --web-url URL       printed browser URL ("" = use the page served by this PC)
        \\  --catchup X         replay late bursts at X times real speed (default 2; 0 = snap)
        \\  --jitter-ms N       fixed playout delay that hides N ms of network jitter (default 0)
        \\  --log PATH          JSON-lines log (default styllink.log; "" = off)
        \\  --usb-qr            show USB QR first (requires working adb reverse)
        \\  --no-uinput         don't create the pen device (network benchmarking)
        \\
    , .{});
    linux.exit(2);
}

fn parseList(comptime n: usize, s: []const u8) [n]u32 {
    var out: [n]u32 = undefined;
    var it = std.mem.splitScalar(u8, s, ',');
    for (&out) |*v| {
        const part = it.next() orelse usage();
        v.* = std.fmt.parseInt(u32, part, 10) catch usage();
    }
    if (it.next() != null) usage();
    return out;
}

// ---------------------------------------------------------------- syscalls

fn check(rc: usize, what: []const u8) usize {
    const e = linux.errno(rc);
    if (e != .SUCCESS) {
        std.debug.print("styllink: {s} failed: {s}\n", .{ what, @tagName(e) });
        if (std.mem.eql(u8, what, "open /dev/uinput"))
            std.debug.print("  -> run ./install-uinput-access.sh once (needs sudo)\n", .{});
        linux.exit(1);
    }
    return rc;
}

fn writeAll(fd: i32, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const rc = linux.write(fd, data.ptr + off, data.len - off);
        switch (linux.errno(rc)) {
            .SUCCESS => off += rc,
            .INTR => {},
            else => return false,
        }
    }
    return true;
}

// ---------------------------------------------------------------- uinput

const EV_SYN = 0x00;
const EV_KEY = 0x01;
const EV_ABS = 0x03;
const SYN_REPORT = 0;
const ABS_X = 0x00;
const ABS_Y = 0x01;
const ABS_PRESSURE = 0x18;
const ABS_TILT_X = 0x1a;
const ABS_TILT_Y = 0x1b;
const BTN_TOOL_PEN = 0x140;
const BTN_TOOL_RUBBER = 0x141;
const BTN_TOUCH = 0x14a;
const BTN_STYLUS = 0x14b;
const INPUT_PROP_DIRECT = 0x01;

const UI_DEV_CREATE: u32 = 0x5501;
const UI_DEV_SETUP: u32 = 0x405c5503; // _IOW('U', 3, struct uinput_setup)
const UI_ABS_SETUP: u32 = 0x401c5504; // _IOW('U', 4, struct uinput_abs_setup)
const UI_SET_EVBIT: u32 = 0x40045564;
const UI_SET_KEYBIT: u32 = 0x40045565;
const UI_SET_ABSBIT: u32 = 0x40045567;
const UI_SET_PROPBIT: u32 = 0x4004556e;

const InputEvent = extern struct {
    sec: isize = 0, // kernel stamps the event itself
    usec: isize = 0,
    type: u16,
    code: u16,
    value: i32,
};

const UinputSetup = extern struct {
    bustype: u16,
    vendor: u16,
    product: u16,
    version: u16,
    name: [80]u8,
    ff_effects_max: u32,
};

const AbsSetup = extern struct {
    code: u16,
    value: i32 = 0,
    minimum: i32,
    maximum: i32,
    fuzz: i32 = 0,
    flat: i32 = 0,
    resolution: i32,
};

comptime {
    std.debug.assert(@sizeOf(InputEvent) == 24);
    std.debug.assert(@sizeOf(UinputSetup) == 92);
    std.debug.assert(@sizeOf(AbsSetup) == 28);
}

const AXIS_MAX: i32 = 65535;
const PRESSURE_MAX = 4095;
const TILT_MAX: i32 = 90;

fn uinputCreate() i32 {
    const rc = check(linux.open("/dev/uinput", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0), "open /dev/uinput");
    const fd: i32 = @intCast(rc);

    const ioc = struct {
        fn set(f: i32, req: u32, val: usize) void {
            _ = check(linux.ioctl(f, req, val), "uinput ioctl");
        }
    };
    ioc.set(fd, UI_SET_EVBIT, EV_SYN);
    ioc.set(fd, UI_SET_EVBIT, EV_KEY);
    ioc.set(fd, UI_SET_EVBIT, EV_ABS);
    for ([_]usize{ BTN_TOOL_PEN, BTN_TOOL_RUBBER, BTN_TOUCH, BTN_STYLUS }) |k| ioc.set(fd, UI_SET_KEYBIT, k);
    for ([_]usize{ ABS_X, ABS_Y, ABS_PRESSURE, ABS_TILT_X, ABS_TILT_Y }) |a| ioc.set(fd, UI_SET_ABSBIT, a);
    ioc.set(fd, UI_SET_PROPBIT, INPUT_PROP_DIRECT);

    // Resolution: report the axes as a ~ 300x169mm surface so the aspect
    // ratio libinput sees matches a 16:9 screen; tilt is units per radian.
    const res_x: i32 = @divTrunc(AXIS_MAX, 300);
    const res_y: i32 = @intCast(@divTrunc(@as(u64, @intCast(AXIS_MAX)) * cfg.desktop[0], @as(u64, 300) * cfg.desktop[1]));
    const axes = [_]AbsSetup{
        .{ .code = ABS_X, .minimum = 0, .maximum = AXIS_MAX, .resolution = res_x },
        .{ .code = ABS_Y, .minimum = 0, .maximum = AXIS_MAX, .resolution = res_y },
        .{ .code = ABS_PRESSURE, .minimum = 0, .maximum = PRESSURE_MAX, .resolution = 0 },
        .{ .code = ABS_TILT_X, .minimum = -TILT_MAX, .maximum = TILT_MAX, .resolution = 57 },
        .{ .code = ABS_TILT_Y, .minimum = -TILT_MAX, .maximum = TILT_MAX, .resolution = 57 },
    };
    for (&axes) |*a| ioc.set(fd, UI_ABS_SETUP, @intFromPtr(a));

    var setup = std.mem.zeroes(UinputSetup);
    setup.bustype = 0x03; // BUS_USB
    setup.vendor = 0x1701;
    setup.product = 0x5713;
    setup.version = 1;
    @memcpy(setup.name[0..12], "StylLink Pen");
    ioc.set(fd, UI_DEV_SETUP, @intFromPtr(&setup));
    ioc.set(fd, UI_DEV_CREATE, 0);
    return fd;
}

// ---------------------------------------------------------------- pen state

// Wire sample (little endian, 10 bytes):
//   u16 x, u16 y (0..65535 across the mapped region)
//   u16 pressure (0..65535)
//   i8 tiltX, i8 tiltY (degrees)
//   u8 flags, u8 reserved
const SAMPLE_SIZE = 10;
const F_IN_RANGE = 1;
const F_TOUCH = 2;
const F_BARREL = 4;
const F_ERASER = 8;

const Pen = struct {
    fd: i32,
    in_range: bool = false,
    eraser: bool = false,
    touch: bool = false,
    barrel: bool = false,

    // Outgoing events wait in a ring and reach the device in paced chunks.
    // The kernel buffers only 128 events between us and X (evdev sizes it
    // from the device's axes); a Wi-Fi burst written in one go overflows it,
    // the kernel drops events (SYN_DROPPED) and fast strokes come out
    // garbled. So: at most CHUNK events per write, ending on a frame
    // boundary, then PACE_US for X to read before the next chunk. Steady
    // input still goes out immediately; only a backlog gets spread out.
    const RING = 1 << 15;
    const CHUNK = 48;
    const PACE_US = 1000;
    var queue: [RING]InputEvent = undefined;
    var qhead: usize = 0; // next to write
    var qlen: usize = 0;
    var waiting = false; // pace timer armed

    fn ev(t: u16, c: u16, v: i32) void {
        if (qlen == RING) return; // hopelessly behind; the device can't take it anyway
        queue[(qhead + qlen) % RING] = .{ .type = t, .code = c, .value = v };
        qlen += 1;
    }

    fn tool(self: *const Pen) u16 {
        return if (self.eraser) BTN_TOOL_RUBBER else BTN_TOOL_PEN;
    }

    fn leave(self: *Pen) void {
        if (!self.in_range) return;
        if (self.touch) ev(EV_KEY, BTN_TOUCH, 0);
        if (self.barrel) ev(EV_KEY, BTN_STYLUS, 0);
        ev(EV_ABS, ABS_PRESSURE, 0);
        ev(EV_KEY, self.tool(), 0);
        ev(EV_SYN, SYN_REPORT, 0);
        self.* = .{ .fd = self.fd };
    }

    /// Start draining queued events, unless a paced drain is already running.
    fn flush(self: *Pen) void {
        if (!waiting) self.drain();
    }

    /// Write one chunk; arm the pace timer if more is queued. Called by
    /// flush() and by the pace timer.
    fn drain(self: *Pen) void {
        waiting = false;
        if (qlen == 0) return;
        if (self.fd < 0) {
            qhead = (qhead + qlen) % RING;
            qlen = 0;
            return;
        }
        // Up to CHUNK contiguous events, cut after the last SYN_REPORT.
        var take = @min(qlen, CHUNK, RING - qhead);
        var i = take;
        while (i > 0 and queue[qhead + i - 1].type != EV_SYN) i -= 1;
        if (i > 0) take = i;
        _ = writeAll(self.fd, std.mem.sliceAsBytes(queue[qhead .. qhead + take]));
        qhead = (qhead + take) % RING;
        qlen -= take;
        // Hold the cooldown even if this write emptied the queue. Otherwise
        // separate small WebSocket reads can each flush immediately and exceed
        // CHUNK events per millisecond, overflowing X's evdev buffer.
        waiting = true;
        const spec = linux.itimerspec{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value = .{ .sec = 0, .nsec = PACE_US * std.time.ns_per_us },
        };
        _ = linux.timerfd_settime(pace_fd, .{}, &spec, null);
    }

    fn mapAxis(v: u16, off: u32, len: u32, total: u32) i32 {
        // region-local 0..65535 -> desktop-global device units
        const px = @as(u64, off) * 65535 + @as(u64, v) * len;
        return @intCast(px / total);
    }

    /// libinput ignores BTN_TOUCH on pens with a pressure axis and decides
    /// contact itself: tip down above ~5% of the range, up below ~1%. Lift
    /// every contact into [6%, 100%] so a light touch the page counts as ink
    /// is ink on the PC too.
    fn contactPressure(p: u16) i32 {
        const floor: u32 = PRESSURE_MAX * 6 / 100;
        return @intCast(floor + @as(u32, p) * (PRESSURE_MAX - floor) / 65535);
    }

    fn sample(self: *Pen, s: *const [SAMPLE_SIZE]u8) void {
        const flags = s[8];
        if (flags & F_IN_RANGE == 0) {
            self.leave();
            return;
        }
        const eraser = flags & F_ERASER != 0;
        if (self.in_range and eraser != self.eraser) self.leave();

        const x = std.mem.readInt(u16, s[0..2], .little);
        const y = std.mem.readInt(u16, s[2..4], .little);
        const p = std.mem.readInt(u16, s[4..6], .little);
        const touch = flags & F_TOUCH != 0;
        const barrel = flags & F_BARREL != 0;

        const ax = mapAxis(x, cfg.region[0], cfg.region[2], cfg.desktop[0]);
        const ay = mapAxis(y, cfg.region[1], cfg.region[3], cfg.desktop[1]);
        const tx = std.math.clamp(@as(i32, @as(i8, @bitCast(s[6]))), -TILT_MAX, TILT_MAX);
        const ty = std.math.clamp(@as(i32, @as(i8, @bitCast(s[7]))), -TILT_MAX, TILT_MAX);

        if (!self.in_range) {
            // Always enter proximity with zero pressure: libinput takes the
            // pressure seen at proximity-in as the pen's resting offset, and a
            // non-zero one would thin out or swallow every following stroke.
            self.in_range = true;
            self.eraser = eraser;
            ev(EV_ABS, ABS_X, ax);
            ev(EV_ABS, ABS_Y, ay);
            ev(EV_ABS, ABS_PRESSURE, 0);
            ev(EV_ABS, ABS_TILT_X, tx);
            ev(EV_ABS, ABS_TILT_Y, ty);
            ev(EV_KEY, self.tool(), 1);
            ev(EV_SYN, SYN_REPORT, 0);
        }
        // libinput smooths tablets by averaging the last 4 frames, which
        // garbles fast strokes. Emitting each sample as `unsmooth` frames
        // makes that average the sample itself. Consecutive frames differ
        // by one device unit (0.03 px) because the kernel drops unchanged
        // values. Pressure and buttons change only in the final frame, so
        // the tip lands and lifts exactly on the sample.
        const reps = @max(cfg.unsmooth, 1);
        for (0..reps) |r| {
            const wobble: i32 = @intCast(r & 1);
            ev(EV_ABS, ABS_X, ax ^ wobble);
            ev(EV_ABS, ABS_Y, ay ^ wobble);
            ev(EV_ABS, ABS_TILT_X, tx);
            ev(EV_ABS, ABS_TILT_Y, ty);
            if (r + 1 == reps) {
                ev(EV_ABS, ABS_PRESSURE, if (touch) contactPressure(p) else 0);
                if (barrel != self.barrel) ev(EV_KEY, BTN_STYLUS, @intFromBool(barrel));
                if (touch != self.touch) ev(EV_KEY, BTN_TOUCH, @intFromBool(touch));
            }
            ev(EV_SYN, SYN_REPORT, 0);
        }
        self.touch = touch;
        self.barrel = barrel;
    }
};

var pen: Pen = undefined;
var pace_fd: i32 = -1;

// ---------------------------------------------------------------- playout

// Wi-Fi delivers pen data in bursts: 100+ ms of samples can land in one
// read. Written at once, the stroke "snaps" forward. Instead every sample is
// due when it would have arrived on a clean network (send time + best-case
// delay + jitter_ms), and a late burst is replayed with its original spacing
// sped up by cfg.catchup, so the pen catches up smoothly in a few frames.

const PLAY_RING = 4096;
const Play = struct { raw: [SAMPLE_SIZE]u8, at: u64 };
var play_q: [PLAY_RING]Play = undefined;
var play_head: usize = 0;
var play_len: usize = 0;
var play_fd: i32 = -1;
var play_prev_due: u64 = 0;
var play_prev_at: u64 = 0;
var play_lag_max_ns: u64 = 0; // per second: longest a sample waited on top of its arrival

fn playEnqueue(raw: *const [SAMPLE_SIZE]u8, due: u64, arrival: u64) void {
    var at = due;
    if (cfg.catchup > 0 and play_prev_at != 0 and due >= play_prev_due) {
        const spacing = due - play_prev_due;
        // Pen pauses longer than this aren't stretched; it's a new movement.
        if (spacing < 100 * std.time.ns_per_ms)
            at = @max(at, play_prev_at + @as(u64, @intFromFloat(@as(f64, @floatFromInt(spacing)) / cfg.catchup)));
    }
    // A late sample can't go out before it arrived; anchoring here (and not
    // at the previous sample, which may have gone out 100+ ms ago) is what
    // spreads the rest of a burst over the following frames.
    at = @max(at, arrival, play_prev_at); // never earlier than arrival, never reordered
    play_prev_due = due;
    play_prev_at = at;
    play_lag_max_ns = @max(play_lag_max_ns, at -| arrival);
    if (play_len == PLAY_RING) { // hopelessly behind: play the oldest now
        pen.sample(&play_q[play_head].raw);
        play_head = (play_head + 1) % PLAY_RING;
        play_len -= 1;
    }
    play_q[(play_head + play_len) % PLAY_RING] = .{ .raw = raw.*, .at = at };
    play_len += 1;
}

/// Emit every sample that is due, then arm the timer for the next one.
fn playDrain() void {
    const now = nowNs();
    while (play_len > 0 and play_q[play_head].at <= now) {
        pen.sample(&play_q[play_head].raw);
        play_head = (play_head + 1) % PLAY_RING;
        play_len -= 1;
    }
    pen.flush();
    if (play_len > 0) {
        const wait = @max(play_q[play_head].at - now, 1000);
        const spec = linux.itimerspec{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value = .{ .sec = @intCast(wait / std.time.ns_per_s), .nsec = @intCast(wait % std.time.ns_per_s) },
        };
        _ = linux.timerfd_settime(play_fd, .{}, &spec, null);
    }
}

fn playReset() void {
    play_len = 0;
    play_prev_at = 0;
    play_prev_due = 0;
}

// ---------------------------------------------------------------- clients

const MAX_CLIENTS = 16;
const LISTEN_TAG: u64 = std.math.maxInt(u64);

const Client = struct {
    fd: i32 = -1,
    ws: bool = false,
    len: usize = 0,
    peer: [4]u8 = .{ 0, 0, 0, 0 },
    stats: Stats = .{},
    buf: [16384]u8 = undefined,
};

var clients: [MAX_CLIENTS]Client = @splat(.{});
var epfd: i32 = -1;
var active_ws: usize = 0;
var newest_ws: ?usize = null;

fn closeClient(c: *Client) void {
    if (c.ws) {
        active_ws -= 1;
        // Lift the pen whenever a drawing client goes away; never leave a
        // stuck button behind.
        playReset();
        pen.leave();
        pen.flush();
        say("styllink: {d}.{d}.{d}.{d} disconnected ({d} connected)\n", .{ c.peer[0], c.peer[1], c.peer[2], c.peer[3], active_ws });
        logJson("\"ev\":\"disconnect\",\"peer\":\"{f}\",\"stalls_total\":{d}", .{ ip(c.peer), c.stats.stalls_total });
        if (newest_ws) |i| if (&clients[i] == c) {
            newest_ws = null;
        };
    }
    if (cfg.io == .epoll) _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, c.fd, null);
    _ = linux.close(c.fd);
    c.* = .{};
}

fn sendFrame(c: *Client, opcode: u8, payload: []const u8) void {
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

fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name))
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

/// Header values go into the log as JSON strings: cut at the first character
/// that would need escaping (Origin never contains one legitimately).
fn jsonSafe(v: []const u8) []const u8 {
    for (v, 0..) |ch, i| if (ch == '"' or ch == '\\' or ch < 0x20) return v[0..i];
    return v[0..@min(v.len, 200)];
}

fn queryParam(target: []const u8, key: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |kv| {
        if (kv.len > key.len and std.mem.startsWith(u8, kv, key) and kv[key.len] == '=')
            return kv[key.len + 1 ..];
    }
    return null;
}

fn httpReply(c: *Client, status: []const u8, ctype: []const u8, body: []const u8) void {
    var hdr: [256]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n" ++
        "Cache-Control: no-store\r\nConnection: close\r\n\r\n", .{ status, ctype, body.len }) catch return;
    _ = writeAll(c.fd, h);
    _ = writeAll(c.fd, body);
}

/// Returns false if the client should be closed.
fn handleHttp(c: *Client) bool {
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
                say("styllink: rejected {d}.{d}.{d}.{d}: wrong token\n", .{ c.peer[0], c.peer[1], c.peer[2], c.peer[3] });
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
        if (!writeAll(c.fd, r)) return false;

        c.ws = true;
        active_ws += 1;
        newest_ws = (@intFromPtr(c) - @intFromPtr(&clients[0])) / @sizeOf(Client);
        say("styllink: {d}.{d}.{d}.{d} connected ({d} connected), benchmarking link...\n", .{ c.peer[0], c.peer[1], c.peer[2], c.peer[3], active_ws });
        logJson("\"ev\":\"connect\",\"peer\":\"{f}\",\"origin\":\"{s}\"", .{ ip(c.peer), jsonSafe(headerValue(head, "Origin") orelse "") });
        var hello: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&hello, "{{\"w\":{d},\"h\":{d}}}", .{ cfg.region[2], cfg.region[3] }) catch return false;
        sendFrame(c, 0x1, msg);

        const rest = c.len - (end + 4);
        std.mem.copyForwards(u8, c.buf[0..rest], c.buf[end + 4 .. c.len]);
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

/// Parse as many complete frames as are buffered. Returns false to close.
fn handleWs(c: *Client) bool {
    var off: usize = 0;
    var pen_msgs: u32 = 0; // pen messages handled in this one read = burst size
    defer {
        c.stats.burst_max = @max(c.stats.burst_max, pen_msgs);
        playDrain();
        const rest = c.len - off;
        if (off > 0 and rest > 0) std.mem.copyForwards(u8, c.buf[0..rest], c.buf[off..c.len]);
        c.len = rest;
    }
    while (true) {
        const b = c.buf[off..c.len];
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
        const payload = c.buf[off + hl + 4 ..][0..plen];
        for (payload, 0..) |*byte, i| byte.* ^= mask[i & 3];
        off += hl + 4 + plen;

        switch (opcode) {
            0x2 => { // binary: u32 client timestamp + batch of pen samples
                if (payload.len < 4) continue;
                const excess = c.stats.uplink(std.mem.readInt(u32, payload[0..4], .little));
                // When this message would have arrived with no network delay.
                const arrival = nowNs();
                const on_time = (arrival -| @as(u64, excess) * std.time.ns_per_us) + @as(u64, cfg.jitter_ms) * std.time.ns_per_ms;
                var active = false;
                var i: usize = 4;
                while (i + SAMPLE_SIZE <= payload.len) : (i += SAMPLE_SIZE) {
                    if (payload[i + 8] & F_IN_RANGE != 0) {
                        c.stats.samples += 1;
                        active = true;
                    }
                    const age_ns = @as(u64, payload[i + 9]) * 500 * std.time.ns_per_us;
                    c.stats.age_max_us = @max(c.stats.age_max_us, @as(u32, @intCast(age_ns / 1000)));
                    c.stats.age_sum_us += age_ns / 1000;
                    c.stats.age_n += 1;
                    playEnqueue(payload[i..][0..SAMPLE_SIZE], on_time -| age_ns, arrival);
                }
                pen_msgs += 1;
                c.stats.arrival(c, active, excess);
            },
            0x1 => if (payload.len > 0) switch (payload[0]) {
                'p' => sendFrame(c, 0x1, payload), // page's own RTT ping: echo
                'b', 's' => c.stats.pong(payload), // our ping coming back
                'i' => reportCaps(c, payload), // page capabilities
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
fn onData(c: *Client, n: usize) bool {
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

fn tuneSocket(fd: i32) void {
    const one: i32 = 1;
    _ = linux.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, std.mem.asBytes(&one), 4);
    // DSCP EF: on Wi-Fi (WMM) this maps our packets/ACKs to the voice queue.
    const tos: i32 = 0xb8;
    _ = linux.setsockopt(fd, linux.IPPROTO.IP, 1, std.mem.asBytes(&tos), 4); // IP_TOS
}

fn claimSlot(fd: i32) ?usize {
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

// ---------------------------------------------------------------- link benchmark

// Every connected tablet gets a burst of pings on connect (summary printed
// once), then a ping every 250 ms. The page echoes them straight back. Each
// pen message also carries the page's send time, so we can see how much
// extra delay the tablet->PC direction adds over its best case.

const TIMER_TAG: u64 = LISTEN_TAG - 1;
const PACE_TAG: u64 = LISTEN_TAG - 2;
const PLAY_TAG: u64 = LISTEN_TAG - 3;
const TICK_MS = 20;
const BURST = 50;
const PING_EVERY = 250 / TICK_MS;
const REPORT_EVERY = 1000 / TICK_MS;

var tfd: i32 = -1;
var ticks: u64 = 0;
var tty = false;
var live_shown = false;

fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Print a log line, first wiping the live status line if it is showing.
fn say(comptime fmt: []const u8, args: anytype) void {
    if (live_shown) std.debug.print("\r\x1b[K", .{});
    live_shown = false;
    std.debug.print(fmt, args);
}

fn Ring(comptime N: usize) type {
    return struct {
        v: [N]u32 = undefined,
        n: usize = 0,
        i: usize = 0,

        fn push(r: *@This(), x: u32) void {
            r.v[r.i] = x;
            r.i = (r.i + 1) % N;
            if (r.n < N) r.n += 1;
        }

        fn pct(r: *const @This(), p: usize) u32 {
            if (r.n == 0) return 0;
            var tmp: [N]u32 = undefined;
            @memcpy(tmp[0..r.n], r.v[0..r.n]);
            std.mem.sort(u32, tmp[0..r.n], {}, std.sort.asc(u32));
            return tmp[(r.n - 1) * p / 100];
        }
    };
}

const Stats = struct {
    burst_sent: u32 = 0,
    burst_at: u64 = 0,
    burst_reported: bool = false,
    burst: Ring(BURST) = .{},
    rtt: Ring(64) = .{}, // ~16 s of background pings
    up: Ring(256) = .{}, // uplink excess delay, us
    up_ref: ?u32 = null,
    up_min_cur: i32 = std.math.maxInt(i32),
    up_min_prev: i32 = std.math.maxInt(i32),
    samples: u32 = 0,
    msgs: u32 = 0,
    // per-second stall diagnostics, reset by the stat report
    last_msg_ns: u64 = 0,
    last_active: bool = false,
    gap_max_ns: u64 = 0,
    burst_max: u32 = 0,
    up_max: u32 = 0,
    stalls: u32 = 0,
    stalls_total: u32 = 0,
    caps_seen: bool = false,
    // How long samples sat in the page before being sent (per second). Large
    // ages mean the tablet's browser was busy, not the network.
    age_max_us: u32 = 0,
    age_sum_us: u64 = 0,
    age_n: u32 = 0,
    tcp_prev: ?TcpInfo = null,

    /// A pen message arrived. While the pen is active the page sends one
    /// every few ms, so a long gap here means the network held data back.
    fn arrival(st: *Stats, c: *const Client, active: bool, excess_us: u32) void {
        const now = nowNs();
        st.up_max = @max(st.up_max, excess_us);
        if (st.last_active and active and st.last_msg_ns != 0) {
            const gap = now - st.last_msg_ns;
            st.gap_max_ns = @max(st.gap_max_ns, gap);
            if (gap > STALL_NS) {
                st.stalls += 1;
                st.stalls_total += 1;
                const t = tcpInfo(c.fd) orelse TcpInfo{};
                const p = st.tcp_prev orelse t;
                logJson("\"ev\":\"stall\",\"peer\":\"{f}\",\"gap_ms\":{f},\"uplink_excess_ms\":{f},\"ooo_since_stat\":{d},\"retrans_since_stat\":{d},\"tcp_rtt_ms\":{f}", .{
                    ip(c.peer), ms(@intCast(@min(gap / 1000, std.math.maxInt(u32)))), ms(excess_us),
                    t.ooo -% p.ooo, t.total_retrans -% p.total_retrans, ms(t.rtt_us),
                });
            }
        }
        st.last_msg_ns = now;
        st.last_active = active;
    }

    fn pong(st: *Stats, payload: []const u8) void {
        const sent = std.fmt.parseInt(u64, payload[1..], 10) catch return;
        const us: u32 = @intCast(@min((nowNs() -| sent) / 1000, std.math.maxInt(u32)));
        if (payload[0] == 'b') st.burst.push(us);
        st.rtt.push(us);
    }

    /// `t` is the page's performance.now() in 0.1 ms units. The two clocks
    /// are unrelated, so only the variation of (arrival - send) means
    /// anything: we report it relative to the best case seen recently.
    fn uplink(st: *Stats, t: u32) u32 {
        st.msgs += 1;
        const here: u32 = @truncate(nowNs() / 100_000);
        const off = here -% t;
        const ref = st.up_ref orelse blk: {
            st.up_ref = off;
            break :blk off;
        };
        const rel: i32 = @bitCast(off -% ref);
        st.up_min_cur = @min(st.up_min_cur, rel);
        const base = @min(st.up_min_cur, st.up_min_prev);
        const excess: u32 = @intCast(@max(rel - base, 0) * 100);
        st.up.push(excess);
        return excess;
    }
};

const STALL_NS = 50 * std.time.ns_per_ms;

/// The bits of Linux `struct tcp_info` we report (offsets from linux/tcp.h).
/// `ooo` (tcpi_rcv_ooopack) counts tablet->PC packets that arrived out of
/// order because an earlier one was lost: TCP then holds back everything
/// behind the hole until the retransmit, so pen data bunches up.
const TcpInfo = struct {
    rto_us: u32 = 0,
    rtt_us: u32 = 0,
    total_retrans: u32 = 0, // PC->tablet retransmits
    segs_in: u32 = 0,
    ooo: u32 = 0,
};

fn tcpInfo(fd: i32) ?TcpInfo {
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

var log_fd: i32 = -1;

/// Append one JSON object (`fields` without braces) with a unix-ms timestamp.
fn logJson(comptime fields: []const u8, args: anytype) void {
    if (log_fd < 0) return;
    var b: [1024]u8 = undefined;
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    const unix_ms = @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
    const line = std.fmt.bufPrint(&b, "{{\"ts\":{d}," ++ fields ++ "}}\n", .{unix_ms} ++ args) catch return;
    _ = writeAll(log_fd, line);
}

const Ip = struct {
    a: [4]u8,
    pub fn format(v: Ip, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}.{d}.{d}.{d}", .{ v.a[0], v.a[1], v.a[2], v.a[3] });
    }
};
fn ip(a: [4]u8) Ip {
    return .{ .a = a };
}

fn sendPing(c: *Client, kind: u8) void {
    var b: [32]u8 = undefined;
    const msg = std.fmt.bufPrint(&b, "{c}{d}", .{ kind, nowNs() }) catch return;
    sendFrame(c, 0x1, msg);
}

const Ms = struct {
    us: u32,
    pub fn format(m: Ms, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}.{d}", .{ m.us / 1000, (m.us % 1000) / 100 });
    }
};
fn ms(us: u32) Ms {
    return .{ .us = us };
}

/// "i<raw><coalesced>": which pointer APIs the page got. Both are limited to
/// secure contexts, and without them fast strokes are sampled at frame rate.
fn reportCaps(c: *Client, payload: []const u8) void {
    if (payload.len < 3) return;
    const raw = payload[1] == '1';
    const coalesced = payload[2] == '1';
    const keepawake = payload.len > 3 and payload[3] == '1';
    const trail = payload.len > 4 and payload[4] == '1';
    const native = payload.len > 5 and payload[5] == '1'; // Android app
    const wifi_lock = payload.len > 6 and payload[6] == '1'; // its low-latency Wi-Fi lock
    logJson("\"ev\":\"caps\",\"peer\":\"{f}\",\"raw\":{},\"coalesced\":{},\"keepawake\":{},\"trail\":{},\"native\":{},\"wifi_lock\":{}", .{ ip(c.peer), raw, coalesced, keepawake, trail, native, wifi_lock });
    if (c.stats.caps_seen) return; // re-sent when a setting changes: log only
    c.stats.caps_seen = true;
    if (native) return say("  pen input: Android app (unbuffered, full sample rate), low-latency Wi-Fi lock {s}\n", .{if (wifi_lock) "held" else "NOT held"});
    if (raw) return say("  pen input: raw events (lowest latency, full sample rate)\n", .{});
    const me = lanAddr() orelse [4]u8{ 127, 0, 0, 1 };
    if (coalesced) return say("  pen input: coalesced events (full sample rate, up to 1 frame extra latency)\n", .{});
    say(
        \\  WARNING: {d}.{d}.{d}.{d} opened the page from an insecure origin, so Chrome hides the
        \\  pen-sample APIs and sends ONE sample per display frame: fast handwriting gets choppy.
        \\  Fix (pick one):
        \\    - tablet Chrome: chrome://flags/#unsafely-treat-insecure-origin-as-secure
        \\      add  http://{d}.{d}.{d}.{d}:{d}  , set Enabled, relaunch Chrome
        \\    - USB: adb reverse tcp:{d} tcp:{d}  and open http://localhost:{d}/?t=...
        \\
    , .{ c.peer[0], c.peer[1], c.peer[2], c.peer[3], me[0], me[1], me[2], me[3], cfg.port, cfg.port, cfg.port, cfg.port });
}

fn reportBurst(c: *Client) void {
    const st = &c.stats;
    st.burst_reported = true;
    const r = &st.burst;
    if (r.n == 0) {
        say("  link benchmark: no replies to {d} pings\n", .{BURST});
        return;
    }
    var jit: u64 = 0;
    for (1..r.n) |i| jit += @abs(@as(i64, r.v[i]) - @as(i64, r.v[i - 1]));
    if (r.n > 1) jit /= r.n - 1;
    const p95 = r.pct(95);
    const verdict = if (p95 < 8000) "great for drawing" else if (p95 < 20000) "usable" else "laggy: try USB (adb reverse) or 5 GHz Wi-Fi";
    logJson("\"ev\":\"bench\",\"peer\":\"{f}\",\"pings\":{d},\"rtt_min_ms\":{f},\"rtt_p50_ms\":{f},\"rtt_p95_ms\":{f},\"rtt_max_ms\":{f},\"jitter_ms\":{f}", .{
        ip(c.peer), r.n, ms(r.pct(0)), ms(r.pct(50)), ms(p95), ms(r.pct(100)), ms(@intCast(jit)),
    });
    say("  link benchmark ({d}/{d} pings): rtt min {f}  p50 {f}  p95 {f}  max {f} ms, jitter {f} ms -> {s}\n", .{
        r.n,           BURST,         ms(r.pct(0)),               ms(r.pct(50)), ms(p95), ms(r.pct(100)),
        ms(@intCast(jit)), verdict,
    });
}

fn reportLive(c: *Client) void {
    const st = &c.stats;
    var b: [320]u8 = undefined;
    const pen_part = if (st.samples == 0)
        std.fmt.bufPrint(b[192..], "pen idle", .{}) catch ""
    else
        std.fmt.bufPrint(b[192..], "pen {d} Hz  gap max {f} ms  stalls {d}", .{
            st.samples, ms(@intCast(@min(st.gap_max_ns / 1000, std.math.maxInt(u32)))), st.stalls,
        }) catch "";
    const line = std.fmt.bufPrint(b[0..192], "  live  rtt {f} ms (p95 {f})  uplink +{f} ms (p95 +{f})  ", .{
        ms(st.rtt.pct(50)), ms(st.rtt.pct(95)), ms(st.up.pct(50)), ms(st.up.pct(95)),
    }) catch return;
    if (tty) {
        std.debug.print("\r\x1b[K{s}{s}", .{ line, pen_part });
        live_shown = true;
    } else if (ticks % (REPORT_EVERY * 10) == 0) {
        std.debug.print("{s}{s}\n", .{ line, pen_part });
    }
}

/// Once a second: one log line per client with this second's link stats
/// (every 10 s while idle), then reset the per-second counters.
fn logStat(c: *Client) void {
    const st = &c.stats;
    const t = tcpInfo(c.fd) orelse TcpInfo{};
    const p = st.tcp_prev orelse t;
    st.tcp_prev = t;
    if (st.msgs > 0 or ticks % (10 * REPORT_EVERY) == 0) {
        logJson("\"ev\":\"stat\",\"peer\":\"{f}\",\"pen_hz\":{d},\"msgs\":{d},\"gap_max_ms\":{f},\"stalls\":{d},\"burst_max\":{d}," ++
            "\"rtt_p50_ms\":{f},\"rtt_p95_ms\":{f},\"uplink_p50_ms\":{f},\"uplink_p95_ms\":{f},\"uplink_max_ms\":{f}," ++
            "\"ooo\":{d},\"retrans\":{d},\"segs_in\":{d},\"tcp_rtt_ms\":{f},\"tcp_rto_ms\":{f},\"smooth_lag_max_ms\":{f},\"age_mean_ms\":{f},\"age_max_ms\":{f}", .{
            ip(c.peer),             st.samples,                      st.msgs,
            ms(@intCast(@min(st.gap_max_ns / 1000, std.math.maxInt(u32)))), st.stalls, st.burst_max,
            ms(st.rtt.pct(50)),     ms(st.rtt.pct(95)),              ms(st.up.pct(50)),
            ms(st.up.pct(95)),      ms(st.up_max),                   t.ooo -% p.ooo,
            t.total_retrans -% p.total_retrans, t.segs_in -% p.segs_in, ms(t.rtt_us),
            ms(t.rto_us),                               ms(@intCast(@min(play_lag_max_ns / 1000, std.math.maxInt(u32)))),
            ms(if (st.age_n > 0) @intCast(st.age_sum_us / st.age_n) else 0), ms(st.age_max_us),
        });
    }
    st.age_max_us = 0;
    st.age_sum_us = 0;
    st.age_n = 0;
    play_lag_max_ns = 0;
    st.gap_max_ns = 0;
    st.burst_max = 0;
    st.up_max = 0;
    st.stalls = 0;
}

fn onTick() void {
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
            if (!st.burst_reported and (st.burst.n == BURST or ticks - st.burst_at > 50)) reportBurst(c);
        }
        if (ticks % (5 * REPORT_EVERY) == 0) { // rotate the uplink baseline window
            st.up_min_prev = st.up_min_cur;
            st.up_min_cur = std.math.maxInt(i32);
        }
        if (ticks % REPORT_EVERY == 0) {
            if (st.burst_reported and newest_ws == i) reportLive(c);
            logStat(c);
            st.samples = 0;
            st.msgs = 0;
        }
    }
}

fn startTimer() void {
    var termios: [64]u8 = undefined;
    tty = linux.errno(linux.ioctl(2, 0x5401, @intFromPtr(&termios))) == .SUCCESS; // TCGETS on stderr
    tfd = @intCast(check(linux.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true }), "timerfd_create"));
    const period = linux.timespec{ .sec = 0, .nsec = TICK_MS * std.time.ns_per_ms };
    const spec = linux.itimerspec{ .it_interval = period, .it_value = period };
    _ = check(linux.timerfd_settime(tfd, .{}, &spec, null), "timerfd_settime");
    pace_fd = @intCast(check(linux.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true }), "timerfd_create"));
    play_fd = @intCast(check(linux.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true }), "timerfd_create"));
}

// ---------------------------------------------------------------- epoll backend

fn runEpoll(lfd: i32) noreturn {
    epfd = @intCast(check(linux.epoll_create1(linux.EPOLL.CLOEXEC), "epoll_create1"));
    var lev = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .u64 = LISTEN_TAG } };
    _ = check(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, lfd, &lev), "epoll_ctl");
    var tev = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .u64 = TIMER_TAG } };
    _ = check(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, tfd, &tev), "epoll_ctl");
    var pev = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .u64 = PACE_TAG } };
    _ = check(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, pace_fd, &pev), "epoll_ctl");
    var yev = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .u64 = PLAY_TAG } };
    _ = check(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, play_fd, &yev), "epoll_ctl");

    const timeout: i32 = if (cfg.busy) 0 else -1;
    var events: [MAX_CLIENTS + 4]linux.epoll_event = undefined;
    while (true) {
        const rc = linux.epoll_wait(epfd, &events, events.len, timeout);
        if (linux.errno(rc) == .INTR) continue;
        for (events[0..check(rc, "epoll_wait")]) |e| {
            if (e.data.u64 == PLAY_TAG) {
                var expirations: u64 = 0;
                _ = linux.read(play_fd, std.mem.asBytes(&expirations), 8);
                playDrain();
                continue;
            }
            if (e.data.u64 == PACE_TAG) {
                var expirations: u64 = 0;
                _ = linux.read(pace_fd, std.mem.asBytes(&expirations), 8);
                pen.drain();
                continue;
            }
            if (e.data.u64 == TIMER_TAG) {
                var expirations: u64 = 0;
                _ = linux.read(tfd, std.mem.asBytes(&expirations), 8);
                onTick();
                continue;
            }
            if (e.data.u64 == LISTEN_TAG) {
                const arc = linux.accept4(lfd, null, null, linux.SOCK.CLOEXEC);
                if (linux.errno(arc) != .SUCCESS) continue;
                const fd: i32 = @intCast(arc);
                tuneSocket(fd);
                const i = claimSlot(fd) orelse continue;
                var ev = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.RDHUP, .data = .{ .u64 = i } };
                _ = check(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, fd, &ev), "epoll_ctl");
                continue;
            }
            const c = &clients[@intCast(e.data.u64)];
            if (c.fd == -1) continue;
            if (e.events & linux.EPOLL.IN == 0) {
                closeClient(c);
                continue;
            }
            if (c.len == c.buf.len) {
                closeClient(c);
                continue;
            }
            const r = linux.read(c.fd, c.buf[c.len..].ptr, c.buf.len - c.len);
            switch (linux.errno(r)) {
                .SUCCESS => if (!onData(c, r)) closeClient(c),
                .INTR, .AGAIN => {},
                else => closeClient(c),
            }
        }
    }
}

// ---------------------------------------------------------------- io_uring backend

fn queueRecv(ring: *linux.IoUring, i: usize) bool {
    const c = &clients[i];
    if (c.len == c.buf.len) return false;
    _ = ring.recv(i, c.fd, .{ .buffer = c.buf[c.len..] }, 0) catch return false;
    return true;
}

fn runUring(lfd: i32) noreturn {
    // Busy mode spins on the completion ring from userspace, so completions
    // must be posted without us entering the kernel (no DEFER_TASKRUN).
    const flags: u32 = if (cfg.busy) 0 else linux.IORING_SETUP_SINGLE_ISSUER | linux.IORING_SETUP_DEFER_TASKRUN;
    var ring = linux.IoUring.init(64, flags) catch linux.IoUring.init(64, 0) catch |err| {
        std.debug.print("styllink: io_uring unavailable ({s}), use --io epoll\n", .{@errorName(err)});
        linux.exit(1);
    };
    _ = ring.accept_multishot(LISTEN_TAG, lfd, null, null, linux.SOCK.CLOEXEC) catch unreachable;
    var expirations: u64 = 0;
    _ = ring.read(TIMER_TAG, tfd, .{ .buffer = std.mem.asBytes(&expirations) }, 0) catch unreachable;
    var pace_exp: u64 = 0;
    _ = ring.read(PACE_TAG, pace_fd, .{ .buffer = std.mem.asBytes(&pace_exp) }, 0) catch unreachable;
    var play_exp: u64 = 0;
    _ = ring.read(PLAY_TAG, play_fd, .{ .buffer = std.mem.asBytes(&play_exp) }, 0) catch unreachable;

    var cqes: [64]linux.io_uring_cqe = undefined;
    while (true) {
        // One syscall per wake: submit pending recvs and wait for a completion.
        if (!cfg.busy) {
            _ = ring.submit_and_wait(1) catch {};
        } else if (ring.sq_ready() > 0) {
            _ = ring.submit() catch {};
        }
        const n = ring.copy_cqes(&cqes, 0) catch 0;
        for (cqes[0..n]) |cqe| {
            if (cqe.user_data == PLAY_TAG) {
                playDrain();
                _ = ring.read(PLAY_TAG, play_fd, .{ .buffer = std.mem.asBytes(&play_exp) }, 0) catch {};
                continue;
            }
            if (cqe.user_data == PACE_TAG) {
                pen.drain();
                _ = ring.read(PACE_TAG, pace_fd, .{ .buffer = std.mem.asBytes(&pace_exp) }, 0) catch {};
                continue;
            }
            if (cqe.user_data == TIMER_TAG) {
                onTick();
                _ = ring.read(TIMER_TAG, tfd, .{ .buffer = std.mem.asBytes(&expirations) }, 0) catch {};
                continue;
            }
            if (cqe.user_data == LISTEN_TAG) {
                if (cqe.flags & linux.IORING_CQE_F_MORE == 0)
                    _ = ring.accept_multishot(LISTEN_TAG, lfd, null, null, linux.SOCK.CLOEXEC) catch {};
                if (cqe.res < 0) continue;
                tuneSocket(cqe.res);
                const i = claimSlot(cqe.res) orelse continue;
                if (!queueRecv(&ring, i)) closeClient(&clients[i]);
                continue;
            }
            const i: usize = @intCast(cqe.user_data);
            const c = &clients[i];
            if (c.fd == -1) continue;
            const keep = cqe.res > 0 and onData(c, @intCast(cqe.res));
            if (!keep or !queueRecv(&ring, i)) closeClient(c);
        }
    }
}

// ---------------------------------------------------------------- banner

/// Primary LAN address: "connect" a UDP socket (sends nothing) and read back
/// the source address the kernel picked.
fn lanAddr() ?[4]u8 {
    const fd: i32 = @intCast(check(linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0), "socket"));
    defer _ = linux.close(fd);
    var dst = linux.sockaddr.in{ .port = std.mem.nativeToBig(u16, 53), .addr = @bitCast([4]u8{ 1, 1, 1, 1 }) };
    if (linux.errno(linux.connect(fd, @ptrCast(&dst), @sizeOf(linux.sockaddr.in))) != .SUCCESS) return null;
    var me: linux.sockaddr.in = undefined;
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    if (linux.errno(linux.getsockname(fd, @ptrCast(&me), &len)) != .SUCCESS) return null;
    return @bitCast(me.addr);
}

fn printAppQr(label: []const u8, uri: []const u8) void {
    std.debug.print("\n  {s}\n  {s}\n", .{ label, uri });
    if (qr.encode(uri)) |code| {
        var out: [32 * 1024]u8 = undefined;
        std.debug.print("{s}", .{qr.render(&code, &out)});
    }
}

fn printBanner() void {
    const me = lanAddr() orelse [4]u8{ 127, 0, 0, 1 };
    var lb: [128]u8 = undefined;
    const tq = if (cfg.token.len > 0) "/?t=" else "/";
    const local = std.fmt.bufPrint(&lb, "http://{d}.{d}.{d}.{d}:{d}{s}{s}", .{ me[0], me[1], me[2], me[3], cfg.port, tq, cfg.token }) catch return;
    // The hosted (HTTPS) page is a secure context, which unlocks the
    // full-rate pen APIs; it finds us through the URL fragment.
    var wb: [256]u8 = undefined;
    const web: ?[]const u8 = if (cfg.web_url.len == 0) null else std.fmt.bufPrint(&wb, "{s}#h={d}.{d}.{d}.{d}:{d}&t={s}", .{
        std.mem.trimEnd(u8, cfg.web_url, "/"), me[0], me[1], me[2], me[3], cfg.port, cfg.token,
    }) catch null;
    // A camera/QR scanner opens the installed native app directly.
    // run.sh enables the USB QR only after ADB forwarding succeeds.
    var ab: [256]u8 = undefined;
    const app = std.fmt.bufPrint(&ab, "styllink://connect?h={d}.{d}.{d}.{d}:{d}&t={s}", .{
        me[0], me[1], me[2], me[3], cfg.port, cfg.token,
    }) catch return;
    if (cfg.usb_qr) {
        var ub: [256]u8 = undefined;
        const usb = std.fmt.bufPrint(&ub, "styllink://connect?h=localhost:{d}&t={s}", .{ cfg.port, cfg.token }) catch return;
        printAppQr("USB ready — scan for the wired connection (lowest latency):", usb);
    }
    printAppQr("Wi-Fi — scan to connect over the LAN:", app);
    if (web) |url| std.debug.print("  Browser (Chrome):  {s}\n", .{url});
    std.debug.print("  Local browser fallback (60 Hz pen over Wi-Fi):  {s}\n", .{local});
    std.debug.print(
        \\  USB (lowest latency): adb reverse tcp:{d} tcp:{d}, then http://localhost:{d}{s}{s}
        \\  Settings on the pad: hover or tap its top-right corner.
        \\
        \\
    , .{ cfg.port, cfg.port, cfg.port, tq, cfg.token });
}

// ---------------------------------------------------------------- main

pub fn main(init: std.process.Init.Minimal) void {
    var args = init.args.iterate();
    _ = args.skip();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--busy")) {
            cfg.busy = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--usb-qr")) {
            cfg.usb_qr = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-uinput")) {
            cfg.uinput = false;
            continue;
        }
        const v = args.next() orelse usage();
        if (std.mem.eql(u8, a, "--port")) {
            cfg.port = std.fmt.parseInt(u16, v, 10) catch usage();
        } else if (std.mem.eql(u8, a, "--token")) {
            cfg.token = v;
            cfg.token_set = true;
        } else if (std.mem.eql(u8, a, "--region")) {
            cfg.region = parseList(4, v);
        } else if (std.mem.eql(u8, a, "--desktop")) {
            cfg.desktop = parseList(2, v);
        } else if (std.mem.eql(u8, a, "--catchup")) {
            cfg.catchup = std.fmt.parseFloat(f64, v) catch usage();
            if (cfg.catchup != 0 and cfg.catchup < 1) usage();
        } else if (std.mem.eql(u8, a, "--jitter-ms")) {
            cfg.jitter_ms = std.fmt.parseInt(u32, v, 10) catch usage();
        } else if (std.mem.eql(u8, a, "--log")) {
            cfg.log_path = v;
        } else if (std.mem.eql(u8, a, "--web-url")) {
            cfg.web_url = v;
        } else if (std.mem.eql(u8, a, "--unsmooth")) {
            cfg.unsmooth = std.fmt.parseInt(usize, v, 10) catch usage();
            if (cfg.unsmooth == 0 or cfg.unsmooth > 16) usage();
        } else if (std.mem.eql(u8, a, "--io")) {
            cfg.io = std.meta.stringToEnum(Io, v) orelse usage();
        } else usage();
    }
    if (cfg.region[2] == 0 or cfg.region[3] == 0 or cfg.desktop[0] == 0 or cfg.desktop[1] == 0) usage();

    var token_buf: [12]u8 = undefined;
    if (!cfg.token_set) {
        var rnd: [6]u8 = undefined;
        _ = check(linux.getrandom(&rnd, rnd.len, 0), "getrandom");
        const hex = std.fmt.bytesToHex(rnd, .lower);
        token_buf = hex;
        cfg.token = &token_buf;
    }

    pen = .{ .fd = if (cfg.uinput) uinputCreate() else -1 };

    if (cfg.log_path.len > 0) {
        const rc = linux.open(cfg.log_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o644);
        if (linux.errno(rc) == .SUCCESS) {
            log_fd = @intCast(rc);
        } else std.debug.print("styllink: can't open log {s}: {s}\n", .{ cfg.log_path, @tagName(linux.errno(rc)) });
    }

    const lfd: i32 = @intCast(check(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0), "socket"));
    const one: i32 = 1;
    _ = linux.setsockopt(lfd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), 4);
    var addr = linux.sockaddr.in{ .port = std.mem.nativeToBig(u16, cfg.port), .addr = 0 };
    // A just-killed io_uring instance releases its listening socket
    // asynchronously, so give a quick restart a few seconds to get the port.
    var tries: usize = 0;
    while (true) : (tries += 1) {
        const rc = linux.bind(lfd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in));
        if (linux.errno(rc) != .ADDRINUSE or tries == 30) {
            _ = check(rc, "bind");
            break;
        }
        const ts = linux.timespec{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts, null);
    }
    _ = check(linux.listen(lfd, 16), "listen");

    printBanner();
    startTimer();
    logJson("\"ev\":\"start\",\"port\":{d},\"io\":\"{s}\",\"busy\":{},\"unsmooth\":{d},\"catchup\":{d},\"jitter_ms\":{d},\"region\":[{d},{d},{d},{d}],\"desktop\":[{d},{d}]", .{
        cfg.port, @tagName(cfg.io), cfg.busy, cfg.unsmooth, cfg.catchup, cfg.jitter_ms, cfg.region[0], cfg.region[1], cfg.region[2], cfg.region[3], cfg.desktop[0], cfg.desktop[1],
    });
    if (log_fd >= 0) std.debug.print("styllink: logging to {s}\n", .{cfg.log_path});
    std.debug.print("styllink: :{d} via {s}{s}, mapping to {d}x{d}+{d}+{d} of {d}x{d}{s}\n", .{
        cfg.port,      @tagName(cfg.io), if (cfg.busy) " (busy-poll)" else "",
        cfg.region[2], cfg.region[3],    cfg.region[0],
        cfg.region[1], cfg.desktop[0],   cfg.desktop[1],
        if (cfg.uinput) "" else " [no uinput]",
    });

    switch (cfg.io) {
        .uring => runUring(lfd),
        .epoll => runEpoll(lfd),
    }
}


test "pen cooldown survives an empty queue between small writes" {
    const testing = std.testing;
    const device: i32 = @intCast(check(linux.open("/dev/null", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0), "test output"));
    defer _ = linux.close(device);
    pace_fd = @intCast(check(linux.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true }), "test timer"));
    defer _ = linux.close(pace_fd);
    defer { Pen.waiting = false; Pen.qlen = 0; Pen.qhead = 0; }
    var output = Pen{ .fd = device };
    Pen.waiting = false;
    Pen.qlen = 0;
    Pen.qhead = 0;
    Pen.ev(EV_ABS, ABS_X, 1);
    Pen.ev(EV_SYN, SYN_REPORT, 0);
    output.flush();
    try testing.expectEqual(@as(usize, 0), Pen.qlen);
    try testing.expect(Pen.waiting);
    // A second independent read in the same cooldown must wait.
    Pen.ev(EV_ABS, ABS_X, 2);
    Pen.ev(EV_SYN, SYN_REPORT, 0);
    output.flush();
    try testing.expectEqual(@as(usize, 2), Pen.qlen);
    // Simulate the timer callback: drain the second write, keep its cooldown.
    output.drain();
    try testing.expectEqual(@as(usize, 0), Pen.qlen);
    try testing.expect(Pen.waiting);
    output.drain(); // idle timer callback releases the cooldown
    try testing.expect(!Pen.waiting);
}
