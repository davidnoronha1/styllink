//! Common video worker lifecycle and readiness dispatch.
const std = @import("std");
const platform = @import("../platform.zig");
const config = @import("../config.zig");
const state = @import("state.zig");
const session = @import("session.zig");
const capture = @import("capture.zig");
const transport = @import("transport.zig");
const encoder = @import("encoder.zig");

pub const Tag = enum(u64) { handoff = 1, client, capture, pace, stat, encoder_in, encoder_out, poll, cursor };

pub fn start(c: config.Config, io: std.Io, allocator: std.mem.Allocator, env: std.process.Environ) void {
    state.cfg = c;
    state.io = io;
    state.allocator = allocator;
    state.environ = env;
    if (!c.video.enabled) return;
    state.stopping.store(false, .release);
    state.handoff = platform.Channel.init() catch return;
    state.worker = std.Thread.spawn(.{ .stack_size = 1 << 20 }, run, .{}) catch {
        state.handoff.deinit(io);
        std.debug.print("styllink: no remote screen (thread)\n", .{});
        return;
    };
}

pub fn enabled() bool {
    return state.cfg.video.enabled and state.worker != null;
}

pub fn adopt(client: platform.Handle) void {
    if (!enabled() or !state.handoff.send(state.io, client)) platform.IO.close(state.io, client);
}

pub fn stop() void {
    const worker = state.worker orelse return;
    state.stopping.store(true, .release);
    _ = state.handoff.send(state.io, platform.invalid_handle);
    worker.join();
    state.worker = null;
    state.handoff.deinit(state.io);
}

fn run() void {
    platform.Scheduling.normalPriority();
    state.reactor = platform.Reactor.init() catch return;
    defer state.reactor.deinit(state.io);
    state.pace_timer = platform.Timer.init() catch return;
    defer state.pace_timer.deinit(state.io);
    state.stat_timer = platform.Timer.init() catch return;
    defer state.stat_timer.deinit(state.io);
    state.cursor_timer = platform.Timer.init() catch return;
    defer state.cursor_timer.deinit(state.io);
    defer session.endSession("server stopped");
    state.stat_timer.arm(std.time.ns_per_s, std.time.ns_per_s);
    watch(state.handoff.read_handle, .{ .readable = true }, .handoff);
    watch(state.pace_timer.handle, .{ .readable = true }, .pace);
    watch(state.stat_timer.handle, .{ .readable = true }, .stat);
    watch(state.cursor_timer.handle, .{ .readable = true }, .cursor);
    if (state.cfg.video.poll_ms > 0) {
        state.poll_timer = platform.Timer.init() catch return;
        const period = @as(u64, state.cfg.video.poll_ms) * std.time.ns_per_ms;
        state.poll_timer.arm(period, period);
        watch(state.poll_timer.handle, .{ .readable = true }, .poll);
    }
    defer state.poll_timer.deinit(state.io);
    var events: [8]platform.types.Event = undefined;
    while (!state.stopping.load(.acquire)) {
        const ready = state.reactor.wait(&events, false) catch return;
        for (ready) |e| {
            if (state.stopping.load(.acquire)) break;
            dispatch(e);
        }
        if (!state.stopping.load(.acquire)) capture.tryFrame();
    }
}

fn dispatch(e: platform.types.Event) void {
    if (e.tag < @backingInt(Tag.handoff) or e.tag > @backingInt(Tag.cursor)) return;
    const tag: Tag = @fromBackingInt(@intCast(e.tag));
    switch (tag) {
        .handoff => {
            const client = state.handoff.receive(state.io) catch return;
            if (state.fd != platform.invalid_handle) session.endSession("replaced by a new connection");
            accept(client);
        },
        .client => {
            if (state.fd == platform.invalid_handle) return;
            if (e.writable) transport.flush();
            if (state.fd == platform.invalid_handle) return;
            if (e.readable) {
                if (!transport.readClient()) session.endSession("disconnected");
            } else if (e.closed) session.endSession("disconnected");
        },
        .capture => state.capture.handleEvents() catch session.endSession("lost the screen capture"),
        .pace => {
            state.pace_timer.consume(state.io);
            state.pace_armed = false;
        },
        .stat => {
            state.stat_timer.consume(state.io);
            session.onSecond();
        },
        .poll => {
            state.poll_timer.consume(state.io);
            if (state.streaming and !state.ses.source) {
                for (0..state.ses.th) |ty| @memset(state.dirty[ty][0..state.ses.tw], true);
                state.any_dirty = true;
            }
        },
        .cursor => {
            state.cursor_timer.consume(state.io);
            if (state.streaming and !state.ses.source) state.capture.pollCursor() catch session.endSession("lost the screen capture");
        },
        .encoder_in => encoder.writeEncoder(),
        .encoder_out => encoder.readEncoder(),
    }
}

pub fn watch(handle: platform.Handle, interest: platform.types.Interest, tag: Tag) void {
    state.reactor.add(handle, interest, @backingInt(tag));
}
pub fn rewatch(handle: platform.Handle, interest: platform.types.Interest, tag: Tag) void {
    state.reactor.modify(handle, interest, @backingInt(tag));
}
fn accept(client: platform.Handle) void {
    state.fd = client;
    state.rx_len = 0;
    state.caps = .{};
    state.peer = platform.Network.peer(client);
    platform.Network.tuneVideo(client);
    state.out_armed = false;
    watch(client, .{ .readable = true }, .client);
}

test "video worker stops and joins without a connected tablet" {
    for (0..3) |_| {
        start(.{}, std.testing.io, std.testing.allocator, .empty);
        try std.testing.expect(enabled());
        stop();
        try std.testing.expect(!enabled());
        try std.testing.expect(state.handoff.read_handle == platform.invalid_handle);
    }
}
