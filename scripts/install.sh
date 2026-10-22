#!/bin/zsh
# Builds and installs into ~/Applications, then opens the dashboard.
# BLITZCLEAN_DEV=1 installs "BlitzClean Dev" beside the released app instead; each only ever stops itself.
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
APP_NAME="BlitzClean"
[[ "${BLITZCLEAN_DEV:-0}" == "1" ]] && APP_NAME="BlitzClean Dev"
SOURCE_APP="$ROOT_DIR/dist/$APP_NAME.app"
TARGET_APP="$HOME/Applications/$APP_NAME.app"
RUNNING="$TARGET_APP/Contents/"
"$ROOT_DIR/scripts/build-app.sh"
mkdir -p "$HOME/Applications"
pkill -f "$RUNNING" 2>/dev/null || true
for attempt in {1..50}; do
    if ! pgrep -f "$RUNNING" >/dev/null; then
        break
    fi
    sleep 0.1
done
if pgrep -f "$RUNNING" >/dev/null; then
    print -u2 "The previous app is still exiting; installation stopped."
    exit 1
fi
if [[ -d "$TARGET_APP" ]]; then
    BACKUP_DIR="$HOME/Library/Application Support/$APP_NAME/Backups/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    ditto -c -k --keepParent "$TARGET_APP" "$BACKUP_DIR/$APP_NAME.zip"
    rm -rf "$TARGET_APP"
fi
ditto "$SOURCE_APP" "$TARGET_APP"
open "$TARGET_APP" --args --dashboard
echo "$TARGET_APP"
