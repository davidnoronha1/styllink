//! Link benchmark, latency statistics, stall diagnostics, and JSON logging.

const std = @import("std");
const linux = std.os.linux;
const util = @import("util.zig");

pub const TICK_MS = 20;
pub const BURST = 50;
pub const PING_EVERY = 250 / TICK_MS;
pub const REPORT_EVERY = 1000 / TICK_MS;
pub const STALL_NS = 50 * std.time.ns_per_ms;

pub var tty = false;
pub var live_shown = false;
pub var log_fd: i32 = -1;

pub fn initTty() void {
    var termios: [64]u8 = undefined;
    tty = linux.errno(linux.ioctl(2, 0x5401, @intFromPtr(&termios))) == .SUCCESS; // TCGETS on stderr
}

pub fn initLog(path: [:0]const u8) void {
    if (path.len > 0) {
        const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o644);
        if (linux.errno(rc) == .SUCCESS) {
            log_fd = @intCast(rc);
        } else {
            std.debug.print("styllink: can't open log {s}: {s}\n", .{ path, @tagName(linux.errno(rc)) });
        }
    }
}

/// Print a log line, first wiping the live status line if it is showing.
pub fn say(comptime fmt: []const u8, args: anytype) void {
    if (live_shown) std.debug.print("\r\x1b[K", .{});
    live_shown = false;
    std.debug.print(fmt, args);
}

pub fn Ring(comptime N: usize) type {
    return struct {
        v: [N]u32 = undefined,
        n: usize = 0,
        i: usize = 0,

        pub fn push(r: *@This(), x: u32) void {
            r.v[r.i] = x;
            r.i = (r.i + 1) % N;
            if (r.n < N) r.n += 1;
        }

        pub fn pct(r: *const @This(), p: usize) u32 {
            if (r.n == 0) return 0;
            var tmp: [N]u32 = undefined;
            @memcpy(tmp[0..r.n], r.v[0..r.n]);
            std.mem.sort(u32, tmp[0..r.n], {}, std.sort.asc(u32));
            return tmp[(r.n - 1) * p / 100];
        }
    };
}

/// The bits of Linux `struct tcp_info` we report (offsets from linux/tcp.h).
/// `ooo` (tcpi_rcv_ooopack) counts tablet->PC packets that arrived out of
/// order because an earlier one was lost: TCP then holds back everything
/// behind the hole until the retransmit, so pen data bunches up.
pub const TcpInfo = struct {
    rto_us: u32 = 0,
    rtt_us: u32 = 0,
    total_retrans: u32 = 0, // PC->tablet retransmits
    segs_in: u32 = 0,
    ooo: u32 = 0,
};

pub fn tcpInfo(fd: i32) ?TcpInfo {
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

/// Append one JSON object (`fields` without braces) with a unix-ms timestamp.
pub fn logJson(comptime fields: []const u8, args: anytype) void {
    if (log_fd < 0) return;
    var b: [1024]u8 = undefined;
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    const unix_ms = @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
    const line = std.fmt.bufPrint(&b, "{{\"ts\":{d}," ++ fields ++ "}}\n", .{unix_ms} ++ args) catch return;
    _ = util.writeAll(log_fd, line);
}

pub const Ip = struct {
    a: [4]u8,
    pub fn format(v: Ip, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}.{d}.{d}.{d}", .{ v.a[0], v.a[1], v.a[2], v.a[3] });
    }
};

pub fn ip(a: [4]u8) Ip {
    return .{ .a = a };
}

pub const Ms = struct {
    us: u32,
    pub fn format(m: Ms, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}.{d}", .{ m.us / 1000, (m.us % 1000) / 100 });
    }
};

pub fn ms(us: u32) Ms {
    return .{ .us = us };
}

