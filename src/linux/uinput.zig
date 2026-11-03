//! Typed Linux uinput device access. Pen state and event pacing live in input.zig.

const std = @import("std");
const linux = std.os.linux;
const util = @import("util.zig");

const pen_events = @import("../input/events.zig");
const Event = pen_events.Event;
const AXIS_MAX = pen_events.AXIS_MAX;
const PRESSURE_MAX = pen_events.PRESSURE_MAX;
const TILT_MAX = pen_events.TILT_MAX;
const KernelEvent = extern struct {
    sec: isize = 0,
    usec: isize = 0,
    type: u16,
    code: u16,
    value: i32,
};
fn kernelEvent(event: Event) KernelEvent {
    return switch (event) {
        .axis_value => |a| .{ .type = EV_ABS, .code = switch (a.which) {
            .x => ABS_X,
            .y => ABS_Y,
            .pressure => ABS_PRESSURE,
            .tilt_x => ABS_TILT_X,
            .tilt_y => ABS_TILT_Y,
        }, .value = a.value },
        .button_value => |b| .{ .type = EV_KEY, .code = switch (b.which) {
            .pen => BTN_TOOL_PEN,
            .eraser => BTN_TOOL_RUBBER,
            .touch => BTN_TOUCH,
            .stylus => BTN_STYLUS,
        }, .value = @intFromBool(b.pressed) },
        .frame_end => .{ .type = EV_SYN, .code = SYN_REPORT, .value = 0 },
    };
}

pub const UinputDevice = struct {
    // A negative descriptor represents disabled desktop input.
    fd: i32 = -1,
    io: std.Io = undefined,

    pub fn createTablet(io: std.Io, desktop: [2]u32) UinputDevice {
        const file = std.Io.Dir.openFileAbsolute(io, "/dev/uinput", .{ .mode = .write_only }) catch |err| {
            std.debug.print("styllink: open /dev/uinput: {t}\n  -> run make install-uinput-access once (needs sudo)\n", .{err});
            std.process.exit(1);
        };
        const fd = file.handle;

        const ioc = struct {
            fn set(f: i32, req: u32, val: usize) void {
                _ = util.checkErrno(linux.ioctl(f, req, val), "uinput ioctl");
            }
        };
        ioc.set(fd, UI_SET_EVBIT, EV_SYN);
        ioc.set(fd, UI_SET_EVBIT, EV_KEY);
        ioc.set(fd, UI_SET_EVBIT, EV_ABS);
        for ([_]usize{ BTN_TOOL_PEN, BTN_TOOL_RUBBER, BTN_TOUCH, BTN_STYLUS }) |k| ioc.set(fd, UI_SET_KEYBIT, k);
        for ([_]usize{ ABS_X, ABS_Y, ABS_PRESSURE, ABS_TILT_X, ABS_TILT_Y }) |a| ioc.set(fd, UI_SET_ABSBIT, a);
        ioc.set(fd, UI_SET_PROPBIT, INPUT_PROP_DIRECT);

        // Resolution: report the axes as a ~ 300x169mm surface so the aspect
        // ratio libinput sees matches a 16:9 screen; tilt is units per radian.
        const res_x: i32 = @divTrunc(AXIS_MAX, 300);
        const res_y: i32 = @intCast(@divTrunc(@as(u64, @intCast(AXIS_MAX)) * desktop[0], @as(u64, 300) * desktop[1]));
        const axes = [_]AbsSetup{
            .{ .code = ABS_X, .minimum = 0, .maximum = AXIS_MAX, .resolution = res_x },
            .{ .code = ABS_Y, .minimum = 0, .maximum = AXIS_MAX, .resolution = res_y },
            .{ .code = ABS_PRESSURE, .minimum = 0, .maximum = PRESSURE_MAX, .resolution = 0 },
            .{ .code = ABS_TILT_X, .minimum = -TILT_MAX, .maximum = TILT_MAX, .resolution = 57 },
            .{ .code = ABS_TILT_Y, .minimum = -TILT_MAX, .maximum = TILT_MAX, .resolution = 57 },
        };
        for (&axes) |*a| ioc.set(fd, UI_ABS_SETUP, @intFromPtr(a));

        var setup = std.mem.zeroes(UinputSetup);
        setup.bustype = 0x03; // BUS_USB
        setup.vendor = 0x1701;
        setup.product = 0x5713;
        setup.version = 1;
        @memcpy(setup.name[0..12], "StylLink Pen");
        ioc.set(fd, UI_DEV_SETUP, @intFromPtr(&setup));
        ioc.set(fd, UI_DEV_CREATE, 0);
        return .{ .fd = fd, .io = io };
    }

    /// Takes ownership of an existing output stream (also useful for tests).
    pub fn fromFile(io: std.Io, file: std.Io.File) UinputDevice {
        return .{ .fd = file.handle, .io = io };
    }

    pub fn isEnabled(self: UinputDevice) bool {
        return self.fd >= 0;
    }

    /// Write a batch in order. The caller controls frame boundaries and pacing.
    pub fn writeEvents(self: UinputDevice, events: []const Event) bool {
        if (!self.isEnabled()) return true;
        var batch: [48]KernelEvent = undefined;
        var offset: usize = 0;
        while (offset < events.len) {
            const count = @min(batch.len, events.len - offset);
            for (events[offset..][0..count], batch[0..count]) |event, *out| out.* = kernelEvent(event);
            const file = std.Io.File{ .handle = self.fd, .flags = .{ .nonblocking = false } };
            file.writeStreamingAll(self.io, std.mem.sliceAsBytes(batch[0..count])) catch return false;
            offset += count;
        }
        return true;
    }

    /// Closing the device's only descriptor also destroys the virtual device.
    pub fn deinit(self: *UinputDevice) void {
        if (self.isEnabled()) (std.Io.File{ .handle = self.fd, .flags = .{ .nonblocking = false } }).close(self.io);
        self.fd = -1;
    }
};

