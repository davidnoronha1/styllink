# StylLink

Use your Android tablet as a pen tablet for Linux.

Supports pressure, tilt, the pen button, and the eraser. Sends pen input only.
Works through Wi-Fi or USB. Built with Zig and native Android views.

<img src="docs/demo.gif" alt="Drawing on the tablet and Linux PC" width="240">

## Install

Download the Linux package and Android APK from a successful
[Build run](https://github.com/davidnoronha1/styllink/actions/workflows/build.yml).
Open **Artifacts** at the bottom of the run page.

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

The menu also has finger input and trail settings.
Set **Trail fade** from 0.1 to 5 seconds.

For browser input, open the browser link from the terminal in Chrome.

## Build

Use the Zig version in [.zig-version](.zig-version):

```sh
./run.sh                    # Builds and starts the Linux server.
```

For Android, install JDK 21 or later and set `ANDROID_HOME` to your SDK path:

```sh
sdkmanager 'platforms;android-36' 'build-tools;36.0.0' 'platform-tools'
sdkmanager --licenses
./android/build.sh          # Creates android/styllink.apk.
./android/build.sh install  # Builds and installs through ADB.
```

[GitHub Actions](.github/workflows/build.yml) builds both packages on each push.
CI uses a new signing key unless you set `ANDROID_DEBUG_KEYSTORE_BASE64`.
A different key requires you to uninstall the old app before you install the new APK.

## Options

```sh
./run.sh --port 9000                 # Use another port.
MONITOR=HDMI-0 ./run.sh              # Select a monitor.
STYLLINK_USB=0 ./run.sh              # Skip automatic USB setup.
./run.sh --no-uinput                # Test the link without desktop input.
```

USB gives the most stable connection. For wireless use, try Ethernet on the PC.
Check `styllink.log` if input stops or has delays.

Use a trusted network. The connection is not encrypted.
