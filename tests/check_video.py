#!/usr/bin/env python3
"""End-to-end check of the remote screen on a virtual X server.

Starts Xvfb and the server, connects to /video like a tablet, draws on the
X screen and checks that the picture rebuilt from the stream matches the
screen pixel for pixel. Also reports draw-to-receive latency per update.

Needs Xvfb, python-xlib and lz4 (pip install python-xlib lz4); the H.264
case also needs ffmpeg with libx264.
  python3 tests/check_video.py [path/to/styllink]
"""

import base64
import os
import socket
import struct
import subprocess
import sys
import time

import lz4.block
from Xlib import X, display

W, H = 640, 480
DISPLAY = ":77"
PORT = 18931
TOKEN = "videotest"


def ws_connect(path):
    s = socket.create_connection(("127.0.0.1", PORT), timeout=5)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall(
        f"GET {path} HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n".encode()
    )
    head = b""
    while b"\r\n\r\n" not in head:
        head += s.recv(1)
    assert b" 101 " in head.split(b"\r\n")[0], head
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return s


def ws_send(s, text):
    data = text.encode()
    mask = os.urandom(4)
    hdr = bytes([0x81])
    hdr += bytes([0x80 | len(data)]) if len(data) < 126 else bytes([0x80 | 126]) + struct.pack(">H", len(data))
    s.sendall(hdr + mask + bytes(b ^ mask[i & 3] for i, b in enumerate(data)))


def recv_exact(s, n):
    b = bytearray()
    while len(b) < n:
        chunk = s.recv(n - len(b))
        if not chunk:
            raise EOFError
        b += chunk
    return bytes(b)


def ws_recv(s):
    b0, b1 = recv_exact(s, 2)
    n = b1 & 0x7F
    if n == 126:
        n = struct.unpack(">H", recv_exact(s, 2))[0]
    elif n == 127:
        n = struct.unpack(">Q", recv_exact(s, 8))[0]
    return b0 & 0x0F, recv_exact(s, n)


class Screen:
    """Rebuilds the stream into an RGB framebuffer, like a tablet would."""

    def __init__(self, sock):
        self.sock = sock
        self.cfg = {}
        self.fb = None
        self.au = []

    def config(self, text):
        self.cfg = dict(kv.split("=") for kv in text[1:].split(";"))
        self.w, self.h = int(self.cfg["w"]), int(self.cfg["h"])
        if self.fb is None:
            self.fb = bytearray(self.w * self.h * 3)

    def frame(self, timeout=3.0):
        """Reads messages until one frame is complete; returns its stats."""
        self.sock.settimeout(timeout)
        rects = 0
        nbytes = 0
        while True:
            op, p = ws_recv(self.sock)
            if op == 1:
                if p[:1] == b"c":
                    self.config(p.decode())
                elif p[:1] == b"e":
                    raise RuntimeError(p.decode())
                continue
            nbytes += len(p)
            if p[:1] == b"H":
                fid = struct.unpack_from("<I", p, 4)[0]
                self.au.append(p[16:])
                if p[1] & 4:  # duplicate pushing the encoder: no ack, keep reading
                    continue
                ws_send(self.sock, f"a{fid}")
                return {"rects": 0, "bytes": nbytes, "key": bool(p[1] & 2)}
            assert p[:1] == b"T", p[:1]
            flags, enc, pix = p[1], p[2], p[3]
            fid, _ts, x, y, w, h, raw_len = struct.unpack_from("<IIHHHHI", p, 4)
            data = p[24:]
            if enc == 1:
                data = lz4.block.decompress(data, uncompressed_size=raw_len)
            assert len(data) == raw_len, (len(data), raw_len)
            bpp = 2 if pix == 1 else 4
            for row in range(h):
                line = data[row * w * bpp : (row + 1) * w * bpp]
                o = ((y + row) * self.w + x) * 3
                if bpp == 4:
                    rgb = bytearray(w * 3)
                    rgb[0::3], rgb[1::3], rgb[2::3] = line[2::4], line[1::4], line[0::4]
                else:
                    rgb = bytearray(w * 3)
                    for i in range(w):
                        v = line[2 * i] | line[2 * i + 1] << 8
                        rgb[3 * i] = (v >> 11) << 3
                        rgb[3 * i + 1] = ((v >> 5) & 63) << 2
                        rgb[3 * i + 2] = (v & 31) << 3
                self.fb[o : o + w * 3] = rgb
            rects += 1
            if flags & 1:
                ws_send(self.sock, f"a{fid}")
                return {"rects": rects, "bytes": nbytes, "key": bool(flags & 2)}


