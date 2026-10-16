//! Single-threaded epoll loop, raw Linux syscalls, no allocations
//! on the hot path.

const std = @import("std");
const linux = std.os.linux;

const qr = @import("qr.zig");
const config = @import("config.zig");
const util = @import("util.zig");
const input = @import("input.zig");
const stats = @import("stats.zig");
const ws = @import("ws.zig");

const check = util.check;

var cfg: config.Config = .{};
var tfd: i32 = -1;

fn startTimer() void {
    tfd = @intCast(check(linux.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true }), "timerfd_create"));
    const period = linux.timespec{ .sec = 0, .nsec = stats.TICK_MS * std.time.ns_per_ms };
    const spec = linux.itimerspec{ .it_interval = period, .it_value = period };
    _ = check(linux.timerfd_settime(tfd, .{}, &spec, null), "timerfd_settime");
}

fn printAppQr(label: []const u8, uri: []const u8) void {
    std.debug.print("\n  {s}\n  {s}\n", .{ label, uri });
    if (qr.encode(uri)) |code| {
        var out: [32 * 1024]u8 = undefined;
        std.debug.print("{s}", .{qr.render(&code, &out)});
    }
}

fn printBanner() void {
    const me = util.lanAddr() orelse [4]u8{ 127, 0, 0, 1 };
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

// ---------------------------------------------------------------- epoll backend

fn runEpoll(lfd: i32) noreturn {
    ws.epfd = @intCast(check(linux.epoll_create1(linux.EPOLL.CLOEXEC), "epoll_create1"));
    var lev = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .u64 = ws.LISTEN_TAG } };
    _ = check(linux.epoll_ctl(ws.epfd, linux.EPOLL.CTL_ADD, lfd, &lev), "epoll_ctl");
    var tev = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .u64 = ws.TIMER_TAG } };
    _ = check(linux.epoll_ctl(ws.epfd, linux.EPOLL.CTL_ADD, tfd, &tev), "epoll_ctl");
    var pev = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .u64 = ws.PACE_TAG } };
    _ = check(linux.epoll_ctl(ws.epfd, linux.EPOLL.CTL_ADD, input.pace_fd, &pev), "epoll_ctl");
    var yev = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .u64 = ws.PLAY_TAG } };
    _ = check(linux.epoll_ctl(ws.epfd, linux.EPOLL.CTL_ADD, input.play_fd, &yev), "epoll_ctl");

    const timeout: i32 = if (cfg.busy) 0 else -1;
    var events: [ws.MAX_CLIENTS + 4]linux.epoll_event = undefined;
    while (true) {
        if (cfg.busy and input.play_len > 0) {
            if (input.play_q[input.play_head].at <= util.nowNs()) {
                input.playDrain();
            }
        }
        const rc = linux.epoll_wait(ws.epfd, &events, events.len, timeout);
        if (linux.errno(rc) == .INTR) continue;
        for (events[0..check(rc, "epoll_wait")]) |e| {
            if (e.data.u64 == ws.PLAY_TAG) {
                var expirations: u64 = 0;
                _ = linux.read(input.play_fd, std.mem.asBytes(&expirations), 8);
                input.playDrain();
                continue;
            }
            if (e.data.u64 == ws.PACE_TAG) {
                var expirations: u64 = 0;
                _ = linux.read(input.pace_fd, std.mem.asBytes(&expirations), 8);
                input.pen.drain();
                continue;
            }
            if (e.data.u64 == ws.TIMER_TAG) {
                var expirations: u64 = 0;
                _ = linux.read(tfd, std.mem.asBytes(&expirations), 8);
                ws.onTick();
                continue;
            }
            if (e.data.u64 == ws.LISTEN_TAG) {
                const arc = linux.accept4(lfd, null, null, linux.SOCK.CLOEXEC);
                if (linux.errno(arc) != .SUCCESS) continue;
                const fd: i32 = @intCast(arc);
                ws.tuneSocket(fd);
                const i = ws.claimSlot(fd) orelse continue;
                var ev = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.RDHUP, .data = .{ .u64 = i } };
                _ = check(linux.epoll_ctl(ws.epfd, linux.EPOLL.CTL_ADD, fd, &ev), "epoll_ctl");
                continue;
            }
            const c = &ws.clients[@intCast(e.data.u64)];
            if (c.fd == -1) continue;
            if (e.events & linux.EPOLL.IN == 0) {
                ws.closeClient(c);
                continue;
            }
            if (c.len == c.buf.len) {
                ws.closeClient(c);
                continue;
            }
            const r = linux.read(c.fd, c.buf[c.len..].ptr, c.buf.len - c.len);
            switch (linux.errno(r)) {
                .SUCCESS => if (!ws.onData(c, r)) ws.closeClient(c),
                .INTR, .AGAIN => {},
                else => ws.closeClient(c),
            }
        }
    }
}

// ---------------------------------------------------------------- main

fn setRealtime() void {
    const param = linux.sched_param{ .priority = 50 };
    const sched_rc = linux.sched_setscheduler(0, .{ .mode = .FIFO }, &param);
    if (linux.errno(sched_rc) == .SUCCESS) {
        std.debug.print("styllink: priority set to SCHED_FIFO 50\n", .{});
        return;
    }
    const prio_rc = linux.syscall3(.setpriority, 0, 0, @as(usize, @bitCast(@as(isize, -20))));
    if (linux.errno(prio_rc) == .SUCCESS) {
        std.debug.print("styllink: priority set to nice -20\n", .{});
        return;
    }
    std.debug.print("styllink: notice: unable to set realtime or high priority (run with CAP_SYS_NICE or sudo)\n", .{});
}

pub fn main(init: std.process.Init.Minimal) void {
    var token_buf: [12]u8 = undefined;
    cfg = config.parseArgs(init, &token_buf);

    if (cfg.realtime) {
        setRealtime();
    }

    stats.initLog(cfg.log_path);
    stats.initTty();
    input.init(cfg);
    ws.init(cfg);

    const lfd: i32 = @intCast(check(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0), "socket"));
    const one: i32 = 1;
    _ = linux.setsockopt(lfd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), 4);
    var addr = linux.sockaddr.in{ .port = std.mem.nativeToBig(u16, cfg.port), .addr = 0 };
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
    stats.logJson("\"ev\":\"start\",\"port\":{d},\"busy\":{},\"unsmooth\":{d},\"catchup\":{d},\"jitter_ms\":{d},\"region\":[{d},{d},{d},{d}],\"desktop\":[{d},{d}]", .{
        cfg.port, cfg.busy, cfg.unsmooth, cfg.catchup, cfg.jitter_ms, cfg.region[0], cfg.region[1], cfg.region[2], cfg.region[3], cfg.desktop[0], cfg.desktop[1],
    });
    if (stats.log_fd >= 0) std.debug.print("styllink: logging to {s}\n", .{cfg.log_path});
    std.debug.print("styllink: :{d}{s}, mapping to {d}x{d}+{d}+{d} of {d}x{d}{s}\n", .{
        cfg.port,      if (cfg.busy) " (busy-poll)" else "",
        cfg.region[2], cfg.region[3],    cfg.region[0],
        cfg.region[1], cfg.desktop[0],   cfg.desktop[1],
        if (cfg.uinput) "" else " [no uinput]",
    });

    runEpoll(lfd);
}

test {
    _ = @import("config.zig");
    _ = @import("input.zig");
    _ = @import("ws.zig");
}
