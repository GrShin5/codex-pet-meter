#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CodexPetHungerMeter.app"
APP_SOURCE="$ROOT_DIR/build/$APP_NAME"
APP_TARGET="$HOME/Applications/$APP_NAME"
AGENT_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$AGENT_DIR/com.codex-pet.hunger-meter.plist"

"$ROOT_DIR/tools/build-hunger-meter.sh"

mkdir -p "$HOME/Applications" "$AGENT_DIR"
rm -rf "$APP_TARGET"
cp -R "$APP_SOURCE" "$APP_TARGET"

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.codex-pet.hunger-meter</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP_TARGET/Contents/MacOS/codex-pet-hunger-meter</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/codex-pet-hunger-meter.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/codex-pet-hunger-meter.err.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
launchctl kickstart -k "gui/$(id -u)/com.codex-pet.hunger-meter"

echo "Installed: $APP_TARGET"
echo "Login item: $PLIST_PATH"

