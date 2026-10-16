# How StylLink Works

StylLink turns an Android tablet or browser into a high-performance, low-latency drawing tablet for Linux. It receives high-frequency stylus samples over WebSocket and translates them into native Linux tablet events via `/dev/uinput`. In the other direction it streams the mapped part of the desktop to the tablet, so the pen draws on the picture of the PC screen.

```text
Stylus on Tablet (120–240 Hz)
       │
       ▼
Android App / Web (PointerEvents & Coalesced History)
       │
       ▼  [WebSocket: Binary Frames, TCP_NODELAY, DSCP Voice QoS]
Linux Server (Single-Threaded Zig, Epoll, Zero Allocation)
       │
       ├─► Playout Buffer (Jitter absorption & catchup smoothing)
       ├─► Event Pacing Ring (evdev chunking, Anti-SYN_DROPPED)
       ▼
  /dev/uinput ("StylLink Pen" virtual USB tablet)
       │
       ▼
X11 / Wayland / libinput ──► Linux Applications (GIMP, Krita, Inkscape, etc.)
```

---

## Connection Details

StylLink supports two connection channels: **USB (wired)** and **Wi-Fi (wireless)**.

### 1. Wired USB Connection (Lowest Latency & Jitter)
- Uses Android Debug Bridge (ADB) reverse port forwarding:
  ```sh
  adb reverse tcp:8080 tcp:8080
  ```
- Traffic routes directly through the USB cable to `http://localhost:8080` without passing through a Wi-Fi router.
- When `run.sh` detects a connected ADB device, it automatically establishes the reverse tunnel and presents the USB connection QR code first.

### 2. Wireless LAN Connection
- Connects directly to the server's local network IP on port 8080.
- StylLink automatically determines the host's LAN IP address by querying the routing table (using a connectionless UDP socket probe) and renders an ANSI QR code in the terminal.

### 3. Connection URIs & Authentication
- **Authentication**: A 48-bit cryptographically secure hex token is generated at startup (stored in `.styllink-token`). Connections must supply this token via query parameter `?t=<token>` or HTTP 403 Forbidden is returned.
- **Android App**: Opens via custom URI scheme:
  ```text
  styllink://connect?h=<host>:<port>&t=<token>
  ```
- **Hosted Web App (Chrome / Web)**:
  ```text
  https://styllink.vercel.app#h=<host>:<port>&t=<token>
  ```
  The hosted HTTPS frontend provides a **Secure Context**, which modern browsers require to grant access to high-rate `pointerrawupdate` and `getCoalescedEvents()` APIs. Connection credentials are passed through the URL hash fragment (`#`), ensuring host parameters never leak to the remote web hosting provider.
- **Local Fallback**: Served directly from the embedded binary at `http://<lan-ip>:<port>/?t=<token>`.

---

## Wire Protocol & Sample Packet

StylLink communicates using lightweight binary WebSocket frames (opcode `0x2`). Communication is optimized for zero-copy parsing and minimal bandwidth.

### Message Payload Layout

