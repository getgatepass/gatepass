#!/bin/bash
# Renders assets/dmg/background.html into assets/dmg/background.tiff (1x + 2x for Retina),
# used by build-app.sh --dmg. Needs Google Chrome and internet (web fonts). Run it only after
# changing the HTML; the TIFF is committed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/assets/dmg"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

render() { # scale, output
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --no-first-run --no-default-browser-check \
    --user-data-dir="$TMP/profile-$1" --force-device-scale-factor="$1" --window-size=660,400 \
    --virtual-time-budget=8000 --screenshot="$2" "file://$DIR/background.html" >/dev/null 2>&1
}

render 1 "$TMP/bg.png"
render 2 "$TMP/bg@2x.png"
sips -s dpiWidth 72 -s dpiHeight 72 "$TMP/bg.png" >/dev/null
sips -s dpiWidth 144 -s dpiHeight 144 "$TMP/bg@2x.png" >/dev/null
tiffutil -cathidpicheck "$TMP/bg.png" "$TMP/bg@2x.png" -out "$DIR/background.tiff" >/dev/null
echo "✓ $DIR/background.tiff"
