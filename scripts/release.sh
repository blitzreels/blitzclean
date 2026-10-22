#!/bin/zsh
# One command for a release: ./scripts/release.sh 1.6.0
# Sets the version, dates the changelog, checks, signs, notarizes, tags, pushes and publishes the GitHub release,
# with appcast.xml uploaded last so installed apps only see a release that is complete. Keys stay in the keychain.
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

VERSION="${1:-}"
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    print -u2 "Usage: ./scripts/release.sh 1.6.0"
    exit 2
fi
TAG="v$VERSION"
REPO="blitzreels/blitzclean"
PLIST="support/Info.plist"

if [[ "$(git branch --show-current)" != "main" ]]; then
    print -u2 "Release from main."
    exit 1
fi
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    print -u2 "Commit or stash your changes first."
    exit 1
fi
git fetch --quiet origin main --tags
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
    print -u2 "main is not the same as origin/main; pull or push first."
    exit 1
fi
if git rev-parse --quiet --verify "refs/tags/$TAG" >/dev/null; then
    print -u2 "$TAG already exists."
    exit 1
fi
if ! grep -q '^## Unreleased' CHANGELOG.md; then
    print -u2 "CHANGELOG.md needs a '## Unreleased' section with this release's notes."
    exit 1
fi

IDENTITY="${BLITZCLEAN_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning \
    | awk -F '"' '/Developer ID Application/ { print $2; exit }')}"
if [[ -z "$IDENTITY" ]]; then
    print -u2 "No Developer ID Application identity in the keychain."
    exit 1
fi
if [[ -z "${NOTARY_PROFILE:-}" ]]; then
    export BLITZCLEAN_ASC_PROFILE="${BLITZCLEAN_ASC_PROFILE:-blitzrecorder}"
fi

# Until the release commit exists, a failure puts the version and changelog back as they were.
restore_unreleased() { git checkout --quiet -- "$PLIST" CHANGELOG.md }
trap restore_unreleased ZERR INT

BUILD=$(( $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST") + 1 ))
plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST"
plutil -replace CFBundleVersion -string "$BUILD" "$PLIST"
sed -i '' "s/^## Unreleased.*/## $VERSION - $(date +%Y-%m-%d)/" CHANGELOG.md
print "Releasing BlitzClean $VERSION build $BUILD"

./scripts/check.sh
rm -f dist/appcast.xml
BLITZCLEAN_SIGNING_IDENTITY="$IDENTITY" ./scripts/package-release.sh
ARCHIVE="dist/BlitzClean-$VERSION-macOS.zip"
for FILE in "$ARCHIVE" "$ARCHIVE.sha256" dist/appcast.xml; do
    if [[ ! -f "$FILE" ]]; then
        print -u2 "Packaging did not produce $FILE; nothing was committed or published."
        restore_unreleased
        exit 1
    fi
done

git add "$PLIST" CHANGELOG.md
git commit --quiet -m "Release BlitzClean $VERSION"
trap - ZERR INT
git tag "$TAG"
git push --quiet origin main "$TAG"

NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT
awk -v version="$VERSION" '
    $0 ~ "^## " version "( |$)" { found = 1; next }
    found && /^## / { exit }
    found { print }
' CHANGELOG.md > "$NOTES"
gh release create "$TAG" "$ARCHIVE" "$ARCHIVE.sha256" -R "$REPO" --title "BlitzClean $VERSION" \
    --notes-file "$NOTES" --verify-tag

CHECK_DIR="$(mktemp -d)"
gh release download "$TAG" -R "$REPO" --pattern "${ARCHIVE:t}*" --dir "$CHECK_DIR"
(cd "$CHECK_DIR" && shasum -a 256 -c "${ARCHIVE:t}.sha256" >/dev/null)
rm -rf "$CHECK_DIR"

gh release upload "$TAG" dist/appcast.xml -R "$REPO"
print "Published https://github.com/$REPO/releases/tag/$TAG"
