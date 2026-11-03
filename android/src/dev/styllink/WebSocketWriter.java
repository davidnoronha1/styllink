package dev.styllink;

import java.io.IOException;
import java.io.OutputStream;
import java.util.concurrent.ThreadLocalRandom;

/** Reuses masked client-frame storage; serializes video-reader and decoder writes. */
final class WebSocketWriter {
    private final OutputStream out;
    private byte[] frame = new byte[256];
    private final byte[] ack = new byte[11]; // 'a' plus an unsigned 32-bit frame id

    WebSocketWriter(OutputStream out) {
        this.out = out;
    }

    void send(int opcode, byte[] payload) throws IOException {
        send(opcode, payload, 0, payload.length);
    }

    synchronized void send(int opcode, byte[] payload, int offset, int len) throws IOException {
        if (offset < 0 || len < 0 || len > 65535 || offset > payload.length - len)
            throw new IllegalArgumentException("invalid WebSocket payload");
        int header = len < 126 ? 2 : 4;
        int size = header + 4 + len;
        if (frame.length < size) frame = new byte[Math.max(size, frame.length * 2)];
        frame[0] = (byte) (0x80 | opcode);
        if (len < 126) {
            frame[1] = (byte) (0x80 | len);
        } else {
            frame[1] = (byte) (0x80 | 126);
            frame[2] = (byte) (len >>> 8);
            frame[3] = (byte) len;
        }
        int mask = ThreadLocalRandom.current().nextInt();
        for (int i = 0; i < 4; i++) frame[header + i] = (byte) (mask >>> (24 - 8 * i));
        for (int i = 0; i < len; i++) frame[header + 4 + i] = (byte) (payload[offset + i] ^ frame[header + (i & 3)]);
        out.write(frame, 0, size);
    }

    /** Decoder callbacks cannot throw; a closed socket is handled by the reader. */
    synchronized void ack(int frameId) {
        long id = frameId & 0xffffffffL;
        int start = ack.length;
        do {
            ack[--start] = (byte) ('0' + id % 10);
            id /= 10;
        } while (id != 0);
        ack[--start] = 'a';
        try {
            send(0x1, ack, start, ack.length - start);
        } catch (IOException ignored) {
        }
    }
}
