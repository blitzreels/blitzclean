#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
ICONSET="$ROOT_DIR/.build/AppIcon.iconset"
SOURCE="$ROOT_DIR/assets/brand/app-icon.png"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$SOURCE" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" "$SOURCE" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
find "$ICONSET" -name '._*' -delete
iconutil -c icns "$ICONSET" -o "$ROOT_DIR/.build/AppIcon.icns"
