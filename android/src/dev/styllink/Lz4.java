package dev.styllink;

/** LZ4 block decoder (no frame header), matching the server's tile encoder. */
final class Lz4 {
    private Lz4() {}

    /** Decodes src[off, off+len) into dst; returns the decoded length. */
    static int decode(byte[] src, int off, int len, byte[] dst, int dstLen) {
        int ip = off, end = off + len, op = 0;
        while (ip < end) {
            int token = src[ip++] & 0xff;
            int lit = token >>> 4;
            if (lit == 15) {
                int b;
                do {
                    b = src[ip++] & 0xff;
                    lit += b;
                } while (b == 255);
            }
            if (op + lit > dstLen || ip + lit > end) throw new IllegalArgumentException("lz4: literals overrun");
            System.arraycopy(src, ip, dst, op, lit);
            ip += lit;
            op += lit;
            if (ip >= end) break;
            int offset = (src[ip] & 0xff) | (src[ip + 1] & 0xff) << 8;
            ip += 2;
            int ml = token & 15;
            if (ml == 15) {
                int b;
                do {
                    b = src[ip++] & 0xff;
                    ml += b;
                } while (b == 255);
            }
            ml += 4;
            if (offset == 0 || offset > op || op + ml > dstLen) throw new IllegalArgumentException("lz4: bad match");
            int from = op - offset;
            if (offset >= ml) {
                System.arraycopy(dst, from, dst, op, ml);
            } else {
                for (int i = 0; i < ml; i++) dst[op + i] = dst[from + i]; // overlapping run
            }
            op += ml;
        }
        return op;
    }
}
