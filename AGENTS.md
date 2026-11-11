# Engineering guide

LexMD is a native macOS 26+ app for Apple silicon that shows every Markdown file in a project at
a glance, reads it beautifully, and updates it in place. Reading comes first; editing is a
keystroke away. Built with SwiftUI and AppKit as a Swift package. Keep documentation brief, human-readable, and free of em dashes.

## Layout

- `Sources/LexMD`: the app. `AppModel` owns state; `EditorController` (NSTextView) and
  `PreviewController` (WKWebView) are long-lived AppKit views hosted by SwiftUI.
- `Resources`: `Info.plist`, the Icon Composer document, and icon source art.
- `scripts/build-app.sh` builds `build/LexMD.app`; `scripts/package-release.sh` builds a release.

## Rules

- Follow system appearance, accessibility, and macOS conventions. Every shortcut stays remappable.
- Never lose user text: autosave writes in place, and external edits reload only without local changes.
- No accounts, analytics, or network use beyond user-enabled update checks.
- Never commit personal paths, private notes, credentials, or signing keys.
- Build and run the app for every change and report what was not verified.