```text
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                 Client Send Timestamp (u32, 0.1 ms)           |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|       X (u16, Little-Endian)  |       Y (u16, Little-Endian)  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|    Pressure (u16, Little-End) |   Tilt X (i8) |   Tilt Y (i8) |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|   Flags (u8)  | Reserved (u8) | ... optional next sample ...  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

1. **4-Byte Header**: `u32` monotonic timestamp from the client in 0.1 ms units (derived from `performance.now()` or Android clock). Used to compute uplink transmission variation and network jitter independently of clock differences between devices.
2. **Batch of 10-Byte Samples**:
   - `x`, `y` (`u16`, 0–65535): Normalized position within the mapped region.
   - `pressure` (`u16`, 0–65535): Normalized stylus tip force.
   - `tiltX`, `tiltY` (`i8`, -90° to +90°): Stylus tilt angles.
   - `flags` (`u8` bitmask):
     - Bit 0 (`0x01`): `F_IN_RANGE` (stylus hovering in proximity).
     - Bit 1 (`0x02`): `F_TOUCH` (stylus tip in physical contact).
     - Bit 2 (`0x04`): `F_BARREL` (stylus side / barrel button pressed).
     - Bit 3 (`0x08`): `F_ERASER` (eraser tip or inverted pen tail).
   - `age` (`u8`): Sample age in 500 µs units indicating how long the sample waited in the client buffer before transmission, distinguishing browser/app rendering delay from network delay.

---

## Linux Input Subsystem (`/dev/uinput`)

StylLink creates a virtual USB graphics tablet device via `/dev/uinput`:

### 1. Virtual Device Registration
- **Identity**: Emulates a USB device (`BUS_USB`, Vendor `0x1701`, Product `0x5713`, named `"StylLink Pen"`).
- **Direct Input Surface (`INPUT_PROP_DIRECT`)**: Tells the Linux kernel and window compositor (X11 / Wayland) that input coordinates map directly to screen space rather than relative mouse offsets.
- **Axes & Resolution**:
  - `ABS_X` / `ABS_Y`: Range `0..65535`. Scaled to match physical dimensions (~300 mm width, aspect ratio matched to screen dimensions) so libinput correctly computes aspect ratio and velocity.
  - `ABS_PRESSURE`: Range `0..4095`.
  - `ABS_TILT_X` / `ABS_TILT_Y`: Range `-90..90` degrees with resolution 57 units/radian.
  - Key bits: `BTN_TOOL_PEN`, `BTN_TOOL_RUBBER`, `BTN_TOUCH`, and `BTN_STYLUS`.

### 2. Desktop Sub-Region Mapping
Physical tablets typically map across all connected displays. StylLink supports mapping the tablet surface onto a single monitor or specific desktop rectangle:
- `--region X,Y,W,H`: The target screen rectangle (e.g. `1920,0,1920,1080` for a second 1080p monitor).
- `--desktop W,H`: The full desktop geometry across all monitors.
- StylLink performs precise linear scaling on incoming coordinates before injecting them into the kernel:
  $$\text{GlobalAxis} = \frac{\text{Offset} \times 65535 + \text{LocalCoord} \times \text{RegionSpan}}{\text{DesktopTotal}}$$

### 3. Circumventing `libinput` Quirks
Standard Linux tablet input stacks (primarily `libinput`) have hardcoded behaviors that are problematic for network tablets. StylLink solves these at the driver level:

- **Cancelling the 4-Frame Moving Average Filter (`--unsmooth`)**:
  - `libinput` applies a moving-average filter across the last 4 tablet frames, which rounds sharp corners and introduces lag during fast handwriting.
  - StylLink emits each sample across $N$ duplicate frames (default `4`). Consecutive frames alternate coordinate values by 1 device unit (wobble `ax ^ (r & 1)`, less than 0.03 px), preventing the kernel from discarding identical values.
  - This forces the 4-frame moving average to evaluate to the exact sample position immediately. Pressure and buttons update only on the final frame so stroke contact lands and lifts precisely.
- **Lifting Contact Pressure Floor**:
  - `libinput` ignores `BTN_TOUCH` on tablets equipped with pressure axes and determines touch solely from pressure (triggering down at ~5% and up at ~1%).
  - Very light brushstrokes would be ignored. StylLink lifts all contact pressures into $[6\%, 100\%]$ (`floor = PRESSURE_MAX * 6 / 100`), guaranteeing that whenever the stylus touches the glass, ink flows on Linux.
- **Zero-Pressure Proximity Entry**:
  - `libinput` samples the pressure when the pen enters hover proximity (`in_range`) and treats that value as the baseline zero-offset. If a pen enters proximity with non-zero pressure, strokes will be thinned or swallowed.
  - StylLink always injects an initial entry event at `ABS_PRESSURE = 0` before any contact events are delivered.

---

## Performance & Latency Optimizations

### 1. Network Optimizations
- **TCP Nagle Bypass (`TCP_NODELAY`)**: Disables Nagle buffering to ensure every WebSocket frame and ping is transmitted immediately without batching delay.
- **Immediate ACK Re-arming (`TCP_QUICKACK`)**: Re-arms `TCP_QUICKACK` after every socket read. This prevents the Linux TCP stack from delaying ACKs (up to 40 ms), which would otherwise cause the tablet's TCP sender window to stall and bunch samples.
- **Wi-Fi QoS Voice Priority (`IP_TOS = 0xb8` / DSCP EF)**: Sets DSCP Expedited Forwarding on outgoing packets. On Wi-Fi networks supporting WMM (802.11e QoS), this maps packets and ACKs into the highest-priority Voice Access Category (`AC_VO`) queue, prioritizing StylLink over regular background traffic.
- **Bufferbloat Prevention (`SO_RCVBUF` / `SO_SNDBUF`)**: Clamps TCP socket receive and send buffers to 64 KB, preventing mobile Wi-Fi routers from buffering megabytes of stale packets during sudden wireless packet loss.
- **Low-Latency Wi-Fi Lock**: The Android app acquires `WIFI_MODE_FULL_LOW_LATENCY` from the Android Wi-Fi manager while active, preventing the mobile Wi-Fi chip from entering power-saving sleep states between sample deliveries.

### 2. Zero-Allocation Hot Path & Event Loops
- **Zero Allocations**: All event queues, client buffers, and stat rings are pre-allocated statically. No dynamic allocations occur during streaming pen input.
- **Vectorized 64-Bit WebSocket Frame Unmasking**: Converts the 4-byte client mask into a 64-bit word (`m32 | (m32 << 32)`) and XORs 8 bytes per CPU instruction on the hot path, followed by a scalar remainder loop.
- **Zero-Memmove Socket Cursor**: Replaces continuous `memmove`/`copyForwards` shifts with a moving read cursor, only compacting buffer remnants when remaining capacity is below 4 KB.
- **Event Loop & Latency Modes**:
  - `epoll`: Event-driven sleep via `epoll_wait` with negligible CPU usage while idle.
  - `--busy`: Enables busy-polling (non-blocking event loop) for zero-latency wakeups without context-switching sleep states. In busy mode, playout timerfd syscalls (`timerfd_settime`) are bypassed, checking timestamps directly in userspace.
  - `--realtime`: Attempts to elevate process priority to `SCHED_FIFO` (priority 50) or `nice -20` to prevent CPU scheduling jitter under desktop load.

### 3. Anti-Buffer Overflow Pacing (Anti-SYN_DROPPED)
- The Linux kernel evdev layer allocates an internal circular queue of only **128 events** between the virtual device and X11/Wayland.
- If a burst of Wi-Fi packets arrives simultaneously and is written in a single syscall, it can exceed 128 events. The kernel drops surplus events with `SYN_DROPPED`, causing jagged or broken lines.
- StylLink buffers events in a 32,768-element pacing ring:
  - Writes are capped at **48 events per chunk**, always aligned to `SYN_REPORT` boundaries.
  - A 1,000 µs (`PACE_US`) timer cooldown is enforced via `timerfd` between chunks to allow the display server to drain its evdev queue.
  - Steady real-time input flushes immediately without queueing; only late network backlogs are paced out smoothly.

### 4. Playout Buffer & Adaptive Burst Catchup
- Network jitter causes stylus packets to arrive in clumps (e.g. 50–100 ms of samples in a single read), which would normally produce sudden visual "snaps" or teleporting lines.
- StylLink schedules each sample to be replayed according to its original transmission timing plus a network delay offset.
- **Catchup Smoothing (`--catchup 2.0`)**: Backlogged samples are played out with their original relative spacing sped up by $2\times$ real-time speed. The stroke catches up smoothly over several animation frames instead of jumping.
- Intentional pen pauses (>100 ms) are detected so stationary intervals are not falsely stretched.
- **Fixed Playout Delay (`--jitter-ms N`)**: Adds a small fixed delay (e.g. 10 ms) to completely eliminate jitter on unstable wireless networks.

### 5. Client-Side Input Harvesting & Predictive Ink Trail
- **High-Frequency Pointer APIs**: The web frontend listens on `pointerrawupdate` and extracts historical events from `event.getCoalescedEvents()`. This bypasses the display's 60 Hz VSync cap and harvests the digitizer's full 120–240 Hz sample rate.
- **Hardware-Accelerated Motion Prediction**:
  - **Android (API 34+)**: Uses `android.view.MotionPredictor` to predict stylus coordinates 15–20 ms into the future based on physical pen dynamics.
  - **Web**: Uses `event.getPredictedEvents()` on Chromium browsers.
- **Zero-Latency Local Trail**: Predicted coordinates extend the local ink canvas preview right up to the moving physical stylus tip, visually cancelling display scanout latency while actual digitizer samples are transmitted to Linux.

---

## Remote Screen (PC → Tablet)

```text
X server ── DAMAGE events ──► video thread (own epoll, normal priority)
   │                              │  dirty 32×32 tiles, capture when the link is free
   └── MIT-SHM ShmGetImage ◄──────┤  copy only the damaged bands
                                  │  diff tiles against the last frame
                                  ▼
             changed rectangles (LZ4 / raw, BGRX / RGB565)  or  H.264 access units
                                  │  [WebSocket /video, DSCP AF41, TCP_NODELAY]
                                  ▼
       Android: GL texture, front buffer · MediaCodec    Web: canvas · WebCodecs
                                  │
                                  └── "a<id>" acknowledgement per shown frame
