import AppKit
import CoreServices
import LexMDRendering
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum ViewMode: String, CaseIterable {
    case edit, split, read
}

enum SidebarPosition: String, CaseIterable {
    case left, right
}

enum AppearanceMode: String, CaseIterable {
    case system, light, dark
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    // Tree
    private(set) var rootURL: URL?
    var tree: [FileNode] = [] {
        didSet {
            updateDisplayTree()
            linksTreeDidChange()
        }
    }
    /// The tree as displayed: compacted when the setting is on, before filtering.
    private(set) var displayTree: [FileNode] = []
    private(set) var displayFolderIDs: [String] = []
    private(set) var isScanning = false
    var filter = ""
    var expanded: Set<String> = [] {
        didSet { defaults.set(Array(expanded), forKey: Keys.expanded) }
    }

    /// Path of the file highlighted in the sidebar.
    var selectedPath: String? {
        didSet { selectionChanged(from: oldValue) }
    }

    // Document
    var currentFile: URL?
    private(set) var wordCount = 0
    var saveError: String?
    private(set) var viewMode: ViewMode = .read
    private(set) var fontScale: Double = 1
    private(set) var recentFolders: [String] = []
    var columnVisibility: NavigationSplitViewVisibility = .all
    var isInspectorPresented = true
    var sidebarPosition: SidebarPosition = .left {
        didSet { defaults.set(sidebarPosition.rawValue, forKey: Keys.sidebarPosition) }
    }
    var appearanceMode: AppearanceMode = .system {
        didSet {
            defaults.set(appearanceMode.rawValue, forKey: Keys.appearance)
            applyAppearance()
        }
    }
    var shortcutOverrides: [String: String] = [:] {
        didSet { defaults.set(shortcutOverrides, forKey: Keys.shortcuts) }
    }
    var shortcutNote: String?
    private(set) var recentFiles: [String] = []
    var history: [String] = []
    var historyIndex = -1
    @ObservationIgnored var isNavigatingHistory = false

    var compactFolders = true {
        didSet {
            defaults.set(compactFolders, forKey: Keys.compactFolders)
            updateDisplayTree()
        }
    }

    /// Lets the preview load images and media from the web. Off by default, so opening a
    /// document never contacts the servers it references.
    var loadsRemoteContent = false {
        didSet {
            defaults.set(loadsRemoteContent, forKey: Keys.loadsRemoteContent)
            preview.setAllowsRemoteContent(loadsRemoteContent)
        }
    }

    // Editor features; see AppModel+Editor.swift.
    var imageFolder = "assets" {
        didSet { defaults.set(imageFolder, forKey: Keys.imageFolder) }
    }
    var checksSpelling = false {
        didSet { defaults.set(checksSpelling, forKey: Keys.checksSpelling); applyEditorSettings() }
    }
    var checksGrammar = false {
        didSet { defaults.set(checksGrammar, forKey: Keys.checksGrammar); applyEditorSettings() }
    }
    var focusMode = false {
        didSet { defaults.set(focusMode, forKey: Keys.focusMode); applyEditorSettings() }
    }
    var typewriterScrolling = false {
        didSet { defaults.set(typewriterScrolling, forKey: Keys.typewriterScrolling); applyEditorSettings() }
    }
    /// Shows git status badges in the sidebar for projects in git repositories.
    var showGitStatus = true {
        didSet {
            defaults.set(showGitStatus, forKey: Keys.showGitStatus)
            gitSettingChanged()
        }
    }

    // In-document find (preview find bar; the editor uses the native find bar)
    var isFindBarVisible = false
    var findQuery = "" {
        didSet { if findQuery != oldValue { findIndex = 0; refreshFind(scroll: true) } }
    }
    var findCaseSensitive = false {
        didSet { if findCaseSensitive != oldValue { findIndex = 0; refreshFind(scroll: true) } }
    }
    var findCount = 0
    var findIndex = 0
    var findFocusToken = 0

