//! Common application lifecycle. The backend supplies only device/capture,
//! readiness and socket tuning; Io and allocation are supplied by the caller.
const std = @import("std");
const platform = @import("platform.zig");
const config = @import("config.zig");
const util = @import("util.zig");
const banner = @import("banner.zig");
const input = @import("input.zig");
const stats = @import("stats.zig");
const ws = @import("ws.zig");
const video = @import("video.zig");

pub const App = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    cfg: config.Config,
    environ: std.process.Environ,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, cfg: config.Config, environ: std.process.Environ) App {
        return .{ .io = io, .allocator = allocator, .cfg = cfg, .environ = environ };
    }

    fn listen(self: *App) !std.Io.net.Server {
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            const server = platform.Network.listen(self.io, self.cfg.network.port) catch |err| switch (err) {
                error.AddressInUse => {
                    if (attempt == 30) return err;
                    try std.Io.sleep(self.io, .fromMilliseconds(100), .awake);
                    continue;
                },
                else => return err,
            };
            return server;
        }
    }

    pub fn run(self: *App) !void {
        const io = self.io;
        const cfg = self.cfg;
        platform.Scheduling.prepare();
        stats.initLog(io, cfg.logging.path);
        defer stats.deinit();
        // The worker must not inherit the pen thread's elevated priority.
        // Join it before closing diagnostics or releasing the allocator.
        video.start(cfg, io, self.allocator, self.environ);
        defer video.runtime.stop();
        if (cfg.runtime.realtime) platform.Scheduling.setRealtime();
        stats.initTty();
        input.init(cfg, io);
        defer input.deinit();
        ws.init(cfg, io);
        ws.reactor = try platform.Reactor.init();
        defer ws.reactor.deinit(io);
        defer for (&ws.clients) |*client| if (client.fd != platform.invalid_handle) ws.closeClient(client);
        var timer = try platform.Timer.init();
        defer timer.deinit(io);
        timer.arm(stats.TICK_MS * std.time.ns_per_ms, stats.TICK_MS * std.time.ns_per_ms);
        var server = try self.listen();
        defer server.deinit(io);
        ws.reactor.add(platform.IO.socketHandle(server.socket.handle), .{ .readable = true }, ws.LISTEN_TAG);
        ws.reactor.add(timer.handle, .{ .readable = true }, ws.TIMER_TAG);
        ws.reactor.add(input.pace_timer.handle, .{ .readable = true }, ws.PACE_TAG);
        ws.reactor.add(input.play_timer.handle, .{ .readable = true }, ws.PLAY_TAG);
        banner.print(cfg, platform.Network.lanAddr(io) orelse .{ 127, 0, 0, 1 });
        stats.logJson("\"ev\":\"start\",\"port\":{d},\"preset\":\"{t}\",\"busy\":{},\"unsmooth\":{d},\"catchup\":{d},\"jitter_ms\":{d},\"region\":[{d},{d},{d},{d}],\"desktop\":[{d},{d}]", .{
            cfg.network.port,      cfg.video.preset,      cfg.runtime.busy,      cfg.input.unsmooth,    cfg.input.catchup,      cfg.input.jitter_ms,
            cfg.display.region[0], cfg.display.region[1], cfg.display.region[2], cfg.display.region[3], cfg.display.desktop[0], cfg.display.desktop[1],
        });
        if (stats.loggingEnabled()) std.debug.print("styllink: logging to {s}\n", .{cfg.logging.path});
        std.debug.print("styllink: :{d}, mapping to {d}x{d}+{d}+{d} of {d}x{d}\n", .{
            cfg.network.port, cfg.display.region[2], cfg.display.region[3], cfg.display.region[0], cfg.display.region[1], cfg.display.desktop[0], cfg.display.desktop[1],
        });
        var events: [ws.MAX_CLIENTS + 4]platform.types.Event = undefined;
        while (true) {
            if (cfg.runtime.busy and input.play_len > 0 and input.play_q[input.play_head].at <= util.nowNs(io)) input.playDrain();
            const ready = try ws.reactor.wait(&events, cfg.runtime.busy);
            for (ready) |event| {
                switch (event.tag) {
                    ws.PLAY_TAG => {
                        input.play_timer.consume(io);
                        input.playDrain();
                    },
                    ws.PACE_TAG => {
                        input.pace_timer.consume(io);
                        input.pen.drain();
                    },
                    ws.TIMER_TAG => {
                        timer.consume(io);
                        ws.onTick();
                    },
                    ws.LISTEN_TAG => {
                        const stream = server.accept(io) catch continue;
                        const handle = platform.IO.socketHandle(stream.socket.handle);
                        ws.tuneSocket(handle);
                        const slot = ws.claimSlot(handle) orelse continue;
                        ws.reactor.add(handle, .{ .readable = true }, slot);
                    },
                    else => {
                        const client = &ws.clients[@intCast(event.tag)];
                        if (client.fd == platform.invalid_handle) continue;
                        if (!event.readable or client.len == client.buf.len) {
                            ws.closeClient(client);
                            continue;
                        }
                        const count = platform.IO.read(io, client.fd, client.buf[client.len..]) catch {
                            ws.closeClient(client);
                            continue;
                        };
                        if (!ws.onData(client, count)) ws.closeClient(client);
                    },
                }
            }
        }
    }
};

test {
    _ = input;
    _ = ws;
    _ = stats;
    _ = video;
}
