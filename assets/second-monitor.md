# Use the tablet as a second monitor

StylLink can stream and map pen input to a rectangle of an extended X11 desktop.
It does not create a display output itself. A real extension needs the window
manager to treat that rectangle as another monitor, so windows and the mouse
can move into it.

## Existing second output: supported path

Enable a second output in the desktop Display Settings, choose **Join Displays**,
and place it to the right of the main monitor. This can be an ordinary screen
or a spare output with an EDID dummy adapter. Check its name and position:

```sh
xrandr --current
xrandr --listmonitors
MONITOR=DP-1 make run
```

Replace `DP-1` with the active output name. For example, if the main monitor is
1920×1080 and the second is 1920×1080 to its right, the launcher passes
`--region 1920,0,1920,1080 --desktop 3840,1080`. Video captures the second region;
pen coordinates map into that region of the full desktop. Restart StylLink
after changing display positions or resolution so both mappings stay aligned.
Do not separately map the StylLink input device onto that output with `xinput`;
the server already performs the region-to-desktop conversion.

The launcher also accepts a RandR 1.5 logical monitor name from
`xrandr --listmonitors`, including outputless monitors. An unknown, inactive,
or out-of-bounds requested monitor fails with an error instead of silently
mapping input to another screen.

## Software-only experiment: desktop/driver dependent

On the inspected host (2026-10-20), X11 exposes NVIDIA-0 and an AMD sink provider.
Only DP-0 is active at 1920×1080; no VIRTUAL connector exists. The framebuffer
limit is 32767×32767. These observations establish available space, but do not
establish that the desktop supports an outputless monitor.

RandR can enlarge the framebuffer and declare a logical monitor without an
output. This does not create an EDID-backed connector. Some window managers
ignore outputless monitors, restore the previous framebuffer size, or keep the
pointer inside physical outputs. Therefore this is an experiment, not a
verified second-display setup on this host.

The following commands are for the specific **single DP-0 at 1920×1080+0+0**
layout above. They change the live desktop; close the server before trying them.
Record `xrandr --current` first and use the actual layout instead if it differs.

```sh
# Preserve the physical output position; reserve a tablet-sized region at right.
xrandr --fb 3840x1080
xrandr --setmonitor STYLLINK 1920/300x1080/169+1920+0 none
xrandr --current
xrandr --listmonitors
MONITOR=STYLLINK make run
```

Success requires all of the following: `--current` still shows 3840×1080,
`--listmonitors` includes STYLLINK, an application window can move into the right
half, and both mouse and tablet pen can reach it. A listed monitor by itself is
insufficient. If the desktop rejects the setup, use the existing-output path.

Stop StylLink, then undo this experiment on that original single-output layout:

```sh
xrandr --delmonitor STYLLINK
xrandr --fb 1920x1080
make run
```

## Other approaches

An Xvfb or separate headless Xorg session can run applications on a virtual
screen, but it is a separate desktop: existing windows cannot simply be dragged
there. StylLink's uinput device is consumed by the host session, so a separate
X server also needs explicit input routing. Setting only `DISPLAY=:99` changes
capture; it does not move pen input to that X server.

NVIDIA supports headless X configuration, but `UseDisplayDevice "none"` disables
display hardware programming and may not work with every desktop environment.
It is not a live virtual-monitor switch. Driver/Xorg configuration changes can
require restarting the graphical session and are outside this launcher change.

References: [X.Org xrandr manual](https://www.x.org/releases/current/doc/man/man1/xrandr.1.xhtml)
(also available locally as `man xrandr`),
[NVIDIA X configuration options](https://download.nvidia.com/XFree86/Linux-aarch64/580.119.02/README/xconfigoptions.html).
