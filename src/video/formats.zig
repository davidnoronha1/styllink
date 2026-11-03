//! Portable tablet capabilities, stream formats and preset negotiation.

const std = @import("std");
const config = @import("../config.zig");

pub const TILE = 32;
pub const MAX_TX = 256; // up to 8192 px wide streams
pub const MAX_TY = 256;
pub const RECT_ROWS = 4; // tile rows per rectangle: bounded buffers, earlier decode
pub const RECT_HDR = 24;
pub const H264_HDR = 16;
pub const MAX_WS_HDR = 10;
pub const AU_CAP = 8 << 20;

pub const Pix = enum(u8) { bgrx = 0, rgb565 = 1 };
pub const Enc = enum(u8) { raw = 0, lz4 = 1 };
pub const Codec = enum { tiles, h264 };

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
    prefer_h264: bool = false, // the tablet's user asked for H.264
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
    source: bool = false, // independent H.264 source: no X capture

    pub fn bpp(s: Session) u32 {
        return if (s.pix == .rgb565) 2 else 4;
    }
};

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
        if (std.mem.eql(u8, k, "prefer")) c.prefer_h264 = std.mem.eql(u8, v, "h264");
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

pub fn negotiate(c: config.Config, k: Caps, w: u32, h: u32) ?Session {
    // Presets describe a preference; capability checks below still decide
    // the actual codec, pixel format, compression and refresh rate.
    var v = c.video;
    switch (v.preset) {
        .auto => {},
        .quality => {
            v.codec = .tiles;
            v.pix = .bgrx;
            v.scale = 1;
        },
        .fast => {
            v.codec = .tiles;
            v.pix = .rgb565;
            v.scale = 2;
            v.inflight = 1;
        },
        .h264 => v.codec = .h264,
    }
    var s: Session = .{ .inflight = v.inflight };
    if (v.source.len > 0) {
        if (!k.h264) return null;
        s.codec = .h264;
        s.source = true;
    } else if (v.codec == .h264 or (v.codec == .auto and k.prefer_h264)) {
        s.codec = if (k.h264) .h264 else if (k.tiles) .tiles else return null;
    } else {
        s.codec = if (k.tiles) .tiles else if (k.h264) .h264 else return null;
    }
    s.fps = if (v.fps > 0) @min(v.fps, k.hz) else k.hz;

    // Half resolution only pays off when the tablet couldn't show the extra
    // pixels anyway (or nearly so, on Wi-Fi where bandwidth is scarce).
    s.scale = v.scale;
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
        s.pix = switch (v.pix) {
            .bgrx => if (k.bgrx) .bgrx else .rgb565,
            .rgb565 => if (k.rgb565) .rgb565 else .bgrx,
            // True color over USB; half the bytes over Wi-Fi.
            .auto => if (k.usb and k.bgrx) .bgrx else if (k.rgb565) .rgb565 else .bgrx,
        };
        s.enc = switch (v.enc) {
            .raw => if (k.raw) .raw else .lz4,
            .lz4, .auto => if (k.lz4) .lz4 else .raw,
        };
    }
    s.tw = (s.sw + TILE - 1) / TILE;
    s.th = (s.sh + TILE - 1) / TILE;
    if (s.sw == 0 or s.sh == 0 or s.tw > MAX_TX or s.th > MAX_TY) return null;
    return s;
}

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
    h.video.codec = .h264;
    const s3 = negotiate(h, usb, 1921, 1081).?;
    try testing.expectEqual(Codec.h264, s3.codec);
    try testing.expectEqual(@as(u32, 1920), s3.sw);
    try testing.expectEqual(@as(u32, 1080), s3.sh);
    try testing.expect(negotiate(h, parseCaps("codec=h264"), 640, 480) != null);
    try testing.expectEqual(Codec.h264, negotiate(c, parseCaps("codec=tiles,h264;prefer=h264"), 640, 480).?.codec);
    try testing.expectEqual(Codec.tiles, negotiate(c, parseCaps("codec=tiles;prefer=h264"), 640, 480).?.codec);
    var src: config.Config = .{};
    src.video.source = "cat";
    try testing.expect(negotiate(src, wifi, 640, 480) == null);
}

test "presets negotiate supported formats and retain tablet preferences in auto" {
    const testing = std.testing;
    const full = parseCaps("w=1280;h=800;hz=90;pix=bgrx,rgb565;enc=lz4,raw;codec=tiles,h264;link=wifi;prefer=h264");
    var c: config.Config = .{};
    try testing.expectEqual(Codec.h264, negotiate(c, full, 1920, 1080).?.codec);

    c.video.preset = .quality;
    const quality = negotiate(c, full, 1920, 1080).?;
    try testing.expectEqual(Codec.tiles, quality.codec);
    try testing.expectEqual(Pix.bgrx, quality.pix);
    try testing.expectEqual(@as(u32, 1), quality.scale);
    try testing.expectEqual(@as(u32, 90), quality.fps);

    c.video.preset = .fast;
    const fast = negotiate(c, full, 1920, 1080).?;
    try testing.expectEqual(Codec.tiles, fast.codec);
    try testing.expectEqual(Pix.rgb565, fast.pix);
    try testing.expectEqual(@as(u32, 2), fast.scale);
    try testing.expectEqual(@as(u32, 960), fast.sw);
    try testing.expectEqual(@as(u32, 1), fast.inflight);
    try testing.expectEqual(@as(u32, 90), fast.fps);

    // Every preset must work with a tablet that only offers raw BGRX tiles.
    const limited = parseCaps("hz=30;pix=bgrx;enc=raw;codec=tiles");
    inline for (std.meta.tags(config.VideoPreset)) |preset| {
        c.video.preset = preset;
        const fallback = negotiate(c, limited, 640, 480).?;
        try testing.expectEqual(Codec.tiles, fallback.codec);
        try testing.expectEqual(Pix.bgrx, fallback.pix);
        try testing.expectEqual(Enc.raw, fallback.enc);
        try testing.expectEqual(@as(u32, 30), fallback.fps);
        try testing.expectEqual(Codec.h264, negotiate(c, parseCaps("codec=h264"), 640, 480).?.codec);
    }
    c.video.preset = .h264;
    try testing.expectEqual(Codec.h264, negotiate(c, full, 1920, 1080).?.codec);
}
