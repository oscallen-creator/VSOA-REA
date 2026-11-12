#!/bin/bash
# Compile non-UI sources with Tests/ into one runner and execute it. XCTest needs Xcode, so tests use
# the tiny harness in Tests/Harness.swift.
#   scripts/test.sh            all areas: Sources/Core + every Sources/*/Engine + all of Tests/
#   scripts/test.sh image      one area only: Sources/Core + Sources/Image/Engine + Tests/ImageTests.swift
#                              (areas: core, image, media, conversion, shell), unaffected by other areas' code
set -euo pipefail
cd "$(dirname "$0")/.."

# A private output path per run: several agents may test at the same time.
OUT="$(mktemp -d "${TMPDIR:-/tmp}/filechanger-tests.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

AREA="${1:-}"
SOURCES=()
if [ -z "$AREA" ]; then
  while IFS= read -r f; do SOURCES+=("$f"); done < <(
    { find Sources/Core -name '*.swift'; find Sources -path '*/Engine/*' -name '*.swift'; find Tests -name '*.swift'; } | sort -u)
else
  Cap="$(echo "${AREA:0:1}" | tr a-z A-Z)${AREA:1}"
  [ -f "Tests/${Cap}Tests.swift" ] || { echo "no such area: $AREA"; exit 2; }
  while IFS= read -r f; do SOURCES+=("$f"); done < <(
    { find Sources/Core -name '*.swift'; [ -d "Sources/$Cap/Engine" ] && find "Sources/$Cap/Engine" -name '*.swift'; } | sort -u)
  printf 'enum TestSuites {\n    static var all: [Suite] { %sSuites }\n}\n' "$AREA" > "$OUT/AllSuites.swift"
  SOURCES+=(Tests/Harness.swift "Tests/${Cap}Tests.swift" "$OUT/AllSuites.swift")
fi

swiftc -Onone -parse-as-library -swift-version 5 -target arm64-apple-macos14.0 \
  -module-name FileChangerTests -num-threads 8 \
  "${SOURCES[@]}" -o "$OUT/FileChangerTests"

FILECHANGER_FIXTURES="$PWD/Tests/Fixtures" "$OUT/FileChangerTests"
