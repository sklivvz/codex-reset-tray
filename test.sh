#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT_DIR="$ROOT/.build"
OUTPUT="$OUTPUT_DIR/codex-tests"
MENU_OUTPUT="$OUTPUT_DIR/tray-menu-tests"
RUNTIME_OUTPUT="$OUTPUT_DIR/tray-menu-runtime-tests"
ICON_CHECK_OUTPUT="$OUTPUT_DIR/icon-pixel-check"
PARSER_OUTPUT="$OUTPUT_DIR/parser-tests"
CACHE_DIR="$OUTPUT_DIR/swift-module-cache"
MARKETING_VERSION=${MARKETING_VERSION:-0.2.0}
BUILD_NUMBER=${BUILD_NUMBER:-1}
export MARKETING_VERSION BUILD_NUMBER

mkdir -p "$OUTPUT_DIR" "$CACHE_DIR"
swiftc -swift-version 5 -parse-as-library \
    -module-cache-path "$CACHE_DIR" \
    "$ROOT/Sources/CodexRateLimits.swift" \
    "$ROOT/Sources/RestorationDetector.swift" \
    "$ROOT/Tests/CodexTests.swift" \
    -o "$OUTPUT"

"$OUTPUT" "$ROOT/Tests/Fixtures"

swiftc -swift-version 5 -parse-as-library \
    -module-cache-path "$CACHE_DIR" \
    "$ROOT/Sources/AppBuildInfo.swift" \
    "$ROOT/Sources/ResetPage.swift" \
    "$ROOT/Tests/ParserSmoke.swift" \
    -o "$PARSER_OUTPUT"

"$PARSER_OUTPUT" "$ROOT/Tests/Fixtures/codexreset-page.html"

swiftc -swift-version 5 -parse-as-library \
    -module-cache-path "$CACHE_DIR" \
    "$ROOT/Sources/AppBuildInfo.swift" \
    "$ROOT/Sources/TrayMenuModel.swift" \
    "$ROOT/Sources/CodexRateLimits.swift" \
    "$ROOT/Sources/RestorationDetector.swift" \
    "$ROOT/Sources/ResetPage.swift" \
    "$ROOT/Tests/TrayMenuTests.swift" \
    -o "$MENU_OUTPUT"

"$MENU_OUTPUT"

# Offscreen AppKit integration test. It builds the real TrayMenuController with
# injected fakes and exercises actual NSMenu/NSMenuItem instances. It does not
# launch the app bundle, create an NSStatusItem, or interact with the desktop.
swiftc -swift-version 5 -parse-as-library \
    -module-cache-path "$CACHE_DIR" \
    "$ROOT/Sources/AppBuildInfo.swift" \
    "$ROOT/Sources/CodexAppServer.swift" \
    "$ROOT/Sources/CodexRateLimits.swift" \
    "$ROOT/Sources/Notifications.swift" \
    "$ROOT/Sources/ResetPage.swift" \
    "$ROOT/Sources/ResetStore.swift" \
    "$ROOT/Sources/RestorationDetector.swift" \
    "$ROOT/Sources/TrayInfoPopover.swift" \
    "$ROOT/Sources/TrayMenuController.swift" \
    "$ROOT/Sources/TrayMenuModel.swift" \
    "$ROOT/Sources/TrayStatusItem.swift" \
    "$ROOT/Tests/TrayMenuRuntimeTests.swift" \
    "$ROOT/Tests/TrayStatusRuntimeTests.swift" \
    "$ROOT/Tests/LiveStatusItemCheck.swift" \
    -o "$RUNTIME_OUTPUT"

"$RUNTIME_OUTPUT"

swiftc -swift-version 5 -parse-as-library \
    -module-cache-path "$CACHE_DIR" \
    "$ROOT/Tests/IconPixelCheck.swift" \
    -o "$ICON_CHECK_OUTPUT"

"$ROOT/smoke-test.sh"
"$ROOT/Tests/BundleTests.sh"