def x_rgb(d, scale, pix):
    """The X screen as the stream should show it."""
    raw = d.screen().root.get_image(0, 0, W, H, X.ZPixmap, 0xFFFFFFFF).data
    sw, sh = W // scale, H // scale
    out = bytearray(sw * sh * 3)
    for y in range(sh):
        for x in range(sw):
            if scale == 1:
                o = (y * W + x) * 4
                b, g, r = raw[o], raw[o + 1], raw[o + 2]
            else:
                px = [raw[((2 * y + dy) * W + 2 * x + dx) * 4 : ((2 * y + dy) * W + 2 * x + dx) * 4 + 3] for dy in (0, 1) for dx in (0, 1)]
                b, g, r = (sum(p[c] for p in px) // 4 for c in range(3))
            if pix == "rgb565":
                r, g, b = r & 0xF8, g & 0xFC, b & 0xF8
            o = (y * sw + x) * 3
            out[o : o + 3] = bytes((r, g, b))
    return out


def close_enough(a, b, tol):
    return all(abs(p - q) <= tol for p, q in zip(a, b))


def run_case(server, name, hello, extra_args, check_scale, pix, tol=0):
    args = [server, "--no-uinput", "--port", str(PORT), "--token", TOKEN, "--web-url", "",
            "--region", f"0,0,{W},{H}", "--desktop", f"{W},{H}"] + extra_args
    env = dict(os.environ, DISPLAY=DISPLAY)
    srv = subprocess.Popen(args, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        for _ in range(50):
            try:
                socket.create_connection(("127.0.0.1", PORT), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.1)
        d = display.Display(DISPLAY)
        root = d.screen().root
        gc = root.create_gc(foreground=0x203040)
        root.fill_rectangle(gc, 0, 0, W, H)
        d.sync()

        s = ws_connect(f"/video?t={TOKEN}")
        ws_send(s, "h" + hello)
        scr = Screen(s)
        first = scr.frame()
        assert first["key"], "first frame must be a key frame"
        print(f"  {name}: {scr.cfg}")
        if "--video-source" in extra_args:
            for _ in range(10):
                scr.frame()
            print(f"  {name}: received {len(scr.au)} access units from the capture command")
            return
        if scr.cfg["codec"] == "h264":
            lat = []
            for i in range(10):
                gc.change(foreground=0x10000 * (i * 20) + 0x80)
                t = time.perf_counter()
                root.fill_rectangle(gc, 40 + i * 10, 40, 60, 60)
                d.sync()
                scr.frame()
                lat.append((time.perf_counter() - t) * 1000)
            path = "/tmp/claude-video-check.h264"
            with open(path, "wb") as f:
                f.write(b"".join(scr.au))
            dec = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-fps_mode", "passthrough", "-f", "rawvideo",
                                  "-pix_fmt", "rgb24", "-"], capture_output=True)
            # Raw streams carry no timestamps; only decoder complaints count.
            bad = [l for l in dec.stderr.decode().splitlines() if l.startswith("[h264")]
            assert dec.returncode == 0 and not bad, bad
            frames = len(dec.stdout) // (W * H * 3)
            assert frames == len(scr.au), (frames, len(scr.au))  # every access unit is one picture
            last = dec.stdout[-W * H * 3:]
            want = x_rgb(d, 1, "bgrx")
            err = sum(abs(p - q) for p, q in zip(last, want)) / len(want)
            assert err < 3, f"last decoded picture differs from the screen (mean error {err:.1f})"
            print(f"  {name}: {len(scr.au)} access units decode cleanly, last matches the screen; "
                  f"draw->received median {sorted(lat)[len(lat) // 2]:.1f} ms, max {max(lat):.1f} ms")
            return
        assert close_enough(scr.fb, x_rgb(d, check_scale, pix), tol), "key frame differs from the screen"

        lat, sizes = [], []
        for i in range(30):
            if i % 2:
                time.sleep(0.02)  # every other stroke starts from an idle link
            gc.change(foreground=(i * 0x0A1B2C) & 0xFFFFFF)
            t = time.perf_counter()
            root.fill_rectangle(gc, (i * 37) % (W - 40), (i * 23) % (H - 40), 3 + i % 7, 30)  # a pen-sized stroke
            d.sync()
            st = scr.frame()
            lat.append((time.perf_counter() - t) * 1000)
            sizes.append(st["bytes"])
        # A big change: most of the screen.
        gc.change(foreground=0xC0C0C0)
        t = time.perf_counter()
        root.fill_rectangle(gc, 10, 10, W - 20, H - 20)
        d.sync()
        big = scr.frame()["bytes"]
        big_ms = (time.perf_counter() - t) * 1000
        while not close_enough(scr.fb, x_rgb(d, check_scale, pix), tol):
            big += scr.frame()["bytes"]
        idle, busy = sorted(lat[1::2]), sorted(lat[0::2])
        print(f"  {name}: strokes {sorted(sizes)[len(sizes) // 2]} B/frame, draw->received median "
              f"{idle[len(idle) // 2]:.2f} ms after idle, {busy[len(busy) // 2]:.1f} ms back-to-back, max {max(lat):.1f} ms; full screen {big} B in {big_ms:.1f} ms; picture matches")
        s.close()
    finally:
        srv.terminate()
        err = srv.communicate(timeout=5)[1].decode()
        if "panic" in err or "error" in err.lower():
            print(err)


