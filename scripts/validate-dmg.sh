#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DMG=${1:?usage: validate-dmg.sh <dmg> <built-app> <version> <build>}
APP=${2:?usage: validate-dmg.sh <dmg> <built-app> <version> <build>}
EXPECTED_VERSION=${3:?usage: validate-dmg.sh <dmg> <built-app> <version> <build>}
EXPECTED_BUILD=${4:?usage: validate-dmg.sh <dmg> <built-app> <version> <build>}
MOUNT="$ROOT/.build/dmg-validation.$$"
SOURCE_ICON="$ROOT/Resources/AppIcon.icns"
BINARY_NAME=CodexResetTray
ATTACHED=0

fail() {
    printf 'DMG validation failed: %s\n' "$1" >&2
    exit 1
}

cleanup() {
    if [ "$ATTACHED" -eq 1 ]; then
        hdiutil detach "$MOUNT" >/dev/null 2>&1 || hdiutil detach -force "$MOUNT" >/dev/null 2>&1 || true
    fi
    if [ -d "$MOUNT" ]; then
        rmdir "$MOUNT" 2>/dev/null || true
    fi
}
trap cleanup EXIT HUP INT TERM

[ -f "$DMG" ] || fail "missing image $DMG"
[ -d "$APP" ] || fail "missing built app $APP"
[ -x "$APP/Contents/MacOS/$BINARY_NAME" ] || fail "built app has no executable"
command -v hdiutil >/dev/null 2>&1 || fail "hdiutil is unavailable"
command -v codesign >/dev/null 2>&1 || fail "codesign is unavailable"
command -v lipo >/dev/null 2>&1 || fail "lipo is unavailable"

hdiutil verify "$DMG" >/dev/null || fail "hdiutil verify rejected the image"

rm -rf "$MOUNT"
mkdir -p "$MOUNT"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" "$DMG" >/dev/null \
    || fail "could not attach the image read-only"
ATTACHED=1

[ -d "$MOUNT/CodexResetTray.app" ] || fail "CodexResetTray.app is missing from the image"
[ -L "$MOUNT/Applications" ] || fail "Applications shortcut is missing from the image"
[ "$(readlink "$MOUNT/Applications")" = "/Applications" ] \
    || fail "Applications shortcut does not point to /Applications"
[ -s "$MOUNT/README.txt" ] || fail "README.txt is missing from the image"
[ -s "$MOUNT/LICENSE" ] || fail "LICENSE is missing from the image"
[ -s "$MOUNT/NOTICE" ] || fail "NOTICE is missing from the image"
[ -s "$MOUNT/.VolumeIcon.icns" ] || fail "volume icon is missing from the image"
cmp -s "$SOURCE_ICON" "$MOUNT/.VolumeIcon.icns" || fail "volume icon differs from Resources/AppIcon.icns"

MAPP="$MOUNT/CodexResetTray.app"
MAPP_BINARY="$MAPP/Contents/MacOS/$BINARY_NAME"
MAPP_INFO="$MAPP/Contents/Info.plist"
MAPP_ICON="$MAPP/Contents/Resources/AppIcon.icns"

[ -x "$MAPP_BINARY" ] || fail "mounted app executable is missing"
[ -f "$MAPP_INFO" ] || fail "mounted app Info.plist is missing"
[ -s "$MAPP_ICON" ] || fail "mounted app icon is missing"
[ -s "$MAPP/Contents/Resources/LICENSE" ] || fail "mounted app LICENSE is missing"
[ -s "$MAPP/Contents/Resources/NOTICE" ] || fail "mounted app NOTICE is missing"

cmp -s "$APP/Contents/MacOS/$BINARY_NAME" "$MAPP_BINARY" \
    || fail "mounted app executable differs from the built app"
cmp -s "$APP/Contents/Info.plist" "$MAPP_INFO" \
    || fail "mounted Info.plist differs from the built app"
