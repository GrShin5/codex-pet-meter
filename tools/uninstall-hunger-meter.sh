#!/usr/bin/env bash
set -euo pipefail

APP_TARGET="$HOME/Applications/CodexPetHungerMeter.app"
PLIST_PATH="$HOME/Library/LaunchAgents/com.codex-pet.hunger-meter.plist"

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
rm -f "$PLIST_PATH"
rm -rf "$APP_TARGET"
defaults delete com.codex-pet.hunger-meter >/dev/null 2>&1 || true

echo "Uninstalled Codex Pet Hunger Meter"

