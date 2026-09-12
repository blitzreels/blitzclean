#!/bin/zsh

set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="${0:A:h:h}"
APP_NAME="BlitzClean"
APP_BUNDLE="$HOME/Applications/$APP_NAME.app"
APP_BINARY="$ROOT_DIR/dist/$APP_NAME.app/Contents/MacOS/$APP_NAME"

case "$MODE" in
    run)
        "$ROOT_DIR/scripts/install.sh"
        ;;
    --debug|debug)
        pkill -x "$APP_NAME" 2>/dev/null || true
        "$ROOT_DIR/scripts/build-app.sh"
        lldb -- "$APP_BINARY"
        ;;
    --logs|logs)
        "$ROOT_DIR/scripts/install.sh"
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
        ;;
    --telemetry|telemetry)
        "$ROOT_DIR/scripts/install.sh"
        /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.blitzreels.BlitzClean"'
        ;;
    --verify|verify)
        "$ROOT_DIR/scripts/install.sh"
        sleep 1
        pgrep -x "$APP_NAME" >/dev/null
        test -x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
        ;;
    *)
        print -u2 "usage: $0 [run|--debug|--logs|--telemetry|--verify]"
        exit 2
        ;;
esac
