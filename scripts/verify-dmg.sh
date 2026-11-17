#!/bin/zsh
# Verify the actual distributable, including its mounted contents.
set -euo pipefail
DMG=${1:?Usage: scripts/verify-dmg.sh path/to/Bowerbird.dmg}
SCRIPT_DIR=${0:A:h}
hdiutil verify "$DMG"
MOUNT_DIR=$(mktemp -d /tmp/bowerbird-dmg-check.XXXXXX)
cleanup() {
  hdiutil detach "$MOUNT_DIR" -quiet || true
  rmdir "$MOUNT_DIR"
}
trap cleanup EXIT
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT_DIR" -quiet
APP="$MOUNT_DIR/Bowerbird.app"
codesign --verify --strict "$APP"
python3 "$SCRIPT_DIR/verify-app.py" "$APP"
test -s "$APP/Contents/Resources/Bowerbird.icns"
test -s "$APP/Contents/Resources/Assets.car"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$APP/Contents/Info.plist")" == "Bowerbird" ]]
lipo "$APP/Contents/MacOS/Bowerbird" -verify_arch arm64 x86_64
[[ "$(readlink "$MOUNT_DIR/Applications")" == "/Applications" ]]
for language in en zh-Hans zh-Hant ja es fr ru; do
  test -f "$APP/Contents/Resources/$language.lproj/Localizable.strings"
  test -f "$APP/Contents/Resources/$language.lproj/Localizable.stringsdict"
done
echo "Verified universal app, signature, privacy checks, licenses, icons, translations and Applications link in $DMG"
