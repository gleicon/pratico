#!/usr/bin/env bash
# Builds dist/Pratico-<version>.dmg: the app, a link to Applications, the read-me, and a
# background that says what to do, laid out by Finder. Without Finder automation (CI, or
# permission declined) the layout is skipped and the DMG is still built.
# Usage: scripts/dmg.sh <app> <dmg> <version> <sign-identity>
set -euo pipefail

APP="${1:?app}" DMG="${2:?dmg}" VERSION="${3:?version}" IDENTITY="${4:?identity}"
VOLUME="Pratico $VERSION"
WORK="$(mktemp -d -t pratico-dmg)"
trap 'hdiutil detach "/Volumes/$VOLUME" -quiet 2>/dev/null || true; rm -rf "$WORK"' EXIT

STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp Support/dmg-README.txt "$STAGE/READ ME FIRST.txt"
cp "$APP/Contents/Resources/Acknowledgements.txt" "$STAGE/"
cp Support/dmg-background.tiff "$STAGE/.background/background.tiff"

RW="$WORK/rw.dmg"
hdiutil create -volname "$VOLUME" -srcfolder "$STAGE" -ov -format UDRW -fs HFS+ "$RW" -quiet
hdiutil attach "$RW" -readwrite -noverify -noautoopen -quiet

if osascript >/dev/null 2>&1 <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 840, 568}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 96
        set text size of opts to 12
        set background picture of opts to file ".background:background.tiff"
        set position of item "Pratico.app" of container window to {170, 196}
        set position of item "Applications" of container window to {470, 196}
        set position of item "READ ME FIRST.txt" of container window to {250, 330}
        set position of item "Acknowledgements.txt" of container window to {390, 330}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
then
    echo "dmg: Finder layout applied"
else
    echo "dmg: Finder automation unavailable; building without the layout"
fi
chmod -Rf go-w "/Volumes/$VOLUME" || true
sync
hdiutil detach "/Volumes/$VOLUME" -quiet
rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" -quiet
codesign --force --sign "$IDENTITY" "$DMG"
echo "dmg: $DMG"
