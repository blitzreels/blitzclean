#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
IDENTITY="${BLITZCLEAN_SIGNING_IDENTITY:-}"
if [[ "$IDENTITY" != "Developer ID Application:"* ]]; then
    print -u2 "Set BLITZCLEAN_SIGNING_IDENTITY to an installed Developer ID Application identity."
    exit 1
fi
BLITZCLEAN_BUILD_ARCHS="arm64 x86_64" "$ROOT_DIR/scripts/build-app.sh"
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
        xcrun notarytool submit "$ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$RECEIPT"
    else
        asc --profile "$BLITZCLEAN_ASC_PROFILE" notarization submit --file "$ARCHIVE" --wait --output json > "$RECEIPT"
    fi
    STATUS="$(plutil -extract status raw -o - "$RECEIPT")"
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
