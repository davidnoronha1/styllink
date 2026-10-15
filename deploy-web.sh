#!/bin/sh
# Deploy the standalone page (web/index.html, nothing else) to Vercel.
# A hosted HTTPS page is a secure context, so tablet Chrome exposes the
# full-rate pen APIs without flags. It connects to this PC over the LAN.
set -e
cd "$(dirname "$0")"
STAGE=.deploy/styllink
mkdir -p "$STAGE"
cp web/index.html "$STAGE/index.html"
cd "$STAGE"
npx --yes vercel@latest deploy --prod --yes "$@"
