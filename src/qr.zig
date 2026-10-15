//! Minimal QR code encoder: byte mode, error correction level M, versions 1-6
//! (up to 106 bytes), rendered to the terminal with half-block characters.
//! Follows the structure of Nayuki's reference implementation.

const std = @import("std");

const MAX_VER = 6;
const MAX_SIZE = MAX_VER * 4 + 17;
const ECC_PER_BLOCK = [_]u8{ 0, 10, 16, 26, 18, 24, 16 }; // level M
const NUM_BLOCKS = [_]u8{ 0, 1, 1, 1, 2, 2, 4 };

pub const Qr = struct {
    size: usize,
    dark: [MAX_SIZE][MAX_SIZE]bool = @splat(@splat(false)),
    func: [MAX_SIZE][MAX_SIZE]bool = @splat(@splat(false)),

    fn set(q: *Qr, x: usize, y: usize, v: bool) void {
        q.dark[y][x] = v;
        q.func[y][x] = true;
    }
};

fn rawModules(ver: usize) usize {
    var r = (16 * ver + 128) * ver + 64;
    if (ver >= 2) {
        const na = ver / 7 + 2;
        r -= (25 * na - 10) * na - 55;
    }
    return r;
}

fn dataCodewords(ver: usize) usize {
    return rawModules(ver) / 8 - @as(usize, ECC_PER_BLOCK[ver]) * NUM_BLOCKS[ver];
}

fn gfMul(x: u8, y: u8) u8 {
    var z: u16 = 0;
    var i: u4 = 8;
    while (i > 0) {
        i -= 1;
        z = (z << 1) ^ ((z >> 7) * 0x11D);
        z ^= ((@as(u16, y) >> @as(u3, @intCast(i))) & 1) * x;
    }
    return @intCast(z & 0xff);
}

fn rsRemainder(data: []const u8, deg: usize, out: []u8) void {
    var div: [32]u8 = @splat(0);
    div[deg - 1] = 1;
    var root: u8 = 1;
    for (0..deg) |_| {
        for (0..deg) |j| {
            div[j] = gfMul(div[j], root);
            if (j + 1 < deg) div[j] ^= div[j + 1];
        }
        root = gfMul(root, 2);
    }
    @memset(out[0..deg], 0);
    for (data) |b| {
        const f = b ^ out[0];
        std.mem.copyForwards(u8, out[0 .. deg - 1], out[1..deg]);
        out[deg - 1] = 0;
        for (0..deg) |i| out[i] ^= gfMul(div[i], f);
    }
}

fn drawFinder(q: *Qr, cx: isize, cy: isize) void {
    var dy: isize = -4;
    while (dy <= 4) : (dy += 1) {
        var dx: isize = -4;
        while (dx <= 4) : (dx += 1) {
            const x = cx + dx;
            const y = cy + dy;
            if (x < 0 or y < 0 or x >= q.size or y >= q.size) continue;
            const d = @max(@abs(dx), @abs(dy));
            q.set(@intCast(x), @intCast(y), d != 2 and d != 4);
        }
    }
}

fn drawAlign(q: *Qr, cx: usize, cy: usize) void {
    for (0..5) |j| for (0..5) |i| {
        const d = @max(@abs(@as(isize, @intCast(i)) - 2), @abs(@as(isize, @intCast(j)) - 2));
        q.set(cx + i - 2, cy + j - 2, d != 1);
    };
}

fn drawFormat(q: *Qr, mask: u3) void {
    const data: u32 = (0 << 3) | @as(u32, mask); // level M = 0b00
    var rem = data;
    for (0..10) |_| rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    const bits = ((data << 10) | rem) ^ 0x5412;
    const s = q.size;
    const b = struct {
        fn f(v: u32, i: u5) bool {
            return (v >> i) & 1 != 0;
        }
    }.f;
    for (0..6) |i| q.set(8, i, b(bits, @intCast(i)));
    q.set(8, 7, b(bits, 6));
    q.set(8, 8, b(bits, 7));
    q.set(7, 8, b(bits, 8));
    for (9..15) |i| q.set(14 - i, 8, b(bits, @intCast(i)));
    for (0..8) |i| q.set(s - 1 - i, 8, b(bits, @intCast(i)));
    for (8..15) |i| q.set(8, s - 15 + i, b(bits, @intCast(i)));
    q.set(8, s - 8, true);
}

fn maskBit(mask: u3, x: usize, y: usize) bool {
    return switch (mask) {
        0 => (x + y) % 2 == 0,
        1 => y % 2 == 0,
        2 => x % 3 == 0,
        3 => (x + y) % 3 == 0,
        4 => (x / 3 + y / 2) % 2 == 0,
        5 => x * y % 2 + x * y % 3 == 0,
        6 => (x * y % 2 + x * y % 3) % 2 == 0,
        7 => ((x + y) % 2 + x * y % 3) % 2 == 0,
    };
}

fn applyMask(q: *Qr, mask: u3) void {
    for (0..q.size) |y| for (0..q.size) |x| {
        if (!q.func[y][x] and maskBit(mask, x, y)) q.dark[y][x] = !q.dark[y][x];
    };
}

