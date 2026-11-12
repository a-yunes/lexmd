import AppKit
import Observation

/// Sidebar state for file commands.
@MainActor
@Observable
final class SidebarFileState {
    /// The item showing an inline name field.
    var renamingPath: String?
    /// The item being renamed was just created as a new document.
    var renameIsNewDocument = false
    /// Empty folders created here, shown until they hold documents; the scanner skips empty folders.
    var newFolders: Set<String> = []
    /// Moves items to the Trash. Replaced in tests.
    @ObservationIgnored var recycler: FileOperations.Recycler = FileOperations.systemRecycler
    /// Items on their way to the Trash; autosave must not recreate documents inside them.
    @ObservationIgnored var trashing: Set<String> = []

    func isTrashing(_ path: String) -> Bool {
        trashing.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}

/// Unsaved file contents written by a link update, filled in once the background write ends.
@MainActor
final class LinkWriteRecord {
    var files: [RewrittenFile] = []
    var task: Task<Void, Never>?
    /// The open document's text around its part of the update, which the editor can undo.
    var openDocument: RewrittenFile?
}

extension AppModel {
    /// The window's undo manager. The editor keeps text undo in its own manager, which document
    /// loads clear, so file operations register on the responders around it instead.
    var fileUndoManager: UndoManager? { editor.scrollView.undoManager ?? NSApp.mainWindow?.undoManager }

    /// Refreshes backlinks, link checks, and git badges right after a file operation, without
    /// waiting for file system events. `changed` lists files whose contents changed in place.
    func filesDidChange(structure: Bool, changed: [String] = []) {
        if structure { outline.index.refresh() } else if !changed.isEmpty { outline.index.update(paths: changed) }
        git.scheduleStatus(after: 0.1)
    }

    func treeWithNewFolders(_ nodes: [FileNode]) -> [FileNode] {
        guard let root = rootURL?.path, !sidebarFiles.newFolders.isEmpty else { return nodes }
        let existing = sidebarFiles.newFolders.filter {
            var isDirectory: ObjCBool = false
            return $0.hasPrefix(root + "/") && FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        return FileTreeEdit.addingFolders(existing, to: nodes, root: root)
    }

    /// Where a new item goes: inside a clicked folder, next to a clicked file, or at the top.
    func folder(for url: URL?) -> URL? {
        guard let root = rootURL else { return nil }
        guard let url, url.path.hasPrefix(root.path + "/") else { return root }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return root }
        return isDirectory.boolValue ? url : url.deletingLastPathComponent()
    }

    func ensureSidebarVisible() {
        if sidebarPosition == .right {
            if !isInspectorPresented { isInspectorPresented = true }
        } else if columnVisibility == .detailOnly {
            columnVisibility = .all
        }
    }

    // MARK: New items

    func newFile(near url: URL?) {
        guard let folder = folder(for: url) else { showOpenPanel(); return }
        do {
            let file = try FileOperations.createFile(in: folder)
            if let root = rootURL?.path {
                tree = FileTreeEdit.inserting(FileNode(url: file, name: file.lastPathComponent, children: nil),
                                              into: tree, parent: folder.path, root: root)
            }
            ensureSidebarVisible()
            reveal(file.path)
            selectedPath = file.path
            sidebarFiles.renameIsNewDocument = true
            sidebarFiles.renamingPath = file.path
            rescanSoon()
            filesDidChange(structure: true)
        } catch {
            showFileProblem("Couldn’t create a document.", error)
        }
    }

    func newFolder(near url: URL?) {
        guard let parent = folder(for: url) else { showOpenPanel(); return }
        do {
            let created = try FileOperations.createFolder(in: parent)
            sidebarFiles.newFolders.insert(created.path)
            updateDisplayTree()
            ensureSidebarVisible()
            reveal(created.path)
            sidebarFiles.renameIsNewDocument = false
            sidebarFiles.renamingPath = created.path
        } catch {
            showFileProblem("Couldn’t create a folder.", error)
        }
    }

    // MARK: Rename

    func beginRename(_ url: URL) {
        ensureSidebarVisible()
        reveal(url.path)
        sidebarFiles.renameIsNewDocument = false
        sidebarFiles.renamingPath = url.path
    }

    func cancelRename() {
        let wasNew = sidebarFiles.renameIsNewDocument
        sidebarFiles.renamingPath = nil
        sidebarFiles.renameIsNewDocument = false
        if wasNew { startWritingNewDocument() }
    }

