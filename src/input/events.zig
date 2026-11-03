//! Portable pen events. Kernel ABI translation belongs to the OS backend.
pub const AXIS_MAX: i32 = 65535;
pub const PRESSURE_MAX: i32 = 4095;
pub const TILT_MAX: i32 = 90;
pub const Axis = enum { x, y, pressure, tilt_x, tilt_y };
pub const Button = enum { pen, eraser, touch, stylus };
pub const Event = union(enum) {
    axis_value: struct { which: Axis, value: i32 },
    button_value: struct { which: Button, pressed: bool },
    frame_end,
    pub fn axis(which: Axis, value: i32) Event {
        return .{ .axis_value = .{ .which = which, .value = value } };
    }
    pub fn button(which: Button, pressed: bool) Event {
        return .{ .button_value = .{ .which = which, .pressed = pressed } };
    }
    pub fn sync() Event {
        return .frame_end;
    }
    pub fn isFrameEnd(self: Event) bool {
        return self == .frame_end;
    }
};
