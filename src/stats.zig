//! Link benchmark, latency statistics, stall diagnostics, and JSON logging.

const std = @import("std");
const platform = @import("platform.zig");
const util = @import("util.zig");

pub const TICK_MS = 20;
pub const BURST = 50;
pub const PING_EVERY = 250 / TICK_MS;
pub const REPORT_EVERY = 1000 / TICK_MS;
pub const STALL_NS = 50 * std.time.ns_per_ms;

pub var tty = false;
pub var live_shown = false;
var io: std.Io = undefined;
var log_file: ?std.Io.File = null;
var log_offset: u64 = 0;
var log_mutex: std.Io.Mutex = .init;

pub fn initTty() void {
    tty = std.Io.File.stderr().isTty(io) catch false;
}

pub fn initLog(context: std.Io, path: [:0]const u8) void {
    initLogAt(context, .cwd(), path);
}

fn initLogAt(context: std.Io, dir: std.Io.Dir, path: []const u8) void {
    deinit();
    io = context;
    if (path.len == 0) return;
    const file = dir.createFile(io, path, .{ .truncate = false }) catch |err| {
        std.debug.print("styllink: can't open log {s}: {t}\n", .{ path, err });
        return;
    };
    const stat = file.stat(io) catch {
        file.close(io);
        return;
    };
    log_offset = stat.size;
    log_file = file;
}

pub fn loggingEnabled() bool {
    return log_file != null;
}

pub fn deinit() void {
    if (log_file) |file| file.close(io);
    log_file = null;
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

/// Optional OS TCP diagnostics, represented by portable counters.
pub const TcpInfo = platform.types.TcpInfo;
pub const tcpInfo = platform.Network.tcpInfo;

/// Append one JSON object (`fields` without braces) with a unix-ms timestamp.
pub fn logJson(comptime fields: []const u8, args: anytype) void {
    const file = log_file orelse return;
    var buffer: [1024]u8 = undefined;
    const unix_ms = std.Io.Clock.real.now(io).toMilliseconds();
    const line = std.fmt.bufPrint(&buffer, "{{\"ts\":{d}," ++ fields ++ "}}\n", .{unix_ms} ++ args) catch return;
    log_mutex.lockUncancelable(io);
    defer log_mutex.unlock(io);
    file.writePositionalAll(io, line, log_offset) catch return;
    log_offset += line.len;
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
    pub fn arrival(st: *Stats, fd: platform.Handle, peer: [4]u8, active: bool, excess_us: u32) void {
        const now = util.nowNs(io);
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
                    ip(peer),       ms(@intCast(@min(gap / 1000, std.math.maxInt(u32)))), ms(excess_us),
                    t.ooo -% p.ooo, t.total_retrans -% p.total_retrans,                   ms(t.rtt_us),
                });
            }
        }
        st.last_msg_ns = now;
        st.last_active = active;
    }

    pub fn pong(st: *Stats, payload: []const u8) void {
        const sent = std.fmt.parseInt(u64, payload[1..], 10) catch return;
        const us: u32 = @intCast(@min((util.nowNs(io) -| sent) / 1000, std.math.maxInt(u32)));
        if (payload[0] == 'b') st.burst.push(us);
        st.rtt.push(us);
    }

    /// `t` is the page's performance.now() in 0.1 ms units. The two clocks
    /// are unrelated, so only the variation of (arrival - send) means
    /// anything: we report it relative to the best case seen recently.
    pub fn uplink(st: *Stats, t: u32) u32 {
        st.msgs += 1;
        const here: u32 = @truncate(util.nowNs(io) / 100_000);
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
    const me = platform.Network.lanAddr(io) orelse [4]u8{ 127, 0, 0, 1 };
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
        r.n,               BURST,   ms(r.pct(0)), ms(r.pct(50)), ms(p95), ms(r.pct(100)),
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
pub fn logStat(fd: platform.Handle, peer: [4]u8, st: *Stats, ticks: u64, play_lag_max_ns: u64) void {
    const t = tcpInfo(fd) orelse TcpInfo{};
    const p = st.tcp_prev orelse t;
    st.tcp_prev = t;
    if (st.msgs > 0 or ticks % (10 * REPORT_EVERY) == 0) {
        logJson("\"ev\":\"stat\",\"peer\":\"{f}\",\"pen_hz\":{d},\"msgs\":{d},\"gap_max_ms\":{f},\"stalls\":{d},\"burst_max\":{d}," ++
            "\"rtt_p50_ms\":{f},\"rtt_p95_ms\":{f},\"uplink_p50_ms\":{f},\"uplink_p95_ms\":{f},\"uplink_max_ms\":{f}," ++
            "\"ooo\":{d},\"retrans\":{d},\"segs_in\":{d},\"tcp_rtt_ms\":{f},\"tcp_rto_ms\":{f},\"smooth_lag_max_ms\":{f},\"age_mean_ms\":{f},\"age_max_ms\":{f}", .{
            ip(peer),                                                       st.samples,                                                       st.msgs,
            ms(@intCast(@min(st.gap_max_ns / 1000, std.math.maxInt(u32)))), st.stalls,                                                        st.burst_max,
            ms(st.rtt.pct(50)),                                             ms(st.rtt.pct(95)),                                               ms(st.up.pct(50)),
            ms(st.up.pct(95)),                                              ms(st.up_max),                                                    t.ooo -% p.ooo,
            t.total_retrans -% p.total_retrans,                             t.segs_in -% p.segs_in,                                           ms(t.rtt_us),
            ms(t.rto_us),                                                   ms(@intCast(@min(play_lag_max_ns / 1000, std.math.maxInt(u32)))), ms(if (st.age_n > 0) @intCast(st.age_sum_us / st.age_n) else 0),
            ms(st.age_max_us),
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

test "JSON logging appends complete lines from both application threads" {
    const context = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    initLogAt(context, temp.dir, "events.jsonl");
    defer deinit();
    try std.testing.expect(loggingEnabled());
    const Worker = struct {
        fn run(id: u8) void {
            for (0..32) |n| logJson("\"ev\":\"test\",\"worker\":{d},\"n\":{d}", .{ id, n });
        }
    };
    const a = try std.Thread.spawn(.{}, Worker.run, .{0});
    const b = try std.Thread.spawn(.{}, Worker.run, .{1});
    a.join();
    b.join();
    deinit();
    // Reopening must append, preserving the previous session's diagnostics.
    initLogAt(context, temp.dir, "events.jsonl");
    logJson("\"ev\":\"reopened\"", .{});
    deinit();
    const file = try temp.dir.openFile(context, "events.jsonl", .{});
    defer file.close(context);
    var buffer: [16384]u8 = undefined;
    const count = try file.readPositionalAll(context, &buffer, 0);
    var lines = std.mem.tokenizeScalar(u8, buffer[0..count], '\n');
    var line_count: usize = 0;
    while (lines.next()) |line| {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("ts") != null);
        line_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 65), line_count);
    initLogAt(context, temp.dir, "");
    try std.testing.expect(!loggingEnabled());
}
