#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CodexPetHungerMeter.app"
DIST_DIR="$ROOT_DIR/dist"
VERSION="0.1.0"
ZIP_PATH="$DIST_DIR/codex-pet-meter-$VERSION.zip"

"$ROOT_DIR/tools/build-hunger-meter.sh"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

ditto -c -k --keepParent "$ROOT_DIR/build/$APP_NAME" "$ZIP_PATH"

echo "Packaged: $ZIP_PATH"
