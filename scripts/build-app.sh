#!/usr/bin/env bash
# Builds LexMD.app into ./build. Pass --install to copy it to /Applications and register it.
set -euo pipefail
cd "$(dirname "$0")/.."

# App Intents (Shortcuts actions): the release build of LexMD writes its compile-time values
# here (see Package.swift), and appintentsmetadataprocessor turns them into Metadata.appintents.
INTENTS="$PWD/.build/appintents"
mkdir -p "$INTENTS"
echo '["AppIntent", "EntityQuery", "AppEntity", "TransientEntity", "AppEnum", "AppShortcutProviding",
 "AppShortcutsProvider", "AnyResolverProviding", "AppIntentsPackage", "DynamicOptionsProvider",
 "_IntentValueRepresentable", "_AssistantIntentsProvider", "_GenerativeFunctionExtractable",
 "IntentValueQuery", "Resolver"]' >"$INTENTS/protocols.json"
export LEXMD_APPINTENTS_DIR="$INTENTS"
CONST_VALUES="$INTENTS/LexMD.swiftconstvalues"

swift build -c release --product LexMD
if [[ ! -s "$CONST_VALUES" ]]; then
  # An up-to-date build does not recompile, so the values may be missing; rebuild LexMD once.
  touch Sources/LexMD/ShortcutsActions.swift
  swift build -c release --product LexMD
fi
swift build -c release --product LexMDQuickLook
BIN=$(swift build -c release --show-bin-path)

APP=build/LexMD.app
ICONS=build/icon
rm -rf "$APP" "$ICONS"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ICONS"

# Compile the Icon Composer document (Liquid Glass Assets.car plus an .icns fallback).
# Absolute paths: actool runs in a shared daemon that may resolve relative ones elsewhere.
xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$PWD/$ICONS" --platform macosx \
  --minimum-deployment-target 26.0 --app-icon AppIcon \
  --output-partial-info-plist "$PWD/$ICONS/partial.plist" >/dev/null

cp "$BIN/LexMD" "$APP/Contents/MacOS/LexMD"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$ICONS/Assets.car" "$ICONS/AppIcon.icns" "$APP/Contents/Resources/"
# SwiftPM resources (Pele and KaTeX); LexMD looks for them in Contents/Resources.
ditto "$BIN/LexMD_LexMD.bundle" "$APP/Contents/Resources/LexMD_LexMD.bundle"
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp LICENSE LICENSE.sparkle THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"

# The lexmd command line tool.
mkdir -p "$APP/Contents/Resources/bin"
install -m 755 Resources/bin/lexmd "$APP/Contents/Resources/bin/lexmd"

# Shortcuts actions. Skipped with a warning when Xcode's App Intents tools are not installed.
if PROCESSOR=$(xcrun --find appintentsmetadataprocessor 2>/dev/null); then
  TOOLCHAIN=$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")
  find "$PWD/Sources/LexMD" -name '*.swift' | sort >"$INTENTS/sources.txt"
  echo "$CONST_VALUES" >"$INTENTS/constvalues.txt"
  "$PROCESSOR" --toolchain-dir "$TOOLCHAIN" --module-name LexMD \
    --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
    --xcode-version "$(xcodebuild -version | awk '/Build version/ { print $3 }')" \
    --platform-family macOS --deployment-target 26.0 --bundle-identifier io.github.a-yunes.lexmd \
    --target-triple arm64-apple-macos26.0 --binary-file "$PWD/$APP/Contents/MacOS/LexMD" \
    --output "$PWD/$APP/Contents/Resources" \
    --source-file-list "$INTENTS/sources.txt" --swift-const-vals-list "$INTENTS/constvalues.txt" \
    --compile-time-extraction --deployment-aware-processing --no-app-shortcuts-localization --force \
    >"$INTENTS/processor.log" 2>&1 || { cat "$INTENTS/processor.log" >&2; exit 1; }
  if [[ ! -s "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata" ]]; then
    echo "error: App Intents metadata was not generated" >&2
    exit 1
  fi
else
  echo "warning: appintentsmetadataprocessor not found; Shortcuts actions are left out" >&2
fi

# The Quick Look extension, with the app's version.
APPEX="$APP/Contents/PlugIns/LexMDQuickLook.appex"
mkdir -p "$APPEX/Contents/MacOS"
cp "$BIN/LexMDQuickLook" "$APPEX/Contents/MacOS/LexMDQuickLook"
cp Resources/QuickLook/Info.plist "$APPEX/Contents/Info.plist"
for KEY in CFBundleShortVersionString CFBundleVersion; do
  VALUE=$(/usr/libexec/PlistBuddy -c "Print :$KEY" Resources/Info.plist)
  /usr/libexec/PlistBuddy -c "Add :$KEY string $VALUE" "$APPEX/Contents/Info.plist"
done

# Ad-hoc signatures for local and unnotarized builds, inside out: Sparkle (with its nested
# helpers), the sandboxed extension with its entitlements, then the app itself. The app is
# signed without --deep so the extension keeps its entitlements.
sign() {
  local log
  log=$(codesign --force --sign - "$@" 2>&1) || { echo "$log" >&2; return 1; }
}
sign --deep "$APP/Contents/Frameworks/Sparkle.framework"
sign --entitlements Resources/QuickLook/LexMDQuickLook.entitlements "$APPEX"
sign "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'tell application id "io.github.a-yunes.lexmd" to quit' >/dev/null 2>&1 || true
  rm -rf /Applications/LexMD.app
  ditto "$APP" /Applications/LexMD.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/LexMD.app
  /System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true
  echo "Installed /Applications/LexMD.app"
fi
