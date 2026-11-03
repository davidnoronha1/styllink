//! Common video pipeline. OS capture and readiness are injected through platform.zig.
pub const formats = @import("video/formats.zig");
pub const pixels = @import("video/pixels.zig");
pub const tiles = @import("video/tiles.zig");
pub const runtime = @import("video/runtime.zig");
pub const start = runtime.start;
pub const enabled = runtime.enabled;
pub const adopt = runtime.adopt;
test {
    _ = formats;
    _ = pixels;
    _ = tiles;
    _ = runtime;
    _ = @import("video/capture.zig");
}