    func commitRename(_ path: String, to proposed: String) {
        guard sidebarFiles.renamingPath == path else { return }
        let wasNew = sidebarFiles.renameIsNewDocument
        sidebarFiles.renamingPath = nil
        sidebarFiles.renameIsNewDocument = false
        defer { if wasNew { startWritingNewDocument() } }
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { NSSound.beep(); return }
        switch FileOperations.checkRename(url, isDirectory: isDirectory.boolValue, to: proposed) {
        case .unchanged:
            break
        case .invalid(let message):
            showFileProblem("Couldn’t rename “\(url.lastPathComponent)”.", message)
        case .valid(let name, let leavesSidebar):
            let move = PathMove(from: path, to: url.deletingLastPathComponent().appendingPathComponent(name).path)
            guard leavesSidebar else {
                performMove(move, actionName: "Rename", offerLinks: true)
                return
            }
            let alert = NSAlert()
            alert.messageText = "Use “\(name)”?"
            alert.informativeText = "It isn’t a Markdown name, so the file won’t appear in the sidebar."
            alert.addButton(withTitle: "Rename")
            alert.addButton(withTitle: "Cancel")
            present(alert) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.performMove(move, actionName: "Rename", offerLinks: true) }
            }
        }
    }

    /// After naming a new document, start writing in it, as New Document does.
    private func startWritingNewDocument() {
        guard currentFile != nil else { return }
        if viewMode == .read { setViewMode(.split) }
        editor.focus()
    }

    // MARK: Move

    /// Moves items dropped on a folder. Items from outside the project are opened instead.
    /// Asks for a folder inside the project, then moves the item there (offering link updates).
    func chooseMoveDestination(for url: URL) {
        guard let root = rootURL else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = url.deletingLastPathComponent()
        panel.prompt = "Move"
        panel.message = "Choose a folder in \(root.lastPathComponent) to move \(url.lastPathComponent) to."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let target = FileScanner.canonicalPath(folder.path)
        guard target == root.path || target.hasPrefix(root.path + "/") else {
            let alert = NSAlert()
            alert.messageText = "Choose a folder inside the project"
            alert.informativeText = "LexMD moves files only within \(root.lastPathComponent)."
            present(alert) { _ in }
            return
        }
        _ = moveItems([url], into: folder)
    }

    @discardableResult
    func moveItems(_ urls: [URL], into folder: URL) -> Bool {
        guard let root = rootURL?.path else { return false }
        let target = FileScanner.canonicalPath(folder.path)
        let inside = urls.filter(\.isFileURL).map { FileScanner.canonicalPath($0.path) }.filter { $0.hasPrefix(root + "/") }
        if inside.isEmpty {
            guard let url = urls.first(where: \.isFileURL) else { return false }
            open(url)
            return true
        }
        var moved = false
        for source in inside where (source as NSString).deletingLastPathComponent != target {
            let name = (source as NSString).lastPathComponent
            if let problem = FileOperations.moveProblem(source, into: target) {
                showFileProblem("Couldn’t move “\(name)”.", problem)
                continue
            }
            let move = PathMove(from: source, to: (target as NSString).appendingPathComponent(name))
            if performMove(move, actionName: "Move", offerLinks: true) { moved = true }
        }
        return moved
    }

    /// Renames or moves an item, updates the tree, tabs and history at once, and offers to
    /// update links. Undo moves it back.
    @discardableResult
    func performMove(_ move: PathMove, actionName: String, offerLinks: Bool) -> Bool {
        let node = FileTreeEdit.node(at: move.from, in: tree)
        let hadMarkdown = node.map(FileTreeEdit.containsMarkdown) ?? FileScanner.isMarkdown(path: move.from)
        saveNow()
        do {
            try FileOperations.move(URL(fileURLWithPath: move.from), to: URL(fileURLWithPath: move.to))
        } catch {
            showFileProblem("Couldn’t \(actionName.lowercased()) “\((move.from as NSString).lastPathComponent)”.", error)
            return false
        }
        applyMove(move)
        if let undo = fileUndoManager {
            undo.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated { _ = model.performMove(move.inverse, actionName: actionName, offerLinks: false) }
            }
            undo.setActionName(actionName)
        }
        if offerLinks, hadMarkdown { offerLinkUpdate(for: move) }
        return true
    }

    /// Updates everything that refers to moved paths.
    func applyMove(_ move: PathMove) {
        guard let root = rootURL?.path else { return }
        sidebarFiles.newFolders = Set(sidebarFiles.newFolders.map { move.map($0) ?? $0 })
        let node = FileTreeEdit.node(at: move.from, in: tree)
        let staysVisible = node.map { $0.children != nil || FileScanner.isMarkdown(path: move.to) } ?? false
        if staysVisible, move.to.hasPrefix(root + "/") {
            tree = FileTreeEdit.moving(tree, move: move, root: root, keep: sidebarFiles.newFolders)
        } else {
            tree = FileTreeEdit.removing(move.from, from: tree, keep: sidebarFiles.newFolders)
        }
        let remapped = Set(expanded.map { move.map($0) ?? $0 })
        if remapped != expanded { expanded = remapped }
        if let current = currentFile?.path, let moved = move.map(current) {
            currentFile = URL(fileURLWithPath: moved)
            defaults.set(moved, forKey: Keys.lastFile)
            render(debounce: false)
        }
        if let selected = selectedPath, let moved = move.map(selected) { selectedPath = moved }
        history = history.map { move.map($0) ?? $0 }
        tabStore.list.remap { move.map($0) }
        if let renaming = sidebarFiles.renamingPath, let moved = move.map(renaming) { sidebarFiles.renamingPath = moved }
        reveal(move.to)
        persistTabs()
        rescan()
        filesDidChange(structure: true)
    }

    // MARK: Duplicate

    func duplicateItem(_ url: URL) {
        saveNow()
        Task { [weak self] in
            let result = await runDetached { () -> Result<FileNode, Error> in
                do {
                    let copy = try FileOperations.duplicate(url)
                    var isDirectory: ObjCBool = false
                    FileManager.default.fileExists(atPath: copy.path, isDirectory: &isDirectory)
                    let children = isDirectory.boolValue ? FileScanner.scan(copy) : nil
                    return .success(FileNode(url: URL(fileURLWithPath: copy.path, isDirectory: isDirectory.boolValue),
                                             name: copy.lastPathComponent, children: children))
                } catch {
                    return .failure(error)
                }
            }
            guard let self else { return }
            switch result {
            case .success(let node):
                if let root = self.rootURL?.path, FileTreeEdit.containsMarkdown(node) {
                    self.tree = FileTreeEdit.inserting(node, into: self.tree, parent: (node.id as NSString).deletingLastPathComponent, root: root)
                }
                self.reveal(node.id)
                self.rescan()
                self.filesDidChange(structure: true)
                if let undo = self.fileUndoManager {
                    undo.registerUndo(withTarget: self) { model in
                        MainActor.assumeIsolated { model.moveToTrash(node.url, registerUndo: false) }
                    }
                    undo.setActionName("Duplicate")
                }
            case .failure(let error):
                self.showFileProblem("Couldn’t duplicate “\(url.lastPathComponent)”.", error)
            }
        }
    }

    // MARK: Trash

    func confirmMoveToTrash(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = "Move “\(url.lastPathComponent)” to the Trash?"
        alert.informativeText = isDirectory.boolValue
            ? "The folder and everything in it move to the Trash. You can put them back from there."
            : "You can put it back from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        present(alert) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.moveToTrash(url) }
        }
    }

    /// Moves an item to the Trash through the system (never deletes), then closes its tabs.
    func moveToTrash(_ url: URL, registerUndo: Bool = true) {
        saveNow()
        let path = url.path
        let recycler = sidebarFiles.recycler
        sidebarFiles.trashing.insert(path)
        Task { [weak self] in
            do {
                let trashed = try await FileOperations.moveToTrash(URL(fileURLWithPath: path), using: recycler)
                self?.sidebarFiles.trashing.remove(path)
                self?.itemWasTrashed(path, to: trashed, registerUndo: registerUndo)
            } catch {
                self?.sidebarFiles.trashing.remove(path)
                self?.saveNow()
                self?.showFileProblem("Couldn’t move “\(url.lastPathComponent)” to the Trash.", error)
            }
        }
    }

    func itemWasTrashed(_ path: String, to trashed: URL?, registerUndo: Bool) {
        let inside: (String) -> Bool = { $0 == path || $0.hasPrefix(path + "/") }
        sidebarFiles.newFolders = sidebarFiles.newFolders.filter { !inside($0) }
        tree = FileTreeEdit.removing(path, from: tree, keep: sidebarFiles.newFolders)
        if let renaming = sidebarFiles.renamingPath, inside(renaming) { sidebarFiles.renamingPath = nil }
        history = history.filter { !inside($0) }
        historyIndex = min(historyIndex, history.count - 1)
        // Text that never reached the disk (typed while the item was moving, or that a tab could
        // not save) goes with its document to the Trash rather than being dropped with the tab.
        var unsaved = tabStore.list.tabs.compactMap { tab in tab.state.unsavedText.map { (tab.path, $0) } }
        if let current = currentFile?.path, text != savedText { unsaved.append((current, text)) }
        for (document, contents) in unsaved where inside(document) {
            guard let trashed, let moved = PathMove(from: path, to: trashed.path).map(document) else { continue }
            try? contents.write(toFile: moved, atomically: false, encoding: .utf8)
        }
        if let current = currentFile?.path, inside(current) {
            // Nothing may write its text back to the old place.
            savedText = text
            _ = tabStore.list.removeAll(where: inside)
            if tabStore.list.activeID != nil { showActiveTab() } else { closeDocument() }
        } else {
            _ = tabStore.list.removeAll(where: inside)
        }
        persistTabs()
        rescan()
        filesDidChange(structure: true)
        guard registerUndo, let trashed, let undo = fileUndoManager else { return }
        undo.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.putBack(trashed, to: path) }
        }
        undo.setActionName("Move to Trash")
    }

    /// Undo for Move to Trash: moves the item back from the Trash.
    private func putBack(_ trashed: URL, to path: String) {
        do {
            try FileOperations.move(trashed, to: URL(fileURLWithPath: path))
        } catch {
            showFileProblem("Couldn’t put “\((path as NSString).lastPathComponent)” back.", error)
            return
        }
        reveal(path)
        rescan()
        filesDidChange(structure: true)
        fileUndoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.moveToTrash(URL(fileURLWithPath: path), registerUndo: false) }
        }
    }

    // MARK: Links

    /// Unsaved and in-memory text of open documents, by path.
    func openDocumentTexts() -> [String: String] {
        var texts: [String: String] = [:]
        for tab in tabStore.list.tabs { if let unsaved = tab.state.unsavedText { texts[tab.path] = unsaved } }
        if let current = currentFile?.path { texts[current] = text }
        return texts
    }

    /// Finds links that the move affects and asks whether to update them.
    func offerLinkUpdate(for move: PathMove) {
        guard let root = rootURL?.path else { return }
        let files = FileScanner.searchableFiles(in: tree, root: root).map(\.path)
        let overrides = openDocumentTexts()
        Task { [weak self] in
            let (context, plan) = await runDetached { () -> (LinkRewriter.Context, LinkUpdatePlan) in
                let context = LinkUpdater.context(root: root, move: move, markdownFiles: files)
                return (context, LinkUpdater.plan(markdownFiles: files, context: context, overrides: overrides))
            }
            guard let self, plan.linkCount > 0, self.rootURL?.path == root else { return }
            self.askToUpdateLinks(plan, context: context, root: root)
        }
    }

    private func askToUpdateLinks(_ plan: LinkUpdatePlan, context: LinkRewriter.Context, root: String) {
        let links = plan.linkCount
        let files = plan.files.count
        let alert = NSAlert()
        alert.messageText = "Update \(links) \(links == 1 ? "link" : "links") in \(files) \(files == 1 ? "file" : "files")?"
        var names = plan.files.prefix(8).map { file in
            let relative = file.path.hasPrefix(root + "/") ? String(file.path.dropFirst(root.count + 1)) : file.path
            return "\(relative) (\(file.count))"
        }
        if files > 8 { names.append("and \(files - 8) more") }
        alert.informativeText = "These links still point to the old location:\n\n" + names.joined(separator: "\n")
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Don’t Update")
        present(alert) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.applyLinkUpdate(plan, context: context) }
        }
    }

    /// Rewrites links: the open document through the editor (nothing unsaved is lost), documents
    /// with unsaved text in other tabs in memory, and other files on disk off the main thread.
    ///
    /// The open document's edit is on the editor's undo stack; the files on disk are one step on
    /// the window's. Undoing that step from the window also undoes the open document's edit while
    /// it is still the editor's latest change, so the update reverts as a whole either way.
    func applyLinkUpdate(_ plan: LinkUpdatePlan, context: LinkRewriter.Context) {
        let undo = fileUndoManager
        undo?.beginUndoGrouping()
        defer { undo?.endUndoGrouping() }
        var onDisk: [String] = []
        let current = currentFile?.path
        let record = LinkWriteRecord()
        for file in plan.files {
            let oldPath = context.oldLocation(of: file.path)
            if file.path == current {
                let before = text
                let edits = LinkRewriter.edits(in: text, oldPath: oldPath, newPath: file.path, context: context)
                if editor.applyEdits(edits, actionName: "Update Links") {
                    record.openDocument = RewrittenFile(path: file.path, before: before, after: editor.textView.string)
                }
            } else if let tab = tabStore.list.tabs.first(where: { $0.path == file.path && $0.state.unsavedText != nil }),
                      let unsaved = tab.state.unsavedText {
                let edits = LinkRewriter.edits(in: unsaved, oldPath: oldPath, newPath: file.path, context: context)
                tabStore.list.update(tab.id) { $0.state.unsavedText = TextEdit.apply(edits, to: unsaved) }
            } else {
                onDisk.append(file.path)
            }
        }
        let paths = onDisk
        record.task = Task { [weak self] in
            let result = await runDetached { LinkUpdater.rewrite(paths, context: context) }
            record.files = result.written
            // A file may have been opened, or got unsaved text, while it was being rewritten:
            // update the text in memory too, or autosave would write the old links back.
            self?.rewriteOpenText(paths, context: context)
            self?.filesDidChange(structure: false, changed: result.written.map(\.path))
            if !result.failed.isEmpty {
                self?.showFileProblem("Some links couldn’t be updated.", Self.list(result.failed, under: self?.rootURL?.path))
            }
        }
        undo?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.replayLinkWrites(record, forward: false) }
        }
        undo?.setActionName("Update Links")
    }

    /// Applies a link update to the in-memory text of open documents among `paths`. Text that
    /// already has the new links is left as it is.
    private func rewriteOpenText(_ paths: [String], context: LinkRewriter.Context) {
        for path in paths {
            let oldPath = context.oldLocation(of: path)
            if path == currentFile?.path {
                let edits = LinkRewriter.edits(in: text, oldPath: oldPath, newPath: path, context: context)
                editor.applyEdits(edits, actionName: "Update Links")
            } else if let tab = tabStore.list.tab(withPath: path), let unsaved = tab.state.unsavedText {
                let edits = LinkRewriter.edits(in: unsaved, oldPath: oldPath, newPath: path, context: context)
                if !edits.isEmpty { tabStore.list.update(tab.id) { $0.state.unsavedText = TextEdit.apply(edits, to: unsaved) } }
            }
        }
    }

    /// Undo and redo for files rewritten on disk. A file edited since is left alone and reported.
    /// The open document's part goes along while the editor's latest change is still that edit.
    private func replayLinkWrites(_ record: LinkWriteRecord, forward: Bool) {
        fileUndoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.replayLinkWrites(record, forward: !forward) }
        }
        fileUndoManager?.setActionName("Update Links")
        if let document = record.openDocument, document.path == currentFile?.path {
            let editorUndo = editor.undoManager
            if forward, text == document.before, editorUndo.canRedo, editorUndo.redoActionName == "Update Links" {
                editorUndo.redo()
            } else if !forward, text == document.after, editorUndo.canUndo, editorUndo.undoActionName == "Update Links" {
                editorUndo.undo()
            }
            // Make sure the model has the editor's text before anything compares it.
            if editor.textView.string != text { editor.onTextChange?(editor.textView.string) }
        }
        let previous = record.task
        record.task = Task { [weak self] in
            await previous?.value
            let files = record.files
            let skipped = await runDetached { LinkUpdater.restore(files, forward: forward) }
            self?.filesDidChange(structure: false, changed: files.map(\.path))
            if !skipped.isEmpty {
                self?.showFileProblem("Some files changed since the links were updated, so they were left as they are.",
                                      Self.list(skipped, under: self?.rootURL?.path))
            }
        }
    }

    private static func list(_ paths: [String], under root: String?) -> String {
        var lines = paths.prefix(8).map { path in
            guard let root, path.hasPrefix(root + "/") else { return path }
            return String(path.dropFirst(root.count + 1))
        }
        if paths.count > 8 { lines.append("and \(paths.count - 8) more") }
        return lines.joined(separator: "\n")
    }

    // MARK: Alerts

    func showFileProblem(_ message: String, _ error: Error) {
        showFileProblem(message, error.localizedDescription)
    }

    func showFileProblem(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        present(alert) { _ in }
    }
}
