import AppKit
import OSLog

/// Document tabs. One editor and one preview are shared; switching tabs saves the outgoing
/// document, then loads the incoming one and restores its view state.
extension AppModel {
    static let tabLog = Logger(subsystem: "io.github.a-yunes.lexmd", category: "tabs")

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
        if let id = tabStore.list.activeID {
            rememberFile(of: id)
            if tabStore.missing.contains(id) { tabStore.missing.remove(id) }
        }
        persistTabs()
    }

    /// Shows a document: the one way to open a document in the window. `selectedPath` follows
    /// it in the sidebar. A failed load leaves the open document (and its highlight) in place.
    func showDocument(_ path: String, placement: DocumentPlacement = .reuseTab, recordsHistory: Bool = true) {
        if path != currentFile?.path {
            if placement == .reuseTab, let existing = tabStore.list.tab(withPath: path), existing.id != tabStore.list.activeID {
                selectTab(existing.id)
                return
            }
            saveNow()
            if currentFile != nil, text != savedText {
                // The open text couldn't be written: it stays in its tab, and the document opens
                // in a new one, so loading in place never replaces text that isn't on disk.
                guard tabStore.list.activeID != nil else { NSSound.beep(); return }
                openInNewTab(path)
                return
            }
            load(URL(fileURLWithPath: path), recordsHistory: recordsHistory)
        }
        selectedPath = currentFile?.path
    }

    /// The sidebar's selection changed, from a click or the arrow keys. Command-click opens the
    /// row in a new tab, and a secondary click leaves the open document alone while the row's
    /// menu shows. The list reports no event, so the event being handled says which click it was.
    func sidebarSelected(_ path: String?) {
        guard let path, path != currentFile?.path else {
            // Keep the open document highlighted when the list clears its selection.
            selectedPath = currentFile?.path
            return
        }
        let event = Self.currentEvent()
        if Self.isContextClick(event) {
            // Opening the row here would replace the document in the active tab before a
            // command such as Open in New Tab runs.
            selectedPath = currentFile?.path
            return
        }
        if currentFile != nil, Self.isCommandClick(event) {
            openInNewTab(path)
            return
        }
        showDocument(path)
    }

    static func isCommandClick(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .leftMouseDown || event.type == .leftMouseUp else { return false }
        return event.modifierFlags.contains(.command)
    }

    /// A right click or Control-click, which shows a context menu.
    static func isContextClick(_ event: NSEvent?) -> Bool {
        switch event?.type {
        case .rightMouseDown?, .rightMouseUp?: true
        case .leftMouseDown?, .leftMouseUp?: event?.modifierFlags.contains(.control) == true
        default: false
        }
    }

    /// The event being handled when the sidebar selection changes. Replaced in tests.
    static var currentEvent: () -> NSEvent? = { NSApp.currentEvent }

    /// Tabs belong to a project; opening another one closes them (they are restored next time).
    func closeTabsForProjectChange() {
        sidebarFiles.renamingPath = nil
        sidebarFiles.newFolders = []
        guard !tabStore.list.isEmpty || currentFile != nil else { return }
        // Other tabs may hold text that could not be saved before; try once more before they close.
        saveAllTabs()
        tabStore.list.removeAll()
        tabStore.references = [:]
        tabStore.missing = []
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
        for tab in list.tabs { rememberFile(of: tab.id) }
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
                try TextFile.writeKeepingFormat(unsaved, toPath: tab.path)
                tabStore.list.update(tab.id) { $0.state.unsavedText = nil }
            } catch {
                continue
            }
        }
    }

    func openInNewTab(_ path: String) {
        Self.tabLog.notice("Open in new tab: \(path, privacy: .private)")
        guard currentFile != nil, tabStore.list.activeID != nil else {
            Self.tabLog.notice("No active tab; opening in place")
            reveal(path)
            showDocument(path, placement: .active)
            return
        }
        guard path != currentFile?.path else {
            Self.tabLog.notice("Already showing this document")
            return
        }
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
            Self.tabLog.error("The new tab's document did not load")
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
        closeUnreadableTab(id)
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
        } else if let key = NSApp.keyWindow, let mainWindow, key !== mainWindow {
            key.performClose(nil)
        } else if currentFile != nil, let id = tabStore.list.activeID {
            closeTab(id)
        } else if let window = NSApp.keyWindow ?? mainWindow, Self.otherWindowsRemainOpen(besides: window, in: NSApp.windows) {
            window.performClose(nil)
        }
        // Otherwise the window is the last one, and closing it would quit LexMD; Close Window
        // remains for that.
    }

    func closeTab(_ id: UUID) {
        guard let tab = tabStore.list.tab(id) else { return }
        if id == tabStore.list.activeID {
            saveNow()
            guard text == savedText else {
                let shown = text
                confirmDiscard(tab.title) { [weak self] in
                    // The answer applies to the text the question was about. If another tab
                    // was brought forward meanwhile, nothing is discarded.
                    guard let self, self.tabStore.list.activeID == id, self.text == shown else { NSSound.beep(); return }
                    self.savedText = self.text
                    self.saveError = nil
                    self.finishClosingActiveTab(id)
                }
                return
            }
            finishClosingActiveTab(id)
        } else if tab.state.unsavedText != nil {
            confirmDiscard(tab.title) { [weak self] in
                guard let self, self.tabStore.list.activeID != id, self.tabStore.list.tab(id) != nil else { NSSound.beep(); return }
                self.tabStore.list.update(id) { $0.state.unsavedText = nil }
                self.tabStore.list.close(id)
                self.persistTabs()
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
        state.find = isFindBarVisible ? TabFindState(query: findQuery, options: findOptions, index: findIndex) : nil
        state.unsavedText = text != savedText ? text : nil
        state.unsavedBase = state.unsavedText == nil ? nil : loadedText
        tabStore.list.update(id) { $0.state = state }
        // Read only while the page still shows this tab's document: after a quick switch the
        // page may show another tab's, whose position would be saved here.
        guard let path = currentFile?.path else { return }
        preview.readScrollFraction(of: path) { [weak self] fraction in
            self?.tabStore.list.updateOpenOrClosed(id) { $0.state.previewFraction = fraction }
        }
    }

    /// Shows the active tab; tabs whose files can't be read are closed and the next is tried.
    func showActiveTab() {
        while let id = tabStore.list.activeID {
            if displayActiveTab() { return }
            NSSound.beep()
            closeUnreadableTab(id)
        }
        closeDocument()
        persistTabs()
    }

    /// Closes a tab whose file can't be read. Text it held that never reached the disk is
    /// offered to be kept in another folder rather than dropped with the tab.
    private func closeUnreadableTab(_ id: UUID) {
        let tab = tabStore.list.tab(id)
        tabStore.list.close(id, remember: false)
        guard let tab, let unsaved = tab.state.unsavedText else { return }
        let documents = [(path: tab.path, text: unsaved)]
        Self.keepUnsavedElsewhere(documents, { Self.unreadableDocumentAlert(documents: documents) }) {}
    }

    /// A tab's file can no longer be read, and its unsaved text couldn't be written back.
    static func unreadableDocumentAlert(documents: [(path: String, text: String)]) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\((documents[0].path as NSString).lastPathComponent)” is no longer available"
        alert.informativeText = "Its changes couldn’t be saved because the file can’t be read or written. Save them in another folder to keep them."
        alert.addButton(withTitle: "Save to Folder…")
        alert.addDestructiveButton("Discard Changes")
        return alert
    }

    /// Loads the active tab's document and restores its view state.
    private func displayActiveTab() -> Bool {
        guard let target = tabStore.list.active else { return false }
        if let unsaved = target.state.unsavedText, !FileManager.default.fileExists(atPath: target.path) {
            // Keep text that never reached the disk by writing it back where it belongs.
            try? TextFile.writeKeepingFormat(unsaved, toPath: target.path)
        }
        let saved = target.state
        history = saved.history.isEmpty ? [target.path] : saved.history
        historyIndex = saved.history.isEmpty ? 0 : min(max(saved.historyIndex, 0), history.count - 1)
        load(URL(fileURLWithPath: target.path), recordsHistory: false)
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
            if let base = state.unsavedBase { loadedText = base }
        }
        if let find = state.find {
            findCaseSensitive = find.options.caseSensitive
            findWholeWord = find.options.wholeWord
            findUsesRegex = find.options.regex
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
        Self.askToDiscard(title, discard)
    }

    /// Asks whether to discard a tab's unsaved changes, running `discard` on yes. Replaced in tests.
    static var askToDiscard: (_ title: String, _ discard: @escaping () -> Void) -> Void = { title, discard in
        AppModel.shared.present(AppModel.discardConfirmation(title)) { response in
            if response == .alertFirstButtonReturn { discard() }
        }
    }

    /// Closing a tab whose text couldn't be saved. Discard Changes closes it; Cancel keeps it.
    static func discardConfirmation(_ title: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Changes to “\(title)” couldn’t be saved"
        alert.informativeText = "If you close the tab now, the changes are lost."
        alert.addDestructiveButton("Discard Changes")
        alert.addCancelButton()
        return alert
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

/// Where `showDocument(_:placement:recordsHistory:)` puts a document.
enum DocumentPlacement {
    /// Switch to the tab that already shows it, or load it in the active tab.
    case reuseTab
    /// Load it in the active tab even when another tab shows it, as Back and Forward do.
    case active
}
