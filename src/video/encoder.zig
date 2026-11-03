//! Common video encoder operations.

const std = @import("std");
const platform = @import("../platform.zig");
const util = @import("../util.zig");
const formats = @import("formats.zig");
const H264_HDR = formats.H264_HDR;

const state = @import("state.zig");
const runtime = @import("runtime.zig");
const session_ops = @import("session.zig");
const transport = @import("transport.zig");

pub const DEFAULT_ENCODER = "ffmpeg -hide_banner -loglevel error -probesize 32 -analyzeduration 0 -fflags +nobuffer " ++
    "-f rawvideo -pix_fmt bgr0 -video_size {w}x{h} -framerate {fps} -i - -an -vsync 0 " ++
    "-c:v libx264 -preset ultrafast -tune zerolatency -bf 0 -g 600 " ++
    "-x264-params aud=1:slices=1:intra-refresh=1:repeat-headers=1 -pix_fmt yuv420p " ++
    "-f h264 -flush_packets 1 -avioflags direct -";

pub fn spawnEncoder() bool {
    var cmd_buf: [4096]u8 = undefined;
    const template = if (state.ses.source) state.cfg.video.source else if (state.cfg.video.encoder.len > 0) state.cfg.video.encoder else DEFAULT_ENCODER;
    const cmd = expand(template, &cmd_buf) orelse return false;
    state.child = std.process.spawn(state.io, .{
        .argv = &.{ platform.shell_exe, platform.shell_arg, cmd },
        .stdin = if (state.ses.source) .ignore else .pipe,
        .stdout = .pipe,
    }) catch return false;
    const child = &state.child.?;
    state.enc_out = platform.IO.fileHandle(child.stdout.?.handle);
    platform.IO.tunePipe(state.enc_out);
    runtime.watch(state.enc_out, .{ .readable = true }, .encoder_out);
    if (child.stdin) |file| {
        state.enc_in = platform.IO.fileHandle(file.handle);
        platform.IO.tunePipe(state.enc_in);
        runtime.watch(state.enc_in, .{}, .encoder_in);
    }
    state.enc_fresh = true;
    state.enc_in_off = 0;
    state.enc_in_len = 0;
    state.enc_q_len = 0;
    state.enc_q_head = 0;
    state.enc_real = 0;
    state.au_len = 0;
    return true;
}

pub fn expand(template: []const u8, buf: *[4096]u8) ?[:0]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '{') if (std.mem.indexOfScalarPos(u8, template, i, '}')) |end| {
            const key = template[i + 1 .. end];
            const val: ?u32 = if (std.mem.eql(u8, key, "w")) state.ses.sw else if (std.mem.eql(u8, key, "h")) state.ses.sh else if (std.mem.eql(u8, key, "fps")) state.ses.fps else if (std.mem.eql(u8, key, "x")) @intCast(state.rx0) else if (std.mem.eql(u8, key, "y")) @intCast(state.ry0) else null;
            if (val) |v| {
                const s = std.fmt.bufPrint(buf[n..], "{d}", .{v}) catch return null;
                n += s.len;
                i = end + 1;
                continue;
            }
        };
        if (n + 1 >= buf.len) return null;
        buf[n] = template[i];
        n += 1;
        i += 1;
    }
    buf[n] = 0;
    return buf[0..n :0];
}

pub fn stopEncoder() void {
    if (state.child) |*child| {
        if (state.enc_in != platform.invalid_handle) state.reactor.remove(state.enc_in);
        if (state.enc_out != platform.invalid_handle) state.reactor.remove(state.enc_out);
        child.kill(state.io);
        state.child = null;
    }
    state.enc_in = platform.invalid_handle;
    state.enc_out = platform.invalid_handle;
}

pub fn feedEncoder(now: u64) void {
    state.enc_fresh = false;
    state.enc_real += 1;
    pushFrame(.{ .ns = now, .dup = false });
}

pub fn pushFrame(f: state.Fed) void {
    if (state.enc_q_len == state.enc_q.len) return;
    state.enc_q[(state.enc_q_head + state.enc_q_len) % state.enc_q.len] = f;
    state.enc_q_len += 1;
    state.enc_in_off = 0;
    state.enc_in_len = @as(usize, state.ses.sw) * state.ses.sh * 4;
    writeEncoder();
}

pub fn nudgeEncoder() void {
    if (state.enc_real > 0 and state.enc_in_off == state.enc_in_len and state.enc_q_len < 8)
        pushFrame(.{ .ns = util.nowNs(state.io), .dup = true });
}

