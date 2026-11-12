import AppKit

/// Document tabs. One editor and one preview are shared; switching tabs saves the outgoing
/// document, then loads the incoming one and restores its view state.
extension AppModel {
    var showsTabBar: Bool {
        let count = tabStore.list.count
        return rootURL != nil && (count > 1 || (count == 1 && tabStore.alwaysShowTabBar))
    }

    var canReopenClosedTab: Bool { !tabStore.list.closed.isEmpty }

    /// Unsaved changes that could not be written, shown as a dot on the tab.
    func tabHasUnsavedChanges(_ id: UUID) -> Bool {
        if id == tabStore.list.activeID { return saveError != nil }
        return tabStore.list.tab(id)?.state.unsavedText != nil
    }

    // MARK: Hooks called by AppModel

    /// After `load`: the active tab now shows this document.
    func tabDidLoad(_ url: URL) {
        tabStore.list.replaceActive(with: url.path)
        persistTabs()
    }

    /// Lets a selection open in a new tab (Command-click) or switch to the tab that already
    /// shows it. Returns true when handled here.
    func routeSelectionToTabs(_ path: String) -> Bool {
        if currentFile != nil, Self.isCommandClick(NSApp.currentEvent) {
            openInNewTab(path)
            return true
        }
        if !isNavigatingHistory, let existing = tabStore.list.tab(withPath: path), existing.id != tabStore.list.activeID {
            selectTab(existing.id)
            return true
        }
        return false
    }

    static func isCommandClick(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .leftMouseDown || event.type == .leftMouseUp else { return false }
        return event.modifierFlags.contains(.command)
    }

    /// Tabs belong to a project; opening another one closes them (they are restored next time).
    func closeTabsForProjectChange() {
        sidebarFiles.renamingPath = nil
        sidebarFiles.newFolders = []
        guard !tabStore.list.isEmpty || currentFile != nil else { return }
        tabStore.list.removeAll()
        closeDocument()
    }

    /// Reopens the tabs saved for the current project. Returns true when a document opened.
    @discardableResult
    func restoreTabs() -> Bool {
        guard let root = rootURL?.path, tabStore.list.isEmpty,
              let entry = defaults.dictionary(forKey: Keys.openTabs)?[root] as? [String: Any],
              let paths = entry["paths"] as? [String] else { return false }
        let restored = TabList.restorable(
            paths: paths, active: entry["active"] as? Int ?? 0, root: root,
            exists: { FileManager.default.fileExists(atPath: $0) }
        )
        guard !restored.paths.isEmpty else { return false }
        var list = TabList()
        for path in restored.paths { list.insert(DocumentTab(path: path), at: list.count) }
        list.activate(list.tabs[restored.active].id)
        tabStore.list = list
        showActiveTab()
        return currentFile != nil
    }

    func persistTabs() {
        guard let root = rootURL?.path else { return }
        var all = defaults.dictionary(forKey: Keys.openTabs) ?? [:]
        let list = tabStore.list
        if list.isEmpty {
            all.removeValue(forKey: root)
        } else {
            all[root] = ["paths": list.tabs.map(\.path), "active": list.activeIndex ?? 0]
        }
        let known = Set(recentFolders).union([root])
        all = all.filter { known.contains($0.key) }
        defaults.set(all, forKey: Keys.openTabs)
    }

    // MARK: Commands

    /// Opens a project document in the active tab (or the tab already showing it), or in a new tab.
    func openPath(_ path: String, inNewTab: Bool) {
        if inNewTab, currentFile != nil, rootURL.map({ path.hasPrefix($0.path + "/") }) == true {
            reveal(path)
            openInNewTab(path)
        } else {
            open(URL(fileURLWithPath: path))
        }
    }

    /// Saves the active document and writes text that other tabs could not save before.
    func saveAllTabs() {
        saveNow()
        for tab in tabStore.list.tabs where tab.id != tabStore.list.activeID {
            guard let unsaved = tab.state.unsavedText else { continue }
            do {
                try unsaved.write(toFile: tab.path, atomically: false, encoding: .utf8)
                tabStore.list.update(tab.id) { $0.state.unsavedText = nil }
            } catch {
                continue
            }
        }
    }

