//! Linux uinput virtual tablet, pen state emulation, pacing, and jitter playout.

const std = @import("std");
const linux = std.os.linux;
const util = @import("util.zig");
const config = @import("config.zig");

// ---------------------------------------------------------------- uinput

pub const EV_SYN = 0x00;
pub const EV_KEY = 0x01;
pub const EV_ABS = 0x03;
pub const SYN_REPORT = 0;
pub const ABS_X = 0x00;
pub const ABS_Y = 0x01;
pub const ABS_PRESSURE = 0x18;
pub const ABS_TILT_X = 0x1a;
pub const ABS_TILT_Y = 0x1b;
pub const BTN_TOOL_PEN = 0x140;
pub const BTN_TOOL_RUBBER = 0x141;
pub const BTN_TOUCH = 0x14a;
pub const BTN_STYLUS = 0x14b;
pub const INPUT_PROP_DIRECT = 0x01;

pub const UI_DEV_CREATE: u32 = 0x5501;
pub const UI_DEV_SETUP: u32 = 0x405c5503; // _IOW('U', 3, struct uinput_setup)
pub const UI_ABS_SETUP: u32 = 0x401c5504; // _IOW('U', 4, struct uinput_abs_setup)
pub const UI_SET_EVBIT: u32 = 0x40045564;
pub const UI_SET_KEYBIT: u32 = 0x40045565;
pub const UI_SET_ABSBIT: u32 = 0x40045567;
pub const UI_SET_PROPBIT: u32 = 0x4004556e;

pub const InputEvent = extern struct {
    sec: isize = 0, // kernel stamps the event itself
    usec: isize = 0,
    type: u16,
    code: u16,
    value: i32,
};

pub const UinputSetup = extern struct {
    bustype: u16,
    vendor: u16,
    product: u16,
    version: u16,
    name: [80]u8,
    ff_effects_max: u32,
};

