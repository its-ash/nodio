#!/bin/bash
# Builds a styled Nodio DMG: background image, icon layout, Read Me, and Fix Nodio.terminal.
# Usage: dmg/make.sh <path/to/Nodio.app> <out.dmg>
set -euo pipefail

APP="${1:?usage: make.sh <Nodio.app> <out.dmg>}"
OUT="${2:?usage: make.sh <Nodio.app> <out.dmg>}"
VOL="Nodio"
HERE="$(cd "$(dirname "$0")" && pwd)"

[ -d "$APP" ] || { echo "make.sh: $APP not found" >&2; exit 1; }

TMP="$(mktemp -d)"
MNT=""
cleanup() {
  [ -n "$MNT" ] && hdiutil detach "$MNT" -force -quiet 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

STAGE="$TMP/stage"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/Nodio.app"
ln -s /Applications "$STAGE/Applications"
cp "$HERE/Read Me.txt" "$HERE/Fix Nodio.terminal" "$STAGE/"

echo "→ Drawing DMG background…"
swift "$HERE/background.swift" "$TMP/bg"
tiffutil -cathidpicheck "$TMP/bg.png" "$TMP/bg@2x.png" -out "$STAGE/.background/background.tiff" >/dev/null 2>&1

echo "→ Creating disk image…"
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -size "${SIZE_MB}m" -ov "$TMP/rw.dmg" -quiet
MNT="$(hdiutil attach "$TMP/rw.dmg" -readwrite -noverify -noautoopen | awk -F'\t' '/\/Volumes\//{print $NF; exit}')"
[ -n "$MNT" ] || { echo "make.sh: cannot mount image" >&2; exit 1; }

echo "→ Arranging the window (Finder may ask for permission)…"
osascript - "$(basename "$MNT")" <<'APPLESCRIPT'
on run argv
  set diskName to item 1 of argv
  tell application "Finder"
    tell disk diskName
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set bounds of container window to {200, 120, 860, 588}
      set opts to icon view options of container window
      set arrangement of opts to not arranged
      set icon size of opts to 96
      set text size of opts to 12
      set background picture of opts to file ".background:background.tiff"
      set position of item "Nodio.app" of container window to {165, 150}
      set position of item "Applications" of container window to {495, 150}
      set position of item "Read Me.txt" of container window to {250, 300}
      set position of item "Fix Nodio.terminal" of container window to {410, 300}
      update without registering applications
      delay 1
      close
    end tell
  end tell
end run
APPLESCRIPT

chmod -Rf go-w "$MNT" 2>/dev/null || true
sync
hdiutil detach "$MNT" -quiet
MNT=""

echo "→ Compressing…"
rm -f "$OUT"
hdiutil convert "$TMP/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT" -quiet
echo "→ Built $OUT"
