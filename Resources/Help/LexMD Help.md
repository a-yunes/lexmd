# LexMD Help

LexMD shows every Markdown file in a project at a glance, reads it beautifully, and updates it in
place. This page covers the basics. The shortcuts shown are the defaults; you can change any of
them in Settings > Shortcuts.

- [Opening a project](#opening-a-project)
- [Reading and editing](#reading-and-editing)
- [Tabs](#tabs)
- [Outline and links](#outline-and-links)
- [Open Quickly and Find](#open-quickly-and-find)
- [Export, print, and copy](#export-print-and-copy)
- [Committing changes](#committing-changes)
- [Quick Look and the command line](#quick-look-and-the-command-line)
- [Keyboard shortcuts](#keyboard-shortcuts)

## Opening a project

A project is any folder. Choose File > Open (⌘O) and pick a folder, drag a folder onto the
window, or choose one from File > Open Recent. In Finder, you can also Control-click a folder and
choose Services > Open in LexMD.

The sidebar lists every Markdown file in the project. Folders without Markdown are hidden, and a
folder that holds a single item is merged into it; turn this off with View > Compact Single-Item
Folders. Opening a Markdown file from Finder opens its folder as the project.

LexMD never moves or copies your files on its own. Create, rename, duplicate, move, and trash
documents from the File menu or by Control-clicking a row in the sidebar. When a document moves,
LexMD offers to update the links that point to it.

## Reading and editing

Documents open in the preview. Switch views from the toolbar or the View menu:

- Preview Only (⌘1) shows the rendered document.
- Preview and Editor (⌘2) shows the source beside the preview.
- Editor Only (⌘3) shows just the source.

Changes save as you type, and File > Save (⌘S) saves right away. If another app changes a document
you have not edited, LexMD reloads it. Text you have not saved is never discarded without asking.

The Format menu wraps the selection in Markdown: Bold (⇧⌘B), Italic (⌘I), Strikethrough (⇧⌘X),
Inline Code (⌘E), and Link (⌘K). Format Table (⌥⌘T) aligns the table at the insertion point.
Focus Mode (⌥⌘F) dims everything but the current paragraph, and Typewriter Scrolling keeps the
line you are writing in the middle of the window.

## Tabs

Open several documents in tabs. New Tab (⌘T) asks which document to open. Close Tab (⌘W) closes
the current document, and Reopen Closed Tab (⇧⌘T) brings it back. Move between tabs with ⌃⇥ and
⌃⇧⇥, or drag a tab to reorder it.

## Outline and links

View > Show Outline (⌥⌘O) lists the document's headings, the documents that link to it, and links
that point nowhere. Click a heading to jump to it.

Links between documents work in both views. Wiki links such as `[[Document Name]]` are supported,
and the editor suggests documents and headings as you type a link. Go > Back (⌘[) and
Go > Forward (⌘]) retrace the documents you visited.

## Open Quickly and Find

- Open Quickly (⌘P) jumps to any document as you type part of its name.
- Find (⌘F) searches the current document. Find Next (⌘G) and Find Previous (⇧⌘G) move between
  matches.
- Find in Files (⇧⌘F) searches every document in the project.

## Export, print, and copy

From the File menu, choose Export as PDF (⇧⌘E) or Export as HTML, or print with ⌥⌘P.
Edit > Copy as Rich Text (⌥⌘C) copies the selection, or the whole document, with its formatting,
ready to paste into Mail or a word processor.

## Committing changes

When the project is in a Git repository, the sidebar marks changed documents and a Source Control
menu appears. Source Control > Commit (⌥⌘K) lists the changed files with their changes and the
author that will be recorded, then commits the files you choose with your message. LexMD uses the
Git already installed on your Mac and never pushes.

## Quick Look and the command line

Select a Markdown file in Finder and press Space to preview it the way LexMD renders it.

To open files from Terminal, choose LexMD > Install Command Line Tool. Then:

```sh
lexmd .            # open the current folder as the project
lexmd notes.md     # open a document in a tab
lexmd -n idea.md   # create the document if it is missing, then open it
lexmd --help       # list every option
```

## Keyboard shortcuts

Choose Help > Keyboard Shortcuts to see every command and its shortcut. Click a shortcut to record
a new one. Giving a command a shortcut that another command uses removes it from the other one.
