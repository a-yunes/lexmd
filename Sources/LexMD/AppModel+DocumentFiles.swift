import AppKit

/// What to do with text that could not be saved before quitting or opening another project.
enum UnsavedTextChoice {
    case saveToFolder(URL)
    case discard
    case cancel
}

/// Open documents whose files other apps move or delete, and text that cannot be saved.
extension AppModel {
    // MARK: Files moved or deleted by other apps

    /// Remembers a tab's file by identity, so a rename or move by another app can be followed.
    func rememberFile(of id: UUID) {
        guard let path = tabStore.list.tab(id)?.path,
              let bookmark = try? URL(fileURLWithPath: path).bookmarkData() else { return }
        tabStore.references[id] = bookmark
    }

    /// True when a file event concerns an open document or a folder holding one.
    func eventsTouchOpenDocuments(_ events: [DirectoryWatcher.Event]) -> Bool {
        var paths = tabStore.list.tabs.map(\.path)
        if let current = currentFile?.path { paths.append(current) }
        return events.contains { event in
            paths.contains { $0 == event.path || $0.hasPrefix(event.path + "/") }
        }
    }

    /// Follows open documents that another app renamed or moved within the project, so autosave
    /// writes to their new place. A document whose file is gone keeps its text and is marked.
    func followMovedDocuments() {
        let root = rootURL?.path
        for tab in tabStore.list.tabs {
            guard !FileManager.default.fileExists(atPath: tab.path) else {
                // Another app may have replaced the file: remember the one there now.
                rememberFile(of: tab.id)
                continue
            }
            var stale = false
            guard let root, let bookmark = tabStore.references[tab.id],
                  let found = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                       relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            let moved = FileScanner.canonicalPath(found.path)
            // A move out of the project, as to the Trash, counts as a deletion.
            guard moved != tab.path, moved.hasPrefix(root + "/"), !FileScanner.isIgnored(moved, root: root),
                  FileManager.default.fileExists(atPath: moved), tabStore.list.tab(withPath: moved) == nil else { continue }
            applyMove(PathMove(from: tab.path, to: moved))
        }
        updateMissingDocuments()
    }

    /// Marks the tabs whose files are no longer on disk.
    func updateMissingDocuments() {
        var missing = Set<UUID>()
        for tab in tabStore.list.tabs where !FileManager.default.fileExists(atPath: tab.path) { missing.insert(tab.id) }
        if tabStore.missing != missing { tabStore.missing = missing }
    }

    /// The open document's file is no longer on disk.
    var isCurrentDocumentMissing: Bool {
        guard currentFile != nil, let id = tabStore.list.activeID else { return false }
        return tabStore.missing.contains(id)
    }

    // MARK: Text that cannot be saved

    /// Before quitting or opening another project: writes what can be written, then asks about
    /// text that still cannot be, so it is never dropped silently. `completion` gets whether to go on.
    func settleUnsavedText(before action: String, completion: @escaping (Bool) -> Void) {
        saveAllTabs()
        let documents = unsavedDocuments()
        guard !documents.isEmpty else { completion(true); return }
        Self.askAboutUnsavedText(documents, action) { [weak self] choice in
            guard let self else { completion(false); return }
            switch choice {
            case .cancel:
                completion(false)
            case .discard:
                self.discardUnsavedText()
                completion(true)
            case .saveToFolder(let folder):
                do {
                    for document in documents {
                        let file = (document.path as NSString).lastPathComponent as NSString
                        let target = FileOperations.uniqueURL(in: folder, base: file.deletingPathExtension, extension: file.pathExtension)
                        try document.text.write(to: target, atomically: true, encoding: .utf8)
                    }
                    self.discardUnsavedText()
                    completion(true)
                } catch {
                    self.present(NSAlert(error: error)) { _ in completion(false) }
                }
            }
        }
    }

    /// Forgets text that could not be saved, after it was kept elsewhere or the user discarded it.
    func discardUnsavedText() {
        savedText = text
        saveError = nil
        for tab in tabStore.list.tabs where tab.state.unsavedText != nil {
            tabStore.list.update(tab.id) { $0.state.unsavedText = nil }
        }
    }

    /// Asks what to do with unsaved text. Replaced in tests.
    static var askAboutUnsavedText: (
        _ documents: [(path: String, text: String)], _ action: String, _ reply: @escaping (UnsavedTextChoice) -> Void
    ) -> Void = { documents, action, reply in
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = documents.count == 1
            ? "Changes to “\((documents[0].path as NSString).lastPathComponent)” couldn’t be saved."
            : "Changes to \(documents.count) documents couldn’t be saved."
        alert.informativeText = "Save them in another folder to keep them, or discard them to \(action)."
        alert.addButton(withTitle: "Save to Folder…")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        AppModel.shared.present(alert) { response in
            switch response {
            case .alertFirstButtonReturn:
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.canCreateDirectories = true
                panel.prompt = "Save"
                panel.message = "Choose a folder for the unsaved documents."
                reply(panel.runModal() == .OK ? panel.url.map(UnsavedTextChoice.saveToFolder) ?? .cancel : .cancel)
            case .alertSecondButtonReturn:
                reply(.discard)
            default:
                reply(.cancel)
            }
        }
    }
}
