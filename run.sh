#!/bin/sh
# Build (if needed) and start styllink mapped to one monitor. Extra args are
# passed through (e.g. --busy, --io uring, --port 9000, --token foo).
#   ./run.sh                 primary monitor
#   MONITOR=HDMI-0 ./run.sh  pick a monitor by xrandr name
set -e
cd "$(dirname "$0")"

if [ ! -x styllink ] || [ src/main.zig -nt styllink ] || [ src/qr.zig -nt styllink ] || [ web/index.html -nt styllink ]; then
  echo "building..."
  zig build-exe -O ReleaseFast -fstrip --dep page -Mroot=src/main.zig -Mpage=web/page.zig -femit-bin=styllink
  rm -f styllink.o
fi

GEO=""
if command -v xrandr >/dev/null 2>&1 && [ -n "$DISPLAY" ]; then
  DESK=$(xrandr --current | sed -n 's/.*current \([0-9]*\) x \([0-9]*\),.*/\1,\2/p' | head -n1)
  if [ -n "$MONITOR" ]; then
    LINE=$(xrandr --current | grep "^$MONITOR connected" || true)
  else
    LINE=$(xrandr --current | grep " connected primary" || xrandr --current | grep " connected" | head -n1)
  fi
  REGION=$(echo "$LINE" | grep -o '[0-9]*x[0-9]*+[0-9]*+[0-9]*' | head -n1 |
    sed 's/\([0-9]*\)x\([0-9]*\)+\([0-9]*\)+\([0-9]*\)/\3,\4,\1,\2/')
  [ -n "$REGION" ] && [ -n "$DESK" ] && GEO="--region $REGION --desktop $DESK"
fi

# Keep a configured tablet working across restarts. An explicit --token wins,
# including --token "". Create the default with private permissions atomically.
TOKEN_SET=false
SERVER_PORT=8080
EXPECT_VALUE=""
for arg in "$@"; do
  case "$EXPECT_VALUE" in
    port) SERVER_PORT=$arg; EXPECT_VALUE="" ;;
    skip) EXPECT_VALUE="" ;;
    *)
      case "$arg" in
        --port) EXPECT_VALUE=port ;;
        --token) TOKEN_SET=true; EXPECT_VALUE=skip ;;
        --busy|--no-uinput|--usb-qr) ;;
        *) EXPECT_VALUE=skip ;;
      esac
      ;;
  esac
done

# Only a single authorized physical USB device qualifies; wireless ADB does
# not prove a wired path. Keep Wi-Fi pairing available if ADB is absent/fails.
if [ "${STYLLINK_USB:-1}" != 0 ] && command -v adb >/dev/null 2>&1; then
  case "$SERVER_PORT" in
    ''|*[!0-9]*) ;;
    *)
      if [ "${#SERVER_PORT}" -le 5 ] && [ "$SERVER_PORT" -gt 0 ] && [ "$SERVER_PORT" -le 65535 ] &&
         [ "$(adb -d get-state 2>/dev/null)" = device ] &&
         adb -d reverse "tcp:$SERVER_PORT" "tcp:$SERVER_PORT" >/dev/null 2>&1; then
        echo "USB ready: ADB forwarding localhost:$SERVER_PORT to this PC. USB QR comes first."
        set -- --usb-qr "$@"
      fi
      ;;
  esac
fi
if [ "$TOKEN_SET" = false ]; then
  if [ ! -e .styllink-token ]; then
    TOKEN_TMP=$(mktemp .styllink-token.XXXXXX)
    trap 'rm -f "$TOKEN_TMP"' EXIT HUP INT TERM
    od -An -N24 -tx1 /dev/urandom | tr -d ' \n' > "$TOKEN_TMP"
    chmod 600 "$TOKEN_TMP"
    ln "$TOKEN_TMP" .styllink-token 2>/dev/null || [ -f .styllink-token ]
    rm -f "$TOKEN_TMP"
    trap - EXIT HUP INT TERM
  fi
  TOKEN=$(cat .styllink-token)
  if [ -z "$TOKEN" ]; then
    echo "Empty .styllink-token; remove it to generate a new token." >&2
    exit 1
  fi
  set -- --token "$TOKEN" "$@"
fi
exec ./styllink $GEO "$@"
