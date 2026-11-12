#!/bin/bash
# Fast type-check, no binary. Builders run this after every change.
#   scripts/check.sh            whole app module
#   scripts/check.sh image      only Sources/Core + Sources/UI + Sources/Image (unaffected by other areas' work)
#   (areas: image, media, conversion, shell)
set -euo pipefail
cd "$(dirname "$0")/.."
AREA="${1:-}"
SOURCES=()
if [ -z "$AREA" ]; then
  while IFS= read -r f; do SOURCES+=("$f"); done < <(find Sources -name '*.swift' | sort)
else
  dir="Sources/$(echo "${AREA:0:1}" | tr a-z A-Z)${AREA:1}"
  [ -d "$dir" ] || { echo "no such area: $dir"; exit 2; }
  while IFS= read -r f; do SOURCES+=("$f"); done < <(find Sources/Core Sources/UI "$dir" -name '*.swift' | sort)
  # The shell needs the catalog stubs of other areas; type-check against their current files.
  if [ "$AREA" = shell ]; then
    while IFS= read -r f; do SOURCES+=("$f"); done < <(find Sources/App Sources/Image Sources/Media Sources/Conversion -name '*.swift' | sort)
  fi
fi
if out=$(swiftc -typecheck -parse-as-library -swift-version 5 -target arm64-apple-macos14.0 \
    -module-name FileChanger "${SOURCES[@]}" 2>&1); then
  echo "typecheck ok (${#SOURCES[@]} files)"
else
  echo "$out" | grep -v "warning:" | grep -A3 "error:" | head -80
  echo "typecheck FAILED"; exit 1
fi
