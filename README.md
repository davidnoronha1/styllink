# StylLink

**Turn an Android tablet into a pen tablet for Linux.**

Draw in the native Android app or a browser, and StylLink replays your strokes
as a real Linux pen device—with pressure, tilt, barrel button, and eraser.
Only pen samples cross the network. There is no screen streaming.

[Quick start](#quick-start) · [Android app](#android-app) · [Browser pad](#browser-pad) · [Build](#build-from-source) · [CI downloads](#github-actions) · [Latency](#latency-and-troubleshooting)

## At a glance

- **Native Android app:** direct stylus input, historical samples, and a
  foreground low-latency Wi-Fi lock. Native views throughout; no WebView.
- **Small Zig server:** Linux syscalls, an epoll event loop, and a virtual
  `StylLink Pen` device through `/dev/uinput`.
- **QR pairing:** scan once to open the app with your PC's address and token.
- **Quiet canvas:** black background, a visible menu button, and a gray
  disconnected banner. Optional pressure-sensitive ink preview with adjustable fade.
- **Wi-Fi or USB:** keep the tablet wireless, or use ADB forwarding for a
  wired connection.
- **Link diagnostics:** connection benchmarks, live latency statistics, and
  JSON-lines logs for investigating stutter.

```text
Android stylus → native app / browser → WebSocket → Zig server → uinput → Linux apps
```

## Requirements

| Component | Requirement |
| --- | --- |
| PC | Linux with `/dev/uinput` and libinput; tested on Ubuntu 22.04 with X11 |
| Tablet | Android 11 or newer; a pressure-sensitive stylus for pen features |
| Network | Both devices on a reachable LAN, or USB with ADB forwarding |
| Server build | The Zig version pinned in [.zig-version](.zig-version) |
| Android build | JDK 21 or newer, Android SDK platform 36 and build-tools 36.0.0 |

StylLink sends strokes only: use the PC's display to see the target application.
Pressure, tilt, and eraser support also depend on the stylus and drawing app.
Wayland behavior has not been validated.

## Quick start

### 1. Set up the PC

Build from source below, or download and extract the Linux artifact from a
successful GitHub Actions run. From the project or extracted directory:

```sh
./install-uinput-access.sh   # one-time setup; invokes sudo
./run.sh
```

The setup script grants your active desktop user access to `/dev/uinput` and
installs a libinput smoothing override. The server prints pairing QR codes, connection
links, and the target monitor. If one authorized USB tablet is attached,
`run.sh` sets up ADB forwarding and shows its USB QR first, followed by Wi-Fi. `run.sh` selects the primary monitor with
`xrandr`; set `MONITOR=HDMI-0` to choose another.

### 2. Install the Android app

Download `styllink.apk` from the Android CI artifact and install it on the tablet,
or build and install it with a USB-connected, ADB-authorized device:

```sh
./android/build.sh install
```

### 3. Pair and draw

1. Open StylLink and tap the menu button in the top-right corner.
2. Choose **Open camera to scan QR**.
3. Scan the **USB** or **Wi-Fi** QR in the PC terminal and tap its `styllink://connect?...` link.
4. Return to StylLink and draw in your Linux application.

The app saves the address and token, then connects using the chosen QR.
The Wi-Fi QR uses the PC LAN address; the USB QR uses `localhost` through ADB
forwarding. Attaching a cable alone does not switch an existing app connection. Keep the app in the foreground and the tablet unlocked.

The camera app must support QR scanning and opening custom-scheme links. You
can also use another QR scanner or enter the PC address and token manually.
StylLink delegates scanning to the standard camera app and needs no camera permission.

## Android app

The menu contains connection settings, QR scanning, finger drawing, ink trail
preview, the low-latency Wi-Fi switch, and **Use USB · localhost:8080**.
The USB button fills the address; tap **Connect** to apply it. It preserves your token. **Trail fade** ranges from **0.1 to
5 seconds**, with a **0.9-second** default. Settings are saved between launches.

A gray Wi-Fi icon and **Not connected** message appear while offline. The
banner disappears automatically after connecting. The app releases its
connection and Wi-Fi lock when paused.

Pairing links use this format:

```text
styllink://connect?h=192.168.1.10:8080&t=YOUR_TOKEN
```

Use the PC's actual LAN address and the token printed by the server. Optional
`&l=0` / `&l=1` disables/enables the Wi-Fi lock for A/B testing.

## Browser pad

The server also prints a link to [the hosted browser pad](https://styllink.vercel.app).
The page connects directly to your PC; the static host does not relay pen data.
The PC address and token are passed in the URL fragment and removed from the
address bar after loading.

Use Chrome for the hosted HTTPS page. It may ask for local network access
before connecting to the PC's plain WebSocket endpoint. Other browsers can
block this connection. HTTPS exposes raw/coalesced pointer events; the plain
HTTP LAN fallback generally provides fewer samples.

Hover over or tap the browser pad's top-right corner to reveal its settings:
finger/mouse input, aspect-ratio letterboxing, trail preview, keep-awake, and
fullscreen. On Android, **Open in Android app** passes the connection details
to the native app. The browser cannot request Android's low-latency Wi-Fi lock.

## Connect over USB

Enable USB debugging on the tablet, connect the cable, and authorize the PC.
Start `./run.sh`: it checks for a single authorized physical USB device using
`adb -d`, forwards the selected server port, and prints the **USB QR first**.
The Wi-Fi QR follows so both connection methods remain available.

Scan the USB QR, or open the app menu, tap **Use USB · localhost:8080**, then
**Connect**. Your existing token is retained. With `--port 9000`, the automatic
forward and USB QR use port 9000; when using the button, edit its address to
`localhost:9000` before connecting.

If ADB is missing, unauthorized, ambiguous (multiple USB devices), or forwarding
fails, the launcher shows Wi-Fi pairing only. Wireless ADB does not qualify as
a wired connection. Set `STYLLINK_USB=0 ./run.sh` to disable automatic forwarding.
The Android app does not claim a cable is usable merely because USB debugging
is enabled; working forwarding is checked on the PC.

For manual setup:

```sh
adb -d reverse tcp:8080 tcp:8080
```

Then connect to `localhost:8080` in the app with the server token. If launching
the binary directly, `./styllink --usb-qr` displays USB pairing first after you
have configured forwarding yourself. For the browser, open
`http://localhost:8080/?t=YOUR_TOKEN` on the tablet. Localhost is a secure context,
so Chrome can expose full-rate pointer input without HTTPS.

## Build from source

### Linux server

Install the exact version in [.zig-version](.zig-version). The project uses
Zig development APIs; stable releases and unrelated nightly versions may not compile.

```sh
zig version
zig build-exe -O ReleaseFast -fstrip --dep page \
  -Mroot=src/main.zig -Mpage=web/page.zig -femit-bin=styllink
```

`./run.sh` also builds the server when the binary is missing or its inputs change.
The browser page is embedded in the server; no separate web server is required.

### Android APK

Install a JDK and Android command-line tools, then install the SDK packages
and accept their licenses:

```sh
sdkmanager 'platforms;android-36' 'build-tools;36.0.0' 'platform-tools'
sdkmanager --licenses
export ANDROID_HOME="$HOME/Android/Sdk"  # adjust to your SDK location
./android/build.sh
```

The script uses `aapt2`, `javac`, `d8`, `zipalign`, and `apksigner` directly;
Gradle is not required. Output: `android/styllink.apk`. It generates a local
`android/debug.keystore` on the first build and reuses it for subsequent builds.

### Checks

```sh
zig test -O ReleaseSafe --dep page -Mroot=src/main.zig -Mpage=web/page.zig
python3 tests/check_link.py
```

The Zig test checks input pacing using `/dev/null`, without drawing on the
desktop. The Java/Python test checks WebSocket framing, sample-buffer reuse,
benchmark echoes, rapid connection replacement, and automatic reconnect.

## GitHub Actions

[The Build workflow](.github/workflows/build.yml) runs on pushes, pull requests,
and manual dispatches. Two independent Ubuntu jobs build and verify the outputs:

| Artifact | Contents |
| --- | --- |
| `styllink-linux-x86_64` | ReleaseFast server, launch/setup scripts, README, and archive SHA-256 |
| `styllink-android` | Signed development APK and SHA-256 |

Open **Actions → Build → a successful run → Artifacts** to download them.
Extract the Linux artifact ZIP, then its `.tar.gz` archive to preserve executable
permissions. Artifacts are retained for 30 days. The workflow does not publish
GitHub releases or deploy the hosted browser page.

CI pins Zig through `.zig-version`, uses JDK 21 and Android SDK 36, runs both
regression checks, and verifies the APK signature before upload.

**Consistent APK signing:** optionally set the repository Actions secret
`ANDROID_DEBUG_KEYSTORE_BASE64` to a base64 encoding of your local
`android/debug.keystore` (alias `styllink`, store/key password `android`).
This lets CI APKs update installations signed with that same key. Without the
secret, each run generates a fresh development key; Android requires uninstalling
an existing app signed with a different key, which clears its settings. Secrets
are unavailable to pull requests from forks, so those builds use a fresh key.
These APKs are development builds, not store releases.

## Server options

Pass options through `./run.sh`:

| Option | Default | Purpose |
| --- | --- | --- |
| `--port N` | `8080` | HTTP/WebSocket listening port |
| `--token STR` | Saved by `run.sh` | Override the access token |
| `--region X,Y,W,H` | Selected monitor | Target rectangle on the desktop |
| `--desktop W,H` | Detected with `xrandr` | Full desktop dimensions |
| `--io epoll\|uring` | `epoll` | Event loop backend |
| `--busy` | Off | Reduce wake-up delay by keeping a CPU core busy |
| `--unsmooth N` | `4` | Repeat frames to counter libinput smoothing; `1` disables repetition |
| `--catchup X` | `2` | Replay delayed bursts at X times normal speed; `0` disables burst smoothing |
| `--jitter-ms N` | `0` | Add a fixed playout delay to absorb network jitter |
| `--web-url URL` | Hosted pad | Override the printed browser URL; empty uses the local page |
| `--log PATH` | `styllink.log` | JSON-lines log path; empty disables logging |
| `--usb-qr` | Auto via `run.sh` | Show USB pairing QR first; requires ADB forwarding |
| `--no-uinput` | Off | Measure the link without generating desktop input |

```sh
MONITOR=HDMI-0 ./run.sh
./run.sh --port 9000 --catchup 1.5
./run.sh --no-uinput --log /tmp/styllink-link.jsonl
```

`run.sh` stores its default token in `.styllink-token` with mode `0600`, keeping
configured clients working across restarts. Delete that file to rotate the
token and reconnect your clients. Running `./styllink` directly generates a
new token by default. `--token ""` disables authentication.

The connection uses plain LAN WebSockets, without transport encryption.
Use a trusted network: anyone with the address and token can inject pen input.

## Latency and troubleshooting

**Connected, but stuttery?** Check the link before adding buffering. The app's
Wi-Fi lock is a request to Android, not a guarantee of smooth delivery. Recent
equal-rate measurements found tablet-to-router p95 of 7.6 ms and PC-to-router
p95 of 120 ms, despite PC power saving being off. Connecting the **PC by Ethernet
while leaving the tablet on Wi-Fi** is a useful way to isolate that hop. USB
forwarding is another comparison.

**Fast strokes look rounded or distorted?** libinput can average pen samples.
The setup script installs `AttrTabletSmoothing=0`; X11 may need a new login
session to load the override. The default `--unsmooth 4` counters the averaging
in the meantime. Use `--unsmooth 1` once you have verified smoothing is disabled.

**What does burst smoothing cost?** Delayed samples retain their spacing and
replay at `--catchup` speed. In a synthetic 100 ms flow / 130 ms stall test,
2× replay reduced the largest jump from 75 px to 19 px, at a cost of about
65 ms additional delay for the worst sample. More jitter buffering trades
latency for smoother motion; it cannot make late network data arrive earlier.

**Input events disappear?** The server limits uinput writes to 48 events on
frame boundaries, with a 1 ms cooldown even when the queue becomes empty.
This prevents separate small reads from bypassing pacing. `SYN_DROPPED` in the
X log indicates an input-buffer overflow.

**No connection?** Check the PC address, token, firewall/TCP port, shared LAN,
and router client-isolation settings. The native app's disconnected banner
and menu show connection state. USB pairing requires `adb reverse` first.

### Read the measurements

Each connection starts a 50-ping benchmark. The terminal then displays RTT,
uplink excess, and pen rate. **Uplink excess** is delay above the recent best
case, not absolute one-way latency; the two clocks are not synchronized.

`styllink.log` records connection/capability events, benchmarks, active
per-second stats, periodic idle stats, and gaps over 50 ms. Useful fields:

| Field | Meaning |
| --- | --- |
| `pen_hz`, `msgs` | Samples and pen messages in the reporting interval |
| `gap_max_ms`, `stalls` | Longest active-message gap and gaps over 50 ms |
| `uplink_p95_ms` | Tail delivery delay above the recent baseline |
| `age_mean_ms`, `age_max_ms` | Sample age when the client assembled its message |
| `smooth_lag_max_ms` | Maximum scheduled playout wait beyond arrival |
| `ooo`, `retrans` | TCP out-of-order arrivals and PC retransmission counters |

TCP reordering can contribute to stalls, but these counters alone do not
pinpoint radio, router, application, or driver behavior.

For a Wi-Fi-lock comparison, draw continuously for equal intervals with the
native lock enabled and disabled, then summarize the log:

```sh
python3 tools/analyze-wifi.py styllink.log
adb shell dumpsys wifi
```

The analyzer groups native stats by advertised lock state. Android's
`WifiLockManager` dump verifies whether `styllink:pen` is active for the foreground
app. Pauses between strokes also count as gaps, so keep the test conditions comparable.

## Project layout

| Path | Purpose |
| --- | --- |
| `src/main.zig` | HTTP/WebSocket server, uinput pen, paced replay, diagnostics |
| `src/qr.zig` | Terminal QR encoder |
| `android/` | Native Java app, resources, and standalone build script |
| `web/index.html` | Standalone browser drawing pad |
| `run.sh` | Incremental build, monitor selection, token persistence, launch |
| `install-uinput-access.sh` | One-time uinput/libinput setup |
| `.github/workflows/build.yml` | Linux and Android CI builds |
| `tests/`, `tools/` | Regression checks and log analysis |

`./deploy-web.sh` deploys the browser page to Vercel when configured locally.
