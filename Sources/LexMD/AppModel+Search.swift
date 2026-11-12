import AppKit
import Foundation

struct QuickPreviewLine: Identifiable, Equatable {
    let id: Int
    let text: String
    let match: NSRange?
}

struct QuickPreviewData: Equatable {
    let name: String
    let folder: String
    let detail: String
    let lines: [QuickPreviewLine]
}

enum QuickItem {
    case file(FileMatch)
    case hit(SearchHit)
}

extension AppModel {
    // MARK: - Find in document

    func showFind() {
        guard currentFile != nil else { NSSound.beep(); return }
        if !isFindBarVisible, let selection = editor.selectedSingleLineText() {
            findQuery = selection
        }
        isFindBarVisible = true
        findFocusToken += 1
        refreshFind(scroll: true)
    }

    func findNext(_ forward: Bool) {
        guard currentFile != nil else { return }
        guard isFindBarVisible else { showFind(); return }
        guard findCount > 0 else { NSSound.beep(); return }
        findIndex = (findIndex + (forward ? 1 : -1) + findCount) % findCount
        refreshFind(scroll: true)
    }

    func closeFindBar() {
        guard isFindBarVisible else { return }
        isFindBarVisible = false
        findCount = 0
        editor.clearFindHighlights()
        preview.setHighlight(nil, scroll: false)
        if viewMode != .read { editor.focus() }
    }

    /// Recomputes matches for the find bar and highlights them in the editor and preview.
    func refreshFind(scroll: Bool) {
        guard isFindBarVisible, currentFile != nil, !findQuery.isEmpty,
              let regex = try? QuickSearchEngine.regex(for: findQuery, options: findOptions) else {
            if findCount != 0 { findCount = 0 }
            editor.clearFindHighlights()
            if isFindBarVisible { preview.setHighlight(nil, scroll: false) }
            return
        }
        transientHighlight = false
        let matches = QuickSearchEngine.matches(of: regex, in: text)
        if viewMode == .read {
            // The rendered page decides the count; see highlightCountChanged.
            editor.setFindHighlights(matches, current: nil)
            preview.setHighlight(.init(query: findQuery, options: findOptions, current: findIndex), scroll: scroll)
            return
        }
        if findCount != matches.count { findCount = matches.count }
        if findIndex >= matches.count { findIndex = max(0, matches.count - 1) }
        let current = matches.isEmpty ? nil : findIndex
        editor.setFindHighlights(matches, current: current)
        if scroll, let current { editor.reveal(matches[current], indicator: true, select: true) }
        preview.setHighlight(
            .init(query: findQuery, options: findOptions, current: current ?? -1),
            scroll: scroll && viewMode == .split
        )
    }

    private var findOptions: SearchOptions {
        var options = SearchOptions()
        options.caseSensitive = findCaseSensitive
        return options
    }

    func highlightCountChanged(_ count: Int) {
        guard isFindBarVisible, viewMode == .read else { return }
        if findCount != count { findCount = count }
        if findIndex >= count, count > 0 { findIndex = count - 1 }
    }

    // MARK: - Find in Files

    var quickItemCount: Int { quickResults.files.count + quickResults.hits.count }

    func quickItem(at index: Int) -> QuickItem? {
        if index < 0 { return nil }
        if index < quickResults.files.count { return .file(quickResults.files[index]) }
        let hitIndex = index - quickResults.files.count
        return hitIndex < quickResults.hits.count ? .hit(quickResults.hits[hitIndex]) : nil
    }

    func toggleQuickSearch(mode: QuickMode = .everything) {
        if isQuickSearchVisible, quickMode == mode {
            quickFocusToken += 1
            return
        }
        guard rootURL != nil else { showOpenPanel(); return }
        if quickMode != mode {
            quickQueries[quickMode] = quickQuery
            quickMode = mode
            quickQuery = quickQueries[mode] ?? ""
        }
        if mode == .everything, let selection = editor.selectedSingleLineText() { quickQuery = selection }
        if mode == .files, !isQuickSearchVisible { quickQuery = "" }
        isQuickSearchVisible = true
        quickFocusToken += 1
        installQuickKeyMonitor()
        scheduleQuickSearch(debounce: false)
    }