    // Find in Files
    var isQuickSearchVisible = false
    /// Set by New Tab: the file picked in Open Quickly opens in a new tab.
    var quickOpensInNewTab = false
    var quickMode: QuickMode = .everything
    var quickQuery = "" {
        didSet { if quickQuery != oldValue { scheduleQuickSearch() } }
    }
    var quickOptions = SearchOptions() {
        didSet { if quickOptions != oldValue { scheduleQuickSearch() } }
    }
    var quickResults = QuickSearchResults()
    var isQuickSearching = false
    var quickSelection = 0
    var quickPreview: QuickPreviewData?
    var quickFocusToken = 0

    /// Shows the outline, backlinks, and link problems beside the document.
    var isOutlineVisible = false {
        didSet {
            defaults.set(isOutlineVisible, forKey: Keys.outlineVisible)
            outlineVisibilityChanged()
        }
    }
    var suggestsLinks = true {
        didSet { defaults.set(suggestsLinks, forKey: Keys.suggestsLinks) }
    }
    var marksBrokenLinks = true {
        didSet {
            defaults.set(marksBrokenLinks, forKey: Keys.marksBrokenLinks)
            linkSettingsChanged()
        }
    }
    let outline = OutlineModel()

    let editor = EditorController()
    let preview = PreviewController(allowsRemoteContent: UserDefaults.standard.bool(forKey: Keys.loadsRemoteContent))
    let updates = UpdateService()
    var isOnboardingPresented = false

    @ObservationIgnored var text = ""
    @ObservationIgnored var savedText = ""
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var rescanTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var pendingScrollReset = false
    @ObservationIgnored let defaults = UserDefaults.standard
    @ObservationIgnored var quickTask: Task<Void, Never>?
    @ObservationIgnored var quickKeyMonitor: Any?
    @ObservationIgnored var quickQueries: [QuickMode: String] = [:]
    @ObservationIgnored var transientHighlight = false
    @ObservationIgnored let tabStore = TabStore()
    @ObservationIgnored let sidebarFiles = SidebarFileState()

    enum Keys {
        static let root = "rootPath"
        static let lastFile = "lastFile"
        static let expanded = "expanded"
        static let viewMode = "viewMode"
        static let fontScale = "fontScale"
        static let recentFolders = "recentFolders"
        static let compactFolders = "compactFolders"
        static let shortcuts = "shortcuts"
        static let sidebarPosition = "sidebarPosition"
        static let appearance = "appearance"
        static let onboardingComplete = "onboardingComplete"
        static let recentFiles = "recentFiles"
        static let loadsRemoteContent = "loadsRemoteContent"
        static let openTabs = "openTabs"
        static let alwaysShowTabBar = "alwaysShowTabBar"
        static let imageFolder = "imageFolder"
        static let checksSpelling = "checksSpelling"
        static let checksGrammar = "checksGrammar"
        static let focusMode = "focusMode"
        static let typewriterScrolling = "typewriterScrolling"
        static let showGitStatus = "showGitStatus"
        static let outlineVisible = "outlineVisible"
        static let suggestsLinks = "suggestsLinks"
        static let marksBrokenLinks = "marksBrokenLinks"
    }

