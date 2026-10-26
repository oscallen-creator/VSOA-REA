#!/bin/sh
# Builds the macOS disk image into out/.
# - electron-builder refuses to sign in a path with an apostrophe ("Oscar's Whisper"), so it
#   builds through a symlink without one.
# - It signs with the "OscarsWhisper Dev" certificate when this Mac has one, so macOS keeps
#   the Accessibility permission across rebuilds (README, "Install it as a desktop app
#   (macOS)"). Without it the app is signed ad-hoc and loses the permission on every rebuild.
set -e
link="$TMPDIR/oscars-whisper"
ln -sfn "$PWD" "$link"
identity=-
if security find-identity -v -p codesigning | grep -q '"OscarsWhisper Dev"'; then
  identity="OscarsWhisper Dev"
fi
echo "[dist-mac] signing as: $identity"
exec npx electron-builder --projectDir "$link" --mac --arm64 -c.mac.identity="$identity"
