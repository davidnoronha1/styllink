package dev.styllink;

import android.content.Context;
import android.util.Log;
import android.view.Display;
import android.view.Surface;
import android.view.SurfaceHolder;
import android.view.SurfaceView;

import java.io.BufferedInputStream;
import java.io.DataInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;

/**
 * The PC screen, behind the pad. Opens /video next to the pen link, tells the
 * server what this tablet can show (display size and refresh rate, pixel
 * formats, tile encodings, H.264, USB or Wi-Fi) and renders what it picks.
 * One thread reads the socket and renders tiles itself; H.264 goes to
 * MediaCodec. Every shown frame is acknowledged: the server captures again
 * only when frames arrive, so nothing queues up on a slow link.
 */
final class ScreenView extends SurfaceView implements SurfaceHolder.Callback {
    interface Listener {
        /** Stream size, from the network thread. */
        void onScreenFormat(int width, int height);
        void onScreenStatus(String status);
    }

    static final class Options {
        boolean frontBuffer = true;
        boolean preferH264 = false;
    }

    private static final byte[] KEYFRAME_REQUEST = {'k'};
    private final Listener listener;
    private Surface surface;
    private int surfaceW, surfaceH;
    private Thread thread;
    private volatile Socket socket;
    private volatile boolean running;
    private String host = "", token = "";
    private Options options = new Options();
    volatile String status = "";

    ScreenView(Context c, Listener listener) {
        super(c);
        this.listener = listener;
        getHolder().addCallback(this);
    }

    // ------------------------------------------------------------ lifecycle

    void start(String host, String token, Options options) {
        stop();
        if (host.isEmpty()) return;
        synchronized (this) {
            this.host = host;
            this.token = token;
            this.options = options;
            running = true;
            thread = new Thread(this::run, "styllink-screen");
            thread.setPriority(Thread.MAX_PRIORITY);
            thread.start();
        }
    }

    /** Never holds the lock while joining: the thread may be waiting on it. */
    void stop() {
        Thread t;
        synchronized (this) {
            running = false;
            t = thread;
            thread = null;
            notifyAll();
        }
        Socket s = socket;
        if (s != null) {
            try {
                s.close();
            } catch (IOException ignored) {
            }
        }
        if (t != null) {
            t.interrupt();
            try {
                t.join(1000);
            } catch (InterruptedException ignored) {
                Thread.currentThread().interrupt();
            }
        }
    }

    /**
     * The surface's buffer is exactly the stream size; the display hardware
     * scales it to the view for free, and tiles map 1:1 onto pixels.
     */
    void setStreamSize(int w, int h) {
        getHolder().setFixedSize(w, h);
    }

    @Override
    public void surfaceCreated(SurfaceHolder h) {
        synchronized (this) {
            surface = h.getSurface();
            notifyAll();
        }
    }

    @Override
    public void surfaceChanged(SurfaceHolder h, int format, int w, int hgt) {
        synchronized (this) {
            surface = h.getSurface();
            surfaceW = w;
            surfaceH = hgt;
            notifyAll();
        }
    }

    @Override
    public void surfaceDestroyed(SurfaceHolder h) {
        // The renderer must let go of the surface before this returns.
        boolean wasRunning = running;
        String hst = host, tok = token;
        Options o = options;
        stop();
        synchronized (this) {
            surface = null;
        }
        if (wasRunning) post(() -> start(hst, tok, o)); // resumes when a new surface comes
    }

    private synchronized Surface awaitSurface(int w, int h) throws InterruptedException {
        long deadline = System.nanoTime() + 500_000_000L;
        while (running && (surface == null || !surface.isValid()
                || (w > 0 && (surfaceW != w || surfaceH != h) && System.nanoTime() < deadline))) wait(20);
        return running ? surface : null;
    }

    private void setStatus(String s) {
        status = s;
        listener.onScreenStatus(s);
    }

    // ------------------------------------------------------------ session

    private void run() {
        long retry = 300;
        while (running) {
            try {
                session();
                retry = 300;
            } catch (Exception e) {
                if (running) setStatus("screen: " + e.getClass().getSimpleName() + (e.getMessage() != null ? ": " + e.getMessage() : ""));
            }
            if (!running) break;
            try {
                Thread.sleep(retry);
            } catch (InterruptedException e) {
                break;
            }
            retry = Math.min(retry * 2, 3000);
        }
    }

