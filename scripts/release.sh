#!/bin/bash
# Builds a clean Release LiveWallpaper.dmg in build/release.
#
# Every run starts from an empty build folder, so nothing from earlier builds
# can end up inside the app, and the signature is checked before and after
# packaging. A file added after signing makes macOS report the app as damaged.
#
#   scripts/release.sh                     sign with the project's settings
#   SIGN_IDENTITY=- scripts/release.sh     ad-hoc sign, for machines without the team certificate

set -euo pipefail
cd "$(dirname "$0")/.."

OUT=build/release
APP_NAME=LiveWallpaper
DMG="$OUT/$APP_NAME.dmg"

rm -rf "$OUT"
mkdir -p "$OUT/dmg"

sign_args=()
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  sign_args=(CODE_SIGN_IDENTITY="$SIGN_IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=)
fi

xcodebuild \
  -project LiveWallpaper.xcodeproj \
  -scheme LiveWallpaper \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$OUT/DerivedData" \
  ${sign_args[@]+"${sign_args[@]}"} \
  build

APP="$OUT/DerivedData/Build/Products/Release/$APP_NAME.app"
codesign --verify --deep --strict --verbose=2 "$APP"

ditto "$APP" "$OUT/dmg/$APP_NAME.app"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$OUT/dmg" -format UDZO -ov "$DMG"

# Check the app again as it ships inside the DMG.
mnt=$(mktemp -d)
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mnt" "$DMG" >/dev/null
trap 'hdiutil detach "$mnt" >/dev/null; rmdir "$mnt"' EXIT
codesign --verify --deep --strict --verbose=2 "$mnt/$APP_NAME.app"

echo "Created $DMG"
