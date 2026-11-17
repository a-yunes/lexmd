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
            treeGeneration &+= 1
            treePaths = nil
            searchFiles = nil
            updateDisplayTree()
            linksTreeDidChange()
            if isQuickSearchVisible { refreshQuickSearchForTree() }
        }
    }
    /// The tree as displayed: compacted when the setting is on, before filtering.
    private(set) var displayTree: [FileNode] = [] {
        didSet { updateVisibleRows() }
    }
    private(set) var displayFolderIDs: [String] = []
    /// The displayed tree flattened into sidebar rows, honoring the filter and folder expansion.
    private(set) var visibleRows: [TreeRow] = []
    private(set) var isScanning = false
    var filter = "" {
        didSet {
            guard filter != oldValue else { return }
            let filtering = !filter.trimmingCharacters(in: .whitespaces).isEmpty
            if filtering != isFiltering { isFiltering = filtering }
            updateVisibleRows()
        }
    }
    /// Whether the filter holds text. Views and menus read this instead of `filter` so they
    /// update only when filtering starts or stops, not on every keystroke.
    private(set) var isFiltering = false
    var expanded: Set<String> = [] {
        didSet {
            persistExpanded()
            if !isFiltering { updateVisibleRows() }
        }
    }

    /// Path of the file highlighted in the sidebar. Setting it only moves the highlight;
    /// `showDocument(_:)` opens documents and `sidebarSelected(_:)` handles clicks on rows.
    var selectedPath: String?

    // Document
    var currentFile: URL?
    private(set) var wordCount = 0
    var saveError: String?
    private(set) var viewMode: ViewMode = .read {
        didSet {
            updateOutlineFit()
            scrollSync.isEnabled = viewMode == .split
        }
    }
    private(set) var fontScale: Double = 1
    private(set) var recentFolders: [String] = []
    var columnVisibility: NavigationSplitViewVisibility = .all {
        didSet { updateOutlineFit() }
    }
    var isInspectorPresented = true {
        didSet { updateOutlineFit() }
    }
    var sidebarPosition: SidebarPosition = .left {
        didSet {
            defaults.set(sidebarPosition.rawValue, forKey: Keys.sidebarPosition)
            updateOutlineFit()
        }
    }
    /// The window's frame width, reported by the window. With the sidebar and the view mode, it
    /// decides whether the outline fits beside the document.
    @ObservationIgnored var windowWidth: CGFloat = .infinity {
        didSet { updateOutlineFit() }
    }
    /// False while the window is too narrow for the outline beside the document.
    var outlineFitsWindow = true
    /// Set when the reader shows the outline in a window too narrow for it; cleared when they hide it.
    var showsOutlineWhileNarrow = false
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
    /// The command whose shortcut Settings is recording; at most one at a time.
    var recordingShortcut: ShortcutAction?
    @ObservationIgnored var shortcutMonitor: Any?
    /// The window recording happens in; keys typed in other windows are left alone.
    @ObservationIgnored weak var shortcutWindow: NSWindow?
    /// The tab Settings shows, kept between launches. Set it before opening Settings to show a
    /// specific tab; see `showSettings(_:using:)` and `SettingsTabButton`.
    var settingsTab = SettingsTab(rawValue: UserDefaults.standard.string(forKey: SettingsTab.defaultsKey) ?? "") ?? .general {
        didSet { defaults.set(settingsTab.rawValue, forKey: SettingsTab.defaultsKey) }
    }
    private(set) var recentFiles: [String] = []
    var history: [String] = []
    var historyIndex = -1

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
    /// Edit > Substitutions and Correct Spelling Automatically; all off by default.
    var substitutions = TextSubstitutions() {
        didSet {
            guard substitutions != oldValue else { return }
            defaults.set(substitutions.dictionary, forKey: Keys.substitutions)
            applyEditorSettings()
        }
    }
    /// Shows git status badges in the sidebar for projects in git repositories.
    var showGitStatus = true {
        didSet {
            defaults.set(showGitStatus, forKey: Keys.showGitStatus)
            git.setStatusEnabled(showGitStatus)
        }
    }

    // In-document find and replace; the find bar searches the preview and the editor.
    var isFindBarVisible = false
    var findQuery = "" {
        didSet { if findQuery != oldValue { findIndex = 0; refreshFind(scroll: true) } }
    }
    var findCaseSensitive = false {
        didSet { if findCaseSensitive != oldValue { findIndex = 0; refreshFind(scroll: true) } }
    }
    var findWholeWord = false {
        didSet { if findWholeWord != oldValue { findIndex = 0; refreshFind(scroll: true) } }
    }
    var findUsesRegex = false {
        didSet { if findUsesRegex != oldValue { findIndex = 0; refreshFind(scroll: true) } }
    }
    var findCount = 0
    var findIndex = 0
    var findFocusToken = 0
    /// Shown in place of the match count after Replace All, until the next search.
    var findStatus: String?
    var isReplaceVisible = false
    var replaceQuery = ""
    var replaceFocusToken = 0
    /// Whether the editor's selection can seed the find bar (Use Selection for Find).
    var canUseSelectionForFind = false

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
    var quickResults = QuickSearchResults() {
        didSet { quickResultsGeneration &+= 1 }
    }
    /// Changes with every new set of results, so the list starts over at the top.
    private(set) var quickResultsGeneration = 0
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
    /// Keeps the editor and the preview scrolled to the same place in Split view.
    @ObservationIgnored let scrollSync = ScrollSync()
    let preview = PreviewController(allowsRemoteContent: UserDefaults.standard.bool(forKey: Keys.loadsRemoteContent))
    let updates = UpdateService()
    var isOnboardingPresented = false

    @ObservationIgnored var text = ""
    @ObservationIgnored var savedText = ""
    /// Counts renders, so the preview can tell whether it shows the latest text.
    @ObservationIgnored private(set) var renderGeneration = 0
    /// Counts Copy as Rich Text requests; only the latest writes to the pasteboard.
    @ObservationIgnored var copyGeneration = 0
    /// The file version the open document's text was edited from: the text read when it
    /// opened or was reloaded. Saving doesn't change it, so it tells whether the text already
    /// contains a rewrite that was on disk when the document was read.
    @ObservationIgnored var loadedText = ""
    /// How the open document is stored on disk; saving keeps it.
    @ObservationIgnored var documentFormat = TextFile.Format.utf8
    /// The open document's file as LexMD last read or wrote it; a different one on disk means
    /// another app changed it.
    @ObservationIgnored var savedStamp: FileStamp?
    /// A question about the open document's file changing on disk is showing.
    @ObservationIgnored private var isAskingAboutExternalChange = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanRoot: URL?
    @ObservationIgnored private var rowsTask: Task<Void, Never>?
    @ObservationIgnored private var displayFileCount = 0
    /// Expanded folders by project, for the recent projects.
    @ObservationIgnored private var expandedByProject: [String: [String]]?
    @ObservationIgnored private var rescanAfterScan = false
    /// Changes whenever `tree` is set, so work started on an older tree can tell.
    @ObservationIgnored private(set) var treeGeneration = 0
    @ObservationIgnored private var treePaths: (files: Set<String>, folders: Set<String>)?
    /// Open Quickly and Find in Files candidates for the current tree, built off the main thread.
    @ObservationIgnored var searchFiles: [SearchableFile]?
    @ObservationIgnored var quickPendingActivation: Bool?
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
        /// Expanded folders of every project in one list (LexMD 1.0); read once to migrate.
        static let expanded = "expanded"
        static let expandedByProject = "expandedFolders"
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
        static let substitutions = "textSubstitutions"
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
        let stored = defaults.dictionary(forKey: Keys.shortcuts) as? [String: String] ?? [:]
        let resolved = Self.resolvingShortcutConflicts(stored)
        shortcutOverrides = resolved.overrides
        if !resolved.cleared.isEmpty {
            shortcutNote = "Shortcuts you chose replaced the defaults of \(resolved.cleared.map(\.title).joined(separator: ", "))."
        }
        recentFiles = defaults.stringArray(forKey: Keys.recentFiles) ?? []
        sidebarPosition = SidebarPosition(rawValue: defaults.string(forKey: Keys.sidebarPosition) ?? "") ?? .left
        appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        imageFolder = defaults.string(forKey: Keys.imageFolder) ?? "assets"
        checksSpelling = defaults.object(forKey: Keys.checksSpelling) as? Bool ?? false
        checksGrammar = defaults.bool(forKey: Keys.checksGrammar)
        focusMode = defaults.bool(forKey: Keys.focusMode)
        typewriterScrolling = defaults.bool(forKey: Keys.typewriterScrolling)
        substitutions = TextSubstitutions(dictionary: defaults.dictionary(forKey: Keys.substitutions))
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
        configureScrollSync()
        preview.onOpenURL = { [weak self] url in self?.openLink(url) }
        preview.onHighlightCount = { [weak self] count, document in
            // A count from a page still showing the previous document says nothing about this one.
            guard let self, document == self.currentFile?.path else { return }
            self.highlightCountChanged(count)
        }
        preview.onPinch = { [weak self] steps in self?.zoom(by: steps) }
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
        if isCurrentDocumentMissing { return "No longer on disk; saving puts it back" }
        return Self.readingSummary(words: wordCount)
    }

    /// The word count and reading time shown under the document's title.
    static func readingSummary(words: Int) -> String {
        let minutes = max(1, Int((Double(words) / 230).rounded()))
        return String(AttributedString(localized: "^[\(words) word](inflect: true) · \(minutes) min read").characters)
    }

    func updateDisplayTree() {
        let tree = treeWithNewFolders(self.tree)
        displayFileCount = FileScanner.fileCount(in: tree)
        displayTree = compactFolders ? FileScanner.compact(tree) : tree
        displayFolderIDs = FileScanner.folderIDs(in: displayTree)
    }

    /// Projects with more files than this filter the sidebar off the main thread.
    static var backgroundFilterThreshold = 3000

    /// Rebuilds the sidebar rows. Filtering a large project runs in the background, and the
    /// rows update when it finishes; a newer keystroke cancels it.
    private func updateVisibleRows() {
        rowsTask?.cancel()
        rowsTask = nil
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, displayFileCount > Self.backgroundFilterThreshold else {
            visibleRows = FileScanner.rows(displayTree, query: query, expanded: expanded)
            return
        }
        let tree = displayTree
        let expanded = expanded
        rowsTask = Task { [weak self] in
            let rows = await runDetached { FileScanner.rows(tree, query: query, expanded: expanded, cancellable: true) }
            guard let self, !Task.isCancelled else { return }
            self.rowsTask = nil
            self.visibleRows = rows
        }
    }

    private func persistExpanded() {
        guard let root = rootURL?.path else { return }
        var all = storedExpandedFolders()
        all[root] = Array(expanded)
        let known = Set(recentFolders).union([root])
        all = all.filter { known.contains($0.key) }
        expandedByProject = all
        defaults.set(all, forKey: Keys.expandedByProject)
    }

    private func storedExpandedFolders() -> [String: [String]] {
        if let expandedByProject { return expandedByProject }
        var all = defaults.dictionary(forKey: Keys.expandedByProject) as? [String: [String]] ?? [:]
        if let legacy = defaults.stringArray(forKey: Keys.expanded) {
            for project in recentFolders where all[project] == nil {
                all[project] = legacy.filter { $0.hasPrefix(project + "/") }
            }
            defaults.set(all, forKey: Keys.expandedByProject)
            defaults.removeObject(forKey: Keys.expanded)
        }
        expandedByProject = all
        return all
    }

    func isExpanded(_ node: FileNode) -> Bool {
        isFiltering || expanded.contains(node.id)
    }

    func setExpanded(_ node: FileNode, _ value: Bool) {
        if value { expanded.insert(node.id) } else { expanded.remove(node.id) }
    }

    /// The expand/collapse-all control only makes sense with at least two folders on screen,
    /// and not while filtering (filter results are always fully expanded).
    var canToggleAllFolders: Bool {
        !isFiltering && displayFolderIDs.count >= 2
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
                showDocument(last)
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
        panel.message = "Choose a project folder, or a Markdown document to open."
        if let rootURL { panel.directoryURL = rootURL }
        present(panel) { [weak self] response in
            if response == .OK, let url = panel.url { self?.open(url) }
        }
    }

    /// Opens a folder (as the sidebar root) or a Markdown file.
    /// Opens a project folder, or a document (with its folder when it is outside the project).
    /// `placement` and `recordsHistory` apply to a document; see `showDocument(_:placement:recordsHistory:)`.
    /// `then` runs once it has opened, which may be after a question about unsaved text.
    func open(_ url: URL, placement: DocumentPlacement = .reuseTab, recordsHistory: Bool = true, then: (() -> Void)? = nil) {
        let path = FileScanner.canonicalPath(url.path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return }
        let isDirectory = isDir.boolValue
        let inside = rootURL.map { path.hasPrefix($0.path + "/") } ?? false
        let newRoot = isDirectory ? path : (inside ? nil : (path as NSString).deletingLastPathComponent)
        guard let newRoot, let root = rootURL?.path, newRoot != root else {
            finishOpening(path, isDirectory: isDirectory, placement: placement, recordsHistory: recordsHistory)
            then?()
            return
        }
        // Opening another project closes these tabs: text that can't be saved is never dropped.
        settleUnsavedText(before: "open another project") { [weak self] proceed in
            guard proceed, let self else { return }
            self.finishOpening(path, isDirectory: isDirectory, placement: placement, recordsHistory: recordsHistory)
            then?()
        }
    }

    private func finishOpening(_ path: String, isDirectory: Bool, placement: DocumentPlacement, recordsHistory: Bool) {
        if isDirectory {
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
        showDocument(path, placement: placement, recordsHistory: recordsHistory)
    }

    private func setRoot(_ url: URL) {
        let normalized = URL(fileURLWithPath: FileScanner.canonicalPath(url.path), isDirectory: true)
        if rootURL?.path != normalized.path {
            saveNow()
            closeTabsForProjectChange()
            // Nothing that belongs to the previous project carries over: its repositories and
            // commit sheet, and undo of file operations made in it.
            git.projectClosed()
            fileUndoManager?.removeAllActions(withTarget: self)
            sidebarFiles.pendingLinkUpdates = [:]
            rootURL = normalized
            tree = []
            filter = ""
            let root = normalized.path
            expanded = Set(storedExpandedFolders()[root] ?? [])
            defaults.set(root, forKey: Keys.root)
            recentFolders = Array(([root] + recentFolders.filter { $0 != root }).prefix(10))
            defaults.set(recentFolders, forKey: Keys.recentFolders)
            watch(root)
        } else {
            // Opening the same folder again rescans it.
            outline.index.refresh()
        }
        rescan()
    }

    private func watch(_ root: String) {
        watcher = DirectoryWatcher(path: root) { [weak self] events in
            MainActor.assumeIsolated { self?.handleFileEvents(events) }
        }
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


    func rescan() {
        guard let root = rootURL else { return }
        isScanning = tree.isEmpty
        if scanTask != nil, scanRoot == root {
            // Restarting would let a steady stream of changes in a large project keep the
            // scan from ever finishing; scan again once this one ends instead.
            rescanAfterScan = true
            return
        }
        scanTask?.cancel()
        scanRoot = root
        rescanAfterScan = false
        let generation = treeGeneration
        scanTask = Task { [weak self] in
            let nodes = await runDetached { FileScanner.scan(root) }
            guard let self, !Task.isCancelled, self.rootURL == root else { return }
            self.scanTask = nil
            // A file command edited the tree while this scan ran, so the result may be older
            // than what the sidebar shows.
            guard self.treeGeneration == generation else { self.rescan(); return }
            if nodes != self.tree { self.tree = nodes }
            self.isScanning = false
            self.gitProjectScanned()
            if self.rescanAfterScan { self.rescan() }
        }
    }

    /// Rescans once a burst of changes has passed.
    func rescanSoon() {
        rescanTask?.cancel()
        rescanTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.rescan()
        }
    }

    private func handleFileEvents(_ events: [DirectoryWatcher.Event]) {
        guard let root = rootURL?.path else { return }
        if events.contains(where: { Int($0.flags) & kFSEventStreamEventFlagRootChanged != 0 }) {
            projectFolderChanged()
            return
        }
        if eventsTouchOpenDocuments(events) { followMovedDocuments() }
        linksHandleFileEvents(events, root: root)
        git.fileEvents(events)
        var structural = false
        var currentChanged = false
        let current = currentFile?.path
        let paths = { [self] in
            if let treePaths { return treePaths }
            let built = FileScanner.paths(in: tree)
            treePaths = built
            return built
        }
        for event in events {
            if event.path == current { currentChanged = true }
            // Events were dropped below this folder, so the open document may have changed unseen.
            if Int(event.flags) & kFSEventStreamEventFlagMustScanSubDirs != 0, let current,
               current.hasPrefix(event.path.hasSuffix("/") ? event.path : event.path + "/") {
                currentChanged = true
            }
            if !structural, FileScanner.eventChangesTree(path: event.path, flags: event.flags, root: root, paths: paths) {
                structural = true
            }
        }
        if structural { rescanSoon() }
        if currentChanged { reloadFromDiskIfNeeded() }
    }

    // MARK: - Project folder changes

    /// The project folder, or a folder above it, was renamed, moved, or deleted. A moved
    /// project is followed; a deleted one closes once its unsaved changes are safe.
    func projectFolderChanged() {
        guard let root = rootURL?.path else { return }
        let name = (root as NSString).lastPathComponent
        switch ProjectFolderChange(original: root, current: watcher?.folderLocation()) {
        case .unchanged:
            rescanSoon()
            filesDidChange(structure: true)
        case .moved(let newRoot):
            followProjectMove(to: newRoot)
        case .trashed(let trashed):
            // Keep unsaved changes with the folder in the Trash, so Put Back brings them along.
            closeProjectKeeping(writeUnsaved(unsavedDocuments(), through: PathMove(from: root, to: trashed)), name: name)
        case .removed:
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue {
                // Another folder took its place: watch that one.
                watch(root)
                rescan()
                filesDidChange(structure: true)
                return
            }
            closeProjectKeeping(unsavedDocuments(), name: name)
        }
    }

    /// Points everything at the project's new location: the sidebar, the open documents (so
    /// autosave writes to the moved files), tabs, history, and saved settings.
    func followProjectMove(to newRoot: String) {
        guard let oldRoot = rootURL?.path, newRoot != oldRoot else { return }
        rootURL = URL(fileURLWithPath: newRoot, isDirectory: true)
        remapOpenPaths(PathMove(from: oldRoot, to: newRoot))
        tree = tree.map { FileTreeEdit.rebased($0, to: newRoot + "/" + $0.name) }
        recentFolders = Array(([newRoot] + recentFolders.filter { $0 != oldRoot && $0 != newRoot }).prefix(10))
        defaults.set(recentFolders, forKey: Keys.recentFolders)
        defaults.set(newRoot, forKey: Keys.root)
        watch(newRoot)
        saveNow()
        render(debounce: false)
        rescan()
        filesDidChange(structure: true)
    }

    /// Moves every remembered path inside `move` along with it: the open document, the sidebar's
    /// highlight, new folders, the rename field, expanded folders, history, recent files and tabs.
    /// A moved project folder and an item moved inside the project both come through here.
    func remapOpenPaths(_ move: PathMove) {
        let remap = { (path: String) in move.map(path) ?? path }
        if let current = currentFile?.path, let moved = move.map(current) {
            currentFile = URL(fileURLWithPath: moved)
            defaults.set(moved, forKey: Keys.lastFile)
        }
        if let selected = selectedPath, let moved = move.map(selected) { selectedPath = moved }
        sidebarFiles.newFolders = Set(sidebarFiles.newFolders.map(remap))
        if let renaming = sidebarFiles.renamingPath { sidebarFiles.renamingPath = remap(renaming) }
        let remappedExpanded = Set(expanded.map(remap))
        if remappedExpanded != expanded { expanded = remappedExpanded }
        history = history.map(remap)
        let remappedRecent = recentFiles.map(remap)
        if remappedRecent != recentFiles {
            recentFiles = remappedRecent
            defaults.set(recentFiles, forKey: Keys.recentFiles)
        }
        let mapped = Set(tabStore.list.tabs.filter { move.map($0.path) != nil }.map(\.id))
        tabStore.list.remap { move.map($0) }
        closeTabsReplacedByMove(mapped)
        persistTabs()
    }

    /// A move onto the path of a tab whose file was gone (its tab still open) leaves two tabs for
    /// one file. The moved document is the file now there, so the stale tab closes; text it held
    /// that never reached the disk is offered to be kept elsewhere.
    private func closeTabsReplacedByMove(_ mapped: Set<UUID>) {
        let movedPaths = Set(tabStore.list.tabs.filter { mapped.contains($0.id) }.map(\.path))
        let stale = tabStore.list.tabs.filter { !mapped.contains($0.id) && movedPaths.contains($0.path) }
        guard !stale.isEmpty else { return }
        var unsaved: [(path: String, text: String)] = []
        for tab in stale {
            if tab.id == tabStore.list.activeID {
                if text != savedText { unsaved.append((tab.path, text)) }
                savedText = text
                if let moved = tabStore.list.tabs.first(where: { mapped.contains($0.id) && $0.path == tab.path }) {
                    tabStore.list.close(tab.id, remember: false)
                    tabStore.list.activate(moved.id)
                    showActiveTab()
                    continue
                }
            } else if let text = tab.state.unsavedText {
                unsaved.append((tab.path, text))
            }
            tabStore.list.close(tab.id, remember: false)
        }
        if !unsaved.isEmpty {
            Self.keepUnsavedElsewhere(unsaved, { Self.unreadableDocumentAlert(documents: unsaved) }) {}
        }
    }

    /// Text that is not on disk: the open document's edits and tabs whose saves failed.
    func unsavedDocuments() -> [(path: String, text: String)] {
        var documents: [(path: String, text: String)] = []
        if let current = currentFile?.path, text != savedText { documents.append((current, text)) }
        for tab in tabStore.list.tabs where tab.id != tabStore.list.activeID {
            if let unsaved = tab.state.unsavedText { documents.append((tab.path, unsaved)) }
        }
        return documents
    }

    /// Writes each document's text to where `move` took its file, and returns the documents it
    /// couldn't write, so the caller can keep them some other way.
    func writeUnsaved(_ documents: [(path: String, text: String)], through move: PathMove) -> [(path: String, text: String)] {
        documents.filter { document in
            guard let target = move.map(document.path) else { return true }
            return (try? TextFile.writeKeepingFormat(document.text, toPath: target)) == nil
        }
    }

    /// Closes a project whose folder is gone, first offering to save `documents` elsewhere.
    private func closeProjectKeeping(_ documents: [(path: String, text: String)], name: String) {
        guard !documents.isEmpty else { closeProject(); return }
        let root = rootURL
        Self.keepUnsavedElsewhere(documents, { Self.missingProjectAlert(name: name, documents: documents) }) { [weak self] in
            // Another project may have been opened while the question showed; it stays open.
            guard let self, self.rootURL == root else { return }
            self.closeProject()
        }
    }

    /// Offers to save text that lost its file in another folder, then runs `finish`. There is no
    /// Cancel: the file is already gone, so the text is either kept elsewhere or discarded.
    /// Replaced in tests.
    static var keepUnsavedElsewhere: (
        _ documents: [(path: String, text: String)], _ alert: @escaping () -> NSAlert, _ finish: @escaping () -> Void
    ) -> Void = { documents, alert, finish in
        AppModel.shared.askToKeep(documents, alert: alert, then: finish)
    }

    private func askToKeep(_ documents: [(path: String, text: String)], alert: @escaping () -> NSAlert, then finish: @escaping () -> Void) {
        present(alert()) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else { finish(); return }
            let panel = Self.unsavedDocumentsFolderPanel()
            self.present(panel) { [weak self] response in
                guard let self else { return }
                guard response == .OK, let folder = panel.url else {
                    self.askToKeep(documents, alert: alert, then: finish)
                    return
                }
                do {
                    for document in documents {
                        let file = (document.path as NSString).lastPathComponent as NSString
                        let target = FileOperations.uniqueURL(in: folder, base: file.deletingPathExtension, extension: file.pathExtension)
                        try document.text.write(to: target, atomically: true, encoding: .utf8)
                    }
                    finish()
                } catch {
                    // Ask again once the error has been read, so the text is never dropped.
                    self.present(NSAlert(error: error)) { [weak self] _ in self?.askToKeep(documents, alert: alert, then: finish) }
                }
            }
        }
    }

    /// The project folder is gone and some text was never written. There is no Cancel: the
    /// project can't stay open, so the text is either kept elsewhere or discarded.
    static func missingProjectAlert(name: String, documents: [(path: String, text: String)]) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(name)” is no longer available"
        let what = documents.count == 1
            ? "Changes to “\((documents[0].path as NSString).lastPathComponent)”"
            : "Changes to \(documents.count) documents"
        alert.informativeText = "\(what) couldn’t be saved because the project folder is gone. Save them in another folder to keep them."
        alert.addButton(withTitle: "Save to Folder…")
        alert.addDestructiveButton("Discard Changes")
        return alert
    }

    /// An item went to the Trash, but some of its documents' unsaved text couldn't go with it.
    static func trashedItemAlert(name: String, documents: [(path: String, text: String)]) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(name)” is in the Trash"
        let what = documents.count == 1
            ? "Changes to “\((documents[0].path as NSString).lastPathComponent)”"
            : "Changes to \(documents.count) documents"
        alert.informativeText = "\(what) couldn’t be saved with it. Save them in another folder to keep them."
        alert.addButton(withTitle: "Save to Folder…")
        alert.addDestructiveButton("Discard Changes")
        return alert
    }

    /// Asks for a folder to keep documents that can't be saved in place.
    static func unsavedDocumentsFolderPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save"
        panel.message = "Choose a folder for the unsaved documents."
        return panel
    }

    /// Closes the open project; its unsaved changes have already been kept or discarded.
    private func closeProject() {
        savedText = text
        closeTabsForProjectChange()
        fileUndoManager?.removeAllActions(withTarget: self)
        sidebarFiles.pendingLinkUpdates = [:]
        watcher = nil
        scanTask?.cancel()
        scanTask = nil
        rescanTask?.cancel()
        if isQuickSearchVisible { closeQuickSearch() }
        rootURL = nil
        tree = []
        filter = ""
        expanded = []
        isScanning = false
        defaults.removeObject(forKey: Keys.root)
        gitProjectScanned()
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
        alert.addCancelButton()
        present(alert) { response in
            if response == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
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

    /// Loads a document into the editor and preview. `recordsHistory` is false for Back and
    /// Forward, and for a tab's own document, whose history the tab restores.
    func load(_ url: URL, recordsHistory: Bool = true) {
        saveNow()
        guard let file = TextFile.read(url) else {
            NSSound.beep()
            return
        }
        let content = file.text
        currentFile = url
        text = content
        savedText = content
        loadedText = content
        documentFormat = file.format
        savedStamp = FileStamp(url)
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
        recordVisit(url.path, recordsHistory: recordsHistory)
        tabDidLoad(url)
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
        guard currentFile != nil, text != savedText else {
            // Back to the text on disk, as after an undo: nothing is left unsaved.
            if saveError != nil { saveError = nil }
            return
        }
        // Another app may have moved the file since the last event: follow it rather than
        // recreating it here.
        if let path = currentFile?.path, !FileManager.default.fileExists(atPath: path) { followMovedDocuments() }
        guard let url = currentFile, !sidebarFiles.isTrashing(url.path) else { return }
        if let disk = changedOnDisk(url) {
            askAboutExternalChange(disk)
            return
        }
        do {
            // Write in place so file watchers see a modification rather than a replace.
            try TextFile.writeInPlace(text, to: url, as: documentFormat)
            savedText = text
            savedStamp = FileStamp(url)
            if saveError != nil { saveError = nil }
            if isCurrentDocumentMissing { updateMissingDocuments() }
            git.documentSaved()
        } catch {
            saveError = "Couldn’t save: \(error.localizedDescription)"
        }
    }

    private func reloadFromDiskIfNeeded() {
        guard let url = currentFile, let disk = TextFile.read(url), disk.text != savedText else { return }
        guard text == savedText else {
            // Both changed: ask before either version is lost.
            askAboutExternalChange(disk)
            return
        }
        useVersionOnDisk(disk, of: url)
    }

    private func useVersionOnDisk(_ disk: TextFile, of url: URL) {
        text = disk.text
        savedText = disk.text
        loadedText = disk.text
        documentFormat = disk.format
        savedStamp = FileStamp(url)
        if saveError != nil { saveError = nil }
        editor.replaceText(disk.text)
        if isFindBarVisible { refreshFind(scroll: false) }
        render(debounce: false)
    }

    /// LexMD itself rewrote these files, as a link update and its undo do. For the open
    /// document that version is known, so it isn't taken for another app's change.
    func acceptOwnWrites(_ paths: [String]) {
        guard let url = currentFile, paths.contains(url.path), let disk = TextFile.read(url) else { return }
        if text == savedText {
            useVersionOnDisk(disk, of: url)
        } else {
            savedText = disk.text
            loadedText = disk.text
            documentFormat = disk.format
            savedStamp = FileStamp(url)
        }
    }

    /// The file's text when another app changed it since LexMD last read or wrote it.
    private func changedOnDisk(_ url: URL) -> TextFile? {
        guard let savedStamp, FileStamp(url) != savedStamp, let disk = TextFile.read(url), disk.text != savedText else { return nil }
        return disk
    }

    /// Another app changed the open document while it had unsaved edits. Nothing is written
    /// until the user picks a version.
    private func askAboutExternalChange(_ disk: TextFile) {
        guard !isAskingAboutExternalChange, let url = currentFile else { return }
        isAskingAboutExternalChange = true
        saveError = "Changed by another app"
        Self.askAboutExternalChange(url.lastPathComponent) { [weak self] keepMine in
            guard let self else { return }
            self.isAskingAboutExternalChange = false
            guard self.currentFile == url else { return }
            if keepMine {
                // Writing over the other version is now intended.
                self.savedStamp = FileStamp(url)
                self.savedText = TextFile.read(url)?.text ?? self.savedText
                self.saveNow()
            } else if let latest = TextFile.read(url) {
                self.useVersionOnDisk(latest, of: url)
            }
        }
    }

    /// Asks whether to keep LexMD's edits or the version another app saved; `true` keeps
    /// LexMD's. Replaced in tests.
    static var askAboutExternalChange: (_ name: String, _ reply: @escaping (Bool) -> Void) -> Void = { name, reply in
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(name)” was changed by another app"
        alert.informativeText = "It has edits in LexMD that aren’t saved yet. Keep your edits to save them over the other version, or use the other version and lose your edits."
        alert.addButton(withTitle: "Keep My Edits")
        alert.addDestructiveButton("Use Other Version")
        AppModel.shared.present(alert) { reply($0 == .alertFirstButtonReturn) }
    }

    func render(debounce: Bool) {
        renderTask?.cancel()
        renderGeneration += 1
        let generation = renderGeneration
        let document = currentFile?.path
        let source = text
        let base = currentFile?.deletingLastPathComponent()
        let links = linkContext(for: source)
        scheduleOutlineUpdate(debounce: debounce)
        renderTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(nanoseconds: 90_000_000)
                guard !Task.isCancelled else { return }
            }
            let (rendered, words) = await runDetached {
                (MarkdownHTML.renderWithSourceLines(source, links: links), MarkdownHTML.wordCount(source))
            }
            guard let self, !Task.isCancelled else { return }
            let reset = self.pendingScrollReset
            self.pendingScrollReset = false
            self.preview.setDocumentTitle(self.currentFile == nil ? "" : self.title)
            self.preview.render(
                html: rendered.html, baseURL: base, resetScroll: reset, document: document, generation: generation,
                lineCount: rendered.lineCount
            )
            if self.wordCount != words { self.wordCount = words }
        }
    }

    // MARK: - View settings

    /// `focusesEditor` is false when the find bar keeps focus, as when Replace shows the source.
    func setViewMode(_ mode: ViewMode, focusesEditor: Bool = true) {
        guard viewMode != mode else { return }
        viewMode = mode
        defaults.set(mode.rawValue, forKey: Keys.viewMode)
        if isFindBarVisible { refreshFind(scroll: false) }
        if mode != .read, focusesEditor { editor.whenVisible { [weak self] in self?.editor.focus() } }
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

    private func recordVisit(_ path: String, recordsHistory: Bool) {
        recentFiles = Array(([path] + recentFiles.filter { $0 != path }).prefix(30))
        defaults.set(recentFiles, forKey: Keys.recentFiles)
        guard recordsHistory else { return }
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
        let target = history[index]
        open(URL(fileURLWithPath: target), placement: .active, recordsHistory: false)
        // Moved only once the document shows: a file that can't be read leaves Back where it was.
        if currentFile?.path == target, history.indices.contains(index), history[index] == target { historyIndex = index }
    }

    func toggleSidebar() {
        withMotion(.snappy(duration: 0.25)) {
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

    /// Creates "Untitled.md" next to the open document, or at the top of the project, selects it,
    /// and starts naming it in the sidebar, as the sidebar's New Document does.
    func newDocument() {
        guard rootURL != nil else { showOpenPanel(); return }
        newFile(near: currentFile)
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

/// A file's modification date and size, to notice changes made by other apps.
struct FileStamp: Equatable {
    var modified: Date
    var size: Int

    init?(_ url: URL) {
        // Read the file system each time: URL resource values are cached per URL.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        self.modified = modified
        size = (attributes[.size] as? NSNumber)?.intValue ?? 0
    }
}
