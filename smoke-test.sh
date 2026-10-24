#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT_DIR="$ROOT/.build"
OUTPUT="$OUTPUT_DIR/parser-smoke"
CACHE_DIR="$OUTPUT_DIR/swift-module-cache"

mkdir -p "$OUTPUT_DIR" "$CACHE_DIR"
swiftc -swift-version 5 -parse-as-library \
    -module-cache-path "$CACHE_DIR" \
    "$ROOT/Sources/AppBuildInfo.swift" \
    "$ROOT/Sources/ResetPage.swift" \
    "$ROOT/Tests/ParserSmoke.swift" \
    -o "$OUTPUT"
"$OUTPUT" "$ROOT/Tests/Fixtures/codexreset-page.html"
