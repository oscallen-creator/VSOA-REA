#!/bin/bash
# Package FileChanger as a disk image for installing and testing it on a Mac.
#   scripts/make-dmg.sh   -> build/FileChanger.dmg
# Builds the release app and runs every unit test first (packaging stops if one fails). The image's window
# shows three items on a rendered background: FileChanger, Applications (drag to install), and
# "Setup & Test" (installs, then runs the bundled test runner). Finder lays out the window, so the first run
# may ask to let Terminal control Finder.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
VOL="FileChanger $VERSION"
[ -d "/Volumes/$VOL" ] && { echo "Eject the mounted \"$VOL\" disk first."; exit 1; }

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/filechanger-dmg.XXXXXX")"
RW="$STAGE.rw.dmg"
MNT=""
cleanup() { if [ -n "$MNT" ]; then hdiutil detach "$MNT" -quiet -force; fi; rm -rf "$STAGE" "$RW"; }
trap cleanup EXIT
mkdir "$STAGE/.support" "$STAGE/.background"

scripts/build.sh release
TEST_BIN="$STAGE/.support/FileChangerTests" scripts/test.sh
[ -f dmg/background@2x.png ] || swift scripts/make-dmg-background.swift

ditto build/FileChanger.app "$STAGE/FileChanger.app"
ln -s /Applications "$STAGE/Applications"
cp "dmg/Setup & Test.command" "$STAGE/"
chmod +x "$STAGE/Setup & Test.command"
SetFile -a E "$STAGE/Setup & Test.command"   # label it "Setup & Test"
tiffutil -cathidpicheck dmg/background.png dmg/background@2x.png -out "$STAGE/.background/background.tiff"
cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"

# Lay out the window on a writable copy; Finder saves it in the volume's .DS_Store.
# Window and icon positions match the layout scripts/make-dmg-background.swift draws for (720 x 460 points
# of content; the window bounds add Finder's 28-point title bar).
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
hdiutil attach -readwrite -noverify -noautoopen "$RW" >/dev/null
MNT="/Volumes/$VOL"
SetFile -a C "$MNT"   # use .VolumeIcon.icns
# Finder can lag behind the mount (especially right after a disk of the same name was ejected).
for _ in $(seq 20); do
  [ "$(osascript -e "tell application \"Finder\" to exists disk \"$VOL\"")" = true ] && break
  sleep 0.5
done
osascript <<EOF
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 920, 608}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "FileChanger.app" to {170, 205}
    set position of item "Applications" to {550, 205}
    set position of item "Setup & Test.command" to {360, 340}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
rm -rf "$MNT/.fseventsd"
sync
hdiutil detach "$MNT" -quiet
MNT=""

hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -ov -o build/FileChanger.dmg >/dev/null
echo "made build/FileChanger.dmg"
