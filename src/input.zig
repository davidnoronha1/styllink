//! Linux uinput virtual tablet, pen state emulation, pacing, and jitter playout.

const std = @import("std");
const platform = @import("platform.zig");
const util = @import("util.zig");
const config = @import("config.zig");
const uinput = @import("input/events.zig");

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
    device: platform.InputDevice = .{},
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
    pub var queue: [RING]uinput.Event = undefined;
    pub var qhead: usize = 0; // next to write
    pub var qlen: usize = 0;
    pub var waiting = false; // pace timer armed

    fn enqueue(event: uinput.Event) void {
        if (qlen == RING) return; // hopelessly behind; the device can't take it anyway
        queue[(qhead + qlen) % RING] = event;
        qlen += 1;
    }

    pub fn axis(which: uinput.Axis, value: i32) void {
        enqueue(.axis(which, value));
    }

    pub fn button(which: uinput.Button, pressed: bool) void {
        enqueue(.button(which, pressed));
    }

    pub fn sync() void {
        enqueue(.sync());
    }

    fn tool(self: *const Pen) uinput.Button {
        return if (self.eraser) .eraser else .pen;
    }

    pub fn leave(self: *Pen) void {
        if (!self.in_range) return;
        if (self.touch) button(.touch, false);
        if (self.barrel) button(.stylus, false);
        axis(.pressure, 0);
        button(self.tool(), false);
        sync();
        self.* = .{ .device = self.device };
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
        if (!self.device.isEnabled()) {
            qhead = (qhead + qlen) % RING;
            qlen = 0;
            return;
        }
        // Up to CHUNK contiguous events, cut after the last SYN_REPORT.
        var take = @min(qlen, CHUNK, RING - qhead);
        var i = take;
        while (i > 0 and !queue[qhead + i - 1].isFrameEnd()) i -= 1;
        if (i > 0) take = i;
        _ = self.device.writeEvents(queue[qhead .. qhead + take]);
        qhead = (qhead + take) % RING;
        qlen -= take;
        // Hold the cooldown even if this write emptied the queue. Otherwise
        // separate small WebSocket reads can each flush immediately and exceed
        // CHUNK events per millisecond, overflowing X's evdev buffer.
        waiting = true;
        pace_timer.arm(PACE_US * std.time.ns_per_us, 0);
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
        const floor: u32 = uinput.PRESSURE_MAX * 6 / 100;
        return @intCast(floor + @as(u32, p) * (uinput.PRESSURE_MAX - floor) / 65535);
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

        const ax = mapAxis(x, cfg.display.region[0], cfg.display.region[2], cfg.display.desktop[0]);
        const ay = mapAxis(y, cfg.display.region[1], cfg.display.region[3], cfg.display.desktop[1]);
        const tx = std.math.clamp(@as(i32, @as(i8, @bitCast(s[6]))), -uinput.TILT_MAX, uinput.TILT_MAX);
        const ty = std.math.clamp(@as(i32, @as(i8, @bitCast(s[7]))), -uinput.TILT_MAX, uinput.TILT_MAX);

        if (!self.in_range) {
            // Always enter proximity with zero pressure: libinput takes the
            // pressure seen at proximity-in as the pen's resting offset, and a
            // non-zero one would thin out or swallow every following stroke.
            self.in_range = true;
            self.eraser = eraser;
            axis(.x, ax);
            axis(.y, ay);
            axis(.pressure, 0);
            axis(.tilt_x, tx);
            axis(.tilt_y, ty);
            button(self.tool(), true);
            sync();
        }
        // libinput smooths tablets by averaging the last 4 frames, which
        // garbles fast strokes. Emitting each sample as `unsmooth` frames
        // makes that average the sample itself. Consecutive frames differ
        // by one device unit (0.03 px) because the kernel drops unchanged
        // values. Pressure and buttons change only in the final frame, so
        // the tip lands and lifts exactly on the sample.
        const reps = @max(cfg.input.unsmooth, 1);
        for (0..reps) |r| {
            const wobble: i32 = @intCast(r & 1);
            axis(.x, ax ^ wobble);
            axis(.y, ay ^ wobble);
            axis(.tilt_x, tx);
            axis(.tilt_y, ty);
            if (r + 1 == reps) {
                axis(.pressure, if (touch) contactPressure(p) else 0);
                if (barrel != self.barrel) button(.stylus, barrel);
                if (touch != self.touch) button(.touch, touch);
            }
            sync();
        }
        self.touch = touch;
        self.barrel = barrel;
    }
};

pub var pen: Pen = undefined;
pub var pace_timer: platform.Timer = .{};
var io: std.Io = undefined;

// ---------------------------------------------------------------- playout

// Wi-Fi delivers pen data in bursts: 100+ ms of samples can land in one
// read. Written at once, the stroke "snaps" forward. Instead every sample is
// due when it would have arrived on a clean network (send time + best-case
// delay + jitter_ms), and a late burst is replayed with its original spacing
// sped up by cfg.input.catchup, so the pen catches up smoothly in a few frames.

