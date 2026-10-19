#!/bin/bash
# Archive, Developer ID sign, notarize, staple, and package a distributable DMG.
#
# Requires:
#   NOTARY_PROFILE           keychain profile from `xcrun notarytool store-credentials`
#   DEVELOPER_ID_APPLICATION "Developer ID Application: Name (TEAMID)"
set -euo pipefail
cd "$(dirname "$0")/.."

: "${NOTARY_PROFILE:?Set NOTARY_PROFILE (create it with: xcrun notarytool store-credentials)}"
: "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION to your Developer ID Application identity}"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
command -v xcodegen >/dev/null || { echo 'Install XcodeGen: brew install xcodegen' >&2; exit 1; }

ARCHIVE=build/Lumen.xcarchive
APP=build/Lumen.app
DMG=dist/Lumen.dmg

rm -rf "$ARCHIVE" "$APP" dist
mkdir -p dist
xcodegen generate

# Archive builds with hardened runtime (see project.yml) and Developer ID signing.
xcodebuild -quiet -project Lumen.xcodeproj -scheme Lumen -configuration Release \
  -destination "platform=macOS,arch=$(uname -m)" -archivePath "$ARCHIVE" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION" \
  archive

cp -R "$ARCHIVE/Products/Applications/Lumen.app" "$APP"
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$APP"
codesign --verify --strict --verbose=2 "$APP"

if command -v create-dmg >/dev/null; then
  create-dmg --volname Lumen --window-size 540 380 \
    --icon "Lumen.app" 150 180 --app-drop-link 390 180 "$DMG" "$APP"
else
  echo 'Tip: brew install create-dmg for a styled disk image.' >&2
  hdiutil create -volname Lumen -srcfolder "$APP" -ov -format UDZO "$DMG"
fi

# Notarize the DMG (which covers the app inside), then staple both artifacts.
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler staple "$APP"

spctl --assess --type execute --verbose=2 "$APP"
xcrun stapler validate "$DMG"
echo "Release ready: $DMG"
