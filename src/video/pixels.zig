//! BGRX/RGB565 conversion, downsampling and change detection.

const std = @import("std");
const Pix = @import("formats.zig").Pix;

fn avg(a: u32, b: u32) u32 {
    return (a & b) +% (((a ^ b) & 0xfefefefe) >> 1);
}

pub fn convRow(comptime pix: Pix, comptime half: bool, src: []const u8, below: []const u8, dst: []u8, w: usize) u32 {
    var diff: u32 = 0;
    for (0..w) |i| {
        var p: u32 = undefined;
        if (half) {
            const a = std.mem.readInt(u32, src[i * 8 ..][0..4], .little);
            const b = std.mem.readInt(u32, src[i * 8 + 4 ..][0..4], .little);
            const c = std.mem.readInt(u32, below[i * 8 ..][0..4], .little);
            const d = std.mem.readInt(u32, below[i * 8 + 4 ..][0..4], .little);
            p = avg(avg(a, b), avg(c, d));
        } else {
            p = std.mem.readInt(u32, src[i * 4 ..][0..4], .little);
        }
        switch (pix) {
            .bgrx => {
                const v = p | 0xff000000; // the pad byte is undefined
                const o = dst[i * 4 ..][0..4];
                diff |= std.mem.readInt(u32, o, .little) ^ v;
                std.mem.writeInt(u32, o, v, .little);
            },
            .rgb565 => {
                const v: u16 = @truncate(((p >> 8) & 0xf800) | ((p >> 5) & 0x07e0) | ((p >> 3) & 0x001f));
                const o = dst[i * 2 ..][0..2];
                diff |= std.mem.readInt(u16, o, .little) ^ v;
                std.mem.writeInt(u16, o, v, .little);
            },
        }
    }
    return diff;
}

test "convRow converts, halves and reports changes" {
    const testing = std.testing;
    var src: [16]u8 = .{ 0x10, 0x20, 0x30, 0, 0x30, 0x40, 0x50, 0, 0x10, 0x20, 0x30, 0, 0x30, 0x40, 0x50, 0 };
    var dst: [8]u8 = @splat(0);
    try testing.expect(convRow(.bgrx, false, &src, &src, &dst, 2) != 0);
    try testing.expectEqualSlices(u8, &.{ 0x10, 0x20, 0x30, 0xff, 0x30, 0x40, 0x50, 0xff }, &dst);
    try testing.expect(convRow(.bgrx, false, &src, &src, &dst, 2) == 0);
    var half: [4]u8 = undefined;
    _ = convRow(.bgrx, true, &src, &src, &half, 1);
    try testing.expectEqualSlices(u8, &.{ 0x20, 0x30, 0x40, 0xff }, &half);
    var px: [2]u8 = undefined;
    const white = [4]u8{ 0xff, 0xff, 0xff, 0 };
    _ = convRow(.rgb565, false, &white, &white, &px, 1);
    try testing.expectEqual(@as(u16, 0xffff), std.mem.readInt(u16, &px, .little));
}
