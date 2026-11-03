//! Generic entry point. The caller supplies the allocator and Io implementation.
const std = @import("std");
const config = @import("config.zig");
const App = @import("app.zig").App;

pub fn main(init: std.process.Init) !void {
    var token_buf: [12]u8 = undefined;
    const cfg = config.parseArgs(init.minimal, init.io, &token_buf);
    var app = App.init(init.io, init.gpa, cfg, init.minimal.environ);
    try app.run();
}

test {
    _ = @import("app.zig");
    _ = @import("lz4.zig");
    _ = @import("qr.zig");
    _ = @import("video.zig");
    _ = @import("util.zig");
}
