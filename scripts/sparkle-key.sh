#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
ACCOUNT="${BLITZCLEAN_SPARKLE_ACCOUNT:-blitzreels-blitzclean}"
TOOLS="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin"
if [[ ! -x "$TOOLS/generate_keys" ]]; then
    (cd "$ROOT_DIR" && swift package resolve >/dev/null)
fi
if ! "$TOOLS/generate_keys" --account "$ACCOUNT" -p >/dev/null 2>&1; then
    "$TOOLS/generate_keys" --account "$ACCOUNT" >/dev/null
    print -u2 "Created the Sparkle signing key in the login keychain (account $ACCOUNT)."
    print -u2 "Back it up now; without it, installed copies cannot accept future updates:"
    print -u2 "  $TOOLS/generate_keys --account $ACCOUNT -x <path outside the repository>"
fi
"$TOOLS/generate_keys" --account "$ACCOUNT" -p
