#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/CodexPetHungerMeter.app"
BIN_PATH="$BUILD_DIR/codex-pet-hunger-meter"
ICON_PATH="$APP_DIR/Contents/Resources/AppIcon.icns"

mkdir -p "$BUILD_DIR"
export CLANG_MODULE_CACHE_PATH="/private/tmp/codex-pet-hunger-meter-module-cache"
export TMPDIR="/private/tmp/codex-pet-hunger-meter-tmp"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$TMPDIR"

swiftc "$ROOT_DIR/tools/codex-pet-hunger-meter.swift" \
  -o "$BIN_PATH" \
  -framework AppKit \
  -lsqlite3

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/codex-pet-hunger-meter"
cp "$ROOT_DIR/reference/food_bowl_meter.png" "$APP_DIR/Contents/Resources/food_bowl_meter.png"

xcrun swift "$ROOT_DIR/tools/make-app-icon.swift" \
  "$ROOT_DIR/reference/food_bowl_meter.png" \
  "$ICON_PATH"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>codex-pet-hunger-meter</string>
  <key>CFBundleIdentifier</key>
  <string>com.codex-pet.hunger-meter</string>
  <key>CFBundleName</key>
  <string>Codex Pet Hunger Meter</string>
  <key>CFBundleDisplayName</key>
  <string>Pet Meter</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

echo "Built: $APP_DIR"
