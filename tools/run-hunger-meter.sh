#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT_DIR/tools/build-hunger-meter.sh"
exec "$ROOT_DIR/build/CodexPetHungerMeter.app/Contents/MacOS/codex-pet-hunger-meter"