cmp -s "$APP/Contents/Resources/AppIcon.icns" "$MAPP_ICON" \
    || fail "mounted app icon differs from the built app"
cmp -s "$APP/Contents/Resources/LICENSE" "$MAPP/Contents/Resources/LICENSE" \
    || fail "mounted app LICENSE differs from the built app"
cmp -s "$APP/Contents/Resources/NOTICE" "$MAPP/Contents/Resources/NOTICE" \
    || fail "mounted app NOTICE differs from the built app"

plutil -lint "$MAPP_INFO" >/dev/null || fail "mounted Info.plist is malformed"
[ "$(plutil -extract CFBundleIdentifier raw "$MAPP_INFO")" = "io.github.sklivvz.codex-reset-tray" ] \
    || fail "wrong CFBundleIdentifier"
[ "$(plutil -extract CFBundleExecutable raw "$MAPP_INFO")" = "$BINARY_NAME" ] \
    || fail "wrong CFBundleExecutable"
[ "$(plutil -extract CFBundleShortVersionString raw "$MAPP_INFO")" = "$EXPECTED_VERSION" ] \
    || fail "wrong CFBundleShortVersionString"
[ "$(plutil -extract CFBundleVersion raw "$MAPP_INFO")" = "$EXPECTED_BUILD" ] \
    || fail "wrong CFBundleVersion"
[ "$(plutil -extract LSMinimumSystemVersion raw "$MAPP_INFO")" = "13.0" ] \
    || fail "wrong LSMinimumSystemVersion"
[ "$(plutil -extract LSUIElement raw "$MAPP_INFO")" = "true" ] \
    || fail "LSUIElement must stay true"
[ "$(plutil -extract CFBundleIconFile raw "$MAPP_INFO")" = "AppIcon" ] \
    || fail "wrong CFBundleIconFile"

codesign --verify --deep --strict "$MAPP" >/dev/null 2>&1 \
    || fail "mounted app signature does not verify"
SIGNATURE=$(codesign -dv --verbose=4 "$MAPP" 2>&1 || true)
case "$SIGNATURE" in
    *"Signature=adhoc"*) ;;
    *) fail "expected an ad-hoc signature, got: $(printf '%s\n' "$SIGNATURE" | grep 'Signature=' || echo unknown)" ;;
esac

ARCHS=$(lipo -archs "$MAPP_BINARY")
for expected in arm64 x86_64; do
    printf '%s\n' "$ARCHS" | tr ' ' '\n' | grep -qx "$expected" \
        || fail "mounted binary is missing $expected (got: $ARCHS)"
done

MOUNT_LINE=$(mount | grep -F " on $MOUNT " || true)
case "$MOUNT_LINE" in
    *read-only*) ;;
    *) fail "attached image is not mounted read-only" ;;
esac
if touch "$MOUNT/.CodexResetTray-write-test" 2>/dev/null; then
    fail "read-only attach unexpectedly allowed a write"
fi

hdiutil detach "$MOUNT" >/dev/null || fail "could not detach the image"
ATTACHED=0
rmdir "$MOUNT"
if mount | grep -Fq " on $MOUNT "; then
    fail "image is still mounted after detach"
fi

SHA256=$(shasum -a 256 "$DMG" | awk '{print $1}')
printf 'DMG validation passed\n'
printf '  Image: %s\n' "$DMG"
printf '  SHA-256: %s\n' "$SHA256"
printf '  Architectures: %s\n' "$ARCHS"
printf '  Bundle version: %s (%s)\n' "$EXPECTED_VERSION" "$EXPECTED_BUILD"
printf '  Signature: ad-hoc, verified with codesign --verify --deep --strict\n'
printf '  Contents: CodexResetTray.app, Applications -> /Applications, README.txt, LICENSE, NOTICE, .VolumeIcon.icns\n'
printf '  Attach mode: read-only (write probe rejected); detached\n'
