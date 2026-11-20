# Releasing LexMD

## Prepare

Set `CFBundleShortVersionString` in `Resources/Info.plist` and always increase `CFBundleVersion`.
Add the release notes to [CHANGELOG.md](CHANGELOG.md) under `## <version>`: the update window
shows that section to people before they install, so keep it short and written for them.
Build, install, and check the app.

## Package

```sh
./scripts/package-release.sh
```

This writes `build/Release`: the zip Sparkle installs, a disk image for first downloads,
`appcast.xml` (with the version's notes from the changelog), and `SHA256SUMS`. Builds are ad-hoc signed and not notarized.

## Signing key

The `lexmd-updates` key in the login Keychain signs the zip and `appcast.xml`. Only its public
key is in `Resources/Info.plist`, and the script refuses to package if they differ.
Back up the private key outside the repository; losing it prevents updates for existing installs:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account lexmd-updates -x lexmd-updates.key
```

Do not edit a signed feed by hand.

## Publish

Create a GitHub release tagged `v<version>` and upload every file in `build/Release`.
The app reads `releases/latest/download/appcast.xml`, so the feed and zip must be published
together. Never replace the assets of a published version; ship a new version instead.
