#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QA_DIR="$ROOT_DIR/build/qa-current-usage"
cd "$ROOT_DIR"
bash -n tools/build-hunger-meter.sh tools/run-hunger-meter.sh tools/install-hunger-meter.sh tools/uninstall-hunger-meter.sh tools/verify-hunger-meter.sh scripts/package-release.sh
tools/build-hunger-meter.sh
codesign --verify --deep --strict build/CodexPetHungerMeter.app
cmp build/codex-pet-hunger-meter build/CodexPetHungerMeter.app/Contents/MacOS/codex-pet-hunger-meter
build/codex-pet-hunger-meter --self-test
mkdir -p "$QA_DIR"
for fixture in normal pro-no-limit unknown cached; do
  for size in 80 99 224; do
    for side in left right; do
      for adjustment in .85 1.2; do
        output="$QA_DIR/$fixture-$size-$side-$adjustment.png"
        build/codex-pet-hunger-meter --preview "$output" --preview-fixture "$fixture" --size "$size" --side "$side" --adjustment "$adjustment"
        [[ -s "$output" ]]
      done
    done
  done
done
build/codex-pet-hunger-meter --preview "$QA_DIR/public-pro.png" --preview-fixture public-pro --size 180
[[ -s "$QA_DIR/public-pro.png" ]]
/usr/bin/python3 tools/tests/test-release-tools.py
echo "Verified: deterministic self-tests and 48 PNG fixtures in $QA_DIR"
