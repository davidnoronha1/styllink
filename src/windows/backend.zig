//! Implement the operations exported by linux/backend.zig here. The common
//! App, WebSocket protocol, pen state and video pipeline are reused unchanged.
comptime {
    @compileError("Windows backend is not implemented yet; implement the platform.zig service contract in windows/backend.zig");
}