    func openInNewTab(_ path: String) {
        guard currentFile != nil, tabStore.list.activeID != nil else {
            reveal(path)
            selectedPath = path
            return
        }
        guard path != currentFile?.path else { return }
        if let existing = tabStore.list.tab(withPath: path) {
            selectTab(existing.id)
            return
        }
        let previous = tabStore.list.activeID
        let savedHistory = (history, historyIndex)
        leaveActiveTab()
        let tab = tabStore.list.open(path)
        history = []
        historyIndex = -1
        if isFindBarVisible { hideFindBarQuietly() }
        load(URL(fileURLWithPath: path))
        guard currentFile?.path == path else {
            tabStore.list.close(tab.id, remember: false)
            if let previous { tabStore.list.activate(previous) }
            (history, historyIndex) = savedHistory
            persistTabs()
            return
        }
        reveal(path)
        selectedPath = path
    }

    func selectTab(_ id: UUID) {
        guard id != tabStore.list.activeID, tabStore.list.tab(id) != nil else { return }
        let previous = tabStore.list.activeID
        let savedHistory = (history, historyIndex)
        if currentFile != nil { leaveActiveTab() }
        tabStore.list.activate(id)
        guard !displayActiveTab() else { return }
        // The file is gone or unreadable: drop its tab and stay on the previous one.
        NSSound.beep()
        tabStore.list.close(id, remember: false)
        if let previous, let tab = tabStore.list.tab(previous), tab.path == currentFile?.path {
            tabStore.list.activate(previous)
            (history, historyIndex) = savedHistory
            selectedPath = tab.path
            persistTabs()
        } else {
            showActiveTab()
        }
    }

    /// Close Tab: closes the active tab, or the window when no document is open (or another
    /// window, such as Settings, is in front).
    func performCloseCommand() {
        let mainWindow = editor.scrollView.window
        if let key = NSApp.keyWindow, key.sheetParent != nil || (key === mainWindow && key.attachedSheet != nil) {
            // A sheet (such as Commit) is in front; it closes with its own buttons.
            NSSound.beep()
        } else if let key = NSApp.keyWindow, key !== mainWindow {
            key.performClose(nil)
        } else if currentFile != nil, let id = tabStore.list.activeID {
            closeTab(id)
        } else {
            (NSApp.keyWindow ?? mainWindow)?.performClose(nil)
        }
    }

    func closeTab(_ id: UUID) {
        guard let tab = tabStore.list.tab(id) else { return }
        if id == tabStore.list.activeID {
            saveNow()
            guard text == savedText else {
                confirmDiscard(tab.title) { [weak self] in
                    guard let self else { return }
                    self.savedText = self.text
                    self.saveError = nil
                    self.finishClosingActiveTab(id)
                }
                return
            }
            finishClosingActiveTab(id)
        } else if tab.state.unsavedText != nil {
            confirmDiscard(tab.title) { [weak self] in
                self?.tabStore.list.update(id) { $0.state.unsavedText = nil }
                self?.tabStore.list.close(id)
                self?.persistTabs()
            }
        } else {
            tabStore.list.close(id)
            persistTabs()
        }
    }

    func closeOtherTabs(_ id: UUID) {
        if id != tabStore.list.activeID { selectTab(id) }
        guard id == tabStore.list.activeID else { return }
        for tab in tabStore.list.tabs where tab.id != id && tab.state.unsavedText == nil {
            tabStore.list.close(tab.id)
        }
        persistTabs()
    }

    func showNextTab() { showNeighborTab(1) }
    func showPreviousTab() { showNeighborTab(-1) }

    private func showNeighborTab(_ offset: Int) {
        guard let id = tabStore.list.neighbor(offset) else { NSSound.beep(); return }
        selectTab(id)
    }

    func reopenClosedTab() {
        guard let closed = tabStore.list.popClosed(exists: { FileManager.default.fileExists(atPath: $0) }) else {
            NSSound.beep()
            return
        }
        if let existing = tabStore.list.tab(withPath: closed.tab.path) {
            selectTab(existing.id)
            return
        }
        if currentFile != nil { leaveActiveTab() }
        tabStore.list.insert(closed.tab, at: closed.index)
        showActiveTab()
    }

    func moveTab(_ id: UUID, to index: Int) {
        tabStore.list.move(id, to: index)
        persistTabs()
    }

    // MARK: Switching

    /// Saves the active document and remembers its view state.
    func leaveActiveTab() {
        guard let id = tabStore.list.activeID else { return }
        saveNow()
        let previousFraction = tabStore.list.tab(id)?.state.previewFraction
        var state = TabViewState()
        state.selection = editor.textView.selectedRange()
        state.editorOrigin = editor.scrollView.contentView.bounds.origin
        state.previewFraction = previousFraction
        state.history = history
        state.historyIndex = historyIndex
        state.find = isFindBarVisible ? TabFindState(query: findQuery, caseSensitive: findCaseSensitive, index: findIndex) : nil
        state.unsavedText = text != savedText ? text : nil
        tabStore.list.update(id) { $0.state = state }
        // The script runs before the next document renders, so this reads the outgoing page.
        preview.readScrollFraction { [weak self] fraction in
            self?.tabStore.list.update(id) { $0.state.previewFraction = fraction }
        }
    }

