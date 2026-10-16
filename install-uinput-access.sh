#!/bin/sh
# One-time setup (needs sudo):
#  1. let the logged-in desktop user create virtual input devices
#     (uaccess grants /dev/uinput to whoever owns the active local seat)
#  2. turn off libinput's tablet smoothing for the StylLink pen. libinput
#     averages the last 4 samples, which is invisible when writing slowly but
#     garbles fast handwriting, where samples are 10-40 px apart.
set -e
RULE=/etc/udev/rules.d/60-styllink-uinput.rules
echo 'KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uinput"' | sudo tee "$RULE" >/dev/null
sudo modprobe uinput
sudo udevadm control --reload-rules
sudo udevadm trigger --name-match=uinput
# Apply to the current session immediately as well.
sudo setfacl -m "u:$(id -un):rw" /dev/uinput
echo "ok: uinput access: $(getfacl -p /dev/uinput 2>/dev/null | grep "user:$(id -un)")"

QUIRKS=/etc/libinput/local-overrides.quirks
sudo mkdir -p /etc/libinput
if ! sudo grep -q '^\[StylLink Pen\]' "$QUIRKS" 2>/dev/null; then
  printf '\n[StylLink Pen]\nMatchName=StylLink Pen\nModelTabletSmoothing=0\nAttrTabletSmoothing=0\n' | sudo tee -a "$QUIRKS" >/dev/null
elif ! sudo grep -q 'ModelTabletSmoothing=0' "$QUIRKS" 2>/dev/null; then
  printf 'ModelTabletSmoothing=0\n' | sudo tee -a "$QUIRKS" >/dev/null
fi
echo "ok: libinput smoothing disabled for StylLink Pen ($QUIRKS); restart styllink to apply"
