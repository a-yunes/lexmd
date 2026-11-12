import AppKit
import CoreServices
import Foundation
import Observation

/// Git state for the open project: repositories, sidebar badges, and the commit sheet.
@MainActor
@Observable
final class GitModel {
    static let shared = GitModel()

    /// The located git, or nil when git is unavailable (all git UI is then hidden).
    private(set) var tool: Git?
    private(set) var repositories: [GitRepository] = []
    private(set) var snapshots: [String: GitStatusSnapshot] = [:]
    /// Absolute file path to its change, for files inside the project.
    private(set) var badges: [String: GitChangeKind] = [:]
    /// Folders inside the project that contain changed Markdown files.
    private(set) var changedFolders: Set<String> = []
    var commitSession: CommitSession?
    private(set) var isDiscovering = false

    @ObservationIgnored private var projectRoot: String?
    @ObservationIgnored private var folders: [String] = []
    @ObservationIgnored private var statusEnabled = true
    @ObservationIgnored private var discoverTask: Task<Void, Never>?
    @ObservationIgnored private var rediscoverTask: Task<Void, Never>?
    @ObservationIgnored private var scheduledTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var needsAnotherStatus = false
    @ObservationIgnored private var lastStatusEnd = Date.distantPast
    @ObservationIgnored private var lastStatusDuration: TimeInterval = 0
    @ObservationIgnored private var activeObserver: Any?

