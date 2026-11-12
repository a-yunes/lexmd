# Changelog

## Unreleased

- A demo project with diagrams, math, callouts, links and images opens during setup. Help > Open
  Demo Project brings it back, restoring any demo files that were deleted.
- Mermaid diagrams render with Pele and math renders with KaTeX (`$inline$`, `$$display$$`,
  `math` blocks), both following light and dark. Footnotes get links and back-links, and simple
  front matter shows as a properties table.
- Outline panel (⌥⌘O) with the headings of the document, the documents that link to it, and any
  broken links. Wiki links (`[[Name]]`, `[[Name|label]]`, `[[Name#Heading]]`) open the matching
  document, and the editor suggests files, images and headings while you type a link.
- Tabs: press ⌘T or the + button to pick a file for a new tab, Command-click a file, choose Open
  in New Tab, or press ⌘↩ in Open Quickly. Open tabs return when the project opens again.
- Open Quickly matches names typed with their extension, such as `readme.md`, and updates its
  results when files change while it is open.
- LexMD follows a project folder that is renamed or moved, and closes one that is deleted after
  keeping any unsaved changes. Expanded folders are remembered for each recent project.
- Rename (↩) and Move to Trash (⌘⌫) in the sidebar can be changed in Settings > Shortcuts.
- Settings has General, Editor, Preview, Source Control, Shortcuts and Updates tabs and reopens
  on the last one. Shortcuts are grouped like the menus and can be searched by name or keys;
  combinations macOS keeps for itself, such as ⌘Q or ⌘Space, are refused with the reason.
- Create, rename, duplicate, move and trash files and folders in the sidebar. Renaming or moving
  a document offers to update every link to it, and the change can be undone.
- Export as PDF (⇧⌘E) or HTML, Print (⌥⌘P), and Copy as Rich Text (⌥⌘C), with diagrams and math
  included.
- Paste or drop images to save them next to the document and link them. Pasting a URL over
  selected text makes a link, and spreadsheet tables become Markdown tables. Tab moves between
  table cells and keeps columns aligned.
- Focus Mode (⌥⌘F), Typewriter Scrolling, and spelling and grammar settings that skip code and links.
- In Git repositories, the sidebar marks changed files and Commit… (⌥⌘K) shows the branch, the
  author the commit will use, the changed Markdown files and images with diffs, and a message
  field. It appears only when there are such changes, commits only the files you pick, and never
  contacts a remote. Git features stay hidden outside repositories.
- Quick Look previews of Markdown files in Finder, a `lexmd` command (LexMD > Install Command
  Line Tool…), and Shortcuts actions: Open in LexMD, Create Document, and Get Current Document.

## 1.0.0

First public release.

- Project tree that shows only Markdown files, with compact single-item folders and expand or collapse all.
- Native preview with GitHub-style alerts, task lists, tables, and code highlighting. Opens in Preview by default.
- A locked-down preview: documents never run scripts, links open only when clicked, apps and scripts
  are revealed in Finder instead of launched, and images hosted online load only when allowed in Settings.
- In-place editing with Markdown highlighting, list continuation, and formatting shortcuts, alone or beside the preview.
- Autosave, and automatic reload when files change on disk.
- Find in document, Find in Files with fuzzy file names, and Open Quickly.
- Back and forward navigation, recent projects, and customizable shortcuts.
- Appearance and sidebar position settings, first-run setup, and signed updates with Sparkle.
- Responsive with large projects and documents: the editor restyles only what changed, and searches
  and scans stop as soon as they are superseded.