    private init() {
        viewMode = ViewMode(rawValue: defaults.string(forKey: Keys.viewMode) ?? "") ?? .read
        let scale = defaults.double(forKey: Keys.fontScale)
        fontScale = scale > 0 ? scale : 1
        recentFolders = defaults.stringArray(forKey: Keys.recentFolders) ?? []
        compactFolders = defaults.object(forKey: Keys.compactFolders) as? Bool ?? true
        loadsRemoteContent = preview.allowsRemoteContent
        showGitStatus = defaults.object(forKey: Keys.showGitStatus) as? Bool ?? true
        shortcutOverrides = defaults.dictionary(forKey: Keys.shortcuts) as? [String: String] ?? [:]
        recentFiles = defaults.stringArray(forKey: Keys.recentFiles) ?? []
        sidebarPosition = SidebarPosition(rawValue: defaults.string(forKey: Keys.sidebarPosition) ?? "") ?? .left
        appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        imageFolder = defaults.string(forKey: Keys.imageFolder) ?? "assets"
        checksSpelling = defaults.object(forKey: Keys.checksSpelling) as? Bool ?? false
        checksGrammar = defaults.bool(forKey: Keys.checksGrammar)
        focusMode = defaults.bool(forKey: Keys.focusMode)
        typewriterScrolling = defaults.bool(forKey: Keys.typewriterScrolling)
        configureEditorFeatures()
        isOutlineVisible = defaults.bool(forKey: Keys.outlineVisible)
        suggestsLinks = defaults.object(forKey: Keys.suggestsLinks) as? Bool ?? true
        marksBrokenLinks = defaults.object(forKey: Keys.marksBrokenLinks) as? Bool ?? true

        editor.onTextChange = { [weak self] newText in self?.textDidChange(newText) }
        editor.onCancel = { [weak self] in
            guard let self, self.isFindBarVisible else { return false }
            self.closeFindBar()
            return true
        }
        editor.onScroll = { [weak self] fraction in
            guard let self, self.viewMode == .split else { return }
            self.preview.scroll(to: fraction)
        }
        preview.onOpenURL = { [weak self] url in self?.openLink(url) }
        preview.onHighlightCount = { [weak self] count in self?.highlightCountChanged(count) }
        applyFontScale()
        setUpLinks()

        Task { @MainActor [weak self] in self?.restoreSession() }
    }

    // MARK: - Derived

    var title: String {
        currentFile.map { ($0.lastPathComponent as NSString).deletingPathExtension } ?? "LexMD"
    }

    var subtitle: String {
        if let saveError { return saveError }
        guard currentFile != nil else { return rootURL?.lastPathComponent ?? "" }
        let words = wordCount.formatted()
        let minutes = max(1, Int((Double(wordCount) / 230).rounded()))
        return "\(words) \(wordCount == 1 ? "word" : "words") · \(minutes) min read"
    }

    func updateDisplayTree() {
        let tree = treeWithNewFolders(self.tree)
        displayTree = compactFolders ? FileScanner.compact(tree) : tree
        displayFolderIDs = FileScanner.folderIDs(in: displayTree)
    }

