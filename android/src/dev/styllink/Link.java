package dev.styllink;

import java.io.BufferedInputStream;
import java.io.DataInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.TimeUnit;

/**
 * Minimal WebSocket client for the styllink server, speaking the same
 * protocol as the web page. The UI thread only queues finished frames; a
 * writer thread puts each on the wire as its own packet (TCP_NODELAY, DSCP EF
 * so Wi-Fi sends it from the voice queue) and a reader thread answers the
 * server's pings.
 */
final class Link {
    interface Listener {
        void onLinkChanged();
        /** Capability message sent on every connect ("i..."). */
        String caps();
    }

    private final Listener listener;
    private static final class Session {
        final LinkedBlockingQueue<byte[]> out = new LinkedBlockingQueue<>();
        volatile boolean running = true;
        volatile Socket socket;
        volatile boolean connected;
        volatile long lastSendNanos;
        final String host, token;

        Session(String host, String token) { this.host = host; this.token = token; }
    }
    private volatile Session current;
    private Thread thread;

    volatile boolean connected;
    volatile double rttMs = -1;
    volatile String error = "";

    Link(Listener listener) {
        this.listener = listener;
    }

    synchronized void start(String host, String token) {
        stop();
        if (host.isEmpty()) {
            error = "no PC address set";
            listener.onLinkChanged();
            return;
        }
        Session session = new Session(host, token);
        current = session;
        thread = new Thread(() -> run(session), "styllink-link");
        thread.start();
    }

    synchronized void stop() {
        Session session = current;
        current = null;
        if (session != null) {
            session.running = false;
            session.connected = false;
            closeSocket(session);
        }
        if (thread != null) {
            thread.interrupt();
            thread = null;
        }
        connected = false;
        rttMs = -1;
        listener.onLinkChanged();
    }

    /** Queue a binary message (pen samples). Called on the UI thread. */
    void sendBinary(byte[] payload, int len) {
        Session session = current;
        if (session == null || !session.connected) return;
        session.out.offer(frame(0x2, payload, len));
        session.lastSendNanos = System.nanoTime();
    }

    void sendText(String s) {
        Session session = current;
        if (session == null || !session.connected) return;
        byte[] b = s.getBytes(StandardCharsets.UTF_8);
        session.out.offer(frame(0x1, b, b.length));
    }

    /** Client frames must be masked; the server rejects unmasked ones. */
    private static byte[] frame(int opcode, byte[] p, int len) {
        int hl = len < 126 ? 2 : 4;
        byte[] f = new byte[hl + 4 + len];
        f[0] = (byte) (0x80 | opcode);
        if (len < 126) {
            f[1] = (byte) (0x80 | len);
        } else {
            f[1] = (byte) (0x80 | 126);
            f[2] = (byte) (len >> 8);
            f[3] = (byte) len;
        }
        int m = ThreadLocalRandom.current().nextInt();
        for (int i = 0; i < 4; i++) f[hl + i] = (byte) (m >>> (24 - 8 * i));
        for (int i = 0; i < len; i++) f[hl + 4 + i] = (byte) (p[i] ^ f[hl + (i & 3)]);
        return f;
    }

    private static void closeSocket(Session session) {
        Socket s = session.socket;
        if (s != null) {
            try {
                s.close();
            } catch (IOException ignored) {
            }
        }
    }

    private void run(Session session) {
        long retry = 300;
        while (session.running) {
            try {
                session(session);
                retry = 300;
            } catch (Exception e) {
                if (current == session) error = e.getClass().getSimpleName() + (e.getMessage() != null ? ": " + e.getMessage() : "");
            }
            session.connected = false;
            synchronized (this) {
                if (current == session) {
                    connected = false;
                    rttMs = -1;
                    listener.onLinkChanged();
                }
            }
            if (!session.running) break;
            try {
                Thread.sleep(retry);
            } catch (InterruptedException e) {
                break;
            }
            retry = Math.min(retry * 2, 3000);
        }
    }

