//! LZ4 block format (no frame header): a fast greedy compressor for screen
//! tiles, plus the decoder the tests use. Clients carry their own decoders.

const std = @import("std");

const HASH_LOG = 14;
const MIN_MATCH = 4;
const LAST_LITERALS = 5; // the format requires the last 5 bytes to be literals
const MF_LIMIT = 12; // a match must start at least this far from the end
const MAX_OFFSET = 65535;

/// Worst-case compressed size of `n` input bytes.
pub fn bound(n: usize) usize {
    return n + n / 255 + 16;
}

/// Keeps match candidates between calls. A generation offset marks entries
/// from earlier inputs as stale, so the table is never cleared per tile.
pub const Compressor = struct {
    table: [1 << HASH_LOG]u32 = @splat(0),
    gen: u32 = 1,

    fn hash(v: u32) u32 {
        return (v *% 2654435761) >> (32 - HASH_LOG);
    }

    /// Compresses `src` into `dst` (at least `bound(src.len)` bytes) and
    /// returns the compressed length.
    pub fn compress(self: *Compressor, src: []const u8, dst: []u8) usize {
        std.debug.assert(dst.len >= bound(src.len));
        if (src.len > std.math.maxInt(u32) - self.gen - 1) {
            self.table = @splat(0);
            self.gen = 1;
        }
        const base = self.gen;
        self.gen += @intCast(src.len + 1);

        var op: usize = 0;
        var anchor: usize = 0;
        if (src.len >= MF_LIMIT + 1) {
            const limit = src.len - MF_LIMIT;
            const match_limit = src.len - LAST_LITERALS;
            var ip: usize = 1;
            self.table[hash(read32(src, 0))] = base;
            outer: while (true) {
                // Search, skipping faster through incompressible data.
                var attempts: usize = 1 << 6;
                var cand: usize = undefined;
                while (true) {
                    if (ip >= limit) break :outer;
                    const seq = read32(src, ip);
                    const h = hash(seq);
                    const entry = self.table[h];
                    self.table[h] = base + @as(u32, @intCast(ip));
                    if (entry >= base) {
                        cand = entry - base;
                        if (ip - cand <= MAX_OFFSET and read32(src, cand) == seq) break;
                    }
                    ip += attempts >> 6;
                    attempts += 1;
                }
                while (ip > anchor and cand > 0 and src[ip - 1] == src[cand - 1]) {
                    ip -= 1;
                    cand -= 1;
                }
                var len: usize = MIN_MATCH;
                while (ip + len + 8 <= match_limit) {
                    const diff = read64(src, ip + len) ^ read64(src, cand + len);
                    if (diff != 0) {
                        len += @ctz(diff) >> 3;
                        break;
                    }
                    len += 8;
                } else {
                    while (ip + len < match_limit and src[ip + len] == src[cand + len]) len += 1;
                }
                op = emit(dst, op, src[anchor..ip], ip - cand, len);
                ip += len;
                anchor = ip;
                if (ip >= limit) break;
                // Refill the table just behind the cursor for the next search.
                self.table[hash(read32(src, ip - 2))] = base + @as(u32, @intCast(ip - 2));
            }
        }
        return emitLast(dst, op, src[anchor..]);
    }
};

fn read32(b: []const u8, i: usize) u32 {
    return std.mem.readInt(u32, b[i..][0..4], .little);
}

fn read64(b: []const u8, i: usize) u64 {
    return std.mem.readInt(u64, b[i..][0..8], .little);
}

fn putLen(dst: []u8, op_in: usize, n_in: usize) usize {
    var op = op_in;
    var n = n_in;
    while (n >= 255) : (n -= 255) {
        dst[op] = 255;
        op += 1;
    }
    dst[op] = @intCast(n);
    return op + 1;
}

fn emit(dst: []u8, op_in: usize, lit: []const u8, offset: usize, len: usize) usize {
    var op = op_in;
    const ml = len - MIN_MATCH;
    const token = op;
    op += 1;
    dst[token] = (@as(u8, @intCast(@min(lit.len, 15))) << 4) | @as(u8, @intCast(@min(ml, 15)));
    if (lit.len >= 15) op = putLen(dst, op, lit.len - 15);
    @memcpy(dst[op..][0..lit.len], lit);
    op += lit.len;
    std.mem.writeInt(u16, dst[op..][0..2], @intCast(offset), .little);
    op += 2;
    if (ml >= 15) op = putLen(dst, op, ml - 15);
    return op;
}

fn emitLast(dst: []u8, op_in: usize, lit: []const u8) usize {
    var op = op_in;
    dst[op] = @as(u8, @intCast(@min(lit.len, 15))) << 4;
    op += 1;
    if (lit.len >= 15) op = putLen(dst, op, lit.len - 15);
    @memcpy(dst[op..][0..lit.len], lit);
    return op + lit.len;
}

/// Decodes a block into `dst`, returning the decoded length.
pub fn decompress(src: []const u8, dst: []u8) error{Corrupt}!usize {
    var ip: usize = 0;
    var op: usize = 0;
    while (ip < src.len) {
        const token = src[ip];
        ip += 1;
        var lit: usize = token >> 4;
        if (lit == 15) while (true) {
            if (ip >= src.len) return error.Corrupt;
            const b = src[ip];
            ip += 1;
            lit += b;
            if (b != 255) break;
        };
        if (ip + lit > src.len or op + lit > dst.len) return error.Corrupt;
        @memcpy(dst[op..][0..lit], src[ip..][0..lit]);
        ip += lit;
        op += lit;
        if (ip == src.len) return op;
        if (ip + 2 > src.len) return error.Corrupt;
        const offset = std.mem.readInt(u16, src[ip..][0..2], .little);
        ip += 2;
        if (offset == 0 or offset > op) return error.Corrupt;
        var len: usize = (token & 15) + MIN_MATCH;
        if (token & 15 == 15) while (true) {
            if (ip >= src.len) return error.Corrupt;
            const b = src[ip];
            ip += 1;
            len += b;
            if (b != 255) break;
        };
        if (op + len > dst.len) return error.Corrupt;
        for (0..len) |k| dst[op + k] = dst[op + k - offset];
        op += len;
    }
    return op;
}

test "lz4 round-trips screen-like and random data" {
    const testing = std.testing;
    var c: Compressor = .{};
    var src: [70000]u8 = undefined;
    var dst: [bound(70000)]u8 = undefined;
    var back: [70000]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(42);
    const r = rng.random();
    const lens = [_]usize{ 0, 1, 5, 12, 13, 14, 20, 64, 255, 1000, 4096, 70000 };
    for (lens) |n| {
        for (0..3) |kind| {
            for (src[0..n], 0..) |*b, i| b.* = switch (kind) {
                0 => if ((i / 4) % 50 < 45) 0x20 else @truncate(i), // flat UI with text
                1 => r.int(u8),
                else => @truncate(i % 7),
            };
            const m = c.compress(src[0..n], &dst);
            const k = try decompress(dst[0..m], &back);
            try testing.expectEqual(n, k);
            try testing.expectEqualSlices(u8, src[0..n], back[0..n]);
            if (kind != 1 and n >= 4096) try testing.expect(m < n / 4);
        }
    }
}