pub fn writeEncoder() void {
    if (state.enc_in == platform.invalid_handle) return; // stopped earlier in this batch of events
    while (state.enc_in_off < state.enc_in_len) {
        const count = platform.IO.write(state.io, state.enc_in, state.prev[state.enc_in_off..state.enc_in_len]) catch |err| switch (err) {
            error.WouldBlock => return runtime.rewatch(state.enc_in, .{ .writable = true }, .encoder_in),
            else => return session_ops.endSession("the H.264 encoder stopped reading"),
        };
        if (count == 0) return session_ops.endSession("the H.264 encoder stopped reading");
        state.enc_in_off += count;
    }
    runtime.rewatch(state.enc_in, .{}, .encoder_in);
    // One duplicate right behind a real frame; more only if the encoder
    // turns out to hold several (readEncoder nudges again per output).
    if (state.enc_q_len > 0 and !state.enc_q[(state.enc_q_head + state.enc_q_len - 1) % state.enc_q.len].dup) nudgeEncoder();
}

pub fn readEncoder() void {
    if (state.enc_out == platform.invalid_handle) return;
    while (state.au_len < state.au.len) {
        const count = platform.IO.read(state.io, state.enc_out, state.au[state.au_len..]) catch |err| switch (err) {
            error.WouldBlock => break,
            else => return session_ops.endSession("the H.264 encoder failed"),
        };
        if (count == 0) return session_ops.endSession("the H.264 encoder exited");
        state.au_len += count;
    }
    // The encoder writes each access unit in one write (avioflags direct,
    // 1 MB pipe), so a drained pipe ends on a frame boundary. AUDs split
    // several frames that arrived together.
    var starts: [64]usize = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i + 4 <= state.au_len and n < starts.len) : (i += 1) {
        if (state.au[i] == 0 and state.au[i + 1] == 0 and state.au[i + 2] == 1 and state.au[i + 3] & 0x1f == 9) {
            starts[n] = if (i > 0 and state.au[i - 1] == 0) i - 1 else i;
            n += 1;
            i += 3;
        }
    }
    if (n == 0 or starts[0] != 0) {
        // No delimiters (custom encoder): one frame per drained read.
        if (n == 0) {
            starts[0] = 0;
            n = 1;
        } else starts[0] = 0;
    }
    for (0..n) |k| {
        const end = if (k + 1 < n) starts[k + 1] else state.au_len;
        sendAu(state.au[starts[k]..end]);
        if (state.fd == platform.invalid_handle) return;
    }
    state.au_len = 0;
    nudgeEncoder();
}

pub fn sendAu(data: []const u8) void {
    if (data.len == 0) return;
    var key = false;
    var i: usize = 0;
    while (i + 3 < data.len) : (i += 1) {
        if (data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1) {
            const t = data[i + 3] & 0x1f;
            if (t == 5 or t == 7) key = true;
            i += 3;
        }
    }
    const now = util.nowNs(state.io);
    var cap_ns = now;
    var dup = false;
    if (state.enc_q_len > 0) {
        const f = state.enc_q[state.enc_q_head];
        state.enc_q_head = (state.enc_q_head + 1) % state.enc_q.len;
        state.enc_q_len -= 1;
        cap_ns = f.ns;
        dup = f.dup;
        if (!dup) state.enc_real -|= 1;
    }
    const id = state.frame_id;
    state.frame_id +%= 1;
    state.sent_ns[id % state.sent_ns.len] = cap_ns;
    var hdr: [H264_HDR]u8 = @splat(0);
    hdr[0] = 'H';
    // bit 2: a duplicate; decode it but don't acknowledge (nothing changed).
    hdr[1] = 1 | @as(u8, if (key) 2 else 0) | @as(u8, if (dup) 4 else 0);
    std.mem.writeInt(u32, hdr[4..8], id, .little);
    std.mem.writeInt(u32, hdr[8..12], @truncate(cap_ns / 100_000), .little);
    std.mem.writeInt(u32, hdr[12..16], @intCast(@min((now - cap_ns) / 1000, std.math.maxInt(u32))), .little);
    transport.queue(0x2, &hdr, data);
    transport.flush();
    if (dup) return;
    state.inflight += 1;
    const work = (now - cap_ns) / 1000;
    for ([_]*state.Counters{ &state.sec, &state.total }) |c| {
        c.frames += 1;
        c.bytes += data.len + H264_HDR;
        c.work_sum_us += work;
        c.work_max_us = @max(c.work_max_us, work);
    }
}
