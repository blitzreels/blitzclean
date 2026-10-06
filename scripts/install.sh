#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
SOURCE_APP="$ROOT_DIR/dist/BlitzClean.app"
TARGET_APP="$HOME/Applications/BlitzClean.app"
"$ROOT_DIR/scripts/build-app.sh"
mkdir -p "$HOME/Applications"
pkill -x BlitzClean 2>/dev/null || true
for attempt in {1..50}; do
    if ! pgrep -x BlitzClean >/dev/null; then
        break
    fi
    sleep 0.1
done
if pgrep -x BlitzClean >/dev/null; then
    print -u2 "The previous app is still exiting; installation stopped."
    exit 1
fi
if [[ -d "$TARGET_APP" ]]; then
    BACKUP_DIR="$HOME/Library/Application Support/BlitzClean/Backups/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    ditto -c -k --keepParent "$TARGET_APP" "$BACKUP_DIR/BlitzClean.zip"
    rm -rf "$TARGET_APP"
fi
ditto "$SOURCE_APP" "$TARGET_APP"
open "$TARGET_APP" --args --dashboard
echo "$TARGET_APP"
