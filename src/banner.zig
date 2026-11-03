//! Connection instructions and QR codes shared by all platform backends.

const std = @import("std");
const config = @import("config.zig");
const qr = @import("qr.zig");

fn printAppQr(label: []const u8, uri: []const u8) void {
    std.debug.print("\n  {s}\n  {s}\n", .{ label, uri });
    if (qr.encode(uri)) |code| {
        var out: [32 * 1024]u8 = undefined;
        std.debug.print("{s}", .{qr.render(&code, &out)});
    }
}

pub fn print(cfg: config.Config, me: [4]u8) void {
    var lb: [128]u8 = undefined;
    const tq = if (cfg.network.token.len > 0) "/?t=" else "/";
    const local = std.fmt.bufPrint(&lb, "http://{d}.{d}.{d}.{d}:{d}{s}{s}", .{ me[0], me[1], me[2], me[3], cfg.network.port, tq, cfg.network.token }) catch return;
    // The hosted (HTTPS) page is a secure context, which unlocks the
    // full-rate pen APIs; it finds us through the URL fragment.
    var wb: [256]u8 = undefined;
    const web: ?[]const u8 = if (cfg.network.web_url.len == 0) null else std.fmt.bufPrint(&wb, "{s}#h={d}.{d}.{d}.{d}:{d}&t={s}", .{
        std.mem.trimEnd(u8, cfg.network.web_url, "/"), me[0], me[1], me[2], me[3], cfg.network.port, cfg.network.token,
    }) catch null;
    // A camera/QR scanner opens the installed native app directly.
    // make run enables the USB QR only after ADB forwarding succeeds.
    var ab: [256]u8 = undefined;
    const app = std.fmt.bufPrint(&ab, "styllink://connect?h={d}.{d}.{d}.{d}:{d}&t={s}", .{
        me[0], me[1], me[2], me[3], cfg.network.port, cfg.network.token,
    }) catch return;
    if (cfg.network.usb_qr) {
        var ub: [256]u8 = undefined;
        const usb = std.fmt.bufPrint(&ub, "styllink://connect?h=localhost:{d}&t={s}", .{ cfg.network.port, cfg.network.token }) catch return;
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
    , .{ cfg.network.port, cfg.network.port, cfg.network.port, tq, cfg.network.token });
}