// ---------------------------------------------------------------- uinput

const EV_SYN = 0x00;
const EV_KEY = 0x01;
const EV_ABS = 0x03;
const SYN_REPORT = 0;
const ABS_X = 0x00;
const ABS_Y = 0x01;
const ABS_PRESSURE = 0x18;
const ABS_TILT_X = 0x1a;
const ABS_TILT_Y = 0x1b;
const BTN_TOOL_PEN = 0x140;
const BTN_TOOL_RUBBER = 0x141;
const BTN_TOUCH = 0x14a;
const BTN_STYLUS = 0x14b;
const INPUT_PROP_DIRECT = 0x01;

const UI_DEV_CREATE: u32 = 0x5501;
const UI_DEV_SETUP: u32 = 0x405c5503; // _IOW('U', 3, struct uinput_setup)
const UI_ABS_SETUP: u32 = 0x401c5504; // _IOW('U', 4, struct uinput_abs_setup)
const UI_SET_EVBIT: u32 = 0x40045564;
const UI_SET_KEYBIT: u32 = 0x40045565;
const UI_SET_ABSBIT: u32 = 0x40045567;
const UI_SET_PROPBIT: u32 = 0x4004556e;

const UinputSetup = extern struct {
    bustype: u16,
    vendor: u16,
    product: u16,
    version: u16,
    name: [80]u8,
    ff_effects_max: u32,
};

const AbsSetup = extern struct {
    code: u16,
    value: i32 = 0,
    minimum: i32,
    maximum: i32,
    fuzz: i32 = 0,
    flat: i32 = 0,
    resolution: i32,
};

comptime {
    std.debug.assert(@sizeOf(KernelEvent) == 24);
    std.debug.assert(@sizeOf(UinputSetup) == 92);
    std.debug.assert(@sizeOf(AbsSetup) == 28);
}

test "device writes kernel event batches in order and closes its descriptor" {
    const testing = std.testing;
    var pipe: [2]i32 = undefined;
    _ = util.checkErrno(linux.pipe2(&pipe, .{ .CLOEXEC = true }), "test event pipe");
    defer _ = linux.close(pipe[0]);
    var device = UinputDevice{ .fd = pipe[1], .io = std.testing.io };
    defer device.deinit();
    const events = [_]Event{ .axis(.x, 1234), .button(.touch, true), .sync() };
    try testing.expect(device.writeEvents(&events));
    var bytes: [3 * @sizeOf(KernelEvent)]u8 = undefined;
    const count = util.checkErrno(linux.read(pipe[0], &bytes, bytes.len), "read test events");
    try testing.expectEqual(bytes.len, count);
    // Check the Linux ABI independently of the typed constructors.
    try testing.expectEqual(@as(u16, 0x03), std.mem.readInt(u16, bytes[16..18], .little));
    try testing.expectEqual(@as(u16, 0x00), std.mem.readInt(u16, bytes[18..20], .little));
    try testing.expectEqual(@as(i32, 1234), std.mem.readInt(i32, bytes[20..24], .little));
    try testing.expectEqual(@as(u16, 0x01), std.mem.readInt(u16, bytes[40..42], .little));
    try testing.expectEqual(@as(u16, 0x14a), std.mem.readInt(u16, bytes[42..44], .little));
    try testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, bytes[44..48], .little));
    try testing.expectEqualSlices(u8, &(@as([24]u8, @splat(0))), bytes[48..72]);
    try testing.expect(!events[0].isFrameEnd());
    try testing.expect(events[2].isFrameEnd());
    device.deinit();
    try testing.expect(!device.isEnabled());
    try testing.expect(device.writeEvents(&events));
    try testing.expectEqual(@as(usize, 0), util.checkErrno(linux.read(pipe[0], &bytes, bytes.len), "test closed device"));
}
