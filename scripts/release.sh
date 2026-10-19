#!/bin/bash
# Archive, sign, and package a distributable DMG.
#
# With a paid Apple Developer Program membership, set both of these and the app
# is Developer ID signed, notarized and stapled:
#   NOTARY_PROFILE           keychain profile from `xcrun notarytool store-credentials`
#   DEVELOPER_ID_APPLICATION "Developer ID Application: Name (TEAMID)"
# Without them the build is ad-hoc signed. It installs, but every recipient has
# to approve the first launch (see the README).
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  : "${NOTARY_PROFILE:?Set NOTARY_PROFILE (create it with: xcrun notarytool store-credentials)}"
fi

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
command -v xcodegen >/dev/null || { echo 'Install XcodeGen: brew install xcodegen' >&2; exit 1; }

ARCHIVE=build/Lumen.xcarchive
APP=build/Lumen.app
DMG=dist/Lumen.dmg
IDENTITY="${DEVELOPER_ID_APPLICATION:--}"

rm -rf "$ARCHIVE" "$APP" dist
mkdir -p dist
xcodegen generate

# Archive builds with hardened runtime (see project.yml). An ad-hoc archive is
# signed with "-"; the re-sign below skips the timestamp that ad-hoc signing rejects.
xcodebuild -quiet -project Lumen.xcodeproj -scheme Lumen -configuration Release \
  -destination "platform=macOS,arch=$(uname -m)" -archivePath "$ARCHIVE" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  archive

cp -R "$ARCHIVE/Products/Applications/Lumen.app" "$APP"
SIGN=(--force --options runtime --sign "$IDENTITY")
[[ "$IDENTITY" == "-" ]] || SIGN+=(--timestamp)
codesign "${SIGN[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"

if command -v create-dmg >/dev/null; then
  create-dmg --volname Lumen --window-size 540 380 \
    --icon "Lumen.app" 150 180 --app-drop-link 390 180 "$DMG" "$APP"
else
  echo 'Tip: brew install create-dmg for a styled disk image.' >&2
  # `diskutil` is the modern path; hdiutil still exists on older macOS.
  diskutil image create from --volumeName Lumen --format UDZO "$APP" "$DMG" \
    || hdiutil create -volname Lumen -srcfolder "$APP" -ov -format UDZO "$DMG"
fi

if [[ "$IDENTITY" == "-" ]]; then
  echo "Ad-hoc signed (no Developer ID)."
  echo "Recipients must approve the first launch: right-click the app and choose Open"
  echo "(macOS 14), or use System Settings → Privacy & Security → Open Anyway (macOS 15+)."
else
  # Notarize the DMG (which covers the app inside), then staple both artifacts.
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
  xcrun stapler validate "$DMG"
fi
echo "Release ready: $DMG"