    /** What this tablet can show, as "key=value;..." for the server. */
    private String hello() {
        Display d = getDisplay();
        int w = 0, h = 0;
        float hz = 60;
        if (d != null) {
            Display.Mode mode = d.getMode();
            w = mode.getPhysicalWidth();
            h = mode.getPhysicalHeight();
            if (getResources().getConfiguration().orientation == android.content.res.Configuration.ORIENTATION_PORTRAIT
                    ? w > h : w < h) {
                int t = w;
                w = h;
                h = t;
            }
            for (Display.Mode m : d.getSupportedModes()) {
                if (m.getPhysicalWidth() == mode.getPhysicalWidth() && m.getPhysicalHeight() == mode.getPhysicalHeight())
                    hz = Math.max(hz, m.getRefreshRate());
            }
        }
        String hp = host.substring(0, Math.max(0, host.lastIndexOf(':')));
        boolean usb = hp.equals("localhost") || hp.equals("127.0.0.1") || hp.equals("[::1]");
        return "hv=1;w=" + w + ";h=" + h + ";hz=" + Math.round(hz)
                + ";pix=bgrx,rgb565;enc=lz4,raw;codec=tiles" + (AvcRenderer.available() ? ",h264" : "")
                + ";link=" + (usb ? "usb" : "wifi") + (options.preferH264 ? ";prefer=h264" : "");
    }

