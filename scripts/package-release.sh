#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
IDENTITY="${BLITZCLEAN_SIGNING_IDENTITY:-}"
if [[ "$IDENTITY" != "Developer ID Application:"* ]]; then
    print -u2 "Set BLITZCLEAN_SIGNING_IDENTITY to an installed Developer ID Application identity."
    exit 1
fi
SPARKLE_ACCOUNT="${BLITZCLEAN_SPARKLE_ACCOUNT:-blitzreels-blitzclean}"
SPARKLE_TOOLS="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin"
SPARKLE_PUBLIC_KEY=""
if [[ "${BLITZCLEAN_SKIP_UPDATES:-0}" != "1" ]]; then
    (cd "$ROOT_DIR" && swift package resolve >/dev/null)
    if ! SPARKLE_PUBLIC_KEY="$("$SPARKLE_TOOLS/generate_keys" --account "$SPARKLE_ACCOUNT" -p 2>/dev/null)"; then
        print -u2 "No Sparkle signing key in the login keychain. Run ./scripts/sparkle-key.sh once and back it up,"
        print -u2 "or set BLITZCLEAN_SKIP_UPDATES=1 to package a build that cannot update itself."
        exit 1
    fi
fi
BLITZCLEAN_SPARKLE_PUBLIC_KEY="$SPARKLE_PUBLIC_KEY" BLITZCLEAN_BUILD_ARCHS="arm64 x86_64" \
    "$ROOT_DIR/scripts/build-app.sh"
APP_DIR="$ROOT_DIR/dist/BlitzClean.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
ARCHIVE="$ROOT_DIR/dist/BlitzClean-$VERSION-macOS.zip"
ARCHS=" $(lipo -archs "$APP_DIR/Contents/MacOS/BlitzClean") "
if [[ "$ARCHS" != *" arm64 "* || "$ARCHS" != *" x86_64 "* ]]; then
    print -u2 "The release must contain both arm64 and x86_64: $ARCHS"
    exit 1
fi
codesign --verify --deep --strict "$APP_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE"
if [[ -n "${NOTARY_PROFILE:-}" || -n "${BLITZCLEAN_ASC_PROFILE:-}" ]]; then
    RECEIPT="$ROOT_DIR/dist/notarization-$VERSION.json"
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        STATUS_PATH="status"
        xcrun notarytool submit "$ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$RECEIPT"
    else
        STATUS_PATH="data.attributes.status"
        asc --profile "$BLITZCLEAN_ASC_PROFILE" notarization submit --file "$ARCHIVE" --wait --output json > "$RECEIPT"
    fi
    STATUS="$(plutil -extract "$STATUS_PATH" raw -o - "$RECEIPT")"
    if [[ "$STATUS" != "Accepted" ]]; then
        print -u2 "Notarization failed: $STATUS. See $RECEIPT."
        exit 1
    fi
    xcrun stapler staple "$APP_DIR"
    xcrun stapler validate "$APP_DIR"
    spctl --assess --type execute --verbose=2 "$APP_DIR"
    ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE"
else
    print -u2 "Signed preview only: no notarization profile is configured; this build is not notarized."
fi
cd "$ROOT_DIR/dist"
shasum -a 256 "${ARCHIVE:t}" > "${ARCHIVE:t}.sha256"
print "$ARCHIVE"
print "$ARCHIVE.sha256"
if [[ -n "$SPARKLE_PUBLIC_KEY" && -n "${RECEIPT:-}" ]]; then
    RELEASE_URL="https://github.com/blitzreels/blitzclean/releases"
    APPCAST_DIR="$(mktemp -d)"
    trap 'rm -rf "$APPCAST_DIR"' EXIT
    cp "$ARCHIVE" "$APPCAST_DIR/"
    awk -v version="$VERSION" '
        $0 ~ "^## " version "( |$)" { found = 1; next }
        found && /^## / { exit }
        found { print }
    ' "$ROOT_DIR/CHANGELOG.md" > "$APPCAST_DIR/${ARCHIVE:t:r}.md"
    "$SPARKLE_TOOLS/generate_appcast" --account "$SPARKLE_ACCOUNT" \
        --download-url-prefix "$RELEASE_URL/download/v$VERSION/" \
        --full-release-notes-url "$RELEASE_URL/tag/v$VERSION" \
        --link "https://github.com/blitzreels/blitzclean" \
        --embed-release-notes --maximum-versions 1 \
        -o "$ROOT_DIR/dist/appcast.xml" "$APPCAST_DIR" >/dev/null
    print "$ROOT_DIR/dist/appcast.xml"
elif [[ -n "$SPARKLE_PUBLIC_KEY" ]]; then
    print -u2 "No appcast: only notarized builds are offered as updates."
fi
