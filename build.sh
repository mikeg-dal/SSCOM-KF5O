#!/bin/zsh
# Builds, tests and exports a Developer ID–signed SSCOM.app into ./dist.
# UNSIGNED=1 ./build.sh builds without a Developer ID (no Apple account needed).
# Optional: NOTARY_PROFILE=<notarytool keychain profile> ./build.sh   to notarize and staple.
set -euo pipefail
cd "$(dirname "$0")"
APP=SSCOM
# Your Apple Developer team ID. Defaults to the maintainer's.
TEAM_ID=${TEAM_ID:-49G92DYD5H}

xcodegen generate
(cd SSCOMKit && swift test)

rm -rf build/archive dist
if [[ "${UNSIGNED:-0}" == 1 ]]; then
  # No Apple Developer account needed: ad-hoc signed, for use on this Mac only.
  xcodebuild -project $APP.xcodeproj -scheme $APP -configuration Release -derivedDataPath build/dd \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build | xcbeautify 2>/dev/null || true
  test -d build/dd/Build/Products/Release/$APP.app || { echo "Build failed"; exit 1; }
  mkdir -p dist && ditto build/dd/Build/Products/Release/$APP.app dist/$APP.app
  echo "Done (unsigned): dist/$APP.app"; exit 0
fi
xcodebuild -project $APP.xcodeproj -scheme $APP -configuration Release \
  -archivePath build/archive/$APP.xcarchive DEVELOPMENT_TEAM=$TEAM_ID archive | xcbeautify 2>/dev/null || true
test -d build/archive/$APP.xcarchive || { echo "Archive failed"; exit 1; }

cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath build/archive/$APP.xcarchive \
  -exportOptionsPlist build/ExportOptions.plist -exportPath dist

codesign --verify --deep --strict --verbose=2 dist/$APP.app
ditto -c -k --keepParent dist/$APP.app dist/$APP.zip

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit dist/$APP.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple dist/$APP.app
  rm dist/$APP.zip && ditto -c -k --keepParent dist/$APP.app dist/$APP.zip
  spctl --assess --type execute --verbose dist/$APP.app
fi
echo "Done: dist/$APP.app"
