# Changelog

## 1.1.2

- Undoing a paste or a table edit is saved. Before, the file could keep the text you undid.
- Moving a file or folder to the Trash while it has unsaved changes that can't follow it now
  offers to keep those changes, as closing a deleted project already did.
- Projects in iCloud Drive, or anywhere else inside your Library folder, update the sidebar when
  files change outside LexMD.
- A renamed or moved document stays in Open Quickly's recent files.
- The editor ends a code block at a closing fence longer than the opening one, as the preview
  does, and front matter with Windows line endings is recognized everywhere.
- Links to files with a colon in their name, such as `2026:plan.md`, are written so they aren't
  read as web addresses.
- Exported HTML declares the page language, uses the system's scroll bars, and removes the same
  unsafe SVG content that diagrams already drop.

## 1.1.1

- Fixed a crash when the window was resized narrow, or opened narrow, with the outline or Split
  view showing.
- Resizing the window no longer makes the preview blink. The preview keeps your place, and the
  outline's current heading stays put until the resize ends.
- Rows in the outline can be clicked anywhere along their height, not just on their text.
- An outline shown in a window too narrow for it stays open until you hide it.
- In a very narrow Split view, the editor and preview share the space evenly.

## 1.1.0

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
- Find and Replace in the find bar, with whole-word and regular expression options. Edit gains
  Use Selection for Find, Jump to Selection (⌘J), Substitutions, Transformations and Speech.
- Menus follow macOS: Format sits between Edit and View, toggles say Show or Hide, view modes
  show a checkmark, and commands that can't act are disabled. File adds New Tab…, Close Window
  (⇧⌘W), Quick Look and Move To…; ⌘W no longer quits the app.
- The title shows the document's icon with its folder path menu, the toolbar can be customized,
  the find bar and Open Quickly use Liquid Glass, and the outline is a resizable inspector. The
  tab bar appears once a second document is open and lists hidden tabs when they don't fit.
  Space shows Quick Look for the selected file in the sidebar.
- LexMD Help is built in and works offline, and Help > Keyboard Shortcuts opens the shortcut list.
- Accessibility: Reduce Motion is respected, Increase Contrast and Differentiate Without Color
  underline links and strengthen borders, faint text is easier to read, the editor and preview
  have VoiceOver names, and Tab reaches links and Copy buttons in the preview.
- Faster and steadier: switching documents and typing do far less work, images load in the
  background, large projects rescan and filter without stalling, and documents renamed or moved
  in Finder are followed instead of recreated. Unsaved text is never dropped on quit.

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
