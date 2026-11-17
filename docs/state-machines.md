# LexMD state machines

This document maps the state machines in LexMD, explicit and implicit. For each one it gives
the variables that encode it, its states, the invariants the code relies on, and its
transitions. It then lists the invalid states and transitions the code can reach today, and
groups their fixes into issues ordered by impact.

Line numbers refer to `main` at 666f7d7 (LexMD 1.1.2). Paths are under `Sources/LexMD/` unless
they start with `Sources/` or `Tests/`.

**Evidence levels**

| Mark | Meaning |
|---|---|
| **T** | Reproduced by a test before the fix. The tests are in `Tests/LexMDTests/StateIssueTests+Documents.swift` and `StateIssueTests+Preview.swift` (plus two in `PreviewLoadingTests.swift`), and now check the fixed behaviour. |
| **R** | Confirmed by reading: every step of the sequence is in the code, with no guard that stops it. |
| **P** | Plausible: the steps are in the code, but one depends on timing or on AppKit behaviour that was not demonstrated. |

## Status

All twelve issues in section 9 are fixed; each issue ends with a **Fixed** note that says how. Sections 2 to 8 describe the code as it was audited, so the reasoning behind
each fix stays readable. The "Also found, not pursued further" items in section 8 are unchanged.

## Contents

1. [The machines at a glance](#1-the-machines-at-a-glance)
2. [Documents](#2-documents): save state, tabs, unsaved-text prompts, external changes
3. [Project](#3-project): project lifecycle, tree scan, history, sidebar file commands, link updates, link index, file undo
4. [Preview](#4-preview): page lifecycle, render outbox, render scheduling, tab scroll, outline fit
5. [Find and quick search](#5-find-and-quick-search)
6. [Git](#6-git): discovery, status refresh, commit sheet
7. [Settings and app chrome](#7-settings-and-app-chrome): shortcuts, recorder, updates, onboarding, command line tool
8. [Invalid states the code can reach](#8-invalid-states-the-code-can-reach)
9. [Issues, by impact](#9-issues-by-impact)
10. [Checked and sound](#10-checked-and-sound)

## 1. The machines at a glance

Only three machines are explicit, with an enum or a dedicated type. The rest are encoded in
flag combinations and in optional values whose presence means "in progress".

| Machine | Encoding | Kind |
|---|---|---|
| Document save state | `text`, `savedText`, `saveError`, `saveTask` | implicit |
| Tabs | `TabList` (`tabs`, `activeID`, `closed`), `TabViewState.unsavedText`, `TabStore.missing` | explicit type, implicit states |
| Unsaved-text prompts | callbacks of `askAboutUnsavedText`, `keepUnsavedElsewhere`, `confirmDiscard` | implicit, no state variable |
| Project | `rootURL`, `watcher`, pending alert closures | implicit |
| Tree scan | `scanTask`, `scanRoot`, `rescanAfterScan`, `treeGeneration` | implicit, generation-guarded |
| Link update | a `Task` per move, `LinkWriteRecord` | implicit |
| Link index | `LinkIndex` (`generation`, `task`, `needsFullScan`) | explicit, generation-guarded |
| Preview page | `isLoaded`, `isLoadingTemplate`, `templateNavigation`, `templateRetries` | implicit |
| Preview outbox | `lastHTML`, `hasNewRender`, `pendingHeading`, `pendingScrollFraction`, `highlight` | implicit |
| Outline fit | `isOutlineVisible`, `outlineFitsWindow`, `showsOutlineWhileNarrow` | implicit |
| View mode | `ViewMode` | explicit enum |
| Find bar | `isFindBarVisible`, `findQuery`, `findIndex`, `findCount`, `viewMode` | implicit |
| Quick search | `isQuickSearchVisible`, `quickMode`, `quickTask`, `quickPendingActivation`, `quickOpensInNewTab` | implicit |
| Git discovery and status | `GitModel` tasks and flags | implicit, task-guarded |
| Commit sheet | `CommitSession` flags | implicit |
| Shortcut recorder | per-row `@State isRecording`, `monitor` | implicit, per view |
| Onboarding | `OnboardingView.step` | explicit enum |

The defects in section 8 come from four patterns:

1. **A transition that replaces state without leaving it first.** For example, `load` replaces
   the text even when its save just failed (D1).
2. **A completion that acts on the state current when it finishes, not the state it was started
   for.** Examples: alert callbacks, link-update plans, commit results and preview script
   callbacks.
3. **Two readers of one fact that drifted apart.** Examples: page matches against source
   matches, `DocumentText` against `TextFile`, and the default shortcuts against stored overrides.
4. **Per-project state that outlives the project.** Examples: git, the file undo stack, and
   pending alert closures.

## 2. Documents

### 2.1 Save state of the active document

**Variables**

- `currentFile` AppModel.swift:68
- `text` :233 and `savedText` :234
- `saveError` :70
- `saveTask` :235, a 700 ms debounce
- `sidebarFiles.trashing` AppModel+FileOperations.swift:17
- the active tab's id in `TabStore.missing` TabList.swift:191

**States**

| State | Condition |
|---|---|
| NoDocument | `currentFile == nil` |
| Clean | `text == savedText`, `saveError == nil` |
| DirtyPending | `text != savedText`, `saveTask` sleeping |
| DirtyFailed | `text != savedText`, `saveError != nil`. There is no retry timer; the next edit, ⌘S, a tab switch or quit retries. |
| DirtyTrashing | the document is inside a path being trashed; `saveNow` returns without writing (:898) |
| Missing | orthogonal flag: the file is gone from disk |

**Invariants**

- **I1.** `currentFile != nil` if and only if there is an active tab whose `path == currentFile.path`.
- **I2.** Before `text` is replaced, either `text == savedText`, or the text has been copied
  somewhere that `unsavedDocuments()` reports (a tab's `state.unsavedText`).
- **I3.** `saveError != nil` implies `text != savedText`.
- **I4.** Nothing writes inside a path that is being trashed.
- **I5.** `savedText` equals what was last read from or written to `currentFile`.

**Transitions**

| From | Event | Guard | To | Side effects |
|---|---|---|---|---|
| any | `load(url)` AppModel.swift:846 | read succeeds (:848) | Clean | `saveNow` first (:847); sets `currentFile`, `text`, `savedText`; `saveError = nil`; render; `tabDidLoad` |
| any | `load(url)` | read fails | unchanged | beep only |
| Clean | editor change → `textDidChange` :876 | | DirtyPending | debounced render; `saveTask` re-armed |
| DirtyPending | `saveTask` fires → `saveNow` :892 | file exists, or followed after a move (:897); not trashing (:898) | Clean | write in place, not atomic (:901); `git.documentSaved` |
| DirtyPending | same | write throws | DirtyFailed | `saveError` set (:907) |
| DirtyFailed | edit, ⌘S, tab switch, quit | write succeeds | Clean | |
| DirtyFailed | edit back to `savedText` | `text == savedText` (:894) | **Clean with `saveError` set** | none; breaks I3 (D4) |
| Dirty | `moveToTrash` FileOps:318 | | DirtyTrashing | path added to `trashing` |
| DirtyTrashing | recycler returns → `itemWasTrashed` FileOps:336 | | NoDocument or next tab | unsaved text written into the Trash copy |
| Clean | FSEvent for `currentFile` → `reloadFromDiskIfNeeded` :911 | disk differs from `savedText` | Clean, new text | editor undo cleared |
| Dirty | same | `text != savedText` (:913) | unchanged | external change ignored, so the next save overwrites it (D5) |
| any | `remapOpenPaths` :661 | | same state, new path | the pending save writes to the new path |
| DirtyFailed | Discard in `closeTab`, `discardUnsavedText`, `closeProject` | | Clean or NoDocument | `savedText = text` |

### 2.2 Tabs

**Variables**

- `TabList.tabs`, `activeID`, `closed` (TabList.swift:45-47)
- `TabViewState` (:12-21), including `unsavedText`, `previewFraction`, `history` and `find`
- `TabStore.missing` (:191)

**Per-tab states**

- Active.
- Background, clean.
- Background, unsaved (`state.unsavedText != nil`).
- Missing (orthogonal).
- Closed (in `closed`, only when closed with `remember: true`).

**Invariants**

- **T1.** `activeID == nil` if and only if `tabs` is empty.
- **T2.** I1 from 2.1.
- **T3.** The active tab's `state.unsavedText == nil`: the live text is in `text`.
- **T4.** At most one tab per path. This is not enforced: Back and Forward may duplicate a tab
  on purpose (`DocumentPlacement.active`).
- **T5.** No tab is closed while it holds unsaved text without asking (AGENTS.md: never lose
  user text).

**Transitions**

| Event | Where | Effect |
|---|---|---|
| `showDocument(path, .reuseTab)` | AppModel+Tabs.swift:36 | Selects the tab already showing the path. Otherwise it calls `load` in place, and `tabDidLoad` repoints the active tab. **It does not call `leaveActiveTab`.** |
| `openInNewTab` | :160 | `leaveActiveTab`, open the tab, `load`. On failure it closes the new tab and reactivates the previous one. |
| `selectTab` | :196 | `leaveActiveTab`, activate, `displayActiveTab`. On failure it closes the target with `remember: false` (:205). |
| `leaveActiveTab` | :298 | `saveNow`. Stores the selection, scroll, history, find state and `unsavedText`. Reads the page's scroll asynchronously into the tab (:313). |
| `displayActiveTab` | :330 | Writes `unsavedText` back if the file is missing (`try?`, :334). Then `load`, then `restoreViewState`. |
| `showActiveTab` | :319 | Loops, closing every tab that fails to display. |
| `closeTab` | :234 | Active tab: `saveNow`, then confirm Discard if still dirty. Background tab with `unsavedText`: confirm Discard. |
| `reopenClosedTab` | :277 | Restores the closed tab and its state. |
| `persistTabs` | :120 | Stores paths only. Unsaved text is never persisted. |

### 2.3 Unsaved-text prompts

These flows have no state variable. Each captures data, shows a sheet or alert, and continues
in a callback.

| Flow | Captures | Callback acts on |
|---|---|---|
| `settleUnsavedText` AppModel+DocumentFiles.swift:70 (opening another project) | the document list (:72) | that list, then `discardUnsavedText()`, which touches the current text (:99) |
| `confirmDiscard` AppModel+Tabs.swift:386, from `closeTab` | nothing | the **current** `text` (`savedText = text`, :241) and the tab id |
| `closeProjectKeeping` AppModel.swift:702 | the documents | `closeProject()`, **whatever project is open** (:705) |
| quit, LexMDApp.swift:56 | the documents | `.terminateLater` reply |

`present` (AlertSupport.swift:58) shows a sheet on the key window, or falls back to `runModal`.
Menu commands still run while a sheet is up. `performCloseCommand` and `closeKeyWindow` guard
against that; the others (Show Next Tab, Back, Reopen Closed Tab, Open Recent, external opens)
do not.

Invariant the callbacks assume: **the state they act on is the state the prompt was shown for.**
Nothing enforces it (D3, P2).

### 2.4 External changes

`DirectoryWatcher` (FileScanner.swift:297):

- FSEvents with file events, no defer and watch root; latency 0.3 s; delivered on the main queue.
- `handleFileEvents` (AppModel.swift:584) runs in this order:
  1. a root change → `projectFolderChanged`;
  2. any event under an open document → `followMovedDocuments`;
  3. an exact `event.path == currentFile` → `reloadFromDiskIfNeeded`;
  4. a `MustScanSubDirs` event → rescan only.

Ordering against LexMD's own writes is safe: `saveNow` writes synchronously, and reload compares
the disk against `savedText`. The policy is "local edits win" (:913). There is no check of the
disk before a write (D5).

## 3. Project

### 3.1 Project lifecycle

**Variables**

- `rootURL` AppModel.swift:26 and `watcher` :251
- `tree` :27, `expanded` :56, `recentFolders` :75
- the pending closures of `settleUnsavedText` and `closeProjectKeeping`

**States**

- NoProject.
- Open(root).
- Open + SwitchPrompt(target).
- Open + ClosingPrompt: the folder is gone and the alert is up, while `rootURL` and the watcher
  stay live.

**Invariants**

- **R1.** `rootURL == nil` implies `tree` is empty, there are no tabs, `currentFile` is nil and
  `watcher` is nil.
- **R2.** Every tab path, `currentFile`, `selectedPath` and history entry is under `rootURL`.
- **R3.** Every piece of per-project state belongs to `rootURL`: the git model, the file undo
  stack, the commit sheet, and pending callbacks.

**Transitions**

| From | Event | Guard | To | Side effects |
|---|---|---|---|---|
| NoProject | `restoreSession` :437 | stored root is a folder | Open | restores tabs, or the last file |
| Open(A) | `open(url)` :475, path inside A | | Open(A) | `finishOpening`: reveal and `showDocument` |
| Open(A) | `open` of another folder, or a file outside A | unsaved text can be written | Open(B) | `setRoot` :507: `saveNow`, close tabs, watch, rescan |
| Open(A) | same | unsaved text cannot be written | SwitchPrompt | alert (DocumentFiles:70) |
| SwitchPrompt | Discard or Save to Folder | | Open(B) | |
| SwitchPrompt | Cancel | | Open(A) | |
| Open(A) | root changed, folder moved, `projectFolderChanged` :616 | | Open(A') | `followProjectMove` :643 |
| Open(A) | folder trashed or removed | nothing unsaved | NoProject | `closeProject` :785 |
| Open(A) | same | unsaved text | ClosingPrompt | `keepUnsavedElsewhere` |
| ClosingPrompt | finish (:705) | **none** | NoProject | closes whatever project is open (P2) |

Git is told about the new root only when the scan finishes (:569). Until then it still
describes A (P1).

### 3.2 Tree scan

**Variables:** `scanTask` :237, `scanRoot` :238, `rescanAfterScan` :243, `rescanTask` :250,
`isScanning` :44, `treeGeneration` :245 (bumped by `tree.didSet`).

**States:** Idle, Scanning(root), Scanning + Pending, and Debouncing (250 ms, running alongside).

**Transitions** (`rescan()` :547-571):

- From Idle: start a scan.
- Same root while scanning: go to Pending.
- Another root: cancel and restart.
- On completion:
  - cancelled or root changed: dropped;
  - generation changed: rescan;
  - otherwise: apply the tree and tell git, then rescan if Pending.

**Invariant:** a result is applied only for the current root and generation. **Sound.**

### 3.3 Navigation history

**Variables:** `history`, `historyIndex` (AppModel.swift:113-114), plus a copy per tab.

**Invariant H1:** `currentFile != nil` implies `history[historyIndex] == currentFile.path`.

**Transitions:**

| Function | Line | What it does |
|---|---|---|
| `recordVisit` | :973 | Truncates the history after the index and appends. |
| `navigateHistory` | :988 | Sets the index (:994), **then** opens; the open can fail. |
| `displayActiveTab` | | Restores the tab's history. |
| `leaveActiveTab` | | Saves the history into the tab. |
| `itemWasTrashed` | FileOps:341 | Filters entries and **clamps** the index. |
| `closeDocument` | | Clears the history. |

H1 breaks after a failed open, and after a trash that removes an entry before the index (N1).

### 3.4 Sidebar file commands

**Variables:** `renamingPath` AppModel+FileOperations.swift:9, `renameIsNewDocument` :11,
`newFolders` :13, `trashing` :17.

**States:** Idle, Renaming(path), RenamePrompt, TrashConfirm, Trashing(path) while the recycler
is awaited, Duplicating.

**Transitions:**

- `beginRename` and `commitRename` (:112, :126) → `performMove` (:218) → `applyMove` (:240) and
  `offerLinkUpdate` (:397).
- `moveToTrash` (:318) → `itemWasTrashed` (:336).
- `duplicateItem` (:261).
- `moveItems` (:196) calls `performMove` once per item.

Invariant I4 (no writes inside a trashing path) is enforced in `saveNow` (AppModel.swift:898).
It is not enforced in `saveAllTabs` (AppModel+Tabs.swift:152) or in `displayActiveTab`'s
write-back (:334).

### 3.5 Link update after a rename or move

This flow has no state variable; each move starts its own `Task`.

1. `offerLinkUpdate(move)` captures `files` from the tree and the open documents' text
   (AppModel+FileOperations.swift:397-400).
2. A detached task plans the update (:401-405):
   - `LinkUpdater.context` always builds `moves: [move]` (LinkRewriter.swift:693), although
     `Context` supports several moves.
3. Guard: `plan.linkCount > 0 && rootURL == root` (:406). Nothing checks that the move still
   describes the disk.
4. The user answers a prompt (:411).
5. `applyLinkUpdate` (:441):
   - the open document is edited through the editor;
   - background tabs' `unsavedText` is edited in memory;
   - files on disk are rewritten in a task (:465);
   - then `rewriteOpenText` (:487) applies edits again to documents opened in the meantime.
6. Undo and redo go through `replayLinkWrites` (:502), which restores disk files and the open
   document only.

Invariants the flow assumes:

- **L-a.** The move still holds when the update is applied.
- **L-b.** A plan sees every move made at the same time.
- **L-c.** Applying the edits twice is a no-op.
- **L-d.** Undo reverts every edit the update made.

L-a, L-b and L-d do not hold (L1, L2, L4). L-c does not hold for a moved document (L3).

### 3.6 Link index

`LinkIndex` (LinkIndex.swift:233-318) has `root`, `generation`, `task`, `needsFullScan`,
`pendingPaths` and `snapshot`:

- `setRoot` increments the generation and resets.
- `refresh` and `update(paths:)` queue work.
- `start` loops over jobs and applies the result only if the generation matches.

**Sound.**

### 3.7 File undo stack

All sidebar file operations register on the window's `UndoManager`, with absolute paths
(AppModel+FileOperations.swift:230, 284, 364, 381, 479, 503):

- rename and move;
- duplicate;
- trash and put back;
- link update.

The stack is never cleared on a project change and is not tied to `rootURL` (N4).

## 4. Preview

### 4.1 Page lifecycle

**Variables** (PreviewController.swift): `isLoaded` :35, `loadWaiters` :36,
`isLoadingTemplate` :37, `templateNavigation` :39, `templateRetries` :40.

**States**

| State | `isLoadingTemplate` | `isLoaded` | `templateNavigation` |
|---|---|---|---|
| Loading | true | false | set |
| Loaded | false | true | nil |
| GaveUp | false | false | nil, with `templateRetries == 3` |

**Transitions**

| From | Event | Guard | To | Side effects |
|---|---|---|---|---|
| any | `loadTemplate` (init, remote-content toggle :131) | | Loading | `isLoaded = false` |
| Loading | `didFinish` :287 | it is the latest navigation | Loaded | retries reset; waiters resumed with true; `pendingReset = true`; `flush()` |
| Loading | `didFail` or `didFailProvisional` :313 | latest navigation and retries < 3 | Loading | retries + 1 |
| Loading | same | retries = 3 | GaveUp | waiters left to their timeouts |
| any | WebContent process terminated :309 | **none** | Loading | not counted, no backoff (V6) |

**Invariants:**

- Every waiter in `pageLoaded(within:)` (:246) is resumed exactly once: whichever of
  `didFinish` and its timeout runs first removes it from the dictionary. **Sound.**
- A retry budget that ran out stays at 3 for every later load (V7).

### 4.2 Render outbox

**Variables:** `lastHTML` :41, `lastBase` :42, `pendingReset` :43, `hasNewRender` :45,
`pendingHeading` :46, `pendingScrollFraction` :49, `highlight` :31, `highlightApplied` :32.

- **`render` (:138):** stores the content and flushes when Loaded. Renders requested while the
  page loads collapse to the last one.
- **`flush` (:148):** sends, in this order:
  1. the libraries;
  2. `lexmdRender`;
  3. the pending heading, if this is a new render or the reveal is immediate;
  4. the highlight;
  5. `pendingScrollFraction`, if this is a new render.

  The scroll fraction is sent last, so it overrides a heading revealed in step 3 (V3).
- **`readScrollFraction` (:223) and `applyHighlight` (:204):** query the **live page**. Nothing
  records which document the page shows.

**Invariant the callers assume:** a script result describes the document the model has open.
The page actually shows the last *flushed* render, which lags the model by the render task
(V1, V4, V5).

### 4.3 Render scheduling

`renderTask` (AppModel.swift:236) is cancelled and replaced on every `render(debounce:)` call
(:921).

- The source, base URL and links are captured before the await.
- After the await, `!Task.isCancelled` is checked before handing the result to the preview.

**Sound for the model.** The window between `load` and the flush is where the outbox
consumers in 4.2 read the wrong page.

### 4.4 Per-tab preview scroll

- **Save:** `leaveActiveTab` writes the old fraction at once, then the page's fraction
  asynchronously (AppModel+Tabs.swift:301-315). The comment at :312 says "this reads the
  outgoing page", but the page shows the last flushed render, which can be another tab's (V4).
- **Restore:** `restoreViewState` sets `preview.pendingScrollFraction` (:364), which the next new
  render consumes.

### 4.5 Outline visibility and fit

**Variables:** `isOutlineVisible` :211 (persisted), `outlineFitsWindow` :94,
`showsOutlineWhileNarrow` :96, and `windowWidth` :90 (its didSet calls `updateOutlineFit`).
The didSets of `viewMode`, `columnVisibility`, `isInspectorPresented` and `sidebarPosition` also
call `updateOutlineFit`.

**Derived:** `showsOutlinePanel = isOutlineVisible && canShowOutline && (fits || whileNarrow)`
(AppModel+Outline.swift:237).

**Invariants:**

- `whileNarrow` implies `isOutlineVisible`.
- `fits` depends only on the window frame, never on whether the panel is shown. This is the
  1.1.1 fix for the layout loop.

**Sound.**

### 4.6 View mode and editor visibility

**Variables:**

- `viewMode`, set through `setViewMode` (AppModel.swift:946);
- `WorkspaceContainer.mode` and `needsEvenSplit` (ContentView.swift:550);
- each pane's `isHidden`;
- `editor.pendingWhileHidden` (EditorController.swift:603), drained when the editor is unhidden.

Scroll sync runs both ways in Split mode and is one machine, `ScrollSync`
(ScrollSync.swift), over two panes that only measure and scroll (`ScrollSyncPane`: the editor in
EditorController+SourcePositions.swift, the preview at the end of PreviewController.swift).

**Places** are source positions: a line, counted from 1, plus the fraction of it passed, with 0
the very top of a pane's document and `lines + 2` its end.

- **Editor.** A line spans its wrapped rows (`sourcePosition(at:)`, `offset(ofSourcePosition:)`).
- **Preview.** Innermost blocks carry `data-line` and `data-end`
  (`MarkdownHTML.renderWithSourceLines`). The page reports where they are, and the app keeps
  them as a `PositionMap`: a block's first line at its top edge, the line after its last at its
  bottom edge. A paragraph therefore lines up edge to edge in both panes, and blank lines span
  the gap between blocks.
- **Lines** mean the same everywhere through `LineIndex` (LF, CRLF or a lone CR ends a line).

**Variables:** `ScrollSync.isEnabled` (Split view), `lead` (the leading side, its position,
when it last led, and a glide), and the preview's `pageLayout` (nil until the page reports).

| From | Event | Guard | To | Side effects |
|---|---|---|---|---|
| any | a pane scrolls, `paneScrolled(side, input:)` | the other side doesn't hold the lead, or `input` | side leads | the other pane follows to the same position at the anchor |
| other side leads | same, within `hold` (0.3 s) of its last scroll | no `input` | unchanged | ignored: the follower's layout settling, or the page keeping its place |
| a side leads | first scroll of a lead, follower more than 2 px out of line | Reduce Motion off | same, gliding | the follower closes the distance over `catchUp` (0.25 s), by `step(at:)` |
| any | `isEnabled` turns off | | idle | `lead` cleared; the page stops reporting |

**Rules:**

- **Anchor.** Both panes show the led position at the same height (`ScrollMetrics.anchorOffset`):
  mid-height, sliding to the top edge at the start of the document and the bottom edge at its
  end, so both ends line up and every part can be reached.
- **Whose scroll.** The editor reports scrolls that aren't quiet, with whether the reader used
  the wheel or keys in it. The page reports every scroll: one it made itself goes through
  `scrollPage` and is recognized by where it lands, the others are the reader's, with whether
  they used the wheel, keys or mouse.
- **Suppressed** while a resize settles and during a live resize, as before.

**Sound.**

### 4.7 Export, print and copy

- **Export and print:** each call gets its own offscreen renderer and `PreviewController`
  (ExportController.swift:85, 177, 348).
  - Steps: load → `pageLoaded(20 s)` → `settle`.
  - PDF printing goes through `PrintCompletion`, which resumes once.
  - There is no in-flight tracking or cancellation.
- **Copy as Rich Text** (AppModel+Export.swift:61) picks its source synchronously:
  1. the editor selection, rendered offscreen;
  2. otherwise the **live preview**, if `isPageLoaded`;
  3. otherwise the document, rendered offscreen.

  Each call starts an untracked task that clears the pasteboard when it finishes (V1, V2).

## 5. Find and quick search

### 5.1 Find bar

**Variables** (AppModel.swift):

- `isFindBarVisible` :165, `findQuery` and the option flags :166-177 (each didSet resets the
  index and refreshes)
- `findCount` :178, `findIndex` :179, `findStatus` :182
- `isReplaceVisible` :183, `replaceQuery` :184
- per tab, `TabFindState` (TabList.swift:5): query, case sensitivity and index only

**Invariants**

- **F-a.** `findIndex < findCount`.
- **F-b.** In Read mode, the count and index refer to matches **on the page**
  (AppModel+Search.swift:74, 95). In Edit and Split mode, they refer to matches **in the
  source** (:80).
- **F-c.** Replace edits the match the bar points at.

**Transitions:**

- `showFind`, `findNext`, `closeFindBar`, `refreshFind`, `highlightCountChanged`
  (AppModel+Search.swift:27-99).
- `replaceCurrent` and `replaceAll` (AppModel+Replace.swift:28-66).
- A tab switch saves and restores the per-tab find state (AppModel+Tabs.swift:309, 354).

F-c fails in Read mode. `replaceCurrent` indexes **source** matches with the **page** index
(AppModel+Replace.swift:33), so a match the page doesn't show, such as a link target, shifts it
(F1).

### 5.2 Quick search (Open Quickly and Find in Files)

**Variables** (AppModel.swift):

- `isQuickSearchVisible` :190, `quickOpensInNewTab` :192, `quickMode` :193
- `quickQuery` :194 and `quickOptions` :197, whose didSets schedule a search
- `quickResults` :200, `isQuickSearching` :205, `quickSelection` :206
- `quickPendingActivation` :249, `quickTask` :254, `quickKeyMonitor` :255

**States:** Hidden; Visible and idle; Visible and searching (the list shows the previous
query's results); Visible, searching, with an activation pending.

| From | Event | To |
|---|---|---|
| Hidden | `toggleQuickSearch` :112 or `newTab` :132 | Searching |
| Visible | typing (110 ms debounce) | Searching |
| Searching | results :281 | Idle; a pending activation fires |
| Searching | Return | activation pending |
| any visible state | **row click** (SearchViews.swift:451) | opens at once, **even while searching** (Q1) |
| any | `closeQuickSearch` :138 | Hidden; `quickOpensInNewTab = false` |

**Invariant:** `quickOpensInNewTab` is true only for the Files panel opened by ⌘T. Switching to
Find in Files keeps it (Q3).

## 6. Git

### 6.1 Discovery and availability

**Variables** (AppModel+Git.swift): `tool` :13, `repositories` :14, `isDiscovering` :21,
`projectRoot` :23, `folders` :24, `discoverTask` :26. The located git is cached for the whole
process in `Git.system` (Git.swift:73), a `static let`.

**States:**

- NoProject.
- Discovering.
- Unavailable (no tool).
- Inactive (no repository).
- Active.

**Transitions:**

- **Scan finished** (AppModel.swift:569 → :91): when the root or folders changed,
  `discover()` starts.
- **App activated** (:36): always calls `discover()`, which **cancels the discover in flight**
  (:139).
- **Discover completes** (:149): applied when not cancelled and the root is unchanged.
- **`.git` changes**: `scheduleDiscover`, with a 1 s debounce.

**Invariants:**

- `Git.system` resolves once, correctly.
- A discover result applies to the current root.

The first is not guaranteed. `Git.system` is initialised inside whichever discover task first
touches it. If that task is cancelled while `xcrun --find git` runs, `ProcessRunner` kills the
process (Git.swift:225-235), `locate()` returns nil, and the `static let` keeps nil for the
life of the process (G1).

### 6.2 Status refresh

**Variables:** `statusEnabled` :25, `scheduledTask` :28, `statusTask` :29,
`needsAnotherStatus` :30, `lastStatusEnd` and `lastStatusDuration` :31.

**States:** Disabled, Idle, Scheduled, Running, Running + Pending.

**Rules:**

- At most one status task runs at a time.
- A result is dropped when cancelled, when the root changed, or when status was disabled (:239).
- The `defer` re-runs a pending request.

**Sound.**

### 6.3 Commit sheet

**Presentation:** `GitModel.commitSession`, nil or set (:20).

- `presentCommitSheet` (:248) never checks for an existing session.
- `clear()` on a project change leaves it alone.

**`CommitSession` variables** (CommitSheet.swift): `repository` :13 (its didSet reloads),
`snapshot`, `identity`, `operation`, `isLoading` :20, `loadFailed` :21, `checked` :22,
`selection`, `diff`, `isCommitting` :32, `errorText` :33, `confirmation` :34, `userChoices` :36.

| From | Event | Guard | To |
|---|---|---|---|
| | init | | Loading |
| Loading | load done :101 | same repository | Ready |
| Ready | ⌘↩ `commit()` :155 | `canCommit` | Committing |
| Committing | result :172 | **session still alive** (weak `self`) | Succeeded or Failed |
| Committing | Cancel or Esc :481 (**not disabled**) | | session released; the result is dropped (G2) |
| Committing | repository picker :291 (**not disabled**) | | Loading for another repository while the commit runs (G3) |

**Invariant the success message assumes:** `branchLabel` is the branch of the repository that
was committed. G3 breaks it.

## 7. Settings and app chrome

### 7.1 Shortcut table

Each action's stored override (`shortcutOverrides`, AppModel.swift:103) is absent (use the
default), a combination, or `"none"` (Shortcuts.swift:276-281).

**Invariant K:** no two actions resolve to the same shortcut. `setShortcut` (:297) enforces it
when a shortcut is assigned. Nothing enforces it on load, so a default added later can collide
with an older override (K1).

### 7.2 Shortcut recorder

Each Settings row has its own `@State isRecording` and `monitor` (SettingsView.swift:308).

- `startRecording` (:359) stops only its own row's monitor, then installs an **app-wide** local
  keyDown monitor. That monitor returns nil for every key, in every window.

**Invariant assumed:** at most one row records, and only keys typed in Settings are recorded.
Neither holds (K2).

### 7.3 Updates

`UpdateService` (UpdateService.swift:9-16) tracks the controller (nil, started or failed),
`canCheck`, `automaticChecks`, `automaticDownloads` and `lastChecked`. The setters update the
local value before Sparkle's, and KVO observation brings Sparkle's values back. No reachable
invalid state was demonstrated.

### 7.4 Onboarding

`step` is one of welcome, tour, folder or finish (OnboardingView.swift:9). Its `onChange`
opens the demo whenever the step becomes `tour` and the open project is not the demo (:55).
Going Back from the folder step therefore replaces a project the user just chose (N5).

### 7.5 Command-line tool

`LinkState` is missing, installed, otherLink or otherItem (CommandLineTool.swift:17). The state
is computed when the alert opens; the AppleScript install runs later and re-checks only
afterwards. That leaves a small time-of-check to time-of-use window, which the final check
reports. No defect was reached.

## 8. Invalid states the code can reach

Each entry gives the evidence level, the sequence, and the consequence. The issue that fixes it
is in section 9.

### Documents

**D1 (T). Opening another document in the same tab drops text that couldn't be saved.**
- **Sequence:**
  1. The open document is read-only, its folder is gone, or the disk is full, so `saveNow`
     fails and sets `saveError`.
  2. The user clicks another file in the sidebar: `sidebarSelected` → `showDocument(.reuseTab)`
     (AppModel+Tabs.swift:42) → `load`.
  3. `load` calls `saveNow`, which fails again (AppModel.swift:847). The read succeeds, so `text`,
     `savedText` and `saveError` are replaced (:852-855).
  4. `tabDidLoad` repoints the tab (TabList.swift:73). `leaveActiveTab` is never called.
- **Same path from:** Open Quickly, Find in Files, preview links, backlinks, Back and Forward,
  and New Document.
- **Consequence:** the text is gone with no prompt, and the "Couldn't save" note disappears.
  This breaks I2.
- **Test:** `openingAnotherDocumentKeepsTextThatCouldNotBeSaved`: after the click, nothing holds
  the text.

**D2 (T). An unreadable tab is closed together with its unsaved text.**
- **Sequence:**
  1. Tab A's folder is deleted while A has edits, so the save fails.
  2. Switching to B stores A's text in the tab (AppModel+Tabs.swift:310).
  3. Switching back: the write-back fails silently (`try?`, :334), and `load` fails (:340).
  4. `selectTab` closes A with `remember: false` (:205).
- **Same path from:** `showActiveTab` (:320-324), reached after closing a tab or a trash.
- **Consequence:** the text is lost with a beep. This breaks T5.
- **Test:** `unreadableBackgroundTabKeepsItsText`: only tab B remains.

**D3 (P). A Discard prompt's callback acts on the tab that is active when the user answers.**
- **Variant 1:** with the ⌘W Discard sheet up for tab T1, ⌃Tab selects T2.
  1. Discard runs `savedText = text` (AppModel+Tabs.swift:241), which marks **T2's** text as
     saved.
  2. `finishClosingActiveTab` then reloads T2 from disk, losing T2's restored unsaved text.
  3. T1 goes into `closed` still carrying its "discarded" text. ⇧⌘T brings it back, and
     autosave writes it.
- **Variant 2:** the sheet is for a background tab, which the user selects before answering.
  `list.close(id)` (:251) then closes the **active** tab without `finishClosingActiveTab`. The
  editor keeps showing it while `activeID` points at a neighbour (breaks I1). The next sidebar
  click repoints that neighbour's tab.
- **Why plausible:** it depends on menu key equivalents firing while a sheet is attached.
  `performCloseCommand` (:220) guards against exactly that, which suggests the author has seen
  it.

**D4 (T). "Couldn't save" stays after the text returns to its saved state.**
- `saveNow` returns at `text == savedText` (AppModel.swift:894) before clearing `saveError`.
- **Consequence:** the subtitle and the tab's dirty dot stay. This breaks I3.
- **Test:** `undoingBackToTheSavedTextClearsTheSaveError`.

**D5 (R). Changes made by another app are overwritten without a check.**
- **Sequence:**
  1. LexMD saves.
  2. Another app writes the file.
  3. The user types within the 0.3 s FSEvents latency.
  4. The event finds the document dirty and ignores the change (:913).
  5. The next autosave writes over the other app's version. `saveNow` never compares the disk
     with `savedText` before writing (:901).
- **Also:** a `MustScanSubDirs` event, which FSEvents sends after dropping events (for example
  during a large `git checkout`), only rescans (:608). The open document keeps the old branch's
  text, and the next keystroke writes it back.
- **Consequence:** silent loss of another app's edits.

**E1 (T). Saving re-encodes the file.**
- `load` reads with `DocumentText.read` (QuickSearch.swift:336): UTF-8, then detection, then
  Latin-1. `saveNow` always writes UTF-8 (AppModel.swift:901). `TextFile` (LinkRewriter.swift:604)
  already reads and writes the original encoding and byte order mark, but documents don't use it.
- **Consequence:** a UTF-8 file with one stray byte is read as a single-byte encoding. On the
  first keystroke, "café" is saved as "cafÃ©" (bytes C3 83 C2 A9). UTF-16 and Latin-1 files
  become UTF-8.
- **Test:** `savingKeepsTheFilesBytes`.

### Find and replace

**F1 (T). Replace in Preview Only mode replaces a match the page doesn't show.**
- **Sequence:**
  1. In Read mode, the count and index come from the page (AppModel+Search.swift:74, 95).
  2. `replaceCurrent` applies that index to the source matches (AppModel+Replace.swift:33).
- **Consequence:** in `[x](foo.md) foo` the page shows one "foo". Replace rewrites the link
  target instead, giving `[x](bar.md) foo` and a broken link. Replace All likewise replaces more
  matches than the bar counted.
- **Test:** `replaceInReadModeReplacesTheShownMatch`.

**F2 (R). Per-tab find state drops Whole Word and Regex.**
- `TabFindState` stores only the query, case sensitivity and index (TabList.swift:5), so a query
  saved under Regex is restored in literal mode.
- **Consequence:** the find bar finds nothing, or finds other matches.

### Links and file operations

**L1 (T). Moving several linked items at once breaks the links between them.**
- **Sequence:**
  1. `moveItems` calls `performMove` per item (AppModel+FileOperations.swift:203).
  2. Each item's `offerLinkUpdate` plans against the tree right after its own move, with
     `moves: [move]` (LinkRewriter.swift:693).
  3. Drop `a.md` (linking `b.md`) and `b.md` into F. Plan 1 sees `b.md` still at the root.
- **Consequence:** accepting the first prompt rewrites F/a.md to `../b.md`, which does not exist.
  The link was correct after the move.
- **Test:** `movingTwoLinkedFilesKeepsTheirLink`.

**L2 (R). A link update is applied after its move was undone or superseded.**
- **Variant 1:**
  1. Rename old→new. While the plan runs, press ⌘Z.
  2. The plan's guard checks only the link count and the root (:406), so the prompt appears.
  3. Update rewrites links to `old.md`, which exists again, to `new.md`, which does not.
- **Variant 2:** rename A→B, then B→C before the first plan finishes. Only the first prompt
  appears, and it points every link at B.
- **Why it's timing-dependent:** the plan must still be running, as in a large project.

**L3 (R). A moved document opened during the update gets its links rebased twice.**
- **Sequence:**
  1. The disk rewrite (:466) writes `../b.md` into F/M.
  2. The user opens F/M before the continuation runs.
  3. `rewriteOpenText` (:490) applies the edits again. For a moved document they are not
     idempotent, so the link becomes `../../b.md`.
- **Consequence:** autosave saves the broken link. Undo then skips F/M, because the disk no
  longer matches the record (LinkRewriter.swift:734).

**L4 (R). Undo of a link update leaves in-memory edits in place.**
- Edits to background tabs' `unsavedText` (AppModel+FileOperations.swift:456) and those made by
  `rewriteOpenText` are not recorded in `LinkWriteRecord` (:26), so `replayLinkWrites` cannot
  revert them.

**N4 (R). File undo outlives the project.**
- Rename in project P1, open P2, then Undo Rename from the sidebar. The file moves in P1, and
  `applyMove` reassigns P2's tree.
- The same is true for Undo Duplicate (it trashes a file in P1), Undo Move to Trash and Undo
  Update Links.

**N2 (R). After Redo of Move to Trash, the trash can no longer be undone.**
- The redo registered by `putBack` calls `moveToTrash(registerUndo: false)` (:382), and Undo
  Duplicate does the same (:285).

**N3 (R). Renaming onto the path of a missing tab creates two tabs for one path.**
- `remap` (AppModel.swift:678) does not deduplicate tabs, unlike `followMovedDocuments`
  (AppModel+DocumentFiles.swift:47). This breaks T4.

**N1 (R). The history index stops naming the shown document.**
- **After a failed open:** `navigateHistory` sets the index before the open (:994), and the open
  can fail.
- **After a trash:** `itemWasTrashed` clamps the index instead of recomputing it
  (FileOps:341-342). This breaks H1; Back then does nothing visible, and the next visit truncates
  the wrong entries.

**N6 (R). `duplicateItem` applies its result to whichever project is open when the copy ends.**
- After the await it has no root check (:277-288).

### Project switch

**P1 (T). Commit stays available for the previous project while a new one scans.**
- **Sequence:**
  1. `setRoot` closes the tabs and starts the scan.
  2. Git hears about the new root only when the scan ends (AppModel.swift:569).
  3. Until then, `commitTarget(nil)` returns the old project's repository (AppModel+Git.swift:60).
- **Consequence:**
  - ⌥⌘K opens a commit sheet for the old project.
  - `clear()` never dismisses it, so it stays bound to the old repository.
- **Test:** `commitIsNotOfferedForThePreviousProject`.

**P2 (R/P). The pending "project folder is gone" prompt closes the next project.**
- **Sequence:**
  1. The folder is deleted while it has unsaved text, so `closeProjectKeeping` shows its prompt.
  2. Meanwhile project B is opened, from Finder, the `lexmd` tool or Open Recent.
  3. The prompt's finish runs `closeProject()` without an identity check (AppModel.swift:705),
     so it closes B.
- **Why R/P:** the closure is confirmed by reading; reaching it needs an open while the prompt
  is up.

**P3 (R). Opening a folder and files together asks once per file and reuses one tab.**
- **Sequence:**
  1. `open([folder, files])` (OpenRequests.swift:77) starts the settle prompt for the folder.
  2. It then calls `openPath` for each file at once, while the old root is still open. Each file
     is outside that root, so each goes through `open(url)` and its own prompt
     (AppModel+Tabs.swift:138).
- **Consequence:** N prompts. The files then replace each other in one tab instead of opening
  in tabs, and Save to Folder writes duplicate copies.

### Git

**G1 (T for the mechanism; P for the trigger). Git can be switched off for the whole session.**
- **Mechanism:**
  1. A discover is cancelled while `xcrun --find git` runs. App activation cancels the discover
     in flight (AppModel+Git.swift:36, 139).
  2. `ProcessRunner` sees the cancelled task within 50 ms and kills the lookup.
  3. `Git.system` caches nil.
- **Consequence:** no badges, Source Control menu or Commit until relaunch.
- **What triggers it:** a cold `xcrun` (first launch after boot or after an Xcode update) taking
  longer than 50 ms while the app activates. The test shows that a lookup slower than one poll
  fails under a cancelled caller.
- **Test:** `locatingGitSurvivesACancelledCaller`.

**G2 (R). A commit's result is lost when the sheet closes while committing.**
- **Sequence:**
  1. Cancel and Esc stay enabled while committing (CommitSheet.swift:481).
  2. Closing releases the session.
  3. The commit task holds it weakly and returns at `guard let self` (:173).
- **Consequence:** a failure (a hook, the identity, or `index.lock`) is never shown. Reopening
  the sheet allows a second commit that races the first.

**G3 (R). Changing the repository during a commit reports the wrong branch.**
- **Sequence:**
  1. The picker stays enabled while committing (:291).
  2. Changing it reloads another repository (:14).
  3. The success message reads `self.branchLabel` (:179), which is now the other repository's
     branch.

**G4 (P). ⌥⌘K while the commit sheet is open replaces the session.**
- `presentCommitSheet` (AppModel+Git.swift:248) never checks for an existing session.
- **Consequence:** a commit in flight loses its result, as in G2.

### Preview

**V1 (T). Copy as Rich Text copies the previous document, or text from before the last edits.**
- **Sequence:**
  1. After `load(B)`, B's render is still a pending task.
  2. `copyRichText` sees `isPageLoaded` and clones the live page (AppModel+Export.swift:67, 77),
     which still shows A.
- **Also:** while typing, the copy misses edits made in the last 90 ms plus the render time.
- **Consequence:** the clipboard holds a different document than the one on screen.
- **Test:** `copyRichTextCopiesTheShownDocument`: it copied "Alpha document" while b.md was open.

**V2 (R). An older Copy as Rich Text overwrites a newer clipboard.**
- **Sequence:**
  1. Each copy starts an untracked task.
  2. The offscreen path takes at least a page load plus about 250 ms.
  3. `Exporter.write` clears the pasteboard when the task finishes.
- **Consequence:** a slower, older copy replaces whatever the user copied since.

**V3 (T). A link to a heading in a document already open in another tab lands at the tab's old
scroll position.**
- **Sequence:**
  1. Selecting the tab restores `pendingScrollFraction` (AppModel+Tabs.swift:364).
  2. The link sets `pendingHeading`.
  3. `flush` reveals the heading, then scrolls to the old fraction (PreviewController.swift:157,
     165).
- **Consequence:** the preview ignores the link's heading.
- **Test:** `headingLinkToAnOpenTabRevealsTheHeading`: the heading ended 7,220 px below the top.

**V4 (T). Switching tabs quickly stores another document's scroll position in a tab.**
- **Sequence:**
  1. A→B→C in quick succession: B never renders.
  2. `leaveActiveTab(B)` reads the page, which still shows A, and stores A's fraction in B.
- **Also:** for Reopen Closed Tab, the asynchronous read arrives after the tab was moved to
  `closed`, so the reopened tab gets a stale position.
- **Test:** `fastTabSwitchKeepsEachTabsPreviewPosition`: B's position went from 0.0 to 0.8.

**V5 (T). The find index is clamped by the previous page's match count.**
- **Sequence:**
  1. Restoring tab B's find state applies B's index 7 to a page that still shows A, which has
     two matches.
  2. `highlightCountChanged` clamps the index to 1.
  3. B's render then marks match 8.
- **Consequence:** the bar says "2 of 10" while the page marks the 8th match, and Find Next
  jumps to the 3rd.
- **Test:** `findIndexSurvivesATabSwitchInReadMode`.

**V6 (R). A WebContent crash reloads the page with no limit, and every reload scrolls to the
top.**
- **No limit:** `webContentProcessDidTerminate` reloads without counting (PreviewController.swift:309),
  and `didFinish` resets the retry count. Markup that kills WebContent, such as a huge image or
  SVG, therefore loops.
- **Scroll:** a reload is not a new render, so neither the scroll fraction nor a pending heading
  is reapplied (:153-168). The reset scrolls to the top. A remote-content toggle loses the
  position the same way.

**V7 (R). After three failed template loads, later loads get no retries.**
- `templateRetries` stays at 3 (:326), so the next `loadTemplate` gives up on the first failure.
- **Consequence:** the preview stays blank, and exports wait the full 20 s before failing.

### Quick search

**Q1 (R). Clicking a result while a newer query is still searching opens the wrong place.**
- **Sequence:**
  1. A row click activates at once (SearchViews.swift:451), so it opens a result from the old
     list.
  2. `revealOccurrence` recomputes matches with the **new** query (AppModel+Search.swift:209).
- **Consequence:** the document opens at the wrong match, or at none.

**Q2 (R). A result whose file can't be read highlights a match in the document already open.**
- `load` fails silently (AppModel.swift:848). `activateQuickItem` still calls `revealOccurrence`
  (AppModel+Search.swift:203).

**Q3 (T). Find in Files opened after ⌘T opens every result in a new tab.**
- `newTab` sets `quickOpensInNewTab`, and switching to Find in Files keeps it (:112-136).
- **Test:** `findInFilesAfterNewTabOpensInPlace`.

### Settings

**K1 (T). A shortcut saved before a default existed can bind one key to two commands.**
- **Sequence:**
  1. Stored overrides load as they are (AppModel.swift:299).
  2. Actions without an override take today's default.
  3. 1.1.0 added ⌥⌘O, ⌥⌘K, ⌘J, ⌥⌘F, ⇧⌘E, ⌥⌘P, ⌥⌘C, ⌘T, ⇧⌘W and ⌘⌫ as defaults.
- **Consequence:** a 1.0 override of ⌥⌘O for Show or Hide Sidebar now collides with the
  outline's default. AppKit runs whichever menu item comes first. Overrides recorded before the
  reserved list existed, such as ⌘H, are never re-checked either.
- **Test:** `storedShortcutsNeverBindOneKeyTwice`.

**K2 (R). The shortcut recorder can assign keys to the wrong command and swallows keys in
every window.**
- **Two recorders at once:** clicking a second row starts a second recorder, so two app-wide
  monitors are active (SettingsView.swift:359). The next key goes to whichever monitor runs
  first.
- **Keys swallowed in every window:** each monitor returns nil for every key (:382). After the
  user clicks back into the document window, typing beeps and is lost.
- **Save loses its shortcut:** ⌘S typed in the editor is recorded for the recording row, and
  `setShortcut` sets Save to `"none"` (Shortcuts.swift:300).

### Onboarding

**N5 (R). Going Back from "Open a project" replaces the chosen project with the demo.**
- The step's `onChange` reopens the demo whenever the step becomes `tour`
  (OnboardingView.swift:55).

### Also found, not pursued further (P)

- **Print to a closed window:** `printDocument` captures the window before a load of up to 20 s
  (AppModel+Export.swift:49). If the window closes in the meantime, the print panel has no sheet
  parent, and the continuation and renderer may leak.
- **Two prints at once:** two print operations started together target one window that already
  has a sheet.
- **Trashed file recreated:** `saveAllTabs` and `displayActiveTab`'s write-back skip the
  trashing guard. A file whose recycle has finished, but whose `itemWasTrashed` hasn't run, can
  be recreated at its old path.
- **Watcher released inside its own callback:** `DirectoryWatcher` can be released from inside
  its own FSEvents callback (`closeProject` and `followProjectMove` called from
  `handleFileEvents`).
- **Truncated file on a full disk:** the non-atomic write (AppModel.swift:901) can leave a
  truncated file when the disk fills mid-write.
- **No crash recovery:** unsaved text is never persisted, so a crash loses it.

## 9. Issues, by impact

Each issue groups fixes that share a cause and should land together. Impact ranks lost or
corrupted user data first, then wrong results the user acts on, then wrong display. A fix is
done when its known-issue tests fail (their bugs are gone), the `withKnownIssue` wrappers are
removed, and the suite passes.

### Issue 1. Unsaved text is dropped when the shown document changes

**Impact:** critical; user text is lost without a prompt. **Bugs:** D1, D2, D3, D4.
**Tests:** `openingAnotherDocumentKeepsTextThatCouldNotBeSaved`, `unreadableBackgroundTabKeepsItsText`,
`undoingBackToTheSavedTextClearsTheSaveError`.

Fix: make leaving a document one transition that every path goes through.

- **`load`:** when `saveNow` leaves the text unsaved, do not replace it. Either refuse the
  load, beep and show the save error, or move the text into the tab's `unsavedText` and open
  the target in a new tab. The rule for every caller: `load` never drops `text != savedText`.
- **`selectTab` and `showActiveTab`:** when a tab holding `unsavedText` can't be displayed,
  route the text through `keepUnsavedElsewhere`, as `itemWasTrashed` already does, instead of
  `close(remember: false)`.
- **`confirmDiscard` callbacks:** capture the tab id and the text the prompt was shown for.
  On answer, act on that tab; if it is no longer the one the prompt describes, do nothing.
  Better still, block tab and navigation commands while a document sheet is up, as
  `performCloseCommand` does.
- **`saveNow`:** clear `saveError` whenever `text == savedText`.

**Fixed.** `showDocument` saves first and, when the text still can't be written, opens the
document in a new tab, so the text stays in its own tab. An unreadable tab that held unsaved
text is closed through `closeUnreadableTab`, which offers to keep the text in another folder.
Discard answers are ignored unless the tab they were asked about is still in the same state
(`askToDiscard` is a test seam). `saveNow` clears `saveError` when the text matches the disk.

### Issue 2. Saving changes a file's encoding

**Impact:** high; silent corruption of non-ASCII text. **Bug:** E1. **Test:** `savingKeepsTheFilesBytes`.

Fix:

- Read and write documents with `TextFile`, which keeps the encoding and byte order mark.
  Store it alongside `savedText`, and use it in `saveNow`, `saveAllTabs` and the unsaved-text
  write-backs.
- Don't fall back to a guessed single-byte encoding for data that is almost UTF-8. Open the
  file read-only, or warn before the first save.

**Fixed.** Documents are read and written with `TextFile`, which keeps the encoding and byte
order mark; `DocumentText.read` uses the same rules. Text that the file's encoding can't hold
makes the save fail with an error, so the text stays unsaved rather than being re-encoded.

### Issue 3. Replace edits a different match than the one the find bar shows

**Impact:** high; silently breaks links. **Bugs:** F1, F2.
**Test:** `replaceInReadModeReplacesTheShownMatch`.

Fix:

- In Read mode, either disable Replace (the page cannot map a rendered match back to the source
  reliably) or switch to Split mode before replacing, so that the count, index and edit all
  refer to source matches.
- Store Whole Word and Regex in `TabFindState` with the query.

**Fixed.** Find and Replace and both Replace buttons switch Preview Only to Split before
replacing, without taking focus from the find bar; the first press only shows the source match.
`TabFindState` stores all search options.

### Issue 4. Link updates are planned for one move and applied to another

**Impact:** high; Update Links writes broken links. **Bugs:** L1, L2, L3, L4.
**Test:** `movingTwoLinkedFilesKeepsTheirLink`.

Fix:

- **One plan per drop:** `moveItems` performs every move first, then makes one
  `LinkUpdater.context` with all of them. `Context` already accepts a list.
- **Check before writing:** when the user answers, verify that every move still holds (the
  source is absent and the destination present) and that no newer plan exists. Otherwise drop
  the prompt or re-plan. A per-project generation counter for moves covers both cases.
- **No second rebase:** make `rewriteOpenText` compare the open text against the plan's
  `before` text and skip documents that already contain the rewrite. Don't apply the edits a
  second time.
- **Complete undo:** record in-memory edits (background tabs and `rewriteOpenText`) in
  `LinkWriteRecord`, so undo reverts them.

**Fixed.** A drop plans one update for all its items. Each plan is registered in
`pendingLinkUpdates` and checked against the disk before the question and after the answer, so
an undone or superseded move updates nothing. A rename that continues a pending one (A to B,
then B to C) replaces it with A to C. `rewriteOpenText` skips text that already has the
rewritten version, or that was edited from it: each document remembers the file version it
was read from (`loadedText`, and `unsavedBase` for other tabs), so a document opened after its
file was rewritten keeps its links even when typed into before the update finishes. Edits to
other tabs' unsaved text are recorded so undo reverts them.

### Issue 5. External edits are overwritten without a check

**Impact:** high; another app's changes are lost. Rarer than issues 1 to 4. **Bug:** D5.

Fix:

- At load and save, record the file's modification date and size. Before each write, compare
  them; when the disk changed and the document is dirty, show a conflict prompt (keep mine,
  take theirs, save a copy) instead of writing.
- On `MustScanSubDirs` or a dropped-events flag for the project root, also run
  `reloadFromDiskIfNeeded` for the open document and refresh the background tabs.

**Fixed.** The open document keeps a `FileStamp` (modification date and size) from its last
read or write. `saveNow` checks it before writing; if another app changed the file, it asks
whether to keep LexMD's edits or use the other version (`askAboutExternalChange`), and writes
nothing until then. A `MustScanSubDirs` event above the open document reloads or asks the same
way. LexMD's own rewrites of the open file (link updates and their undo) are recorded as known
versions through `acceptOwnWrites`.

### Issue 6. Work started for one project finishes in the next

**Impact:** medium to high; it can close the wrong project, offer a commit for a project that
is no longer open, or undo a file operation in a closed project. **Bugs:** P1, P2, P3, N4, N6.
**Test:** `commitIsNotOfferedForThePreviousProject`.

Fix: give each opened project a session token, and make per-project state follow it.

- **In `setRoot`:**
  - call `git.clear()` and dismiss the commit sheet at once, without waiting for the scan;
  - remove the window undo manager's file actions;
  - bump the token.
- **Callbacks check the token:** `closeProjectKeeping`'s finish and the duplicate, trash and
  link-update continuations capture the token and do nothing if it has changed.
- **`open([folder, files])`:** settle once, then open the files in the new project after the
  answer, each in its own tab.

**Fixed.** Opening another project calls `git.projectClosed()` at once, removes the window
undo manager's file actions, and drops pending link updates; `closeProject` does the same.
The deleted-project prompt and `duplicateItem` act only if the same project is still open.
`open([folder, files])` asks once and opens the files in tabs once the project is open.

### Issue 7. Commit results can be lost, and git can switch off for the session

**Impact:** medium; the user believes a commit happened, or loses git until relaunch.
**Bugs:** G1, G2, G3, G4. **Test:** `locatingGitSurvivesACancelledCaller`.

Fix:

- **G1:** locate git outside any cancellable task (a detached task that nothing cancels, started
  once), and never cache a nil result: retry on the next discover.
- **G2, G3:** while committing, disable Cancel, Esc and the repository picker, or let the session
  outlive the sheet. In the second case, keep the commit's result on `GitModel` and show it when
  the sheet reopens. Build the success message from the repository and branch captured when the
  commit started.
- **G4:** `presentCommitSheet` brings an existing session to the front instead of replacing it.

**Fixed.** `Git.system` looks git up on another thread (`Git.outsideAnyTask`), outside the
caller's task, and caches only a git it found. While committing, Cancel and the repository
picker are disabled, the session refuses a repository change, the success message names the
branch captured when the commit started, ⌥⌘K keeps the open session, and a project switch keeps
a committing sheet until it reports.

### Issue 8. Preview results are applied to the wrong document

**Impact:** medium; a wrong clipboard, wrong scroll positions, a wrong find position.
**Bugs:** V1, V2, V3, V4, V5. **Tests:** `copyRichTextCopiesTheShownDocument`,
`headingLinkToAnOpenTabRevealsTheHeading`, `fastTabSwitchKeepsEachTabsPreviewPosition`,
`findIndexSurvivesATabSwitchInReadMode`.

Fix: tag the page with the render it shows.

- **Track renders:** give `PreviewController` a `shownRender` id, set when `flush` sends
  `lexmdRender`, and have the model pass a document id with each render.
- **Copy:** use the live page only when the page shows the current document and the latest
  text; otherwise render offscreen. Give copies a generation, and drop a finished copy when a
  newer copy, or a plain ⌘C, has written to the pasteboard (compare `changeCount`).
- **`readScrollFraction` and the highlight count:** only accept the result when the page shows
  the tab or document they were asked for.
- **`flush`:** when a heading reveal is pending, clear `pendingScrollFraction` instead of applying
  it after the reveal.

**Fixed.** Each render carries its document and a generation; the preview records which one
it shows (`shows(_:generation:)`). Scroll reads and highlight counts are accepted only for the
document they were asked about. Copy as Rich Text uses the live page only when it shows the
latest text, and a copy is dropped if a newer one, or anything else, wrote to the pasteboard
first. A heading reveal wins over the tab's remembered position, and a scroll read that arrives
after its tab closed updates the closed entry.

### Issue 9. Shortcuts can be bound twice or to the wrong command

**Impact:** medium; commands silently lose their shortcut, or run the wrong command.
**Bugs:** K1, K2. **Test:** `storedShortcutsNeverBindOneKeyTwice`.

Fix:

- **On load:** after reading `shortcutOverrides`, resolve collisions. The user's explicit choice
  wins, and the other action's default becomes "none", with a one-time note in Settings.
  Re-check reserved combinations at the same time.
- **Recorder:** move the recording state to `AppModel` (`recordingAction: ShortcutAction?`), so
  starting one recorder stops any other. Install the monitor only for keys sent to the Settings
  window, and return other windows' events unchanged.

**Fixed.** `resolvingShortcutConflicts` runs when overrides load: a chosen shortcut wins,
the command whose default it was gets none (with a note in Settings), and reserved
combinations go back to the default. Recording lives in `AppModel` (`recordingShortcut`), so
one row records at a time, and keys sent to other windows stop the recording and reach their
window.

### Issue 10. The preview does not recover well from WebContent crashes

**Impact:** low to medium; a CPU loop on hostile content, and a lost reading position after any
crash. **Bugs:** V6, V7.

Fix:

- Count crashes like failed loads, with a cap and backoff. Reset the count only after a page
  stays loaded for a while.
- Treat a reload as a new render for scroll and heading restore: capture the scroll fraction
  before reloading and reapply it.
- Reset `templateRetries` at the start of each `loadTemplate`.

**Fixed.** After three crashes within a minute the page stops reloading, and the next render
tries again; a page that ran out of load retries also retries on the next render, with a fresh
budget. The page reports its scroll position, and a reload restores it.

### Issue 11. Quick search can open the wrong place

**Impact:** low. **Bugs:** Q1, Q2, Q3. **Test:** `findInFilesAfterNewTabOpensInPlace`.

Fix:

- Store the matched range, or the query, in each hit, and reveal that instead of re-matching
  with the current query.
- Have `showDocument` report success, and skip `revealOccurrence` when it fails.
- Reset `quickOpensInNewTab` whenever the mode changes.

**Fixed.** Results carry the query and options that found them, and a hit is revealed with
those. A hit whose file didn't open leaves the open document alone. Switching the search mode
resets the New Tab flag.

### Issue 12. Bookkeeping slips in history, tabs, undo and onboarding

**Impact:** low. **Bugs:** N1, N2, N3, N5.

Fix:

- **History (N1):** set `historyIndex` only after the open succeeds. After a trash, recompute the
  index from the shown document instead of clamping it.
- **Tabs (N3):** deduplicate tabs in `remapOpenPaths`, as `followMovedDocuments` already does.
- **Undo (N2):** register an undo for a redone trash and a redone duplicate.
- **Onboarding (N5):** open the demo only on the first move from Welcome to Tour, not on every
  return to Tour.

**Fixed.** `navigateHistory` moves the index only after the document shows; a trash shifts
the index by the entries removed before it. A move that lands on a stale tab's path closes that
tab, offering to keep any unsaved text. Redo of Move to Trash registers its undo again.
Onboarding opens the demo only on the way from Welcome to the tour. Undo Duplicate registers
a Redo that duplicates the original again.

## 10. Checked and sound

These were examined for invalid states and none were found:

- **Tree scan:** results are dropped on a root or generation change.
- **Link index:** builds are dropped on a generation change, and old-root updates are filtered.
- **Model render scheduling:** cancellation is checked after the detached render.
- **Preview page waiters:** each `pageLoaded` continuation resumes exactly once, and superseded
  template navigations are ignored.
- **`PrintCompletion`:** resumes once.
- **`DocumentSchemeHandler`:** task bookkeeping is correct.
- **Concurrent exports:** never share a renderer.
- **Outline fit:** fit depends only on the window frame, and no layout feedback loop remains.
- **Git status refresh:** at most one run at a time; results are dropped after a project change.
- **`ProcessRunner`:** pipes are drained concurrently, so there is no deadlock on a full pipe.
- **Quick search after a project change:** clearing the tree cancels the old search.
- **Launch:** session restore and `application(_:open:)` are safe in either order.
