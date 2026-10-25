#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/CodexResetTray.app"
CONTENTS="$APP/Contents"
BIN_STAGE="$BUILD_DIR/.bin"
CACHE_DIR="$ROOT/.build/swift-module-cache"
ICON="$ROOT/Resources/AppIcon.icns"

MARKETING_VERSION=${MARKETING_VERSION:-0.3.0}
BUILD_NUMBER=${BUILD_NUMBER:-1}
BUILD_ARCHS=${BUILD_ARCHS:-$(uname -m)}
BUNDLE_ID="io.github.sklivvz.codex-reset-tray"

fail() {
    printf 'Build failed: %s\n' "$1" >&2
    exit 1
}

case "$MARKETING_VERSION" in
    ""|*[!0-9A-Za-z._-]*) fail "MARKETING_VERSION contains unsupported characters" ;;
esac
case "$BUILD_NUMBER" in
    ""|*[!0-9]*) fail "BUILD_NUMBER must contain digits only" ;;
esac
for ARCH in $BUILD_ARCHS; do
    case "$ARCH" in
        arm64|x86_64) ;;
        *) fail "unsupported architecture '$ARCH' (use arm64 and/or x86_64)" ;;
    esac
done

[ -s "$ICON" ] || fail "missing app icon $ICON; run Tools/generate-app-icon.swift first"
[ -s "$ROOT/LICENSE" ] || fail "missing LICENSE"
[ -s "$ROOT/NOTICE" ] || fail "missing NOTICE"

rm -rf "$APP" "$BIN_STAGE"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$BIN_STAGE"
cp "$ICON" "$CONTENTS/Resources/AppIcon.icns"
cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$CONTENTS/Resources/"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Codex Reset Tray</string>
    <key>CFBundleExecutable</key>
    <string>CodexResetTray</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Codex Reset Tray</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 sklivvz. MIT licensed.</string>
</dict>
</plist>
PLIST

BINARIES=""
for ARCH in $BUILD_ARCHS; do
    OUTPUT="$BIN_STAGE/CodexResetTray-$ARCH"
    mkdir -p "$CACHE_DIR/$ARCH"
    swiftc -O -swift-version 5 -parse-as-library \
        -module-cache-path "$CACHE_DIR/$ARCH" \
        -target "$ARCH-apple-macosx13.0" \
        "$ROOT"/Sources/*.swift \
        -o "$OUTPUT"
    BINARIES="$BINARIES $OUTPUT"
done

# shellcheck disable=SC2086
set -- $BINARIES
if [ "$#" -eq 1 ]; then
    cp "$1" "$CONTENTS/MacOS/CodexResetTray"
else
    lipo -create "$@" -output "$CONTENTS/MacOS/CodexResetTray"
fi
chmod 755 "$CONTENTS/MacOS/CodexResetTray"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - --timestamp=none "$APP" >/dev/null
    codesign --verify --deep --strict "$APP"
fi

ARCHS=$(lipo -archs "$CONTENTS/MacOS/CodexResetTray")
printf 'Built %s\n' "$APP"
printf 'Version %s (%s), architectures: %s\n' "$MARKETING_VERSION" "$BUILD_NUMBER" "$ARCHS"
