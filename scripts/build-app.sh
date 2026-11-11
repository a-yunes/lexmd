#!/usr/bin/env bash
# Builds LexMD.app into ./build. Pass --install to copy it to /Applications and register it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product LexMD

APP=build/LexMD.app
ICONS=build/icon
rm -rf "$APP" "$ICONS"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ICONS"

# Compile the Icon Composer document (Liquid Glass Assets.car plus an .icns fallback).
xcrun actool Resources/AppIcon.icon --compile "$ICONS" --platform macosx \
  --minimum-deployment-target 26.0 --app-icon AppIcon \
  --output-partial-info-plist "$ICONS/partial.plist" >/dev/null

cp .build/release/LexMD "$APP/Contents/MacOS/LexMD"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$ICONS/Assets.car" "$ICONS/AppIcon.icns" "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Frameworks"
ditto .build/release/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
cp LICENSE LICENSE.sparkle THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
# Ad-hoc signature for local and unnotarized builds; nested Sparkle helpers are signed too.
codesign --force --deep --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'tell application id "io.github.a-yunes.lexmd" to quit' >/dev/null 2>&1 || true
  rm -rf /Applications/LexMD.app
  ditto "$APP" /Applications/LexMD.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/LexMD.app
  /System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true
  echo "Installed /Applications/LexMD.app"
fi
