#!/bin/zsh

set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="${0:A:h:h}"
# Local runs install "BlitzClean Dev" beside the released app, so the two can be compared side by side.
# The released app only changes through ./scripts/release.sh and its automatic update.
export BLITZCLEAN_DEV="${BLITZCLEAN_DEV:-1}"
APP_NAME="BlitzClean"
[[ "$BLITZCLEAN_DEV" == "1" ]] && APP_NAME="BlitzClean Dev"
APP_BUNDLE="$HOME/Applications/$APP_NAME.app"
APP_BINARY="$ROOT_DIR/dist/$APP_NAME.app/Contents/MacOS/BlitzClean"

case "$MODE" in
    run)
        "$ROOT_DIR/scripts/install.sh"
        ;;
    --debug|debug)
        pkill -f "$APP_BUNDLE/Contents/" 2>/dev/null || true
        "$ROOT_DIR/scripts/build-app.sh"
        lldb -- "$APP_BINARY"
        ;;
    --logs|logs)
        "$ROOT_DIR/scripts/install.sh"
        /usr/bin/log stream --info --style compact --predicate "process == \"BlitzClean\""
        ;;
    --telemetry|telemetry)
        "$ROOT_DIR/scripts/install.sh"
        /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.blitzreels.BlitzClean"'
        ;;
    --verify|verify)
        "$ROOT_DIR/scripts/install.sh"
        sleep 1
        pgrep -f "$APP_BUNDLE/Contents/MacOS/BlitzClean" >/dev/null
        test -x "$APP_BUNDLE/Contents/MacOS/BlitzClean"
        ;;
    *)
        print -u2 "usage: $0 [run|--debug|--logs|--telemetry|--verify]"
        exit 2
        ;;
esac
