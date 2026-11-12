#!/bin/bash
# Builds the Rust engine + SwiftUI app and assembles a self-contained GatePass.app.
# Usage: scripts/build-app.sh            -> build/GatePass.app
#        scripts/build-app.sh --dmg      -> also build/GatePass.dmg
# By default both binaries are universal (Apple Silicon + Intel).
# Set GATEPASS_ARCH=native for a quicker single-architecture dev build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build"
APP="$OUT/GatePass.app"
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"
VERSION="$(grep -m1 '^version' "$ROOT/engine/Cargo.toml" | cut -d'"' -f2)"
ARCH_MODE="${GATEPASS_ARCH:-universal}"
export MACOSX_DEPLOYMENT_TARGET=14.0

ENGINE_BIN="$OUT/gatepass-engine"
mkdir -p "$OUT"
if [ "$ARCH_MODE" = "native" ]; then
  echo "▸ Building engine (native)…"
  (cd "$ROOT/engine" && "$CARGO" build --release --quiet)
  cp "$ROOT/engine/target/release/gatepass-engine" "$ENGINE_BIN"

  echo "▸ Building app (native)…"
  (cd "$ROOT/app" && swift build -c release --quiet)
  APP_BIN="$(cd "$ROOT/app" && swift build -c release --show-bin-path)/GatePass"
else
  RUSTUP="${RUSTUP:-$HOME/.cargo/bin/rustup}"
  "$RUSTUP" target add aarch64-apple-darwin x86_64-apple-darwin >/dev/null
  for T in aarch64-apple-darwin x86_64-apple-darwin; do
    echo "▸ Building engine ($T)…"
    (cd "$ROOT/engine" && "$CARGO" build --release --quiet --target "$T")
  done
  lipo -create -output "$ENGINE_BIN" \
    "$ROOT/engine/target/aarch64-apple-darwin/release/gatepass-engine" \
    "$ROOT/engine/target/x86_64-apple-darwin/release/gatepass-engine"

  echo "▸ Building app (arm64 + x86_64)…"
  SWIFT_ARCHS=(--arch arm64 --arch x86_64)
  (cd "$ROOT/app" && swift build -c release --quiet "${SWIFT_ARCHS[@]}")
  APP_BIN="$(cd "$ROOT/app" && swift build -c release "${SWIFT_ARCHS[@]}" --show-bin-path)/GatePass"
fi

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$APP_BIN" "$APP/Contents/MacOS/GatePass"
cp "$ENGINE_BIN" "$APP/Contents/MacOS/gatepass-engine"
if [ -f "$ROOT/assets/AppIcon.icns" ]; then
  cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>GatePass</string>
  <key>CFBundleDisplayName</key><string>GatePass</string>
  <key>CFBundleIdentifier</key><string>app.gatepass.sideloader</string>
  <key>CFBundleExecutable</key><string>GatePass</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>GatePass finds and pairs with your Apple TV on the local network.</string>
  <key>NSBonjourServices</key>
  <array><string>_remotepairing-manual-pairing._tcp</string><string>_remotepairing._tcp</string><string>_apple-mobdev2._tcp</string></array>
  <key>NSHumanReadableCopyright</key><string>Open source · MIT</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>iOS App Package</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key><array><string>ipa</string><string>tipa</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# A stable identity (not ad-hoc) keeps macOS from asking for the Keychain password after
# every build/update. Override with GATEPASS_SIGN_IDENTITY, or use "-" for ad-hoc.
SIGN_NAME="${GATEPASS_SIGN_IDENTITY:-GatePass Self-Signed}"
if [ "$SIGN_NAME" != "-" ]; then
  "$ROOT/scripts/make-signing-cert.sh" "$SIGN_NAME" >/dev/null
  SIGN_ID="$(security find-certificate -c "$SIGN_NAME" -Z | awk '/SHA-1 hash:/ {print $3; exit}')"
else
  SIGN_ID="-"
fi
echo "▸ Signing ($SIGN_NAME)…"
codesign --force --timestamp=none --identifier app.gatepass.engine --sign "$SIGN_ID" "$APP/Contents/MacOS/gatepass-engine"
codesign --force --timestamp=none --sign "$SIGN_ID" "$APP"

if [ "${1:-}" = "--dmg" ]; then
  echo "▸ Creating DMG…"
  STAGE="$OUT/dmg-stage"
  rm -rf "$STAGE" "$OUT/GatePass.dmg"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -quiet -volname "GatePass" -srcfolder "$STAGE" -ov -format UDZO "$OUT/GatePass.dmg"
  rm -rf "$STAGE"
  echo "✓ $OUT/GatePass.dmg"
fi

echo "✓ $APP"
