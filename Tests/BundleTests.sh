#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/build/CodexResetTray.app"
INFO="$APP/Contents/Info.plist"
BINARY="$APP/Contents/MacOS/CodexResetTray"
BUNDLED_ICON="$APP/Contents/Resources/AppIcon.icns"
SOURCE_ICON="$ROOT/Resources/AppIcon.icns"
ICON_CHECK="$ROOT/.build/icon-pixel-check"
EXPECTED_VERSION=${MARKETING_VERSION:-0.2.0}
EXPECTED_BUILD=${BUILD_NUMBER:-1}

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

[ -d "$APP" ] || fail "missing $APP; run ./build.sh first"
[ -x "$BINARY" ] || fail "missing app executable"
[ -f "$INFO" ] || fail "missing Info.plist"
[ -s "$SOURCE_ICON" ] || fail "missing source icon $SOURCE_ICON"
[ -f "$BUNDLED_ICON" ] || fail "icon was not copied into the app bundle"
[ -s "$APP/Contents/Resources/LICENSE" ] || fail "LICENSE was not copied into the app bundle"
[ -s "$APP/Contents/Resources/NOTICE" ] || fail "NOTICE was not copied into the app bundle"
cmp -s "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE" || fail "bundled LICENSE differs from LICENSE"
cmp -s "$ROOT/NOTICE" "$APP/Contents/Resources/NOTICE" || fail "bundled NOTICE differs from NOTICE"
[ -x "$ICON_CHECK" ] || fail "missing icon pixel checker; run ./test.sh"

ICON_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$INFO" 2>/dev/null || true)
[ "$ICON_NAME" = "AppIcon" ] || fail "CFBundleIconFile is '$ICON_NAME', expected 'AppIcon'"
[ "$(plutil -extract CFBundleDisplayName raw "$INFO")" = "Codex Reset Tray" ] || fail "wrong CFBundleDisplayName"
[ "$(plutil -extract CFBundleExecutable raw "$INFO")" = "CodexResetTray" ] || fail "wrong CFBundleExecutable"
[ "$(plutil -extract CFBundleIdentifier raw "$INFO")" = "io.github.sklivvz.codex-reset-tray" ] || fail "wrong CFBundleIdentifier"
[ "$(plutil -extract CFBundleName raw "$INFO")" = "Codex Reset Tray" ] || fail "wrong CFBundleName"
[ "$(plutil -extract CFBundlePackageType raw "$INFO")" = "APPL" ] || fail "wrong CFBundlePackageType"
[ "$(plutil -extract CFBundleInfoDictionaryVersion raw "$INFO")" = "6.0" ] || fail "wrong CFBundleInfoDictionaryVersion"
[ "$(plutil -extract CFBundleShortVersionString raw "$INFO")" = "$EXPECTED_VERSION" ] || fail "wrong CFBundleShortVersionString"
[ "$(plutil -extract CFBundleVersion raw "$INFO")" = "$EXPECTED_BUILD" ] || fail "wrong CFBundleVersion"
[ "$(plutil -extract LSApplicationCategoryType raw "$INFO")" = "public.app-category.utilities" ] || fail "wrong LSApplicationCategoryType"
[ "$(plutil -extract LSMinimumSystemVersion raw "$INFO")" = "13.0" ] || fail "wrong LSMinimumSystemVersion"
[ "$(plutil -extract LSUIElement raw "$INFO")" = "true" ] || fail "LSUIElement must stay true"
[ "$(plutil -extract NSHighResolutionCapable raw "$INFO")" = "true" ] || fail "NSHighResolutionCapable must stay true"
[ "$(plutil -extract NSHumanReadableCopyright raw "$INFO")" = "Copyright © 2026 sklivvz. MIT licensed." ] || fail "wrong NSHumanReadableCopyright"
plutil -lint "$INFO" >/dev/null || fail "Info.plist is malformed"
codesign --verify --deep --strict "$APP" >/dev/null 2>&1 || fail "app bundle signature does not verify"

MAGIC=$(dd if="$BUNDLED_ICON" bs=4 count=1 2>/dev/null | od -An -tx1 | tr -d '[:space:]')
[ "$MAGIC" = "69636e73" ] || fail "bundled AppIcon.icns does not start with the icns magic"
cmp -s "$SOURCE_ICON" "$BUNDLED_ICON" || fail "bundled icon differs from Resources/AppIcon.icns"

# Decode the asset's actual pixels. A nonempty file or a valid header is not
# enough: every decoded representation must contain visible pixels.
"$ICON_CHECK" "$SOURCE_ICON" "$BUNDLED_ICON" || fail "an .icns representation is fully transparent"

# A real icns must round-trip through iconutil with the images macOS expects.
# Keep the generated iconset inside this project rather than in system temp.
mkdir -p "$ROOT/.build"
TMP_DIR=$(mktemp -d "$ROOT/.build/icon-bundle-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM
iconutil -c iconset -o "$TMP_DIR/AppIcon.iconset" "$BUNDLED_ICON" \
    || fail "iconutil could not decode the bundled icon"
for name in \
    icon_16x16.png icon_16x16@2x.png \
    icon_32x32.png icon_32x32@2x.png \
    icon_128x128.png icon_128x128@2x.png \
    icon_256x256.png icon_256x256@2x.png \
    icon_512x512.png icon_512x512@2x.png
do
    [ -s "$TMP_DIR/AppIcon.iconset/$name" ] || fail "bundled icon is missing $name"
done

# Every size iconutil extracted must also decode to visible pixel data.
"$ICON_CHECK" "$TMP_DIR/AppIcon.iconset/"*.png \
    || fail "an extracted icon representation is fully transparent"

# This replacement should link AppKit, not SwiftUI.
FRAMEWORKS=$(otool -L "$BINARY")
printf '%s\n' "$FRAMEWORKS" | grep -q '/AppKit.framework/' || fail "app does not link AppKit"
if printf '%s\n' "$FRAMEWORKS" | grep -q '/SwiftUI.framework/'; then
    fail "app still links SwiftUI"
fi

printf 'Bundle icon and framework tests passed\n'
