//! Configuration options and command-line argument parsing.

const std = @import("std");
const util = @import("util.zig");

pub const DEFAULT_WEB_URL = "https://styllink.vercel.app";

pub const Config = struct {
    network: Network = .{},
    display: Display = .{},
    input: Input = .{},
    runtime: Runtime = .{},
    logging: Logging = .{},
    video: Video = .{},

    pub const Network = struct {
        port: u16 = 8080,
        token: []const u8 = "",
        token_set: bool = false,
        usb_qr: bool = false,
        // Hosted copy of web/index.html; "" = only use the page served by us.
        web_url: []const u8 = DEFAULT_WEB_URL,
    };

    pub const Display = struct {
        // Target rectangle and full desktop size. libinput maps the tablet's
        // full range onto the desktop; scaling reaches a region within it.
        region: [4]u32 = .{ 0, 0, 1920, 1080 },
        desktop: [2]u32 = .{ 1920, 1080 },
    };

    pub const Input = struct {
        uinput: bool = true,
        // Frames per pen sample; cancels libinput's 4-frame tablet smoothing.
        // 1 = off (e.g. once AttrTabletSmoothing=0 is active in X).
        unsmooth: usize = 4,
        // Replay late bursts at `catchup` x real speed (0 = write immediately).
        // A fixed playout delay absorbs up to `jitter_ms` of network jitter.
        catchup: f64 = 2.0,
        jitter_ms: u32 = 0,
    };

    pub const Runtime = struct {
        busy: bool = false,
        realtime: bool = false,
    };

    pub const Logging = struct {
        // JSON-lines log of connections, per-second link stats and stalls.
        // An empty path disables logging.
        path: [:0]const u8 = "",
    };

    pub const Video = struct {
        preset: VideoPreset = .auto,
        enabled: bool = true,
        // "auto" is settled per tablet from its capabilities and connection.
        codec: VideoCodec = .auto,
        pix: VideoPix = .auto,
        enc: VideoEnc = .auto,
        scale: u32 = 0, // 0 = auto, 1 = native, 2 = half size
        fps: u32 = 0, // 0 = the tablet's refresh rate
        inflight: u32 = 2, // unacknowledged frames before capture waits
        // Rescan this often (ms) for changes DAMAGE misses; unchanged tiles
        // cost no bytes. Zero disables the periodic rescan.
        poll_ms: u32 = 250,
        // H.264 command: raw BGRX stdin ({w} {h} {fps}), Annex-B stdout.
        // "" = the built-in ffmpeg/x264 command.
        encoder: []const u8 = "",
        // Independent H.264 capture command ({x} {y} {w} {h} {fps}), e.g.
        // PipeWire on Wayland or a hardware capture/encode pipeline.
        source: []const u8 = "",
    };
};

pub const VideoPreset = enum { auto, quality, fast, h264 };

pub const VideoCodec = enum { auto, tiles, h264 };
pub const VideoPix = enum { auto, bgrx, rgb565 };
pub const VideoEnc = enum { auto, lz4, raw };

pub fn usage() noreturn {
    printUsage();
    std.process.exit(2);
}

fn printUsage() void {
    std.debug.print(
        \\usage: styllink [options]
        \\  --port N       listen port (default 8080)
        \\  --token STR    access token (default: random); "" disables the check
        \\  --preset NAME  auto (default) | quality | fast | h264
        \\  --no-video     pen only, without screen sharing
        \\  --no-uinput    view the screen without desktop pen input
        \\  --help         show this help
        \\
        \\Presets negotiate with the tablet capabilities; auto honors tablet preferences.
        \\Use MONITOR=name make run to select a monitor.
        \\Use make run DEBUG=1 to enable JSON logging (default off).
        \\
    , .{});
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

pub fn parseArgs(init: std.process.Init.Minimal, io: std.Io, token_buf: *[12]u8) Config {
    var cfg: Config = .{};
    var args = init.args.iterate();
    _ = args.skip();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--help")) {
            printUsage();
            std.process.exit(0);
        }
        if (std.mem.eql(u8, a, "--no-uinput")) {
            cfg.input.uinput = false;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-video")) {
            cfg.video.enabled = false;
            continue;
        }
        // Launcher plumbing: geometry, USB pairing and DEBUG=1 logging.
        if (std.mem.eql(u8, a, "--usb-qr")) {
            cfg.network.usb_qr = true;
            continue;
        }
        const v = args.next() orelse usage();
        if (std.mem.eql(u8, a, "--port")) {
            cfg.network.port = std.fmt.parseInt(u16, v, 10) catch usage();
        } else if (std.mem.eql(u8, a, "--token")) {
            cfg.network.token = v;
            cfg.network.token_set = true;
        } else if (std.mem.eql(u8, a, "--region")) {
            cfg.display.region = parseList(4, v);
        } else if (std.mem.eql(u8, a, "--desktop")) {
            cfg.display.desktop = parseList(2, v);
        } else if (std.mem.eql(u8, a, "--preset")) {
            cfg.video.preset = std.meta.stringToEnum(VideoPreset, v) orelse usage();
        } else if (std.mem.eql(u8, a, "--log")) {
            cfg.logging.path = v;
        } else usage();
    }
    if (cfg.display.region[2] == 0 or cfg.display.region[3] == 0 or cfg.display.desktop[0] == 0 or cfg.display.desktop[1] == 0) usage();

    if (!cfg.network.token_set) {
        var rnd: [6]u8 = undefined;
        util.randomBytes(io, &rnd);
        const hex = std.fmt.bytesToHex(rnd, .lower);
        token_buf.* = hex;
        cfg.network.token = token_buf;
    }

    return cfg;
}

test "parseList parses valid comma-separated integers" {
    const testing = std.testing;
    const r = parseList(4, "10,20,30,40");
    try testing.expectEqual([4]u32{ 10, 20, 30, 40 }, r);
}
