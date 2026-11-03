//! OS services only. Application behavior, protocols and encoding stay in the core.
pub const types = @import("platform/types.zig");
pub const Backend = switch (@import("builtin").os.tag) {
    .linux => @import("linux/backend.zig"),
    .windows => @import("windows/backend.zig"),
    else => @compileError("Implement a StylLink backend for this operating system"),
};
pub const Handle = Backend.Handle;
pub const invalid_handle = Backend.invalid_handle;
pub const IO = Backend.IO;
pub const Channel = Backend.Channel;
pub const Reactor = Backend.Reactor;
pub const Timer = Backend.Timer;
pub const Network = Backend.Network;
pub const Scheduling = Backend.Scheduling;
pub const Capture = Backend.Capture;
pub const InputDevice = Backend.InputDevice;

pub const shell_exe = Backend.shell_exe;
pub const shell_arg = Backend.shell_arg;