pub const AbsSetup = extern struct {
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

pub const AXIS_MAX: i32 = 65535;
pub const PRESSURE_MAX = 4095;
pub const TILT_MAX: i32 = 90;

pub fn uinputCreate(desktop: [2]u32) i32 {
    const rc = util.check(linux.open("/dev/uinput", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0), "open /dev/uinput");
    const fd: i32 = @intCast(rc);

    const ioc = struct {
        fn set(f: i32, req: u32, val: usize) void {
            _ = util.check(linux.ioctl(f, req, val), "uinput ioctl");
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
    const res_y: i32 = @intCast(@divTrunc(@as(u64, @intCast(AXIS_MAX)) * desktop[0], @as(u64, 300) * desktop[1]));
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
pub const SAMPLE_SIZE = 10;
pub const F_IN_RANGE = 1;
pub const F_TOUCH = 2;
pub const F_BARREL = 4;
pub const F_ERASER = 8;

pub const Pen = struct {
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
    pub const RING = 1 << 15;
    pub const CHUNK = 48;
    pub const PACE_US = 1000;
    pub var queue: [RING]InputEvent = undefined;
    pub var qhead: usize = 0; // next to write
    pub var qlen: usize = 0;
    pub var waiting = false; // pace timer armed

    pub fn ev(t: u16, c: u16, v: i32) void {
        if (qlen == RING) return; // hopelessly behind; the device can't take it anyway
        queue[(qhead + qlen) % RING] = .{ .type = t, .code = c, .value = v };
        qlen += 1;
    }

    pub fn tool(self: *const Pen) u16 {
        return if (self.eraser) BTN_TOOL_RUBBER else BTN_TOOL_PEN;
    }

    pub fn leave(self: *Pen) void {
        if (!self.in_range) return;
        if (self.touch) ev(EV_KEY, BTN_TOUCH, 0);
        if (self.barrel) ev(EV_KEY, BTN_STYLUS, 0);
        ev(EV_ABS, ABS_PRESSURE, 0);
        ev(EV_KEY, self.tool(), 0);
        ev(EV_SYN, SYN_REPORT, 0);
        self.* = .{ .fd = self.fd };
    }

    /// Start draining queued events, unless a paced drain is already running.
    pub fn flush(self: *Pen) void {
        if (!waiting) self.drain();
    }

    /// Write one chunk; arm the pace timer if more is queued. Called by
    /// flush() and by the pace timer.
    pub fn drain(self: *Pen) void {
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
        _ = util.writeAll(self.fd, std.mem.sliceAsBytes(queue[qhead .. qhead + take]));
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

    pub fn mapAxis(v: u16, off: u32, len: u32, total: u32) i32 {
        // region-local 0..65535 -> desktop-global device units
        const px = @as(u64, off) * 65535 + @as(u64, v) * len;
        return @intCast(px / total);
    }

    /// libinput ignores BTN_TOUCH on pens with a pressure axis and decides
    /// contact itself: tip down above ~5% of the range, up below ~1%. Lift
    /// every contact into [6%, 100%] so a light touch the page counts as ink
    /// is ink on the PC too.
    pub fn contactPressure(p: u16) i32 {
        const floor: u32 = PRESSURE_MAX * 6 / 100;
        return @intCast(floor + @as(u32, p) * (PRESSURE_MAX - floor) / 65535);
    }

    pub fn sample(self: *Pen, s: *const [SAMPLE_SIZE]u8) void {
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

pub var pen: Pen = undefined;
pub var pace_fd: i32 = -1;

// ---------------------------------------------------------------- playout

// Wi-Fi delivers pen data in bursts: 100+ ms of samples can land in one
// read. Written at once, the stroke "snaps" forward. Instead every sample is
// due when it would have arrived on a clean network (send time + best-case
// delay + jitter_ms), and a late burst is replayed with its original spacing
// sped up by cfg.catchup, so the pen catches up smoothly in a few frames.

pub const PLAY_RING = 4096;
pub const Play = struct { raw: [SAMPLE_SIZE]u8, at: u64 };
pub var play_q: [PLAY_RING]Play = undefined;
pub var play_head: usize = 0;
pub var play_len: usize = 0;
pub var play_fd: i32 = -1;
pub var play_prev_due: u64 = 0;
pub var play_prev_at: u64 = 0;
pub var play_lag_max_ns: u64 = 0; // per second: longest a sample waited on top of its arrival

pub fn playEnqueue(raw: *const [SAMPLE_SIZE]u8, due: u64, arrival: u64) void {
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
pub fn playDrain() void {
    const now = util.nowNs();
    while (play_len > 0 and play_q[play_head].at <= now) {
        pen.sample(&play_q[play_head].raw);
        play_head = (play_head + 1) % PLAY_RING;
        play_len -= 1;
    }
    pen.flush();
    if (!cfg.busy and play_len > 0) {
        const wait = @max(play_q[play_head].at - now, 1000);
        const spec = linux.itimerspec{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value = .{ .sec = @intCast(wait / std.time.ns_per_s), .nsec = @intCast(wait % std.time.ns_per_s) },
        };
        _ = linux.timerfd_settime(play_fd, .{}, &spec, null);
    }
}

pub fn playReset() void {
    play_len = 0;
    play_prev_at = 0;
    play_prev_due = 0;
}

pub var cfg: config.Config = .{};

pub fn init(c: config.Config) void {
    cfg = c;
    pen = .{ .fd = if (cfg.uinput) uinputCreate(cfg.desktop) else -1 };
    pace_fd = @intCast(util.check(linux.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true }), "timerfd_create"));
    play_fd = @intCast(util.check(linux.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true }), "timerfd_create"));
}

test "pen cooldown survives an empty queue between small writes" {
    const testing = std.testing;
    const device: i32 = @intCast(util.check(linux.open("/dev/null", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0), "test output"));
    defer _ = linux.close(device);
    pace_fd = @intCast(util.check(linux.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true }), "test timer"));
    defer _ = linux.close(pace_fd);
    defer {
        Pen.waiting = false;
        Pen.qlen = 0;
        Pen.qhead = 0;
    }
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
