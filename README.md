<p align="center"><img src="docs/images/icon.png" width="128" height="128" alt="LexMD icon"></p>

# LexMD

See every Markdown file in your project at a glance, read it beautifully, and update it in place.
A native macOS reader for READMEs, docs, and agent instructions, with editing a keystroke away.
No account, subscription, or analytics. Your files stay where they are.

**macOS 26+ · Apple silicon · Free and open source**

- Open a repository to see all of its Markdown in one tree. Other files and folders without
  Markdown are hidden, and folders holding a single file are compacted.
- Read in a clean native preview with GitHub-style alerts, tables, task lists, and code highlighting.
  Documents never run scripts, and images hosted online load only if you allow them.
- Update in place: switch to the editor or keep it side by side. Changes save as you type.
- Diagrams (Mermaid syntax, rendered by Pele), math, footnotes, and front matter as properties.
- Outline, backlinks, wiki links, link suggestions, and broken-link checks.
- Tabs, plus creating, renaming, and moving files with links updated for you.
- Export to PDF or HTML, print, or copy as rich text.
- Paste images, paste tables from spreadsheets, Focus Mode, and Typewriter Scrolling.
- In Git repositories, see changed files and commit them, with the author shown before you commit.
- Quick Look previews in Finder, a `lexmd` command, and Shortcuts actions.
- Find in a document with ⌘F, across the whole project with ⇧⌘F, or jump to any file with ⌘P.
- Follows the system appearance, or choose Light or Dark. Every shortcut can be remapped.
- Signed, optional automatic updates.

Created by **Aleksei Iunes**. A sibling of [Sofla](https://github.com/a-yunes/sofla).

## Install

Download the latest disk image from [Releases](https://github.com/a-yunes/lexmd/releases/latest),
open it, and drag LexMD to Applications. Releases are not notarized by Apple, so the first launch
needs approval: open LexMD, then choose **Open Anyway** in System Settings > Privacy & Security.

Setup lets you pick a project, make LexMD the default for `.md` files, and turn on
update checks. Updates are signed and verified before they install.

## Build

Install Xcode 27 with Swift 6.4, then run:

```sh
./scripts/build-app.sh
open build/LexMD.app
```

Pass `--install` to copy the build to `/Applications`. Builds are ad-hoc signed.
Run the tests with `swift test`.

## Contribute

See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), and [RELEASING.md](RELEASING.md).

Licensed under [MIT](LICENSE). Third-party software and artwork are covered by [NOTICE.md](NOTICE.md).
