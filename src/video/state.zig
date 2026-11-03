//! State owned by the single video worker; initialized before thread handoff.

const std = @import("std");
const platform = @import("../platform.zig");
const config = @import("../config.zig");
const lz4 = @import("../lz4.zig");
const formats = @import("formats.zig");
const tiles = @import("tiles.zig");
const MAX_TX = formats.MAX_TX;
const MAX_TY = formats.MAX_TY;
const Caps = formats.Caps;
const Session = formats.Session;
const Rect = tiles.Rect;

pub var cfg: config.Config = .{};
pub var io: std.Io = undefined;
pub var allocator: std.mem.Allocator = undefined;
pub var environ: std.process.Environ = undefined;
pub var handoff: platform.Channel = .{};
pub var reactor: platform.Reactor = .{};
pub var pace_timer: platform.Timer = .{};
pub var stat_timer: platform.Timer = .{};
pub var poll_timer: platform.Timer = .{};
pub var cursor_timer: platform.Timer = .{};
pub var worker: ?std.Thread = null;
pub var stopping: std.atomic.Value(bool) = .init(false);

// The one video client (a newer one replaces it).
pub var fd: platform.Handle = platform.invalid_handle;
pub var peer: [4]u8 = .{ 0, 0, 0, 0 };
pub var rx: [8192]u8 = undefined;
pub var rx_len: usize = 0;
pub var caps: Caps = .{};
pub var ses: Session = .{};
pub var streaming = false;
pub var out_armed = false;

pub var wire: []u8 = &.{};
pub var wire_off: usize = 0;
pub var wire_len: usize = 0;

// Region actually captured (the mapped region clipped to the X screen).
pub var rx0: i32 = 0;
pub var ry0: i32 = 0;
pub var rw: u32 = 0;
pub var rh: u32 = 0;

pub var capture: platform.Capture = .{};
pub var cap: []u8 = &.{};
pub var prev: []u8 = &.{}; // what the tablet shows, in stream pixels
pub var scratch: []u8 = &.{};
pub var zbuf: []u8 = &.{};
pub var comp: lz4.Compressor = .{};
pub var dirty: [MAX_TY][MAX_TX]bool = @splat(@splat(false));
pub var snap: [MAX_TY][MAX_TX]bool = @splat(@splat(false));
pub var changed: [MAX_TY][MAX_TX]bool = @splat(@splat(false));
pub var any_dirty = false;
pub var force_key = false;

pub var frame_id: u32 = 0;
pub var inflight: u32 = 0;
pub var last_frame_ns: u64 = 0;
pub var pace_armed = false;
pub var sent_ns: [64]u64 = @splat(0);

// Per-second counters for the log, and per-session totals.
pub const Counters = struct {
    frames: u64 = 0,
    rects: u64 = 0,
    bytes: u64 = 0,
    raw_bytes: u64 = 0,
    lat_sum_us: u64 = 0,
    lat_n: u64 = 0,
    lat_max_us: u64 = 0,
    work_max_us: u64 = 0,
    work_sum_us: u64 = 0,
    tile_frames: u64 = 0,
    capture_sum_us: u64 = 0,
    diff_sum_us: u64 = 0,
    encode_sum_us: u64 = 0,
};
pub var sec: Counters = .{};
pub var total: Counters = .{};
pub var session_start_ns: u64 = 0;

// H.264 encoder or source process.
pub var child: ?std.process.Child = null;
pub var enc_in: platform.Handle = platform.invalid_handle;
pub var enc_out: platform.Handle = platform.invalid_handle;
pub var enc_in_off: usize = 0;
pub var enc_in_len: usize = 0;
// Frames inside the encoder, oldest first. Encoders hold frames back (ffmpeg
// keeps one in its pipeline whatever the flags), so after a real frame the
// same picture is fed again until the real one comes out; those duplicates
// encode to tiny skip frames that change nothing on screen.
pub const Fed = struct { ns: u64, dup: bool };
pub var enc_q: [16]Fed = undefined;
pub var enc_q_head: usize = 0;
pub var enc_q_len: usize = 0;
pub var enc_real: usize = 0; // real frames still inside
pub var au: []u8 = &.{};
pub var au_len: usize = 0;
pub var enc_fresh = false; // nothing fed since it started: already begins with a key frame

pub const Band = struct { tx0: u32, tx1: u32, ty0: u32, ty1: u32, off: usize = 0, stride: usize = 0 };
pub var bands: [MAX_TY]Band = undefined;
pub var rects: [MAX_TX * MAX_TY]Rect = undefined;