```

The screen has its own WebSocket (`/video`) on the same port (so the USB `adb reverse` tunnel covers it) and its own thread. A large frame never sits in front of a pen sample: the pen keeps its socket, its voice-queue DSCP and its `SCHED_FIFO` priority (`--realtime`), and the video thread drops back to normal scheduling.

### Negotiation
The tablet speaks first with what it can show:
```text
hv=1;w=2560;h=1600;hz=120;pix=bgrx,rgb565;enc=lz4,raw;codec=tiles,h264;link=usb[;prefer=h264]
```
The server answers with its pick, and may send a new one at any time (followed by a key frame):
```text
ccodec=tiles;w=1920;h=1080;pix=bgrx;enc=lz4;scale=1;fps=120;inflight=2;tile=32
```
- **Codec**: `tiles` unless H.264 was asked for (`--video-codec h264`, or the tablet's "Prefer H.264"), or `--video-source` is set. The browser offers H.264 only when `VideoDecoder` supports it.
- **Pixels**: BGRX (true color) over USB, RGB565 (half the bytes) over Wi-Fi. If frames take over 40 ms to be acknowledged in true color, the server switches to RGB565 by itself.
- **Scale**: half resolution only when the halved picture still covers the tablet's own pixels (USB) or 75% of them (Wi-Fi).
- **Frame rate**: capture runs at up to twice the tablet's refresh rate, so a change right after a frame still makes the next refresh. `--video-fps` sets a hard cap.

### Damage-Driven Tiles
- StylLink talks the X11 protocol itself (no Xlib, no libc): DAMAGE on the root window reports changed rectangles, which mark 32×32 tiles dirty. A 250 ms rescan (`--video-poll`) catches anything DAMAGE misses; unchanged tiles still cost nothing.
- When capture is allowed, `DamageSubtract` is sent first, then one `ShmGetImage` per band of dirty tile rows, all pipelined in one round trip into a shared memory segment (or `GetImage` over the socket when the X server cannot share memory).
- Damage is coarse (often a whole window), so each dirty tile is compared with what the tablet already shows, after conversion to the stream's pixel format. Only tiles that really changed are sent.
- Changed tiles merge into rectangles (runs along a row, stacked up to 4 tile rows). Each rectangle is compressed with LZ4 (raw if that is smaller) and written to the socket right away, so the network sends rectangle *n* while the server encodes *n+1* and the tablet decodes *n−1*.
- Message `T` (little-endian): `'T'`, flags (bit 0 last of frame, bit 1 key frame), encoding (0 raw, 1 LZ4), pixels (0 BGRX, 1 RGB565), u32 frame id, u32 capture time (0.1 ms), u16 x, y, w, h, u32 raw size, then the data.

### Latest Frame Wins
The tablet acknowledges every frame it shows (`a<id>`). With `inflight` frames unacknowledged (default 2), capture waits. Damage keeps piling up meanwhile, so the next capture takes the current screen and skips the stale frames in between. A slow link drops frame rate instead of building a queue. On an idle link, a pen-sized change goes out within about 0.5 ms (see `zig build test-video`).

### H.264
- **Encoder (`--video-encoder`, x264 through ffmpeg by default)**: the same damage-driven capture writes BGRX frames to the command's stdin and reads Annex-B from its stdout. ffmpeg keeps one frame inside its pipeline whatever the flags. So after each real frame the server feeds the same picture again until the real one comes out. Those duplicates encode as tiny skip frames, flagged so the tablet decodes them without acknowledging. A key frame restarts the encoder.
- **Source (`--video-source`)**: a command that captures and encodes on its own, e.g. on Wayland (PipeWire) or a hardware KMS → VAAPI pipeline. Its frames are forwarded as they come.
- Placeholders `{x} {y} {w} {h} {fps}` are filled in. Access units are split at access unit delimiters, so the encoder must emit them (`aud=1`, or `-bsf:v h264_metadata=aud=insert`). Hardware example:
  ```sh
  ./run.sh --video-codec h264 --video-encoder 'ffmpeg -loglevel error -probesize 32 -analyzeduration 0 \
    -vaapi_device /dev/dri/renderD128 -f rawvideo -pix_fmt bgr0 -video_size {w}x{h} -framerate {fps} -i - \
    -fps_mode passthrough -vf format=nv12,hwupload -c:v h264_vaapi -bf 0 -g 600 -aud 1 -async_depth 1 \
    -f h264 -flush_packets 1 -avioflags direct -'
  ```
- Message `H`: `'H'`, flags (bit 1 key frame, bit 2 duplicate), 2 reserved bytes, u32 frame id, u32 capture time, u32 encode time (µs), then the access unit.

### Display Side
- **Android tiles**: the socket thread decodes LZ4 and uploads only the changed rectangles into one texture (`glTexSubImage2D`; BGRX is swizzled in the shader). It draws into a **front-buffer** EGL surface (`EGL_SINGLE_BUFFER` + `EGL_ANDROID_front_buffer_auto_refresh`), touching only the changed area. Without that, it uses unthrottled swaps (interval 0). The surface buffer is exactly the stream size, so the display hardware scales it for free.
- **Android H.264**: MediaCodec decodes straight to the surface, preferring hardware decoders with `FEATURE_LowLatency`, with `KEY_LOW_LATENCY` and realtime priority. Each picture is released for display as soon as it is decoded.
- **Pen mapping**: the picture is letterboxed to the PC's shape and pen coordinates are taken relative to it, so the stroke lands under the tip. The activity also asks for the display's fastest refresh mode.
- **Browser**: `putImageData` per rectangle on a desynchronized canvas, or WebCodecs with `optimizeForLatency`.

---

## Live Diagnostics & Telemetry

StylLink continuously monitors network health without introducing measurement overhead:
- **RTT Pings**: Sends an initial burst of 50 pings upon connection, followed by periodic pings every 250 ms to compute minimum, median, and 95th percentile RTT.
- **Uplink Delay Variation**: Compares tablet transmission timestamps against arrival times to measure tablet-to-PC latency spikes.
- **Linux TCP Telemetry**: Periodically inspects `TCP_INFO` via `getsockopt` to track TCP retransmits and out-of-order packet arrivals (`tcpi_rcv_ooopack`), isolating network packet drops from tablet CPU stalls.
- **JSON-Lines Logging (`--log PATH`)**: Records structured event logs (`connect`, `caps`, `bench`, `stall`, `stat`, `disconnect`) for network performance analysis using `tools/analyze-wifi.py`. The screen adds `video` (the negotiated format) and per-second `vstat` lines: frames, rectangles, bytes sent versus raw, capture-to-acknowledge latency, and encode time.