    /// Shows the active tab; tabs whose files can't be read are closed and the next is tried.
    func showActiveTab() {
        while let id = tabStore.list.activeID {
            if displayActiveTab() { return }
            NSSound.beep()
            tabStore.list.close(id, remember: false)
        }
        closeDocument()
        persistTabs()
    }

    /// Loads the active tab's document and restores its view state.
    private func displayActiveTab() -> Bool {
        guard let target = tabStore.list.active else { return false }
        if let unsaved = target.state.unsavedText, !FileManager.default.fileExists(atPath: target.path) {
            // Keep text that never reached the disk by writing it back where it belongs.
            try? unsaved.write(toFile: target.path, atomically: false, encoding: .utf8)
        }
        let saved = target.state
        history = saved.history.isEmpty ? [target.path] : saved.history
        historyIndex = saved.history.isEmpty ? 0 : min(max(saved.historyIndex, 0), history.count - 1)
        isNavigatingHistory = true
        load(URL(fileURLWithPath: target.path))
        isNavigatingHistory = false
        guard currentFile?.path == target.path else { return false }
        restoreViewState(saved)
        tabStore.list.update(target.id) { $0.state.unsavedText = nil }
        reveal(target.path)
        selectedPath = target.path
        persistTabs()
        return true
    }

    private func restoreViewState(_ state: TabViewState) {
        if let unsaved = state.unsavedText, unsaved != text {
            editor.replaceText(unsaved)
            editor.onTextChange?(unsaved)
        }
        if let find = state.find {
            findCaseSensitive = find.caseSensitive
            findQuery = find.query
            isFindBarVisible = true
            findIndex = find.index
            refreshFind(scroll: false)
        } else if isFindBarVisible {
            hideFindBarQuietly()
        }
        editor.restore(selection: state.selection, origin: state.editorOrigin)
        preview.pendingScrollFraction = state.previewFraction
    }

    /// Hides the find bar without moving focus.
    private func hideFindBarQuietly() {
        isFindBarVisible = false
        findCount = 0
        editor.clearFindHighlights()
        preview.setHighlight(nil, scroll: false)
    }

    private func finishClosingActiveTab(_ id: UUID) {
        leaveActiveTab()
        tabStore.list.close(id)
        if tabStore.list.activeID != nil {
            showActiveTab()
        } else {
            closeDocument()
            persistTabs()
        }
    }

    private func confirmDiscard(_ title: String, discard: @escaping () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(title)” has changes that couldn’t be saved."
        alert.informativeText = "If you close it, those changes are lost."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Close Anyway")
        present(alert) { response in
            if response == .alertSecondButtonReturn { discard() }
        }
    }

    /// Clears the editor and preview when the last tab closes.
    func closeDocument() {
        saveNow()
        if let window = editor.textView.window, window.firstResponder === editor.textView {
            window.makeFirstResponder(nil)
        }
        currentFile = nil
        text = ""
        savedText = ""
        saveError = nil
        editor.load("")
        if isFindBarVisible { hideFindBarQuietly() }
        history = []
        historyIndex = -1
        render(debounce: false)
        selectedPath = nil
        defaults.removeObject(forKey: Keys.lastFile)
    }
}

extension EditorController {
    /// Puts back a remembered caret, selection, and scroll position.
    func restore(selection: NSRange, origin: CGPoint?) {
        let length = (textView.string as NSString).length
        let location = min(selection.location, length)
        textView.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        let clip = scrollView.contentView
        guard let origin else { return }
        if origin.y > clip.bounds.height, let layout = textView.textLayoutManager {
            layout.ensureLayout(for: layout.documentRange)
        }
        let target = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        clip.scroll(to: target)
        scrollView.reflectScrolledClipView(clip)
    }

    /// Replaces ranges as one undoable change, so Edit > Undo reverts them together.
    @discardableResult
    func applyEdits(_ edits: [TextEdit], actionName: String) -> Bool {
        guard !edits.isEmpty else { return false }
        textView.breakUndoCoalescing()
        var applied = false
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            guard NSMaxRange(edit.range) <= (textView.string as NSString).length,
                  textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { continue }
            textView.textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
            textView.didChangeText()
            applied = true
        }
        if applied { textView.undoManager?.setActionName(actionName) }
        textView.breakUndoCoalescing()
        return applied
    }
}
