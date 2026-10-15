# How StylLink works

## Pen input

```text
Android app or browser → WebSocket → Zig server → uinput → Linux application
```

The Android app sends current and historical pen samples. Each sample contains
position, pressure, tilt, pen buttons, and its age. The app uses native Android
views. It requests a low-latency Wi-Fi lock while it is open.

The server uses Linux system calls and an epoll event loop. It creates a
`StylLink Pen` device through `/dev/uinput`. Linux applications receive input
from this device as they do from a physical pen tablet.

The binary is static. It does not require libc or a dynamic linker. The browser
page is included in the binary. Linux kernel support for uinput is still required.

## Connections

Wi-Fi links contain the PC address and an access token. USB links use
`localhost` with ADB reverse forwarding. The server listens on port 8080 by default.

At startup, `run.sh` checks for one authorized USB device. If forwarding works,
it prints the USB QR first. It also prints the Wi-Fi QR. The selected QR opens
the app and saves the connection details.

The launcher saves its token in `.styllink-token`. Delete this file to create
a new token. Connections are not encrypted. Use a trusted network.

## Timing

The server repeats pen frames to counter libinput smoothing. It sends at most
48 input events in each write, then holds a 1 ms pause. This limits input-buffer
loss during bursts.

Delayed samples keep their original spacing. The default replay speed is 2×
to catch up after a network delay. A slower replay can look smoother but adds delay.
The app's ink trail is a local preview. Its fade setting does not delay pen input.

## Build system

[`build.zig`](https://github.com/davidnoronha1/styllink/blob/main/build.zig) defines the server, APK, and test steps:

| Command | Result |
| --- | --- |
| `zig build` | Static server in `zig-out/bin/styllink` |
| `zig build apk` | Signed APK in `zig-out/android/styllink.apk` |
| `zig build all` | Both outputs |
| `zig build apk-install` | Build the APK and install through ADB |
| `zig build test` | Server regression test |
| `zig build test-link` | Java WebSocket regression tests |

Zig compiles the server and tracks its source dependencies. For the APK, Zig
calls `android/build.sh` and tracks the output file. Android SDK tools compile
Java, package resources, and sign the APK. This step runs each time to include
changes to the SDK or signing key. It does not use Gradle.

Use the compiler version in [.zig-version](.zig-version). The default server
build uses ReleaseFast. Use `-Dtarget=x86_64-linux` to select the CI target.
Use `--prefix PATH` to change the output directory.

## Check a delay

The terminal shows a connection benchmark and live link statistics.
`styllink.log` records samples, message gaps, network delay, and replay delay.

```sh
./run.sh --no-uinput --log /tmp/styllink.jsonl
python3 tools/analyze-wifi.py /tmp/styllink.jsonl
```

Draw continuously when you compare connections. Pauses between strokes also
count as message gaps. Compare USB and Wi-Fi before you add more buffering.
