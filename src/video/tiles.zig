//! Merge changed tiles into bounded rectangles for incremental transmission.

const std = @import("std");
const session = @import("formats.zig");

pub const Rect = struct { tx0: u32, tx1: u32, ty0: u32, ty1: u32 };

pub fn buildRects(ses: session.Session, changed: *[session.MAX_TY][session.MAX_TX]bool, rects: []Rect) usize {
    var n: usize = 0;
    var above: usize = 0; // first rectangle that can still end on the row above
    for (0..ses.th) |ty| {
        const row_start = n;
        var tx: usize = 0;
        while (tx < ses.tw) {
            if (!changed[ty][tx]) {
                tx += 1;
                continue;
            }
            const x0 = tx;
            while (tx < ses.tw and changed[ty][tx]) : (tx += 1) changed[ty][tx] = false;
            const x1 = tx - 1;
            for (rects[above..row_start]) |*r| {
                if (r.tx0 == x0 and r.tx1 == x1 and r.ty1 + 1 == ty and r.ty1 - r.ty0 + 1 < session.RECT_ROWS) {
                    r.ty1 = @intCast(ty);
                    break;
                }
            } else {
                rects[n] = .{ .tx0 = @intCast(x0), .tx1 = @intCast(x1), .ty0 = @intCast(ty), .ty1 = @intCast(ty) };
                n += 1;
            }
        }
        while (above < n and rects[above].ty1 < ty) above += 1;
    }
    return n;
}

test "buildRects merges runs into bounded rectangles" {
    const testing = std.testing;
    const ses: session.Session = .{ .tw = 8, .th = 8, .sw = 256, .sh = 256 };
    var changed: [session.MAX_TY][session.MAX_TX]bool = @splat(@splat(false));
    var rects: [session.MAX_TX * session.MAX_TY]Rect = undefined;
    for (0..6) |ty| {
        changed[ty][1] = true;
        changed[ty][2] = true;
    }
    changed[0][5] = true;
    const n = buildRects(ses, &changed, &rects);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(Rect{ .tx0 = 1, .tx1 = 2, .ty0 = 0, .ty1 = 3 }, rects[0]);
    try testing.expectEqual(Rect{ .tx0 = 5, .tx1 = 5, .ty0 = 0, .ty1 = 0 }, rects[1]);
    try testing.expectEqual(Rect{ .tx0 = 1, .tx1 = 2, .ty0 = 4, .ty1 = 5 }, rects[2]);
    for (0..8) |ty| try testing.expect(std.mem.indexOfScalar(bool, changed[ty][0..8], true) == null);
}
