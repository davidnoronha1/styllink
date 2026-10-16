# StylLink

Use your Android tablet as a pen tablet for Linux.

Supports pressure, tilt, the pen button, and the eraser. Shows the PC screen
under the pen, so you draw on the picture itself.
Works through Wi-Fi or USB. Built with Zig and native Android views.

<img src="docs/demo.gif" alt="Drawing on the tablet and Linux PC" width="240">

[How it works](WORKING.md)

## Install

Download: [Linux](https://github.com/davidnoronha1/styllink/actions/runs/38715104674/artifacts/11963055735) · [Android APK](https://github.com/davidnoronha1/styllink/actions/runs/38715104674/artifacts/11962136870) · [All builds](https://github.com/davidnoronha1/styllink/actions/workflows/build.yml)

Artifacts expire after 30 days. Open **All builds** for newer downloads.

1. Extract the Linux ZIP, then extract its `.tar.gz` file.
2. Extract the Android ZIP. Install `styllink.apk` on your tablet.
3. Run these commands on your PC:

```sh
./install-uinput-access.sh   # Run once. Requires sudo.
./run.sh
```

Requires Linux with uinput and libinput, plus Android 11 or later.
Tested with Ubuntu 22.04 and X11.

## Connect

Open the app menu. Select **Open camera to scan QR**.
Scan a QR code from the PC terminal, then open its link.

- **USB:** Enable USB debugging and approve the PC. The server sets up
  forwarding and shows the USB QR first. Requires ADB on the PC.
- **Wi-Fi:** Connect both devices to the same network. Scan the Wi-Fi QR.

You can also enter the address and token from the terminal.
To switch to USB, select **Use USB · localhost:8080**, then **Connect**.
Keep the app open and the tablet unlocked.

The tablet shows the mapped monitor and the pen lands where you see it.
The menu can turn the screen off, switch off front-buffer rendering
if you see tearing, or prefer H.264 for video or weak Wi-Fi.
The screen needs an X11 session; on Wayland, use `--video-source`.

The menu also has finger input and trail settings.
Set **Trail fade** from 0.1 to 5 seconds.

For browser input, open the browser link from the terminal in Chrome.

## Build

Use the Zig version in [.zig-version](.zig-version):

```sh
zig build                   # Static Linux binary: zig-out/bin/styllink.
zig build test              # Unit tests.
zig build test-video        # Screen check on Xvfb (needs ffmpeg, python-xlib, lz4, numpy).
./run.sh                    # Builds and starts the server.
```

For Android, install JDK 21 or later and set `ANDROID_HOME` to your SDK path:

```sh
sdkmanager 'platforms;android-36' 'build-tools;36.0.0' 'platform-tools'
sdkmanager --licenses
zig build apk               # Creates zig-out/android/styllink.apk.
zig build apk-install       # Builds and installs through ADB.
```

[GitHub Actions](https://github.com/davidnoronha1/styllink/actions/workflows/build.yml) builds both packages on each push.
Set `ANDROID_DEBUG_KEYSTORE_BASE64` to keep the CI signing key stable.
A different key requires you to uninstall the old app before you install the new APK.

## Options

```sh
./run.sh --port 9000                 # Use another port.
MONITOR=HDMI-0 ./run.sh              # Select a monitor.
STYLLINK_USB=0 ./run.sh              # Skip automatic USB setup.
./run.sh --no-uinput                # Test the link without desktop input.
./run.sh --no-video                 # Pen only, no screen.
./run.sh --video-pix rgb565         # Half the bytes per pixel (auto: USB bgrx, Wi-Fi rgb565).
./run.sh --video-codec h264         # x264 through ffmpeg instead of changed tiles.
./run.sh --video-encoder 'ffmpeg ... -c:v h264_vaapi ... -f h264 -'   # Hardware encoder.
./run.sh --video-source 'CMD'      # A command that captures and encodes (Wayland).
```

Run `./styllink --help` for every option. See [the remote screen](WORKING.md#remote-screen-pc--tablet)
for the protocol and encoder command placeholders.

USB gives the most stable connection. For wireless use, try Ethernet on the PC.
Pass `--log PATH` (for example, `--log styllink.log`) to record events if input stops or has delays.

Use a trusted network. The connection is not encrypted.