/// Penalty rules 1 (runs), 2 (2x2 blocks) and 4 (balance); good enough to
/// pick a scanner-friendly mask.
fn penalty(q: *const Qr) usize {
    var p: usize = 0;
    const s = q.size;
    for (0..2) |dir| for (0..s) |a| {
        var run: usize = 0;
        var last = false;
        for (0..s) |b| {
            const v = if (dir == 0) q.dark[a][b] else q.dark[b][a];
            if (b > 0 and v == last) {
                run += 1;
                if (run == 5) p += 3 else if (run > 5) p += 1;
            } else run = 1;
            last = v;
        }
    };
    var darkN: usize = 0;
    for (0..s) |y| for (0..s) |x| {
        if (q.dark[y][x]) darkN += 1;
        if (x + 1 < s and y + 1 < s) {
            const v = q.dark[y][x];
            if (v == q.dark[y][x + 1] and v == q.dark[y + 1][x] and v == q.dark[y + 1][x + 1]) p += 3;
        }
    };
    const total = s * s;
    const diff = if (darkN * 20 > total * 10) darkN * 20 - total * 10 else total * 10 - darkN * 20;
    p += (diff + total - 1) / total * 10;
    return p;
}

pub fn encode(text: []const u8) ?Qr {
    var ver: usize = 1;
    while (ver <= MAX_VER and text.len + 2 > dataCodewords(ver)) ver += 1;
    if (ver > MAX_VER) return null;

    // Data bits: mode 0100, 8-bit length, bytes, terminator, padding.
    const cap = dataCodewords(ver);
    var data: [256]u8 = @splat(0);
    data[0] = 0x40 | @as(u8, @intCast(text.len >> 4));
    data[1] = @as(u8, @intCast((text.len & 0xf) << 4));
    for (text, 0..) |c, i| {
        data[1 + i] |= c >> 4;
        data[2 + i] = c << 4;
    }
    var n = text.len + 2;
    var pad: u8 = 0xEC;
    while (n < cap) : (n += 1) {
        data[n] = pad;
        pad ^= 0xEC ^ 0x11;
    }

    // Split into blocks, add Reed-Solomon ECC, interleave.
    const nb: usize = NUM_BLOCKS[ver];
    const ecl: usize = ECC_PER_BLOCK[ver];
    const raw = rawModules(ver) / 8;
    const nshort = nb - raw % nb;
    const shortLen = raw / nb;
    var blocks: [4][128]u8 = undefined;
    var k: usize = 0;
    for (0..nb) |i| {
        const dl = shortLen - ecl + @intFromBool(i >= nshort);
        @memcpy(blocks[i][0..dl], data[k .. k + dl]);
        k += dl;
        var ecc: [32]u8 = undefined;
        rsRemainder(blocks[i][0..dl], ecl, &ecc);
        // short blocks keep a dummy slot so columns line up
        const off = shortLen + 1 - ecl;
        @memcpy(blocks[i][off .. off + ecl], ecc[0..ecl]);
    }
    var all: [256]u8 = undefined;
    var m: usize = 0;
    for (0..shortLen + 1) |i| for (0..nb) |j| {
        if (i == shortLen - ecl and j < nshort) continue;
        all[m] = blocks[j][i];
        m += 1;
    };

    var q = Qr{ .size = ver * 4 + 17 };
    const s = q.size;
    for (0..s) |i| {
        q.set(6, i, i % 2 == 0);
        q.set(i, 6, i % 2 == 0);
    }
    drawFinder(&q, 3, 3);
    drawFinder(&q, @intCast(s - 4), 3);
    drawFinder(&q, 3, @intCast(s - 4));
    if (ver >= 2) drawAlign(&q, s - 7, s - 7);
    drawFormat(&q, 0); // reserve format area

    var bit: usize = 0;
    var right: usize = s - 1;
    while (right >= 1) {
        if (right == 6) right = 5;
        for (0..s) |vert| for (0..2) |j| {
            const x = right - j;
            const up = (right + 1) & 2 == 0;
            const y = if (up) s - 1 - vert else vert;
            if (!q.func[y][x] and bit < m * 8) {
                q.dark[y][x] = (all[bit >> 3] >> @as(u3, @intCast(7 - (bit & 7)))) & 1 != 0;
                bit += 1;
            }
        };
        if (right < 2) break;
        right -= 2;
    }

    var best: u3 = 0;
    var bestP: usize = std.math.maxInt(usize);
    for (0..8) |mi| {
        const mk: u3 = @intCast(mi);
        applyMask(&q, mk);
        drawFormat(&q, mk);
        const p = penalty(&q);
        if (p < bestP) {
            bestP = p;
            best = mk;
        }
        applyMask(&q, mk); // undo (XOR)
    }
    applyMask(&q, best);
    drawFormat(&q, best);
    return q;
}

/// Render with a white quiet zone; two modules per character row.
pub fn render(q: *const Qr, buf: []u8) []const u8 {
    const quiet = 2;
    const span = q.size + 2 * quiet;
    var w: usize = 0;
    const put = struct {
        fn f(b: []u8, o: *usize, s: []const u8) void {
            if (o.* + s.len > b.len) return;
            @memcpy(b[o.*..][0..s.len], s);
            o.* += s.len;
        }
    }.f;
    const isDark = struct {
        fn f(qq: *const Qr, x: usize, y: usize) bool {
            if (x < quiet or y < quiet) return false;
            const xx = x - quiet;
            const yy = y - quiet;
            return xx < qq.size and yy < qq.size and qq.dark[yy][xx];
        }
    }.f;
    var y: usize = 0;
    while (y < span) : (y += 2) {
        put(buf, &w, "  \x1b[107;30m");
        for (0..span) |x| {
            const t = isDark(q, x, y);
            const b = y + 1 < span and isDark(q, x, y + 1);
            put(buf, &w, if (t and b) "█" else if (t) "▀" else if (b) "▄" else " ");
        }
        put(buf, &w, "\x1b[0m\n");
    }
    return buf[0..w];
}
