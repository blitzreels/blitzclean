#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
APP_DIR="$ROOT_DIR/dist/BlitzClean.app"
CONTENTS_DIR="$APP_DIR/Contents"
SIGNING_IDENTITY="${BLITZCLEAN_SIGNING_IDENTITY:-${FREE_SPACE_SIGNING_IDENTITY:--}}"
cd "$ROOT_DIR"
swift build -c release -j "${BLITZCLEAN_BUILD_JOBS:-2}"
BIN_DIR="$(swift build -c release --show-bin-path)"
"$ROOT_DIR/scripts/build-icon.sh"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$BIN_DIR/BlitzClean" "$CONTENTS_DIR/MacOS/BlitzClean"
cp "$ROOT_DIR/support/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/.build/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
find "$APP_DIR" -name '._*' -delete
SIGNING_FLAGS=()
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    SIGNING_FLAGS=(--options runtime --timestamp)
fi
codesign --force "${SIGNING_FLAGS[@]}" --entitlements "$ROOT_DIR/support/FreeSpace.entitlements" --sign "$SIGNING_IDENTITY" "$APP_DIR"
codesign --verify --strict "$APP_DIR"
echo "$APP_DIR"
