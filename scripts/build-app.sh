#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
APP_DIR="$ROOT_DIR/dist/BlitzClean.app"
CONTENTS_DIR="$APP_DIR/Contents"
LOCAL_SIGNING_IDENTITY="$(security find-identity -v -p codesigning | awk -F '"' '/Apple Development:/ { print $2; exit }')"
SIGNING_IDENTITY="${BLITZCLEAN_SIGNING_IDENTITY:-${FREE_SPACE_SIGNING_IDENTITY:-$LOCAL_SIGNING_IDENTITY}}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "No Apple Development signing identity found. An ad-hoc build loses the Accessibility grant." >&2
    echo "Set BLITZCLEAN_SIGNING_IDENTITY=- to build ad-hoc anyway." >&2
    exit 1
fi
cd "$ROOT_DIR"
ARCH_FLAGS=()
BUILD_ARCHS="${BLITZCLEAN_BUILD_ARCHS:-}"
for ARCH in ${=BUILD_ARCHS}; do
    case "$ARCH" in
        arm64|x86_64) ARCH_FLAGS+=(--arch "$ARCH") ;;
        *) print -u2 "Unsupported architecture: $ARCH"; exit 1 ;;
    esac
done
swift build -c release -j "${BLITZCLEAN_BUILD_JOBS:-2}" "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"
"$ROOT_DIR/scripts/build-icon.sh"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$BIN_DIR/BlitzClean" "$CONTENTS_DIR/MacOS/BlitzClean"
cp "$ROOT_DIR/support/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/.build/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
cp "$ROOT_DIR/assets/brand/BlitzClean.icon/Assets/Mark.svg" "$CONTENTS_DIR/Resources/Mark.svg"
find "$APP_DIR" -name '._*' -delete
SIGNING_FLAGS=()
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    SIGNING_FLAGS=(--options runtime)
    if [[ "$SIGNING_IDENTITY" == *"Developer ID Application"* ]]; then
        SIGNING_FLAGS+=(--timestamp)
    fi
fi
codesign --force "${SIGNING_FLAGS[@]}" --entitlements "$ROOT_DIR/support/FreeSpace.entitlements" --sign "$SIGNING_IDENTITY" "$APP_DIR"
codesign --verify --strict "$APP_DIR"
echo "$APP_DIR"