    init() {
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // A repository may have been created or removed while LexMD was in the background.
            MainActor.assumeIsolated { self?.discover() }
        }
    }

    var isAvailable: Bool { tool != nil }
    /// Git UI exists only when git works and the project contains a repository.
    var isActive: Bool { isAvailable && !repositories.isEmpty }
    var showsStatus: Bool { statusEnabled && isActive }

    /// The innermost repository containing `path`.
    func repository(containing path: String) -> GitRepository? {
        repositories.filter { $0.contains(path) }.max { $0.root.count < $1.root.count }
    }

    /// The repository the Commit command applies to: the current document's, or with no
    /// document open, the first one with changes. Nil for a document outside every repository.
    func commitTarget(currentFile: String?) -> GitRepository? {
        guard isActive else { return nil }
        if let currentFile { return repository(containing: currentFile) }
        return repositories.first { hasDocumentChanges($0) } ?? repositories.first
    }

    /// Whether the repository has Markdown or image changes to commit.
    func hasDocumentChanges(_ repository: GitRepository) -> Bool {
        !(snapshots[repository.root]?.documentChanges.isEmpty ?? true)
    }

    /// Commit is offered only when the target repository has document changes. Without a
    /// status snapshot (status off or not loaded yet) it stays available and the sheet checks.
    func canCommit(currentFile: String?) -> Bool {
        guard let target = commitTarget(currentFile: currentFile) else { return false }
        guard snapshots[target.root] != nil else { return true }
        return hasDocumentChanges(target)
    }

    /// The toolbar button shows only when the target repository has document changes.
    func showsCommitButton(currentFile: String?) -> Bool {
        guard showsStatus, let target = commitTarget(currentFile: currentFile) else { return false }
        return hasDocumentChanges(target)
    }

    func badge(for path: String) -> GitChangeKind? { showsStatus ? badges[path] : nil }
    func folderHasChanges(_ path: String) -> Bool { showsStatus && changedFolders.contains(path) }

    // MARK: - Project

    /// Called after every tree scan. Rediscovers repositories when the folders changed.
    func projectScanned(root: String?, tree: [FileNode], statusEnabled: Bool) {
        self.statusEnabled = statusEnabled
        let newFolders = FileScanner.folderIDs(in: tree).sorted()
        guard root != projectRoot || newFolders != folders || (tool == nil && discoverTask == nil) else { return }
        if root != projectRoot { clear() }
        projectRoot = root
        folders = newFolders
        discover()
    }

    func setStatusEnabled(_ enabled: Bool) {
        statusEnabled = enabled
        if enabled {
            refreshNow()
        } else {
            scheduledTask?.cancel()
            scheduledTask = nil
            statusTask?.cancel()
            snapshots = [:]
            badges = [:]
            changedFolders = []
        }
    }

    private func clear() {
        discoverTask?.cancel()
        discoverTask = nil
        scheduledTask?.cancel()
        scheduledTask = nil
        statusTask?.cancel()
        repositories = []
        snapshots = [:]
        badges = [:]
        changedFolders = []
    }

    /// Rediscovers shortly after a repository appears or disappears, once git has finished
    /// writing it.
    private func scheduleDiscover() {
        rediscoverTask?.cancel()
        rediscoverTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.discover()
        }
    }

    private func discover() {
        discoverTask?.cancel()
        guard let root = projectRoot else { isDiscovering = false; return }
        let folders = folders
        let located = tool
        isDiscovering = true
        discoverTask = Task { [weak self] in
            let (git, repos) = await runDetached(priority: .utility) { () -> (Git?, [GitRepository]) in
                guard let git = located ?? Git.system else { return (nil, []) }
                return (git, GitDiscovery.repositories(git: git, projectRoot: root, folders: folders))
            }
            guard let self, !Task.isCancelled, self.projectRoot == root else { return }
            self.discoverTask = nil
            self.isDiscovering = false
            if self.tool == nil { self.tool = git }
            if repos != self.repositories {
                self.repositories = repos
                self.snapshots = self.snapshots.filter { key, _ in repos.contains { $0.root == key } }
                if repos.isEmpty {
                    self.badges = [:]
                    self.changedFolders = []
                }
            }
            self.refreshNow()
        }
    }

    // MARK: - Status refresh

    func documentSaved() { scheduleStatus(after: 0.3) }

    func fileEvents(_ events: [DirectoryWatcher.Event]) {
        guard !events.isEmpty else { return }
        // A repository was created or removed inside the project.
        let structural = kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
            | kFSEventStreamEventFlagItemRenamed
        let changesRepository = events.contains { event in
            Int(event.flags) & structural != 0
                && ((event.path as NSString).lastPathComponent == ".git" || event.path.hasSuffix("/.git/HEAD"))
        }
        if changesRepository { scheduleDiscover() }
        scheduleStatus(after: 1)
    }

    /// Runs status soon, coalescing bursts and spacing runs by how long the last one took,
    /// so large repositories stay responsive.
    func scheduleStatus(after delay: TimeInterval) {
        guard showsStatus, !repositories.isEmpty, scheduledTask == nil else { return }
        scheduledTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            let spacing = max(2, self.lastStatusDuration * 10)
            let wait = self.lastStatusEnd.addingTimeInterval(spacing).timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            self.scheduledTask = nil
            self.runStatus()
        }
    }

    /// Refreshes status right away, after a commit or when settings change.
    func refreshNow() {
        scheduledTask?.cancel()
        scheduledTask = nil
        runStatus()
    }

    private func runStatus() {
        guard showsStatus, let git = tool, let root = projectRoot, !repositories.isEmpty else { return }
        if statusTask != nil {
            needsAnotherStatus = true
            return
        }
        let repos = repositories
        let started = Date()
        statusTask = Task { [weak self] in
            let result = await runDetached(priority: .utility) {
                () -> (snapshots: [String: GitStatusSnapshot], badges: [String: GitChangeKind], folders: Set<String>) in
                var pairs: [(GitRepository, GitStatusSnapshot)] = []
                for repo in repos {
                    guard !Task.isCancelled else { break }
                    if let snapshot = GitDiscovery.status(git: git, repository: repo, projectRoot: root, timeout: 20) {
                        pairs.append((repo, snapshot))
                    }
                }
                let decorations = GitDiscovery.decorations(snapshots: pairs, projectRoot: root)
                let byRoot = Dictionary(pairs.map { ($0.0.root, $0.1) }, uniquingKeysWith: { a, _ in a })
                return (byRoot, decorations.badges, decorations.folders)
            }
            guard let self else { return }
            self.statusTask = nil
            self.lastStatusEnd = Date()
            self.lastStatusDuration = self.lastStatusEnd.timeIntervalSince(started)
            let again = self.needsAnotherStatus
            self.needsAnotherStatus = false
            defer { if again { self.runStatus() } }
            guard !Task.isCancelled, self.projectRoot == root, self.statusEnabled else { return }
            if result.snapshots != self.snapshots { self.snapshots = result.snapshots }
            if result.badges != self.badges { self.badges = result.badges }
            if result.folders != self.changedFolders { self.changedFolders = result.folders }
        }
    }

    // MARK: - Commit sheet

    func presentCommitSheet(currentFile: String?) {
        guard let git = tool, let root = projectRoot,
              let preferred = commitTarget(currentFile: currentFile) else { NSSound.beep(); return }
        commitSession = CommitSession(git: git, projectRoot: root, repositories: repositories, repository: preferred)
    }

    func commitSheetClosed() {
        commitSession = nil
        refreshNow()
    }
}

extension AppModel {
    var git: GitModel { GitModel.shared }

    func gitProjectScanned() {
        git.projectScanned(root: rootURL?.path, tree: tree, statusEnabled: showGitStatus)
    }

    func gitDocumentSaved() { git.documentSaved() }

    func gitFileEvents(_ events: [DirectoryWatcher.Event]) { git.fileEvents(events) }

    func gitSettingChanged() { git.setStatusEnabled(showGitStatus) }

    /// Whether any git UI (menu, setting, badges) is shown for the open project.
    var showsGitCommands: Bool { git.isActive }
    var canCommitCurrentDocument: Bool { git.canCommit(currentFile: currentFile?.path) }
    var showsCommitButton: Bool { git.showsCommitButton(currentFile: currentFile?.path) }

    /// Saves unsaved text in every tab, then opens the commit sheet for the current document's repository.
    func showCommitSheet() {
        saveAllTabs()
        git.presentCommitSheet(currentFile: currentFile?.path)
    }
}