pub const Stats = struct {
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
    pub fn arrival(st: *Stats, fd: i32, peer: [4]u8, active: bool, excess_us: u32) void {
        const now = util.nowNs();
        st.up_max = @max(st.up_max, excess_us);
        if (st.last_active and active and st.last_msg_ns != 0) {
            const gap = now - st.last_msg_ns;
            st.gap_max_ns = @max(st.gap_max_ns, gap);
            if (gap > STALL_NS) {
                st.stalls += 1;
                st.stalls_total += 1;
                const t = tcpInfo(fd) orelse TcpInfo{};
                const p = st.tcp_prev orelse t;
                logJson("\"ev\":\"stall\",\"peer\":\"{f}\",\"gap_ms\":{f},\"uplink_excess_ms\":{f},\"ooo_since_stat\":{d},\"retrans_since_stat\":{d},\"tcp_rtt_ms\":{f}", .{
                    ip(peer), ms(@intCast(@min(gap / 1000, std.math.maxInt(u32)))), ms(excess_us),
                    t.ooo -% p.ooo, t.total_retrans -% p.total_retrans, ms(t.rtt_us),
                });
            }
        }
        st.last_msg_ns = now;
        st.last_active = active;
    }

    pub fn pong(st: *Stats, payload: []const u8) void {
        const sent = std.fmt.parseInt(u64, payload[1..], 10) catch return;
        const us: u32 = @intCast(@min((util.nowNs() -| sent) / 1000, std.math.maxInt(u32)));
        if (payload[0] == 'b') st.burst.push(us);
        st.rtt.push(us);
    }

    /// `t` is the page's performance.now() in 0.1 ms units. The two clocks
    /// are unrelated, so only the variation of (arrival - send) means
    /// anything: we report it relative to the best case seen recently.
    pub fn uplink(st: *Stats, t: u32) u32 {
        st.msgs += 1;
        const here: u32 = @truncate(util.nowNs() / 100_000);
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

/// "i<raw><coalesced>": which pointer APIs the page got. Both are limited to
/// secure contexts, and without them fast strokes are sampled at frame rate.
pub fn reportCaps(peer: [4]u8, st: *Stats, payload: []const u8, port: u16) void {
    if (payload.len < 3) return;
    const raw = payload[1] == '1';
    const coalesced = payload[2] == '1';
    const keepawake = payload.len > 3 and payload[3] == '1';
    const trail = payload.len > 4 and payload[4] == '1';
    const native = payload.len > 5 and payload[5] == '1'; // Android app
    const wifi_lock = payload.len > 6 and payload[6] == '1'; // its low-latency Wi-Fi lock
    logJson("\"ev\":\"caps\",\"peer\":\"{f}\",\"raw\":{},\"coalesced\":{},\"keepawake\":{},\"trail\":{},\"native\":{},\"wifi_lock\":{}", .{ ip(peer), raw, coalesced, keepawake, trail, native, wifi_lock });
    if (st.caps_seen) return; // re-sent when a setting changes: log only
    st.caps_seen = true;
    if (native) return say("  pen input: Android app (unbuffered, full sample rate), low-latency Wi-Fi lock {s}\n", .{if (wifi_lock) "held" else "NOT held"});
    if (raw) return say("  pen input: raw events (lowest latency, full sample rate)\n", .{});
    const me = util.lanAddr() orelse [4]u8{ 127, 0, 0, 1 };
    if (coalesced) return say("  pen input: coalesced events (full sample rate, up to 1 frame extra latency)\n", .{});
    say(
        \\  WARNING: {d}.{d}.{d}.{d} opened the page from an insecure origin, so Chrome hides the
        \\  pen-sample APIs and sends ONE sample per display frame: fast handwriting gets choppy.
        \\  Fix (pick one):
        \\    - tablet Chrome: chrome://flags/#unsafely-treat-insecure-origin-as-secure
        \\      add  http://{d}.{d}.{d}.{d}:{d}  , set Enabled, relaunch Chrome
        \\    - USB: adb reverse tcp:{d} tcp:{d}  and open http://localhost:{d}/?t=...
        \\
    , .{ peer[0], peer[1], peer[2], peer[3], me[0], me[1], me[2], me[3], port, port, port, port });
}

pub fn reportBurst(peer: [4]u8, st: *Stats) void {
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
        ip(peer), r.n, ms(r.pct(0)), ms(r.pct(50)), ms(p95), ms(r.pct(100)), ms(@intCast(jit)),
    });
    say("  link benchmark ({d}/{d} pings): rtt min {f}  p50 {f}  p95 {f}  max {f} ms, jitter {f} ms -> {s}\n", .{
        r.n,           BURST,         ms(r.pct(0)),               ms(r.pct(50)), ms(p95), ms(r.pct(100)),
        ms(@intCast(jit)), verdict,
    });
}

pub fn reportLive(st: *const Stats, ticks: u64) void {
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
pub fn logStat(fd: i32, peer: [4]u8, st: *Stats, ticks: u64, play_lag_max_ns: u64) void {
    const t = tcpInfo(fd) orelse TcpInfo{};
    const p = st.tcp_prev orelse t;
    st.tcp_prev = t;
    if (st.msgs > 0 or ticks % (10 * REPORT_EVERY) == 0) {
        logJson("\"ev\":\"stat\",\"peer\":\"{f}\",\"pen_hz\":{d},\"msgs\":{d},\"gap_max_ms\":{f},\"stalls\":{d},\"burst_max\":{d}," ++
            "\"rtt_p50_ms\":{f},\"rtt_p95_ms\":{f},\"uplink_p50_ms\":{f},\"uplink_p95_ms\":{f},\"uplink_max_ms\":{f}," ++
            "\"ooo\":{d},\"retrans\":{d},\"segs_in\":{d},\"tcp_rtt_ms\":{f},\"tcp_rto_ms\":{f},\"smooth_lag_max_ms\":{f},\"age_mean_ms\":{f},\"age_max_ms\":{f}", .{
            ip(peer),             st.samples,                      st.msgs,
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
    st.gap_max_ns = 0;
    st.burst_max = 0;
    st.up_max = 0;
    st.stalls = 0;
}
