# Build from a source checkout or launch an extracted Linux package.
.DEFAULT_GOAL := build
SHELL := /bin/sh
.SHELLFLAGS := -ec
.ONESHELL:

ARGS ?=
DEBUG ?= 0
ZIG ?= zig

.PHONY: help build run test apk apk-install all install-uinput-access deploy-web

help:
	@printf '%s\n' \
	  'make build                 Build the Linux server (default).' \
	  'make run [ARGS="..."]      Build and launch; MONITOR selects a display.' \
	  'make run DEBUG=1           Enable JSON logging to styllink.log.' \
	  'make test                  Run Zig unit tests.' \
	  'make apk                   Build the Android APK.' \
	  'make apk-install           Build and install the APK through ADB.' \
	  'make all                   Build the Linux server and Android APK.' \
	  'make install-uinput-access Configure uinput and pen smoothing (uses sudo).' \
	  'make deploy-web [ARGS="..."] Deploy the browser page to Vercel.'

build:
	@if [ -f build.zig ]; then
		$(ZIG) build
		cp zig-out/bin/styllink .styllink-next
		chmod +x .styllink-next
		mv -f .styllink-next styllink
	elif [ ! -x styllink ]; then
		echo 'No server binary or build.zig found.' >&2
		exit 1
	fi

run: build
	@set -- $(ARGS)
	if [ "$(DEBUG)" = 1 ]; then
	  set -- --log styllink.log "$$@"
	fi
	GEO=""
	if command -v xrandr >/dev/null 2>&1 && [ -n "$$DISPLAY" ]; then
	  XRANDR=$$(xrandr --current)
	  DESK=$$(printf '%s\n' "$$XRANDR" | sed -n 's/.*current \([0-9]*\) x \([0-9]*\),.*/\1,\2/p' | head -n1)
	  REGION=""
	  if [ -n "$$MONITOR" ]; then
	    # Logical monitors can cover framebuffer space without a physical output.
	    # Compare names literally; connector names must not become regex patterns.
	    REGION=$$(xrandr --listmonitors 2>/dev/null | awk -v name="$$MONITOR" '
	      NF >= 3 {
	        monitor=$$2; sub(/^[+*]+/, "", monitor)
	        if (monitor == name && split($$3, g, /[\/x+]/) == 6 &&
	            g[1] ~ /^[0-9]+$$/ && g[3] ~ /^[0-9]+$$/ &&
	            g[5] ~ /^[0-9]+$$/ && g[6] ~ /^[0-9]+$$/)
	          print g[5] "," g[6] "," g[1] "," g[3]
	      }' | head -n1)
	    LINE=$$(printf '%s\n' "$$XRANDR" | awk -v name="$$MONITOR" '$$1 == name && $$2 == "connected"')
	  else
	    LINE=$$(printf '%s\n' "$$XRANDR" | grep " connected primary" || printf '%s\n' "$$XRANDR" | grep " connected" | head -n1)
	  fi
	  if [ -z "$$REGION" ]; then
	    REGION=$$(printf '%s\n' "$$LINE" | grep -o '[0-9]*x[0-9]*+[0-9]*+[0-9]*' | head -n1 |
	      sed 's/\([0-9]*\)x\([0-9]*\)+\([0-9]*\)+\([0-9]*\)/\3,\4,\1,\2/')
	  fi
	  if [ -n "$$MONITOR" ] && ! awk -v region="$$REGION" -v desk="$$DESK" 'BEGIN {
	    split(region, r, ","); split(desk, d, ",")
	    exit !(region != "" && d[1] > 0 && d[2] > 0 && r[3] > 0 && r[4] > 0 &&
	      r[1] + r[3] <= d[1] && r[2] + r[4] <= d[2])
	  }'; then
	    echo "MONITOR=$$MONITOR has no active region inside the X11 framebuffer. Check xrandr --listmonitors and --current." >&2
	    exit 1
	  fi
	  [ -n "$$REGION" ] && [ -n "$$DESK" ] && GEO="--region $$REGION --desktop $$DESK"
	elif [ -n "$$MONITOR" ]; then
	  echo "MONITOR requires xrandr and an X11 DISPLAY." >&2
	  exit 1
	fi

	# Keep a configured tablet working across restarts. An explicit --token wins,
	# including --token "". Create the default with private permissions atomically.
	TOKEN_SET=false
	SERVER_PORT=8080
	EXPECT_VALUE=""
	for arg in "$$@"; do
	  case "$$EXPECT_VALUE" in
	    port) SERVER_PORT=$$arg; EXPECT_VALUE="" ;;
	    skip) EXPECT_VALUE="" ;;
	    *)
	      case "$$arg" in
	        '--port') EXPECT_VALUE=port ;;
	        '--token') TOKEN_SET=true; EXPECT_VALUE=skip ;;
	        '--help'|'--no-uinput'|'--no-video'|'--usb-qr') ;;
	        *) EXPECT_VALUE=skip ;;
	      esac
	      ;;
	  esac
	done

	# Only a single authorized physical USB device qualifies; wireless ADB does
	# not prove a wired path. Keep Wi-Fi pairing available if ADB is absent/fails.
	if [ "$${STYLLINK_USB:-1}" != 0 ] && command -v adb >/dev/null 2>&1; then
	  case "$$SERVER_PORT" in
	    ''|*[!0-9]*) ;;
	    *)
	      if [ "$${#SERVER_PORT}" -le 5 ] && [ "$$SERVER_PORT" -gt 0 ] && [ "$$SERVER_PORT" -le 65535 ] &&
	         [ "$$(adb -d get-state 2>/dev/null)" = device ] &&
	         adb -d reverse "tcp:$$SERVER_PORT" "tcp:$$SERVER_PORT" >/dev/null 2>&1; then
	        echo "USB ready: ADB forwarding localhost:$$SERVER_PORT to this PC. USB QR comes first."
	        set -- --usb-qr "$$@"
	      fi
	      ;;
	  esac
	fi
	if [ "$$TOKEN_SET" = false ]; then
	  if [ ! -e .styllink-token ]; then
	    TOKEN_TMP=$$(mktemp .styllink-token.XXXXXX)
	    trap 'rm -f "$$TOKEN_TMP"' EXIT HUP INT TERM
	    od -An -N24 -tx1 /dev/urandom | tr -d ' \n' > "$$TOKEN_TMP"
	    chmod 600 "$$TOKEN_TMP"
	    ln "$$TOKEN_TMP" .styllink-token 2>/dev/null || [ -f .styllink-token ]
	    rm -f "$$TOKEN_TMP"
	    trap - EXIT HUP INT TERM
	  fi
	  TOKEN=$$(cat .styllink-token)
	  if [ -z "$$TOKEN" ]; then
	    echo "Empty .styllink-token; remove it to generate a new token." >&2
	    exit 1
	  fi
	  set -- --token "$$TOKEN" "$$@"
	fi
	exec ./styllink $$GEO "$$@"