    var visibleTree: [FileNode] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return displayTree }
        return FileScanner.filter(displayTree, query: query)
    }

    /// The visible tree flattened into rows, honoring folder expansion.
    var visibleRows: [TreeRow] {
        var rows: [TreeRow] = []
        func walk(_ nodes: [FileNode], depth: Int) {
            for node in nodes {
                rows.append(TreeRow(node: node, depth: depth))
                if let children = node.children, isExpanded(node) {
                    walk(children, depth: depth + 1)
                }
            }
        }
        walk(visibleTree, depth: 0)
        return rows
    }

    func isExpanded(_ node: FileNode) -> Bool {
        !filter.trimmingCharacters(in: .whitespaces).isEmpty || expanded.contains(node.id)
    }

    func setExpanded(_ node: FileNode, _ value: Bool) {
        if value { expanded.insert(node.id) } else { expanded.remove(node.id) }
    }

    /// The expand/collapse-all control only makes sense with at least two folders on screen,
    /// and not while filtering (filter results are always fully expanded).
    var canToggleAllFolders: Bool {
        filter.trimmingCharacters(in: .whitespaces).isEmpty && displayFolderIDs.count >= 2
    }

    var allFoldersExpanded: Bool {
        displayFolderIDs.allSatisfy { expanded.contains($0) }
    }

    func setAllFoldersExpanded(_ value: Bool) {
        if value { expanded.formUnion(displayFolderIDs) } else { expanded.subtract(displayFolderIDs) }
    }

    /// Expands or collapses a folder together with every folder inside it.
    func setExpanded(subtreeOf nodes: [FileNode], _ value: Bool) {
        let ids = FileScanner.folderIDs(in: nodes)
        guard !ids.isEmpty else { return }
        if value { expanded.formUnion(ids) } else { expanded.subtract(ids) }
    }

    // MARK: - Opening

    private func restoreSession() {
        guard rootURL == nil, let stored = defaults.string(forKey: Keys.root) else { return }
        let path = FileScanner.canonicalPath(stored)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return }
        setRoot(URL(fileURLWithPath: path, isDirectory: true))
        if restoreTabs() { return }
        if let stored = defaults.string(forKey: Keys.lastFile) {
            let last = FileScanner.canonicalPath(stored)
            if last.hasPrefix(path + "/"), FileManager.default.fileExists(atPath: last) {
                reveal(last)
                selectedPath = last
            }
        }
    }

    func clearRecentFolders() {
        recentFolders = []
        defaults.set(recentFolders, forKey: Keys.recentFolders)
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = FileScanner.markdownExtensions.compactMap { UTType(filenameExtension: $0) } + [.folder]
        panel.prompt = "Open"
        panel.message = "Choose a folder to browse, or a Markdown file to open."
        if let rootURL { panel.directoryURL = rootURL }
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    /// Opens a folder (as the sidebar root) or a Markdown file.
    func open(_ url: URL) {
        let path = FileScanner.canonicalPath(url.path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return }
        if isDir.boolValue {
            setRoot(URL(fileURLWithPath: path, isDirectory: true))
            if tabStore.list.isEmpty { restoreTabs() }
            return
        }
        if let root = rootURL?.path, path.hasPrefix(root + "/") {
            // Already inside the current tree.
        } else {
            setRoot(URL(fileURLWithPath: path).deletingLastPathComponent())
        }
        reveal(path)
        selectedPath = path
    }

    private func setRoot(_ url: URL) {
        let normalized = URL(fileURLWithPath: FileScanner.canonicalPath(url.path), isDirectory: true)
        if rootURL?.path != normalized.path {
            saveNow()
            closeTabsForProjectChange()
            rootURL = normalized
            tree = []
            filter = ""
            let root = normalized.path
            let stored = defaults.stringArray(forKey: Keys.expanded) ?? []
            expanded = Set(stored.filter { $0.hasPrefix(root + "/") })
            defaults.set(root, forKey: Keys.root)
            recentFolders = Array(([root] + recentFolders.filter { $0 != root }).prefix(10))
            defaults.set(recentFolders, forKey: Keys.recentFolders)
            watcher = DirectoryWatcher(path: root) { [weak self] events in
                MainActor.assumeIsolated { self?.handleFileEvents(events) }
            }
        }
        rescan()
    }

    func reveal(_ path: String) {
        guard let root = rootURL?.path else { return }
        var dir = (path as NSString).deletingLastPathComponent
        var toExpand: [String] = []
        while dir.hasPrefix(root + "/") {
            toExpand.append(dir)
            dir = (dir as NSString).deletingLastPathComponent
        }
        let missing = toExpand.filter { !expanded.contains($0) }
        if !missing.isEmpty { expanded.formUnion(missing) }
    }

    func rescanSoon() { scheduleRescan() }

    func rescan() {
        guard let root = rootURL else { return }
        isScanning = tree.isEmpty
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            let nodes = await runDetached { FileScanner.scan(root) }
            guard let self, !Task.isCancelled, self.rootURL == root else { return }
            if nodes != self.tree { self.tree = nodes }
            self.isScanning = false
            self.gitProjectScanned()
        }
    }

    private func scheduleRescan() {
        rescanTask?.cancel()
        rescanTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.rescan()
        }
    }

    private func handleFileEvents(_ events: [DirectoryWatcher.Event]) {
        guard let root = rootURL?.path else { return }
        linksHandleFileEvents(events, root: root)
        gitFileEvents(events)
        var structural = false
        var currentChanged = false
        let current = currentFile?.path
        let structuralMask = kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
            | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagRootChanged
        for event in events {
            if event.path == current { currentChanged = true }
            guard !FileScanner.isIgnored(event.path, root: root) else { continue }
            let flags = Int(event.flags)
            guard flags & structuralMask != 0 else { continue }
            let isDir = flags & kFSEventStreamEventFlagItemIsDir != 0
            if isDir || FileScanner.isMarkdown(path: event.path) || flags & kFSEventStreamEventFlagMustScanSubDirs != 0 {
                structural = true
            }
        }
        if structural { scheduleRescan() }
        if currentChanged { reloadFromDiskIfNeeded() }
    }

    /// Follows a link clicked in the preview.
    func openLink(_ url: URL) {
        guard url.isFileURL else { openExternalLink(url); return }
        let path = FileScanner.canonicalPath(url.path)
        guard FileManager.default.fileExists(atPath: path) else { NSSound.beep(); return }
        let file = URL(fileURLWithPath: path)
        if FileScanner.isMarkdown(path: path) {
            openDocument(file, fragment: url.fragment(percentEncoded: false), inNewTab: preview.linkModifiers.contains(.command))
        } else if FileScanner.opensWithoutRunningCode(file) {
            NSWorkspace.shared.open(file)
        } else {
            // Apps, scripts, folders, and anything else that could run code are only revealed.
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
    }

    /// Web and mail links open directly; other schemes launch apps, so they ask first.
    private func openExternalLink(_ url: URL) {
        if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Open this link in another app?"
        alert.informativeText = String(url.absoluteString.prefix(400))
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        present(alert) { response in
            if response == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
        }
    }

    /// Shows an alert as a sheet on the key window, or modally when there is none.
    func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    func revealCurrentInFinder() {
        if let currentFile {
            NSWorkspace.shared.activateFileViewerSelecting([currentFile])
        } else if let rootURL {
            NSWorkspace.shared.activateFileViewerSelecting([rootURL])
        }
    }

    // MARK: - Document lifecycle

    private func selectionChanged(from old: String?) {
        guard selectedPath != old else { return }
        guard let path = selectedPath else {
            // Keep the open document highlighted when the list clears its selection.
            if let current = currentFile?.path { selectedPath = current }
            return
        }
        guard path != currentFile?.path else { return }
        if routeSelectionToTabs(path) { return }
        load(URL(fileURLWithPath: path))
    }

    func load(_ url: URL) {
        saveNow()
        guard let content = Self.read(url) else {
            NSSound.beep()
            return
        }
        currentFile = url
        text = content
        savedText = content
        saveError = nil
        if !isFindBarVisible {
            transientHighlight = false
            preview.setHighlight(nil, scroll: false)
        }
        editor.load(content)
        if isFindBarVisible {
            findIndex = 0
            refreshFind(scroll: false)
        }
        pendingScrollReset = true
        render(debounce: false)
        defaults.set(url.path, forKey: Keys.lastFile)
        recordVisit(url.path)
        tabDidLoad(url)
    }

    private static func read(_ url: URL) -> String? {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        var encoding = String.Encoding.utf8
        if let s = try? String(contentsOf: url, usedEncoding: &encoding) { return s }
        return try? String(contentsOf: url, encoding: .isoLatin1)
    }

    private func textDidChange(_ newText: String) {
        text = newText
        if transientHighlight {
            transientHighlight = false
            preview.setHighlight(nil, scroll: false)
        }
        if isFindBarVisible { refreshFind(scroll: false) }
        render(debounce: true)
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        guard let url = currentFile, text != savedText else { return }
        do {
            // Write in place so file watchers see a modification rather than a replace.
            try text.write(to: url, atomically: false, encoding: .utf8)
            savedText = text
            if saveError != nil { saveError = nil }
            gitDocumentSaved()
        } catch {
            saveError = "Couldn’t save: \(error.localizedDescription)"
        }
    }

    private func reloadFromDiskIfNeeded() {
        guard let url = currentFile, let disk = Self.read(url), disk != savedText else { return }
        guard text == savedText else { return } // Local edits win; autosave will write them.
        text = disk
        savedText = disk
        editor.replaceText(disk)
        render(debounce: false)
    }

    func render(debounce: Bool) {
        renderTask?.cancel()
        let source = text
        let base = currentFile?.deletingLastPathComponent()
        let links = linkContext(for: source)
        scheduleOutlineUpdate(debounce: debounce)
        renderTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(nanoseconds: 90_000_000)
                guard !Task.isCancelled else { return }
            }
            let (html, words) = await runDetached {
                (MarkdownHTML.render(source, links: links), MarkdownHTML.wordCount(source))
            }
            guard let self, !Task.isCancelled else { return }
            let reset = self.pendingScrollReset
            self.pendingScrollReset = false
            self.preview.render(html: html, baseURL: base, resetScroll: reset)
            if self.wordCount != words { self.wordCount = words }
        }
    }

    // MARK: - View settings

    func setViewMode(_ mode: ViewMode) {
        guard viewMode != mode else { return }
        viewMode = mode
        defaults.set(mode.rawValue, forKey: Keys.viewMode)
        if isFindBarVisible { refreshFind(scroll: false) }
        if mode != .read {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 50_000_000)
                self?.editor.focus()
            }
        }
    }

    func zoom(by step: Int) {
        let steps: [Double] = [0.8, 0.9, 1, 1.1, 1.2, 1.35, 1.5, 1.7, 2]
        if step == 0 {
            fontScale = 1
        } else {
            let index = steps.firstIndex { $0 >= fontScale - 0.001 } ?? 2
            fontScale = steps[min(max(index + step, 0), steps.count - 1)]
        }
        defaults.set(fontScale, forKey: Keys.fontScale)
        applyFontScale()
    }

    private func applyFontScale() {
        editor.fontSize = 14 * fontScale
        preview.setScale(fontScale)
    }

    // MARK: - Navigation

    private func recordVisit(_ path: String) {
        recentFiles = Array(([path] + recentFiles.filter { $0 != path }).prefix(30))
        defaults.set(recentFiles, forKey: Keys.recentFiles)
        guard !isNavigatingHistory else { return }
        if historyIndex < history.count - 1 { history.removeSubrange((historyIndex + 1)...) }
        if history.last != path { history.append(path) }
        historyIndex = history.count - 1
    }

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex < history.count - 1 }

    func goBack() { navigateHistory(by: -1) }
    func goForward() { navigateHistory(by: 1) }

    private func navigateHistory(by step: Int) {
        var index = historyIndex + step
        while index >= 0, index < history.count, !FileManager.default.fileExists(atPath: history[index]) {
            index += step
        }
        guard index >= 0, index < history.count else { NSSound.beep(); return }
        historyIndex = index
        isNavigatingHistory = true
        open(URL(fileURLWithPath: history[index]))
        isNavigatingHistory = false
    }

    func toggleSidebar() {
        withAnimation(.snappy(duration: 0.25)) {
            if sidebarPosition == .right {
                isInspectorPresented.toggle()
            } else {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            }
        }
    }

    /// Applies the appearance setting to every window (nil follows the system).
    func applyAppearance() {
        guard let app = NSApp else { return }
        switch appearanceMode {
        case .system: app.appearance = nil
        case .light: app.appearance = NSAppearance(named: .aqua)
        case .dark: app.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: - New document

    func newDocument() {
        guard let root = rootURL else { showOpenPanel(); return }
        var folder = root
        if let current = currentFile?.deletingLastPathComponent(), current.path.hasPrefix(root.path) {
            folder = current
        }
        let alert = NSAlert()
        alert.messageText = "New Markdown Document"
        alert.informativeText = "Create it in “\(folder.lastPathComponent)”."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Untitled"
        field.bezelStyle = .roundedBezel
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.createDocument(named: field.stringValue, in: folder)
        }
        present(alert, completion: finish)
    }

    private func createDocument(named rawName: String, in folder: URL) {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        if name.isEmpty { name = "Untitled" }
        var base = name
        if FileScanner.isMarkdown(path: name) { base = (name as NSString).deletingPathExtension } else { name += ".md" }
        let ext = (name as NSString).pathExtension
        var url = folder.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(counter).\(ext)")
            counter += 1
        }
        do {
            try "# \(base)\n\n".write(to: url, atomically: false, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        rescanSoon()
        if viewMode == .read { setViewMode(.split) }
        open(url)
        editor.focus()
        editor.moveCursorToEnd()
    }

    // MARK: - Onboarding

    func presentOnboardingIfNeeded() {
        if !defaults.bool(forKey: Keys.onboardingComplete) { isOnboardingPresented = true }
    }

    func showOnboarding() { isOnboardingPresented = true }

    func completeOnboarding() {
        defaults.set(true, forKey: Keys.onboardingComplete)
        isOnboardingPresented = false
    }
}