pub const PLAY_RING = 4096;
pub const Play = struct { raw: [SAMPLE_SIZE]u8, at: u64 };
pub var play_q: [PLAY_RING]Play = undefined;
pub var play_head: usize = 0;
pub var play_len: usize = 0;
pub var play_timer: platform.Timer = .{};
pub var play_prev_due: u64 = 0;
pub var play_prev_at: u64 = 0;
pub var play_lag_max_ns: u64 = 0; // per second: longest a sample waited on top of its arrival

pub fn playEnqueue(raw: *const [SAMPLE_SIZE]u8, due: u64, arrival: u64) void {
    var at = due;
    if (cfg.input.catchup > 0 and play_prev_at != 0 and due >= play_prev_due) {
        const spacing = due - play_prev_due;
        // Pen pauses longer than this aren't stretched; it's a new movement.
        if (spacing < 100 * std.time.ns_per_ms)
            at = @max(at, play_prev_at + @as(u64, @intFromFloat(@as(f64, @floatFromInt(spacing)) / cfg.input.catchup)));
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
    const now = util.nowNs(io);
    while (play_len > 0 and play_q[play_head].at <= now) {
        pen.sample(&play_q[play_head].raw);
        play_head = (play_head + 1) % PLAY_RING;
        play_len -= 1;
    }
    pen.flush();
    if (!cfg.runtime.busy and play_len > 0) {
        const wait = @max(play_q[play_head].at - now, 1000);
        play_timer.arm(wait, 0);
    }
}

pub fn playReset() void {
    play_len = 0;
    play_prev_at = 0;
    play_prev_due = 0;
}

pub var cfg: config.Config = .{};

pub fn init(c: config.Config, context: std.Io) void {
    cfg = c;
    io = context;
    pen = .{ .device = if (cfg.input.uinput) platform.InputDevice.createTablet(io, cfg.display.desktop) else .{} };
    pace_timer = platform.Timer.init() catch |err| util.fatal(err, "input pace timer");
    play_timer = platform.Timer.init() catch |err| util.fatal(err, "input playout timer");
}

pub fn deinit() void {
    pen.device.deinit();
    pace_timer.deinit(io);
    play_timer.deinit(io);
}

test "pen cooldown survives an empty queue between small writes" {
    const testing = std.testing;
    io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const file = try temp.dir.createFile(io, "events", .{});
    var device = platform.InputDevice.fromFile(io, file);
    defer device.deinit();
    pace_timer = try platform.Timer.init();
    defer pace_timer.deinit(io);
    defer {
        Pen.waiting = false;
        Pen.qlen = 0;
        Pen.qhead = 0;
    }
    var output = Pen{ .device = device };
    Pen.waiting = false;
    Pen.qlen = 0;
    Pen.qhead = 0;
    Pen.axis(.x, 1);
    Pen.sync();
    output.flush();
    try testing.expectEqual(@as(usize, 0), Pen.qlen);
    try testing.expect(Pen.waiting);
    // A second independent read in the same cooldown must wait.
    Pen.axis(.x, 2);
    Pen.sync();
    output.flush();
    try testing.expectEqual(@as(usize, 2), Pen.qlen);
    // Simulate the timer callback: drain the second write, keep its cooldown.
    output.drain();
    try testing.expectEqual(@as(usize, 0), Pen.qlen);
    try testing.expect(Pen.waiting);
    output.drain(); // idle timer callback releases the cooldown
    try testing.expect(!Pen.waiting);
}

test "pen releases the old tool in a separate frame before eraser proximity" {
    const testing = std.testing;
    const saved_cfg = cfg;
    defer cfg = saved_cfg;
    defer {
        Pen.qhead = 0;
        Pen.qlen = 0;
    }
    cfg = .{};
    cfg.input.unsmooth = 1;
    Pen.qhead = 0;
    Pen.qlen = 0;
    var output: Pen = .{};
    var sample_bytes = [_]u8{ 0x00, 0x80, 0x00, 0x80, 0xff, 0xff, 0, 0, F_IN_RANGE | F_TOUCH, 0 };
    output.sample(&sample_bytes);
    const start = Pen.qlen;
    sample_bytes[8] |= F_ERASER;
    output.sample(&sample_bytes);
    try testing.expectEqualDeep(uinput.Event.button(.touch, false), Pen.queue[start]);
    try testing.expectEqualDeep(uinput.Event.axis(.pressure, 0), Pen.queue[start + 1]);
    try testing.expectEqualDeep(uinput.Event.button(.pen, false), Pen.queue[start + 2]);
    try testing.expect(Pen.queue[start + 3].isFrameEnd());
    try testing.expectEqualDeep(uinput.Event.axis(.pressure, 0), Pen.queue[start + 6]);
    try testing.expectEqualDeep(uinput.Event.button(.eraser, true), Pen.queue[start + 9]);
    try testing.expect(Pen.queue[start + 10].isFrameEnd());
    try testing.expect(output.in_range and output.eraser and output.touch);
}
