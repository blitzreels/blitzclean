#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
APP_DIR="$ROOT_DIR/dist/BlitzClean.app"
CONTENTS_DIR="$APP_DIR/Contents"
LOCAL_SIGNING_IDENTITY="$(security find-identity -v -p codesigning | awk -F '"' '/Apple Development:/ { print $2; exit }')"
SIGNING_IDENTITY="${BLITZCLEAN_SIGNING_IDENTITY:-$LOCAL_SIGNING_IDENTITY}"
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
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources" "$CONTENTS_DIR/Frameworks"
cp "$BIN_DIR/BlitzClean" "$CONTENTS_DIR/MacOS/BlitzClean"
ditto "$BIN_DIR/Sparkle.framework" "$CONTENTS_DIR/Frameworks/Sparkle.framework"
cp "$ROOT_DIR/.build/artifacts/sparkle/Sparkle/LICENSE" "$CONTENTS_DIR/Resources/Sparkle-LICENSE.txt"
cp "$ROOT_DIR/licenses/OrphanBar-LICENSE.txt" "$CONTENTS_DIR/Resources/OrphanBar-LICENSE.txt"
if ! otool -l "$CONTENTS_DIR/MacOS/BlitzClean" | grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$CONTENTS_DIR/MacOS/BlitzClean"
fi
cp "$ROOT_DIR/support/Info.plist" "$CONTENTS_DIR/Info.plist"
# Only release packaging passes the key; development builds never update themselves.
if [[ -n "${BLITZCLEAN_SPARKLE_PUBLIC_KEY:-}" ]]; then
    PLIST="$CONTENTS_DIR/Info.plist"
    plutil -replace SUFeedURL -string "${BLITZCLEAN_SPARKLE_FEED_URL:-https://github.com/blitzreels/blitzclean/releases/latest/download/appcast.xml}" "$PLIST"
    plutil -replace SUPublicEDKey -string "$BLITZCLEAN_SPARKLE_PUBLIC_KEY" "$PLIST"
    plutil -replace SUEnableAutomaticChecks -bool YES "$PLIST"
    plutil -replace SUAutomaticallyUpdate -bool YES "$PLIST"
    plutil -replace SUScheduledCheckInterval -integer 86400 "$PLIST"
    plutil -replace SUVerifyUpdateBeforeExtraction -bool YES "$PLIST"
fi
cp "$ROOT_DIR/.build/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
cp "$ROOT_DIR/assets/brand/BlitzClean.icon/Assets/Mark.svg" "$CONTENTS_DIR/Resources/Mark.svg"
cp "$ROOT_DIR"/assets/brand/family/*.png "$CONTENTS_DIR/Resources/"
find "$APP_DIR" -name '._*' -delete
SIGNING_FLAGS=()
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    SIGNING_FLAGS=(--options runtime)
    if [[ "$SIGNING_IDENTITY" == *"Developer ID Application"* ]]; then
        SIGNING_FLAGS+=(--timestamp)
    fi
fi
SPARKLE="$CONTENTS_DIR/Frameworks/Sparkle.framework/Versions/B"
codesign --force "${SIGNING_FLAGS[@]}" --sign "$SIGNING_IDENTITY" "$SPARKLE/XPCServices/Installer.xpc"
codesign --force "${SIGNING_FLAGS[@]}" --preserve-metadata=entitlements --sign "$SIGNING_IDENTITY" "$SPARKLE/XPCServices/Downloader.xpc"
codesign --force "${SIGNING_FLAGS[@]}" --sign "$SIGNING_IDENTITY" "$SPARKLE/Autoupdate"
codesign --force "${SIGNING_FLAGS[@]}" --sign "$SIGNING_IDENTITY" "$SPARKLE/Updater.app"
codesign --force "${SIGNING_FLAGS[@]}" --sign "$SIGNING_IDENTITY" "$CONTENTS_DIR/Frameworks/Sparkle.framework"
codesign --force "${SIGNING_FLAGS[@]}" --entitlements "$ROOT_DIR/support/BlitzClean.entitlements" --sign "$SIGNING_IDENTITY" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
echo "$APP_DIR"
