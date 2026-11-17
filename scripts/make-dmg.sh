#!/bin/zsh
# Builds a dmg that can be handed to other people.
#
# Signed with the locally self-signed "Bowerbird Dev" certificate (created by make-cert.sh), the same
# one build-app.sh uses. This used to use an ad-hoc signature (codesign -s -), on the grounds that
# "other people's machines won't trust this certificate anyway". That reasoning turned out to be
# only half right:
#
# 1. At Gatekeeper the two are the same: neither is issued by Apple, neither is notarized, and both
#    need "Open Anyway" under "System Settings → Privacy & Security" on first launch. A self-signed
#    certificate is no worse than ad-hoc here.
# 2. The Accessibility permission is tied to the code signature's designated requirement. For ad-hoc
#    that's the cdhash, which changes with every build, so **every upgrade means removing and
#    re-adding the permission**. With the self-signed certificate it's
#    `identifier "app.bowerbird.mac" and certificate leaf = H"…"`, stable across builds, so granting
#    once is enough, on other people's machines too.
#
# The cost: the certificate's private key lives only on this machine. Lose it (new machine, OS
# reinstall) and the next build has a new certificate, so everyone has to grant permission again.
# Back up the .p12.
set -euo pipefail
cd "$(dirname "$0")/.."
SIGN_IDENTITY=${SIGN_IDENTITY:-Bowerbird Dev}
# CI exercises the actual release packaging without access to the private signing key.
# Local releases still require a stable certificate identity by default.
if [[ "$SIGN_IDENTITY" == "-" && "${CI:-}" != "true" ]]; then
  echo "Ad-hoc disk images are only allowed for CI validation"; exit 1
fi
command -v dmgbuild >/dev/null || { echo "dmgbuild not found; run: uv tool install dmgbuild"; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Support/Info.plist)
APP="build/Bowerbird.app"
DMG="build/Bowerbird-$VERSION.dmg"

# Keep dependency resource-bundle fallback paths outside the home directory.
# Source paths can also appear in debug symbols; strip those from the packaged copy below.
SCRATCH=/tmp/bowerbird-release
# One universal binary for Apple silicon and Intel, as Maccy, Ice and Stats ship: a single download,
# nobody has to know which chip they have.
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release --scratch-path "$SCRATCH" $ARCHS
BIN="$(swift build -c release --scratch-path "$SCRATCH" $ARCHS --show-bin-path)/Bowerbird"
[[ "$(lipo -archs "$BIN")" == *x86_64*arm64* || "$(lipo -archs "$BIN")" == *arm64*x86_64* ]] \
  || { echo "Not a universal binary: $(lipo -archs "$BIN")"; exit 1 }

swift scripts/make-icon.swift
rm -rf "$APP" "$DMG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Bowerbird"
# Remove debug symbols before signing, including source paths in both architecture slices.
xcrun strip -S "$APP/Contents/MacOS/Bowerbird"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cp build/icon-resources/Bowerbird.icns "$APP/Contents/Resources/Bowerbird.icns"
cp build/icon-resources/Assets.car "$APP/Contents/Resources/Assets.car"
for lproj in Support/*.lproj; do
  cp -R "$lproj" "$APP/Contents/Resources/"
done

python3 scripts/verify-app.py "$APP"
codesign --force --sign "$SIGN_IDENTITY" --identifier app.bowerbird.mac "$APP"
codesign --verify --strict "$APP"
# The signature must be a stable identity, not a cdhash; that's the whole reason for not using ad-hoc, so check it right here
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  codesign -d -r- "$APP" 2>&1 | grep 'certificate leaf' >/dev/null || { echo "Signature is not a certificate identity"; exit 1 }
fi

# --- Disk image -------------------------------------------------------------------------------
# Laid out the way Mac apps usually are: the app on the left, an Applications shortcut on the
# right, on a plain background. Assembled by dmgbuild (https://github.com/dmgbuild/dmgbuild),
# which writes the Finder window layout straight into the volume's .DS_Store; see
# scripts/dmg-settings.py. Install once with: uv tool install dmgbuild
if [ -d /Volumes/Bowerbird ]; then hdiutil detach /Volumes/Bowerbird -quiet || true; fi
dmgbuild -s scripts/dmg-settings.py -D app="$APP" "Bowerbird" "$DMG"
scripts/verify-dmg.sh "$DMG"

echo "Done: $DMG ($(du -h "$DMG" | cut -f1))"
echo "Signature:"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Identifier|Signature|Authority" || true
