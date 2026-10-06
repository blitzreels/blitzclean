#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"
swift build -j "${BLITZCLEAN_BUILD_JOBS:-2}"
swift test --no-parallel -j "${BLITZCLEAN_BUILD_JOBS:-2}"
xcrun swift-format lint --strict --recursive Sources Tests Package.swift
plutil -lint support/Info.plist support/BlitzClean.entitlements
for SCRIPT in scripts/*.sh script/build_and_run.sh; do
    zsh -n "$SCRIPT"
done
