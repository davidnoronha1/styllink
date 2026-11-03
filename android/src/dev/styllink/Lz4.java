package dev.styllink;

/** LZ4 block decoder (no frame header), matching the server's tile encoder. */
final class Lz4 {
    private Lz4() {}

    /** Decodes src[off, off+len) into dst; returns the decoded length. */
    static int decode(byte[] src, int off, int len, byte[] dst, int dstLen) {
        if (off < 0 || len < 0 || off > src.length - len || dstLen < 0 || dstLen > dst.length)
            throw new IllegalArgumentException("lz4: invalid bounds");
        int ip = off, end = off + len, op = 0;
        while (ip < end) {
            int token = src[ip++] & 0xff;
            int lit = token >>> 4;
            if (lit == 15) {
                int b;
                do {
                    if (ip >= end) throw new IllegalArgumentException("lz4: truncated literals");
                    b = src[ip++] & 0xff;
                    lit += b;
                    if (lit > dstLen - op) throw new IllegalArgumentException("lz4: literals overrun");
                } while (b == 255);
            }
            if (lit > dstLen - op || lit > end - ip) throw new IllegalArgumentException("lz4: literals overrun");
            System.arraycopy(src, ip, dst, op, lit);
            ip += lit;
            op += lit;
            if (ip >= end) break;
            if (end - ip < 2) throw new IllegalArgumentException("lz4: truncated offset");
            int offset = (src[ip] & 0xff) | (src[ip + 1] & 0xff) << 8;
            ip += 2;
            int ml = token & 15;
            if (ml == 15) {
                int b;
                do {
                    if (ip >= end) throw new IllegalArgumentException("lz4: truncated match");
                    b = src[ip++] & 0xff;
                    ml += b;
                    if (ml > dstLen - op) throw new IllegalArgumentException("lz4: match overrun");
                } while (b == 255);
            }
            ml += 4;
            if (offset == 0 || offset > op || ml > dstLen - op) throw new IllegalArgumentException("lz4: bad match");
            int from = op - offset;
            if (offset >= ml) {
                System.arraycopy(dst, from, dst, op, ml);
            } else {
                // Seed the repeating pattern, then double the initialized
                // span. arraycopy alone has memmove semantics and would copy
                // uninitialized bytes for an overlapping LZ4 match.
                int copied = Math.min(offset, ml);
                System.arraycopy(dst, from, dst, op, copied);
                while (copied < ml) {
                    int count = Math.min(copied, ml - copied);
                    System.arraycopy(dst, op, dst, op + copied, count);
                    copied += count;
                }
            }
            op += ml;
        }
        return op;
    }
}
