#!/usr/bin/env bash
# Packages a release into build/Release: a zip and a disk image of LexMD.app, SHA256SUMS,
# and a Sparkle appcast.xml signed with the `lexmd-updates` key from the login Keychain.
# The feed carries the version's notes from CHANGELOG.md, which the update window shows.
# Upload every file in build/Release to the GitHub release tagged v<version>.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="a-yunes/lexmd"
KEY_ACCOUNT="lexmd-updates"
TOOLS=.build/artifacts/sparkle/Sparkle/bin

./scripts/build-app.sh

APP=build/LexMD.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
# Before anything is built: a release without notes in CHANGELOG.md stops here.
NOTES=$(./scripts/release-notes.sh "$VERSION")
OUT=build/Release
rm -rf "$OUT" && mkdir -p "$OUT"
# On failure, remove the temporary folders and the incomplete release, so nothing partial is
# uploaded by mistake.
STAGE=
FEED_DIR=
PACKAGED=
cleanup() {
  [[ -z "$STAGE" ]] || rm -rf "$STAGE"
  [[ -z "$FEED_DIR" ]] || rm -rf "$FEED_DIR"
  [[ -n "$PACKAGED" ]] || rm -rf "$OUT"
}
trap cleanup EXIT

# The embedded public key must match the private key that signs the feed.
PUBLIC_KEY=$("$TOOLS/generate_keys" --account "$KEY_ACCOUNT" -p)
EMBEDDED_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP/Contents/Info.plist")
if [[ "$PUBLIC_KEY" != "$EMBEDDED_KEY" ]]; then
  echo "error: Keychain key '$KEY_ACCOUNT' does not match SUPublicEDKey in Info.plist" >&2
  exit 1
fi

ZIP="LexMD-$VERSION.zip"
DMG="LexMD-$VERSION.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$ZIP"

STAGE=$(mktemp -d build/dmg.XXXXXX)
ditto "$APP" "$STAGE/LexMD.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "LexMD $VERSION" -srcfolder "$STAGE" -format ULFO -ov "$OUT/$DMG"
rm -rf "$STAGE"
STAGE=

# Sparkle installs from the zip; the disk image is for first-time downloads.
FEED_DIR=$(mktemp -d build/feed.XXXXXX)
cp "$OUT/$ZIP" "$FEED_DIR/"
# Notes named after the archive are embedded in its feed item.
printf '%s\n' "$NOTES" > "$FEED_DIR/${ZIP%.zip}.html"
TZ=UTC "$TOOLS/generate_appcast" --account "$KEY_ACCOUNT" --maximum-deltas 0 --embed-release-notes \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --link "https://github.com/$REPO" "$FEED_DIR"
cp "$FEED_DIR/appcast.xml" "$OUT/appcast.xml"
rm -rf "$FEED_DIR"
FEED_DIR=
"$TOOLS/sign_update" --account "$KEY_ACCOUNT" --verify "$OUT/appcast.xml"

(cd "$OUT" && shasum -a 256 "$ZIP" "$DMG" appcast.xml > SHA256SUMS)
PACKAGED=1
echo "Release $VERSION ($BUILD) is ready in $OUT:"
ls -1 "$OUT"