def main():
    server = sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/styllink"
    xvfb = subprocess.Popen(["Xvfb", DISPLAY, "-screen", "0", f"{W}x{H}x24", "-nolisten", "tcp"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(1)
        caps = f"w={W};h={H};hz=120;pix=bgrx,rgb565;enc=lz4,raw;codec=tiles,h264"
        run_case(server, "usb bgrx lz4", caps + ";link=usb", [], 1, "bgrx")
        run_case(server, "wifi rgb565 lz4", caps + ";link=wifi", [], 1, "rgb565")
        run_case(server, "raw", caps + ";link=usb", ["--video-enc", "raw"], 1, "bgrx")
        run_case(server, "half size", f"w={W // 2};h={H // 2};hz=60;pix=bgrx;enc=lz4;codec=tiles;link=usb",
                 ["--video-scale", "2"], 2, "bgrx", tol=2)
        run_case(server, "h264 (x264 via ffmpeg)", caps + ";link=wifi", ["--video-codec", "h264"], 1, "bgrx")
        if b"x11grab" in subprocess.run(["ffmpeg", "-hide_banner", "-devices"], capture_output=True).stdout:
            source = ("ffmpeg -hide_banner -loglevel error -f x11grab -framerate {fps} -video_size {w}x{h} "
                      "-i " + DISPLAY + "+{x},{y} -c:v libx264 -preset ultrafast -tune zerolatency "
                      "-x264-params aud=1 -pix_fmt yuv420p -f h264 -avioflags direct -")
            run_case(server, "external capture", caps + ";hz=30", ["--video-source", source], 1, "bgrx")
        print("video check passed")
    finally:
        xvfb.terminate()


if __name__ == "__main__":
    main()