    /// New Tab: Open Quickly for files, and the chosen file opens in a new tab.
    func newTab() {
        guard rootURL != nil else { showOpenPanel(); return }
        toggleQuickSearch(mode: .files)
        quickOpensInNewTab = true
    }

    func closeQuickSearch() {
        isQuickSearchVisible = false
        quickOpensInNewTab = false
        quickPendingActivation = nil
        quickTask?.cancel()
        if let monitor = quickKeyMonitor {
            NSEvent.removeMonitor(monitor)
            quickKeyMonitor = nil
        }
    }

    /// While the panel is open, ↑ ↓ ↩ and esc drive it no matter which control has focus.
    private func installQuickKeyMonitor() {
        guard quickKeyMonitor == nil else { return }
        quickKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isQuickSearchVisible else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control])
            if modifiers == .command, event.keyCode == 36 || event.keyCode == 76 {
                self.activateQuickSelection(inNewTab: true)
                return nil
            }
            guard modifiers.isEmpty else { return event }
            switch event.keyCode {
            case 125: self.moveQuickSelection(1)
            case 126: self.moveQuickSelection(-1)
            case 36, 76: self.activateQuickSelection()
            case 53: self.closeQuickSearch()
            default: return event
            }
            return nil
        }
    }

    func moveQuickSelection(_ delta: Int) {
        quickPendingActivation = nil
        let count = quickItemCount
        guard count > 0 else { return }
        setQuickSelection(min(max(quickSelection + delta, 0), count - 1))
    }

    func setQuickSelection(_ index: Int) {
        quickSelection = index
        updateQuickPreview()
    }

    /// Opens the selected result. While results for the typed query are still coming, the
    /// list shows an earlier query's results, so the first new result opens once it arrives.
    func activateQuickSelection(inNewTab: Bool = false) {
        if isQuickSearching {
            quickPendingActivation = inNewTab
            return
        }
        activateQuickItem(at: quickSelection, inNewTab: inNewTab)
    }

    func activateQuickItem(at index: Int, inNewTab: Bool = false) {
        guard let item = quickItem(at: index) else { NSSound.beep(); return }
        let newTab = inNewTab || quickOpensInNewTab || NSEvent.modifierFlags.contains(.command)
        closeQuickSearch()
        switch item {
        case .file(let file):
            reveal(file.path)
            if newTab { openInNewTab(file.path) } else { selectedPath = file.path }
        case .hit(let hit):
            reveal(hit.path)
            if newTab { openInNewTab(hit.path) } else { selectedPath = hit.path }
            revealOccurrence(hit.occurrence)
        }
    }

    /// Selects the n-th match of the current query in the open document and scrolls both panes to it.
    private func revealOccurrence(_ occurrence: Int) {
        guard let regex = try? QuickSearchEngine.regex(for: quickRegexQuery, options: quickOptions) else { return }
        let ranges = QuickSearchEngine.matches(of: regex, in: text)
        guard !ranges.isEmpty else { return }
        let index = min(occurrence, ranges.count - 1)
        editor.reveal(ranges[index], indicator: true, select: true)
        transientHighlight = true
        preview.setHighlight(.init(query: quickRegexQuery, options: quickOptions, current: index), scroll: true)
    }

    private var quickRegexQuery: String {
        quickOptions.regex ? quickQuery : quickQuery.trimmingCharacters(in: .whitespaces)
    }

    func scheduleQuickSearch(debounce: Bool = true) {
        quickTask?.cancel()
        guard isQuickSearchVisible || !debounce else { return }
        let query = quickQuery
        guard let root = rootURL?.path else { return }
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            var empty = QuickSearchResults()
            if quickMode == .files { empty.files = recentFileMatches(root: root) }
            quickResults = empty
            isQuickSearching = false
            quickPendingActivation = nil
            setQuickSelection(0)
            return
        }
        let filesOnly = quickMode == .files
        let options = quickOptions
        // Listing the tree's files takes a while in large projects, so it happens off the
        // main thread once per tree.
        let cachedFiles = searchFiles
        let tree = self.tree
        let generation = treeGeneration
        let currentPath = currentFile?.path
        let overrides = currentPath.map { [$0: text] } ?? [:]
        isQuickSearching = true
        quickTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(nanoseconds: 110_000_000)
                guard !Task.isCancelled else { return }
            }
            let (files, results) = await runDetached { () -> ([SearchableFile], QuickSearchResults) in
                let files = cachedFiles ?? FileScanner.searchableFiles(in: tree, root: root)
                return (files, QuickSearchEngine.run(
                    query: query, options: options, files: files, overrides: overrides,
                    currentPath: currentPath, filesOnly: filesOnly
                ))
            }
            guard let self else { return }
            if cachedFiles == nil, self.treeGeneration == generation { self.searchFiles = files }
            guard !Task.isCancelled else { return }
            self.quickResults = results
            self.isQuickSearching = false
            self.setQuickSelection(0)
            if let inNewTab = self.quickPendingActivation {
                self.quickPendingActivation = nil
                self.activateQuickItem(at: 0, inNewTab: inNewTab)
            }
        }
    }

    /// Recently opened files in this folder, most recent first (excluding the open one).
    private func recentFileMatches(root: String) -> [FileMatch] {
        let current = currentFile?.path
        return recentFiles
            .filter { $0 != current && $0.hasPrefix(root + "/") && FileManager.default.fileExists(atPath: $0) }
            .prefix(12)
            .map { path in
                let dir = (path as NSString).deletingLastPathComponent
                let folder = String(dir.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                return FileMatch(path: path, name: name, folder: folder, score: 0, matched: [])
            }
    }

    /// The open document's live text, or the file's (cached) contents.
    private func previewText(_ path: String) -> String {
        path == currentFile?.path ? text : QuickSearchEngine.read(path) ?? ""
    }

    private func updateQuickPreview() {
        guard isQuickSearchVisible, let item = quickItem(at: quickSelection) else {
            if quickPreview != nil { quickPreview = nil }
            return
        }
        switch item {
        case .file(let file):
            let text = previewText(file.path)
            let lines = Self.lines(of: text, count: 10).enumerated().map {
                QuickPreviewLine(id: $0.offset + 1, text: String($0.element.prefix(300)), match: nil)
            }
            quickPreview = QuickPreviewData(name: file.name, folder: file.folder, detail: "File", lines: lines)
        case .hit(let hit):
            let text = previewText(hit.path)
            let center = hit.line - 1
            let all = Self.lines(of: text, count: center + 6)
            let lower = max(0, center - 4), upper = min(all.count - 1, center + 5)
            var lines: [QuickPreviewLine] = []
            if lower <= upper {
                for i in lower...upper {
                    var line = all[i]
                    if line.hasSuffix("\r") { line.removeLast() }
                    let isMatch = i == center
                    lines.append(QuickPreviewLine(
                        id: i + 1,
                        text: isMatch ? hit.lineText : String(line.prefix(300)),
                        match: isMatch ? hit.lineMatch : nil
                    ))
                }
            }
            let name = (hit.name as NSString).deletingPathExtension
            quickPreview = QuickPreviewData(name: name, folder: hit.folder, detail: "Line \(hit.line)", lines: lines)
        }
    }

    /// The first `count` lines of `text`, split at line feeds like `components(separatedBy:)`,
    /// without splitting the rest of a long document on every selection change.
    nonisolated static func lines(of text: String, count: Int) -> [String] {
        guard count > 0 else { return [] }
        return text.utf8.split(separator: UInt8(ascii: "\n"), maxSplits: count, omittingEmptySubsequences: false)
            .prefix(count)
            .map { String(Substring($0)) }
    }
}
