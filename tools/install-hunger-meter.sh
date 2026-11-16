#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CodexPetHungerMeter.app"
APP_SOURCE="$ROOT_DIR/build/$APP_NAME"
INSTALL_ROOT="$HOME"
USE_EXISTING=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP_SOURCE="${2:?Missing --app path}"; USE_EXISTING=true; shift 2 ;;
    --test-root)
      [[ "${CODEX_PET_INSTALL_TESTING:-}" == 1 ]] || { echo 'Test root is restricted to the test harness' >&2; exit 1; }
      INSTALL_ROOT="${2:?Missing test root}"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
$USE_EXISTING || "$ROOT_DIR/tools/build-hunger-meter.sh"
APP_TARGET="$INSTALL_ROOT/Applications/$APP_NAME"
AGENT_DIR="$INSTALL_ROOT/Library/LaunchAgents"
PLIST_PATH="$AGENT_DIR/com.codex-pet.hunger-meter.plist"
EXECUTABLE="$APP_TARGET/Contents/MacOS/codex-pet-hunger-meter"
DOMAIN="gui/$(id -u)"
SERVICE="$DOMAIN/com.codex-pet.hunger-meter"
[[ -d "$APP_SOURCE" && ! -L "$APP_SOURCE" ]] || { echo 'Expected a real app bundle' >&2; exit 1; }
codesign --verify --deep --strict "$APP_SOURCE"
# A successful print must identify this executable before reusing a registration.
loaded_expected() {
  local details
  details="$(launchctl print "$SERVICE" 2>/dev/null)" || return 1
  awk -v expected="$EXECUTABLE" '
    /^[[:space:]]*program = / { sub(/^[[:space:]]*program = /, ""); if ($0 == expected) found=1 }
    END { exit !found }' <<< "$details"
}
WAS_LOADED=false
if launchctl print "$SERVICE" >/dev/null 2>&1; then
  loaded_expected || { echo 'Existing LaunchAgent points to an unexpected executable; no changes made' >&2; exit 1; }
  WAS_LOADED=true
fi
mkdir -p "$INSTALL_ROOT/Applications" "$AGENT_DIR"
STAGE="$(mktemp -d "$INSTALL_ROOT/Applications/.pet-meter-install.XXXXXX")"
REPLACED=false
SUCCESS=false
BOOTSTRAPPED=false
cleanup() {
  local status=$?
  if ! $SUCCESS && $REPLACED; then
    if $BOOTSTRAPPED && ! $WAS_LOADED; then
      launchctl bootout "$SERVICE" >/dev/null 2>&1 || echo 'Rollback could not unload the new job' >&2
    fi
    rm -rf "$APP_TARGET"
    if [[ -d "$STAGE/previous.app" ]]; then mv "$STAGE/previous.app" "$APP_TARGET"; fi
    if [[ -f "$STAGE/previous.plist" ]]; then
      cp -p "$STAGE/previous.plist" "$PLIST_PATH"
    else
      rm -f "$PLIST_PATH"
    fi
    if $WAS_LOADED; then launchctl kickstart -k "$SERVICE" >/dev/null 2>&1 || echo 'Rollback restored files; restart of the previous job failed' >&2; fi
    echo 'Installation failed; previous app and login item files restored' >&2
  fi
  rm -rf "$STAGE"
  exit "$status"
}
trap cleanup EXIT
# Stage and verify before replacing the installed app. Preferences are untouched.
ditto --norsrc --noextattr --noqtn "$APP_SOURCE" "$STAGE/$APP_NAME"
codesign --verify --deep --strict "$STAGE/$APP_NAME"
cmp "$APP_SOURCE/Contents/MacOS/codex-pet-hunger-meter" "$STAGE/$APP_NAME/Contents/MacOS/codex-pet-hunger-meter"
STAGED_PLIST="$STAGE/agent.plist"
plutil -create xml1 "$STAGED_PLIST"
plutil -insert Label -string com.codex-pet.hunger-meter "$STAGED_PLIST"
plutil -insert ProgramArguments -array "$STAGED_PLIST"
plutil -insert ProgramArguments.0 -string "$EXECUTABLE" "$STAGED_PLIST"
plutil -insert RunAtLoad -bool YES "$STAGED_PLIST"
plutil -insert KeepAlive -bool NO "$STAGED_PLIST"
plutil -insert StandardOutPath -string /tmp/codex-pet-hunger-meter.out.log "$STAGED_PLIST"
plutil -insert StandardErrorPath -string /tmp/codex-pet-hunger-meter.err.log "$STAGED_PLIST"
plutil -lint "$STAGED_PLIST"
if [[ -f "$PLIST_PATH" ]]; then cp -p "$PLIST_PATH" "$STAGE/previous.plist"; fi
if [[ -e "$APP_TARGET" ]]; then mv "$APP_TARGET" "$STAGE/previous.app"; fi
REPLACED=true
mv "$STAGE/$APP_NAME" "$APP_TARGET"
cp "$STAGED_PLIST" "$PLIST_PATH"
if ! $WAS_LOADED; then
  if launchctl bootstrap "$DOMAIN" "$PLIST_PATH"; then
    BOOTSTRAPPED=true
  elif ! loaded_expected; then
    echo 'LaunchAgent bootstrap failed and no matching registration appeared' >&2
    exit 1
  else
    BOOTSTRAPPED=true
  fi
fi
loaded_expected || { echo 'LaunchAgent registration does not match the installed executable' >&2; exit 1; }
launchctl kickstart -k "$SERVICE"
SUCCESS=true
echo "Installed: $APP_TARGET"
echo "Login item: $PLIST_PATH"