    private void session() throws Exception {
        int colon = host.lastIndexOf(':');
        String h = colon > 0 ? host.substring(0, colon) : host;
        int port = colon > 0 ? Integer.parseInt(host.substring(colon + 1)) : 8080;
        Surface surf = awaitSurface(0, 0);
        if (surf == null) return;
        Socket s = new Socket();
        socket = s;
        TileRenderer tiles = null;
        AvcRenderer avc = null;
        try {
            s.setTcpNoDelay(true);
            s.setTrafficClass(0x88); // DSCP AF41: the Wi-Fi video queue, below the pen's voice queue
            s.setSoTimeout(5000);
            s.connect(new InetSocketAddress(h, port), 3000);
            OutputStream os = s.getOutputStream();
            InputStream is = new BufferedInputStream(s.getInputStream(), 65536);
            os.write(("GET /video?t=" + URLEncoder.encode(token, "UTF-8") + " HTTP/1.1\r\nHost: " + host
                    + "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                    + "Sec-WebSocket-Key: c3R5bGxpbmstc2NyZWVu\r\nSec-WebSocket-Version: 13\r\n"
                    + "Origin: android-app://dev.styllink\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
            String statusLine = readStatus(is);
            if (!statusLine.contains(" 101 ")) throw new IOException(statusLine);
            s.setSoTimeout(0);
            WebSocketWriter writer = new WebSocketWriter(os);
            writer.send(0x1, hello().getBytes(StandardCharsets.US_ASCII));

            DataInputStream in = new DataInputStream(is);
            byte[] buf = new byte[1 << 16];
            byte[] pixels = new byte[1 << 16];
            Map<String, String> cfg = new HashMap<>();
            boolean h264 = false;
            int frames = 0;
            final boolean trace = Log.isLoggable("StylLinkVideo", Log.DEBUG);
            int tileFrames = 0, tileRects = 0;
            long decodeNs = 0, uploadNs = 0, presentNs = 0, maxPresentNs = 0;
            long since = System.nanoTime();
            while (running) {
                int b0 = in.readUnsignedByte(), b1 = in.readUnsignedByte();
                long len = b1 & 0x7f;
                if (len == 126) len = in.readUnsignedShort();
                else if (len == 127) len = in.readLong();
                if (len < 0 || len > (64 << 20)) throw new IOException("frame too large");
                if (buf.length < len) buf = new byte[(int) Math.max(len, buf.length * 2L)];
                in.readFully(buf, 0, (int) len);
                int n = (int) len, op = b0 & 0x0f;
                if (op == 0x8) break;
                if (op == 0x9) {
                    writer.send(0xA, buf, 0, n);
                    continue;
                }
                if (op == 0x1 && n > 0) {
                    String text = new String(buf, 0, n, StandardCharsets.UTF_8);
                    if (text.charAt(0) == 'e') throw new IOException(text.substring(1));
                    if (text.charAt(0) != 'c') continue;
                    cfg.clear();
                    for (String kv : text.substring(1).split(";")) {
                        int eq = kv.indexOf('=');
                        if (eq > 0) cfg.put(kv.substring(0, eq), kv.substring(eq + 1));
                    }
                    int w = Integer.parseInt(cfg.get("w")), hh = Integer.parseInt(cfg.get("h"));
                    h264 = "h264".equals(cfg.get("codec"));
                    boolean is565 = "rgb565".equals(cfg.get("pix"));
                    listener.onScreenFormat(w, hh);
                    surf = awaitSurface(w, hh);
                    if (surf == null) return;
                    if (h264) {
                        if (tiles != null) {
                            tiles.release();
                            tiles = null;
                        }
                        if (avc == null || !avc.matches(w, hh)) {
                            if (avc != null) avc.release();
                            avc = new AvcRenderer(surf, w, hh, writer::ack);
                        }
                    } else {
                        if (avc != null) {
                            avc.release();
                            avc = null;
                        }
                        if (tiles == null || !tiles.matches(w, hh, is565)) {
                            if (tiles != null) tiles.release();
                            tiles = new TileRenderer(surf, w, hh, is565, options.frontBuffer);
                            if (trace) Log.d("StylLinkVideo", "renderer=" + (tiles.frontBuffered() ? "front" : "swap")
                                    + " size=" + w + "x" + hh + " pix=" + cfg.get("pix"));
                        }
                    }
                    setStatus(String.format(java.util.Locale.ROOT, "screen: %dx%d %s%s",
                            w, hh, h264 ? "H.264 · " + avc.name : cfg.get("pix") + " " + cfg.get("enc"),
                            !h264 && tiles.frontBuffered() ? " · front buffer" : ""));
                    continue;
                }
                if (op != 0x2 || n < 16) continue;
                if (buf[0] == 'T' && tiles != null && n >= 24) {
                    int flags = buf[1], enc = buf[2];
                    int id = le32(buf, 4);
                    int x = le16(buf, 12), y = le16(buf, 14), w = le16(buf, 16), hh = le16(buf, 18);
                    int raw = le32(buf, 20);
                    tiles.validateRect(x, y, w, hh, raw);
                    long tileStart = trace ? System.nanoTime() : 0;
                    byte[] decoded;
                    int decodedOffset;
                    if (enc == 1) {
                        if (pixels.length < raw) pixels = new byte[Math.max(raw, pixels.length * 2)];
                        if (Lz4.decode(buf, 24, n - 24, pixels, raw) != raw)
                            throw new IOException("incomplete tile");
                        decoded = pixels;
                        decodedOffset = 0;
                    } else {
                        if (enc != 0 || raw != n - 24) throw new IOException("invalid raw tile");
                        decoded = buf;
                        decodedOffset = 24;
                    }
                    long uploadStart = trace ? System.nanoTime() : 0;
                    if (trace) decodeNs += uploadStart - tileStart;
                    tiles.rect(x, y, w, hh, decoded, decodedOffset, raw);
                    long uploaded = trace ? System.nanoTime() : 0;
                    if (trace) {
                        uploadNs += uploaded - uploadStart;
                        tileRects++;
                    }
                    if ((flags & 1) != 0) {
                        tiles.present();
                        if (trace) {
                            long presented = System.nanoTime() - uploaded;
                            presentNs += presented;
                            maxPresentNs = Math.max(maxPresentNs, presented);
                            tileFrames++;
                        }
                        writer.ack(id);
                        frames++;
                    }
                } else if (buf[0] == 'H' && avc != null) {
                    int flags = buf[1];
                    if (!avc.feed(buf, 16, n - 16, le32(buf, 4), (flags & 2) != 0, (flags & 4) != 0)) {
                        writer.send(0x1, KEYFRAME_REQUEST); // decoder stalled: start over from a key frame
                    }
                    if ((flags & 4) == 0) frames++;
                }
                long now = System.nanoTime();
                if (now - since > 2_000_000_000L) {
                    if (trace && tileFrames > 0) {
                        // CPU calls only: upload may wait for the driver, and
                        // present/ack do not measure scanout or visible pixels.
                        Log.d("StylLinkVideo", String.format(java.util.Locale.ROOT,
                                "tiles frames=%d rects=%d decode=%.3f upload=%.3f present=%.3f present_max=%.3f ms/frame",
                                tileFrames, tileRects, decodeNs / 1e6 / tileFrames,
                                uploadNs / 1e6 / tileFrames, presentNs / 1e6 / tileFrames, maxPresentNs / 1e6));
                        tileFrames = tileRects = 0;
                        decodeNs = uploadNs = presentNs = maxPresentNs = 0;
                    }
                    listener.onScreenStatus(status + String.format(java.util.Locale.ROOT, " · %.0f fps", frames * 1e9 / (now - since)));
                    frames = 0;
                    since = now;
                }
            }
        } finally {
            if (tiles != null) tiles.release();
            if (avc != null) avc.release();
            try {
                s.close();
            } catch (IOException ignored) {
            }
            socket = null;
        }
    }

    private static String readStatus(InputStream is) throws IOException {
        StringBuilder sb = new StringBuilder();
        int matched = 0;
        while (matched < 4) {
            int c = is.read();
            if (c < 0) throw new IOException("incomplete HTTP response");
            sb.append((char) c);
            matched = (c == (matched % 2 == 0 ? '\r' : '\n')) ? matched + 1 : (c == '\r' ? 1 : 0);
            if (sb.length() > 4096) throw new IOException("bad HTTP response");
        }
        int eol = sb.indexOf("\r\n");
        return eol >= 0 ? sb.substring(0, eol) : sb.toString();
    }

    private static int le16(byte[] b, int i) {
        return (b[i] & 0xff) | (b[i + 1] & 0xff) << 8;
    }

    private static int le32(byte[] b, int i) {
        return (b[i] & 0xff) | (b[i + 1] & 0xff) << 8 | (b[i + 2] & 0xff) << 16 | (b[i + 3] & 0xff) << 24;
    }
}