test:
	$(ZIG) build test

apk:
	$(ZIG) build apk

apk-install:
	$(ZIG) build apk-install

all: build apk

# One-time host setup; uaccess follows the active desktop seat.
install-uinput-access:
	@RULE=/etc/udev/rules.d/60-styllink-uinput.rules
	echo 'KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uinput"' | sudo tee "$$RULE" >/dev/null
	sudo modprobe uinput
	sudo udevadm control --reload-rules
	sudo udevadm trigger --name-match=uinput
	# Apply to the current session immediately as well.
	sudo setfacl -m "u:$$(id -un):rw" /dev/uinput
	echo "ok: uinput access: $$(getfacl -p /dev/uinput 2>/dev/null | grep "user:$$(id -un)")"

	QUIRKS=/etc/libinput/local-overrides.quirks
	sudo mkdir -p /etc/libinput
	if ! sudo grep -q '^\[StylLink Pen\]' "$$QUIRKS" 2>/dev/null; then
	  printf '\n[StylLink Pen]\nMatchName=StylLink Pen\nModelTabletSmoothing=0\nAttrTabletSmoothing=0\n' | sudo tee -a "$$QUIRKS" >/dev/null
	elif ! sudo grep -q 'ModelTabletSmoothing=0' "$$QUIRKS" 2>/dev/null; then
	  printf 'ModelTabletSmoothing=0\n' | sudo tee -a "$$QUIRKS" >/dev/null
	fi
	echo "ok: libinput smoothing disabled for StylLink Pen ($$QUIRKS); restart styllink to apply"

# Host only the standalone page so tablet Chrome has a secure context.
deploy-web:
	@STAGE=.deploy/styllink
	mkdir -p "$$STAGE"
	cp web/index.html "$$STAGE/index.html"
	cd "$$STAGE"
	npx --yes vercel@latest deploy --prod --yes $(ARGS)
