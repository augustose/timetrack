#!/usr/bin/env bash
#
# Rebuild, reinstall and restart TimeTrack after a code change.
#
# The order matters: the app has to stop before /Applications is overwritten,
# and the login agent has to be re-bootstrapped afterwards or launchd keeps
# pointing at the binary that is no longer there.
#
#   ./scripts/dev-install.sh                    build, install, restart
#   ./scripts/dev-install.sh --cli-only         skip the menu bar app
#   ./scripts/dev-install.sh --no-agent         install but do not restart the agent
#   ./scripts/dev-install.sh --reset-permission clear the stale Accessibility grant
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

APP_NAME="TimeTrackBar"
CLI_NAME="timetrack"
AGENT_ID="ca.senet.timetrackbar"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
APP_PATH="/Applications/${APP_NAME}.app"

CLI_ONLY=0
NO_AGENT=0
RESET_PERMISSION=0

for arg in "$@"; do
  case "$arg" in
    --cli-only)         CLI_ONLY=1 ;;
    --no-agent)         NO_AGENT=1 ;;
    --reset-permission) RESET_PERMISSION=1 ;;
    -h|--help)          sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
note() { printf '    %s\n' "$1"; }
warn() { printf '\n\033[33m!!  %s\033[0m\n' "$1"; }

# --- 1. Stop whatever is currently running ---------------------------------
step "Stopping the running sampler"

if [ "$NO_AGENT" -eq 0 ]; then
  launchctl bootout "gui/$(id -u)/${AGENT_ID}" 2>/dev/null && note "login agent unloaded" \
    || note "login agent was not loaded"
fi

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  pkill -x "$APP_NAME" || true
  # KeepAlive can race us; give launchd a moment to give up.
  for _ in 1 2 3 4 5; do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
    sleep 0.4
  done
  note "menu bar app stopped"
fi

if pgrep -f "${CLI_NAME} run" >/dev/null 2>&1; then
  pkill -f "${CLI_NAME} run" || true
  note "CLI sampler stopped"
fi

# A sampler killed mid-tick can leave the lock behind.
rm -f "$HOME/.local/state/timetrack/sampler.lock"

# --- 2. Build ---------------------------------------------------------------
step "Building"
if [ "$CLI_ONLY" -eq 1 ]; then
  make build
else
  make bundle
fi

# --- 3. Install -------------------------------------------------------------
step "Installing"
make install-cli
if [ "$CLI_ONLY" -eq 0 ]; then
  make install-app
fi

# --- 4. Accessibility -------------------------------------------------------
# macOS keys the Accessibility grant to the code signature. An ad-hoc rebuild
# produces a new signature, so the old entry stays in the list looking enabled
# while actually granting nothing — window titles silently go blank.
SIGNATURE="$(codesign -dvv "$APP_PATH" 2>&1 | grep -i '^Signature=' | head -1 || true)"
ADHOC=0
case "$SIGNATURE" in *adhoc*) ADHOC=1 ;; esac

if [ "$RESET_PERMISSION" -eq 1 ]; then
  step "Resetting the Accessibility grant"
  tccutil reset Accessibility ca.senet.timetrackbar 2>/dev/null || true
  note "cleared — the app will ask again on next launch"
fi

# --- 5. Restart -------------------------------------------------------------
if [ "$CLI_ONLY" -eq 0 ] && [ "$NO_AGENT" -eq 0 ]; then
  step "Restarting"
  make agent
fi

# --- 6. Report --------------------------------------------------------------
step "Result"

if [ -n "$SIGNATURE" ]; then
  note "$SIGNATURE"
fi

if command -v "$BIN_DIR/$CLI_NAME" >/dev/null 2>&1; then
  "$BIN_DIR/$CLI_NAME" status || true
fi

if [ "$ADHOC" -eq 1 ]; then
  warn "This build is ad-hoc signed."
  cat <<'EOF'
    macOS ties the Accessibility grant to the signature, so every rebuild looks
    like a different app: the entry stays checked in System Settings but grants
    nothing, and window titles come back empty.

    Two ways out:

      1. Create the stable certificate once (recommended):
           make signing-help
         Name it exactly "TimeTrack Self-Signed", type Code Signing,
         Self Signed Root. After that this script is a one-liner forever.

      2. Until then, after each rebuild:
           ./scripts/dev-install.sh --reset-permission
         then re-approve TimeTrackBar when it asks.
EOF
fi
