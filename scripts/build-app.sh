#!/bin/zsh
# Usage: scripts/build-app.sh [debug|release]
# SIGN_IDENTITY picks the signing identity; "-" signs ad hoc, for machines without the certificate (CI).
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${1:-debug}
SIGN_IDENTITY=${SIGN_IDENTITY:-Bowerbird Dev}
BUILD_OPTIONS=(-c "$CONFIG")
if [[ "$CONFIG" == "release" ]]; then
  BUILD_OPTIONS+=(--scratch-path /tmp/bowerbird-release-native)
fi
swift build "${BUILD_OPTIONS[@]}"
BIN="$(swift build "${BUILD_OPTIONS[@]}" --show-bin-path)/Bowerbird"
swift scripts/make-icon.swift
APP="build/Bowerbird.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Bowerbird"
if [[ "$CONFIG" == "release" ]]; then
  xcrun strip -S "$APP/Contents/MacOS/Bowerbird"
fi
cp Support/Info.plist "$APP/Contents/Info.plist"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cp build/icon-resources/Bowerbird.icns "$APP/Contents/Resources/Bowerbird.icns"
cp build/icon-resources/Assets.car "$APP/Contents/Resources/Assets.car"
# Localization files go straight into Resources so Bundle.main finds them, bypassing the SPM resource bundle
for lproj in Support/*.lproj; do
  cp -R "$lproj" "$APP/Contents/Resources/"
done
if [[ "$CONFIG" == "release" ]]; then
  python3 scripts/verify-app.py "$APP"
fi
codesign --force --sign "$SIGN_IDENTITY" --identifier app.bowerbird.mac "$APP"
echo "built $APP"
