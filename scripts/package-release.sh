#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MARKETING_VERSION=${MARKETING_VERSION:-0.2.0}
BUILD_NUMBER=${BUILD_NUMBER:-1}
BUILD_ARCHS=${BUILD_ARCHS:-arm64 x86_64}
DIST="$ROOT/dist"
STAGE="$DIST/.stage-v$MARKETING_VERSION"
MOUNT="$DIST/.dmg-mount.$$"
APP="$ROOT/build/CodexResetTray.app"
BINARY="$APP/Contents/MacOS/CodexResetTray"
ICON="$ROOT/Resources/AppIcon.icns"
VOLNAME="Codex Reset Tray"
RW_DMG="$DIST/.CodexResetTray-v$MARKETING_VERSION-rw.dmg"
ATTACHED=0

fail() {
    printf 'Packaging failed: %s\n' "$1" >&2
    exit 1
}

cleanup() {
    if [ "$ATTACHED" -eq 1 ]; then
        hdiutil detach "$MOUNT" >/dev/null 2>&1 || hdiutil detach -force "$MOUNT" >/dev/null 2>&1 || true
    fi
    if [ -d "$MOUNT" ]; then
        rmdir "$MOUNT" 2>/dev/null || true
    fi
    rm -rf "$STAGE" "$RW_DMG"
}
trap cleanup EXIT HUP INT TERM

for required in LICENSE NOTICE README.md; do
    [ -s "$ROOT/$required" ] || fail "missing $required"
done
[ -s "$ICON" ] || fail "missing app icon $ICON"
command -v hdiutil >/dev/null 2>&1 \
    || fail "hdiutil is unavailable; a macOS DMG cannot be created in this environment. No release artifact was produced."
command -v shasum >/dev/null 2>&1 || fail "shasum is unavailable"

export MARKETING_VERSION BUILD_NUMBER BUILD_ARCHS
"$ROOT/build.sh"

ARCHS=$(lipo -archs "$BINARY")
for expected in arm64 x86_64; do
    printf '%s\n' "$ARCHS" | tr ' ' '\n' | grep -qx "$expected" \
        || fail "built app is missing $expected (got: $ARCHS); universal release requires both"
done
ARCH_LABEL=universal
ASSET="CodexResetTray-v$MARKETING_VERSION-macos-$ARCH_LABEL.dmg"
DMG="$DIST/$ASSET"
CHECKSUM="$DMG.sha256"

rm -rf "$STAGE" "$MOUNT" "$RW_DMG"
rm -f "$DMG" "$CHECKSUM"
mkdir -p "$STAGE"

ditto "$APP" "$STAGE/CodexResetTray.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$STAGE/"
cat > "$STAGE/README.txt" <<TXT
Codex Reset Tray v$MARKETING_VERSION
===================================

Drag CodexResetTray.app to the Applications shortcut in this window.

Requirements: macOS 13 or later, the codex CLI signed in with ChatGPT auth,
and an app-server that supports account/rateLimits/read.

This build is ad-hoc signed and is not notarized by Apple. On first launch,
macOS may require right-click > Open, or System Settings > Privacy & Security >
Open Anyway.

After launch, left-click the menu-bar icon for details or right-click it for the
actions menu. Use the "Show 7d Label" item to hide or show the usage text; its
check mark shows whether the text is visible, and the icon always remains
visible.

Project: https://github.com/sklivvz/codex-reset-tray
License: MIT (see LICENSE). See NOTICE for attribution and trademarks.
TXT

codesign --verify --deep --strict "$STAGE/CodexResetTray.app"

# Build a writable staging image so the standard macOS volume icon can be set
# without driving Finder or any other application. Then convert to compressed,
# read-only UDZO and validate the final image through a read-only attach.
hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ \
    -format UDRW -ov "$RW_DMG" >/dev/null
mkdir -p "$MOUNT"
hdiutil attach -readwrite -nobrowse -noautoopen -mountpoint "$MOUNT" "$RW_DMG" >/dev/null
ATTACHED=1
cp "$ICON" "$MOUNT/.VolumeIcon.icns"
if command -v SetFile >/dev/null 2>&1; then
    SetFile -a C "$MOUNT"
fi
sync
hdiutil detach "$MOUNT" >/dev/null
ATTACHED=0
rmdir "$MOUNT"

hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" >/dev/null
rm -f "$RW_DMG"

[ -s "$DMG" ] || fail "hdiutil did not produce $DMG"
"$ROOT/scripts/validate-dmg.sh" "$DMG" "$APP" "$MARKETING_VERSION" "$BUILD_NUMBER"

(
    cd "$DIST"
    shasum -a 256 "$ASSET" > "$ASSET.sha256"
)

printf 'Packaged %s\n' "$DMG"
printf 'Size: %s bytes\n' "$(stat -f%z "$DMG")"
printf 'Checksum: %s\n' "$CHECKSUM"
printf 'Architectures: %s\n' "$ARCHS"