    private void session(Session session) throws IOException, InterruptedException {
        String host = session.host, token = session.token;
        int colon = host.lastIndexOf(':');
        String h = colon > 0 ? host.substring(0, colon) : host;
        int port = colon > 0 ? Integer.parseInt(host.substring(colon + 1)) : 8080;
        Socket s = new Socket();
        session.socket = s;
        Thread reader = null;
        try {
            if (!session.running) return;
            s.setSoTimeout(5000);
            s.setTcpNoDelay(true);
            s.setTrafficClass(0xB8); // DSCP EF: WMM voice access category on Wi-Fi
            s.connect(new InetSocketAddress(h, port), 3000);
            OutputStream os = s.getOutputStream();
            InputStream is = new BufferedInputStream(s.getInputStream(), 8192);
            String req = "GET /ws?t=" + URLEncoder.encode(token, "UTF-8") + " HTTP/1.1\r\n"
                    + "Host: " + host + "\r\n"
                    + "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                    + "Sec-WebSocket-Key: c3R5bGxpbmstYW5kcm9pZA==\r\nSec-WebSocket-Version: 13\r\n"
                    + "Origin: android-app://dev.styllink\r\n\r\n";
            os.write(req.getBytes(StandardCharsets.US_ASCII));
            String status = readStatus(is);
            if (!status.contains(" 101 ")) throw new IOException(status.isEmpty() ? "no reply" : status);

            s.setSoTimeout(0);
            synchronized (this) {
                if (!session.running || current != session) return;
                session.out.clear();
                session.connected = true;
                connected = true;
                error = "";
                listener.onLinkChanged();
                sendText(listener.caps());
            }

            reader = new Thread(() -> readLoop(session, s, is), "styllink-rx");
            reader.start();

            long lastPing = 0;
            while (session.running && !s.isClosed()) {
                byte[] f = session.out.poll(20, TimeUnit.MILLISECONDS);
                if (f != null) os.write(f);
                long now = System.nanoTime();
                // Keep the radio busy while the pen is idle, like the page does.
                if (now - session.lastSendNanos > 45_000_000L) {
                    byte[] k = {'k'};
                    os.write(frame(0x1, k, 1));
                    session.lastSendNanos = now;
                }
                if (now - lastPing > 1_000_000_000L) {
                    byte[] p = ("p" + now).getBytes(StandardCharsets.US_ASCII);
                    os.write(frame(0x1, p, p.length));
                    lastPing = now;
                }
            }
        } finally {
            session.connected = false;
            closeSocket(session);
            if (reader != null) reader.join(1000);
            session.socket = null;
        }
    }

    /** Read the HTTP response headers; return the status line. */
    private static String readStatus(InputStream is) throws IOException {
        StringBuilder sb = new StringBuilder();
        int matched = 0;
        while (matched < 4) {
            int c = is.read();
            if (c < 0) break;
            sb.append((char) c);
            matched = (c == (matched % 2 == 0 ? '\r' : '\n')) ? matched + 1 : (c == '\r' ? 1 : 0);
            if (sb.length() > 4096) break;
        }
        if (matched != 4) throw new IOException("incomplete HTTP response");
        int eol = sb.indexOf("\r\n");
        return eol >= 0 ? sb.substring(0, eol) : sb.toString();
    }

    private void readLoop(Session session, Socket s, InputStream is) {
        try {
            DataInputStream in = new DataInputStream(is);
            byte[] p = new byte[128];
            while (true) {
                int b0 = in.readUnsignedByte();
                int b1 = in.readUnsignedByte();
                int op = b0 & 0x0f;
                long len = b1 & 0x7f;
                if (len == 126) len = in.readUnsignedShort();
                else if (len == 127) len = in.readLong();
                if ((b1 & 0x80) != 0) throw new IOException("masked server frame");
                if (len < 0 || len > 65535) break;
                int n = (int) len;
                if (p.length < n) p = new byte[Math.max(n, p.length * 2)];
                in.readFully(p, 0, n);
                if (op == 0x8) break;
                if (op == 0x9) {
                    session.out.offer(frame(0xA, p, n));
                    continue;
                }
                if (op != 0x1 || n == 0) continue;
                char k = (char) p[0];
                if (k == 'b' || k == 's') {
                    session.out.offer(frame(0x1, p, n)); // server's link benchmark: echo
                } else if (k == 'p') {
                    try {
                        long sent = Long.parseLong(new String(p, 1, n - 1, StandardCharsets.US_ASCII));
                        if (current == session) {
                            rttMs = (System.nanoTime() - sent) / 1e6;
                            listener.onLinkChanged();
                        }
                    } catch (NumberFormatException ignored) {
                    }
                }
            }
        } catch (IOException ignored) {
        }
        try { s.close(); } catch (IOException ignored) {} // wakes this connection's writer
    }
}
