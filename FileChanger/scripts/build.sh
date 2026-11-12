#!/bin/bash
# Build FileChanger.app with swiftc directly. SwiftPM is not used: on Command Line Tools 16.2
# its PackageDescription library does not match the compiler, so manifests fail to link.
#   scripts/build.sh            debug build  -> build/FileChanger.app
#   scripts/build.sh release    optimized build
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-debug}"
# BUILD_DIR lets parallel builds (e.g. reviewers) use their own folder.
BUILD_DIR="${BUILD_DIR:-build}"
APP="$BUILD_DIR/FileChanger.app"
OPT=(-Onone -g)
[ "$MODE" = release ] && OPT=(-O -whole-module-optimization)

mkdir -p "$BUILD_DIR"
# All app sources compile as one module. Tests/ is excluded. Compile a snapshot so files edited
# mid-build (by a person or another agent) can't fail the compile with "modified during the build".
SNAP="$(mktemp -d "${TMPDIR:-/tmp}/filechanger-src.XXXXXX")"
trap 'rm -rf "$SNAP"' EXIT
rsync -a --include='*/' --include='*.swift' --exclude='*' Sources/ "$SNAP/Sources/"
SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find "$SNAP/Sources" -name '*.swift' | sort)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc "${OPT[@]}" -parse-as-library -swift-version 5 -target arm64-apple-macos14.0 \
  -module-name FileChanger -num-threads 8 \
  "${SOURCES[@]}" -o "$APP/Contents/MacOS/FileChanger"

[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift
cp Resources/Info.plist "$APP/Contents/Info.plist"
find Resources -mindepth 1 -maxdepth 1 ! -name Info.plist -exec cp -R {} "$APP/Contents/Resources/" \;

# Ad-hoc signature, no hardened runtime: personal build, same as Oscar's Whisper.
codesign --force --deep --sign - "$APP"
echo "built $APP ($MODE)"
