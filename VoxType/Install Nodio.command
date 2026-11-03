#!/bin/bash
# Copies Nodio to Applications, removes the download quarantine, and opens it.
set -euo pipefail

APP="Nodio.app"
DEST="/Applications/$APP"
SRC="$(cd "$(dirname "$0")" && pwd)/$APP"

[ -d "$SRC" ] || { echo "Cannot find $APP next to this script."; exit 1; }

pkill -x Nodio 2>/dev/null || true
echo "→ Copying $APP to /Applications…"
if ! { rm -rf "$DEST" && ditto "$SRC" "$DEST"; } 2>/dev/null; then
  echo "→ Administrator password needed."
  sudo rm -rf "$DEST"
  sudo ditto "$SRC" "$DEST"
fi

echo "→ Removing quarantine…"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || sudo xattr -dr com.apple.quarantine "$DEST"

echo "→ Removing old Accessibility entry…"
tccutil reset Accessibility com.nodio.app >/dev/null 2>&1 || true

echo "→ Opening Nodio…"
open "$DEST"
echo "Done. You can close this window."
