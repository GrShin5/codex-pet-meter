#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREVIEW_PATH="$ROOT_DIR/build/hunger-meter-preview.png"

cd "$ROOT_DIR"

bash -n tools/build-hunger-meter.sh \
  tools/run-hunger-meter.sh \
  tools/install-hunger-meter.sh \
  tools/uninstall-hunger-meter.sh \
  tools/verify-hunger-meter.sh

tools/build-hunger-meter.sh
build/codex-pet-hunger-meter --status --cached-only
build/codex-pet-hunger-meter --preview "$PREVIEW_PATH" --size 180

if [[ ! -s "$PREVIEW_PATH" ]]; then
  echo "Preview was not created: $PREVIEW_PATH" >&2
  exit 1
fi

echo "Verified: $PREVIEW_PATH"

