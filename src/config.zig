//! Configuration options and command-line argument parsing.

const std = @import("std");
const linux = std.os.linux;
const util = @import("util.zig");

pub const DEFAULT_WEB_URL = "https://styllink.vercel.app";

pub const Config = struct {
    port: u16 = 8080,
    token: []const u8 = "",
    token_set: bool = false,
    // Target rectangle on the desktop, and the full desktop size. libinput maps
    // the tablet's full range onto the whole desktop, so a region is reached
    // by scaling into a sub-range.
    region: [4]u32 = .{ 0, 0, 1920, 1080 },
    desktop: [2]u32 = .{ 1920, 1080 },
    busy: bool = false,
    uinput: bool = true,
    usb_qr: bool = false,
    // Frames per pen sample; cancels libinput's 4-frame tablet smoothing.
    // 1 = off (e.g. once AttrTabletSmoothing=0 is active in X).
    unsmooth: usize = 4,
    // Hosted copy of web/index.html; "" = only use the page served by us.
    web_url: []const u8 = DEFAULT_WEB_URL,
    // JSON-lines log of connections, per-second link stats and stalls.
    log_path: [:0]const u8 = "",
    // Burst smoothing: samples that arrive late in a bunch are replayed with
    // their original spacing at `catchup` x real speed (0 = no smoothing,
    // just write them at once). `jitter_ms` adds a fixed playout delay that
    // absorbs that much network jitter completely.
    catchup: f64 = 2.0,
    jitter_ms: u32 = 0,
    realtime: bool = false,
    // Remote screen (PC -> tablet). Each "auto" is settled per tablet from
    // what it reports it can decode and how it is connected.
    video: bool = true,
    video_codec: VideoCodec = .auto,
    video_pix: VideoPix = .auto,
    video_enc: VideoEnc = .auto,
    video_scale: u32 = 0, // 0 = auto, 1 = native, 2 = half size
    video_fps: u32 = 0, // 0 = the tablet's refresh rate
    video_inflight: u32 = 2, // unacknowledged frames before capture waits
    // Rescan the whole region this often (ms) in case DAMAGE misses a change
    // (some compositors, fullscreen GL); unchanged tiles still cost no bytes.
    video_poll_ms: u32 = 250,
    // H.264: a command that reads raw BGRX frames on stdin ({w} {h} {fps})
    // and writes Annex-B H.264 to stdout. "" = the built-in ffmpeg/x264 line.
    video_encoder: []const u8 = "",
    // H.264 from a command that captures the screen itself ({x} {y} {w} {h}
    // {fps}), e.g. on Wayland or with a hardware capture/encode pipeline.
    video_source: []const u8 = "",
};

pub const VideoCodec = enum { auto, tiles, h264 };
pub const VideoPix = enum { auto, bgrx, rgb565 };
pub const VideoEnc = enum { auto, lz4, raw };

pub fn usage() noreturn {
    std.debug.print(
        \\usage: styllink [options]
        \\  --port N            listen port (default 8080)
        \\  --token STR         access token (default: random); "" disables the check
        \\  --region X,Y,W,H    desktop rectangle to map the pad onto
        \\  --desktop W,H       full desktop size (for --region)
        \\  --busy              spin instead of sleeping: lowest wake-up latency, burns a core
        \\  --realtime          set SCHED_FIFO or -20 nice priority for minimum latency
        \\  --unsmooth N        frames per sample to cancel libinput smoothing (default 4, 1 = off)
        \\  --web-url URL       printed browser URL ("" = use the page served by this PC)
        \\  --catchup X         replay late bursts at X times real speed (default 2; 0 = snap)
        \\  --jitter-ms N       fixed playout delay that hides N ms of network jitter (default 0)
        \\  --log PATH          JSON-lines log (default off)
        \\  --usb-qr            show USB QR first (requires working adb reverse)
        \\  --no-uinput         don't create the pen device (network benchmarking)
        \\  --no-video          don't offer the remote screen
        \\  --video-codec C     auto | tiles (damage tiles, lowest latency) | h264
        \\  --video-pix P       auto | bgrx (true color) | rgb565 (half the bytes)
        \\  --video-enc E       auto | lz4 | raw (tile compression)
        \\  --video-scale N     0 = auto, 1 = native, 2 = half resolution
        \\  --video-fps N       frame rate cap (default: the tablet's refresh rate)
        \\  --video-inflight N  frames on the wire before capture waits (default 2)
        \\  --video-poll MS     full rescan interval for missed damage (default 250, 0 = off)
        \\  --video-encoder CMD H.264 encoder: raw BGRX on stdin -> Annex-B on stdout
        \\  --video-source CMD  H.264 capture command (Wayland, hardware pipelines)
        \\
    , .{});
    linux.exit(2);
}

pub fn parseList(comptime n: usize, s: []const u8) [n]u32 {
    var out: [n]u32 = undefined;
    var it = std.mem.splitScalar(u8, s, ',');
    for (&out) |*v| {
        const part = it.next() orelse usage();
        v.* = std.fmt.parseInt(u32, part, 10) catch usage();
    }
    if (it.next() != null) usage();
    return out;
}

pub fn parseArgs(init: std.process.Init.Minimal, token_buf: *[12]u8) Config {
    var cfg: Config = .{};
    var args = init.args.iterate();
    _ = args.skip();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--busy")) {
            cfg.busy = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--realtime")) {
            cfg.realtime = true;
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
        if (std.mem.eql(u8, a, "--no-video")) {
            cfg.video = false;
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
        } else if (std.mem.eql(u8, a, "--video-codec")) {
            cfg.video_codec = std.meta.stringToEnum(VideoCodec, v) orelse usage();
        } else if (std.mem.eql(u8, a, "--video-pix")) {
            cfg.video_pix = std.meta.stringToEnum(VideoPix, v) orelse usage();
        } else if (std.mem.eql(u8, a, "--video-enc")) {
            cfg.video_enc = std.meta.stringToEnum(VideoEnc, v) orelse usage();
        } else if (std.mem.eql(u8, a, "--video-scale")) {
            cfg.video_scale = std.fmt.parseInt(u32, v, 10) catch usage();
            if (cfg.video_scale > 2) usage();
        } else if (std.mem.eql(u8, a, "--video-fps")) {
            cfg.video_fps = std.fmt.parseInt(u32, v, 10) catch usage();
        } else if (std.mem.eql(u8, a, "--video-inflight")) {
            cfg.video_inflight = std.fmt.parseInt(u32, v, 10) catch usage();
            if (cfg.video_inflight == 0) usage();
        } else if (std.mem.eql(u8, a, "--video-poll")) {
            cfg.video_poll_ms = std.fmt.parseInt(u32, v, 10) catch usage();
        } else if (std.mem.eql(u8, a, "--video-encoder")) {
            cfg.video_encoder = v;
        } else if (std.mem.eql(u8, a, "--video-source")) {
            cfg.video_source = v;
        } else usage();
    }
    if (cfg.region[2] == 0 or cfg.region[3] == 0 or cfg.desktop[0] == 0 or cfg.desktop[1] == 0) usage();

    if (!cfg.token_set) {
        var rnd: [6]u8 = undefined;
        _ = util.check(linux.getrandom(&rnd, rnd.len, 0), "getrandom");
        const hex = std.fmt.bytesToHex(rnd, .lower);
        token_buf.* = hex;
        cfg.token = token_buf;
    }

    return cfg;
}

test "parseList parses valid comma-separated integers" {
    const testing = std.testing;
    const r = parseList(4, "10,20,30,40");
    try testing.expectEqual([4]u32{ 10, 20, 30, 40 }, r);
}

