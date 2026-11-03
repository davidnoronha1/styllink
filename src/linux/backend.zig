//! Bare OS services used by the common application and video pipeline.
pub const Handle = @import("io.zig").Handle;
pub const invalid_handle: Handle = -1;
pub const IO = @import("io.zig");
pub const Channel = IO.Channel;
pub const Reactor = @import("reactor.zig").Reactor;
pub const Timer = @import("reactor.zig").Timer;
pub const Network = @import("network.zig");
pub const Scheduling = @import("scheduling.zig");
pub const Capture = @import("capture.zig").Capture;
pub const InputDevice = @import("uinput.zig").UinputDevice;

pub const shell_exe = "/bin/sh";
pub const shell_arg = "-c";
