import AppKit
import Observation
import SwiftUI

/// State of one open commit sheet.
@MainActor
@Observable
final class CommitSession: Identifiable {
    let id = UUID()
    let git: Git
    let projectRoot: String
    let repositories: [GitRepository]
    var repository: GitRepository {
        didSet {
            guard repository != oldValue else { return }
            // A commit in progress keeps its repository: its result is reported for it.
            guard !isCommitting else { repository = oldValue; return }
            userChoices = [:]
            selection = nil
            reload()
        }
    }

    private(set) var snapshot: GitStatusSnapshot?
    private(set) var identity: GitIdentity?
    private(set) var operation: String?
    private(set) var isLoading = true
    private(set) var loadFailed = false
    var checked: Set<String> = []
    var selection: String? {
        didSet { if selection != oldValue { loadDiff() } }
    }
    private(set) var diff: GitDiff?
    var summary = ""
    var details = ""
    var identityName = ""
    var identityEmail = ""
    var isEditingIdentity = false
    private(set) var isCommitting = false
    private(set) var errorText: String?
    private(set) var confirmation: String?

    @ObservationIgnored private var userChoices: [String: Bool] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var diffTask: Task<Void, Never>?
    /// Saves open documents before committing.
    @ObservationIgnored var saveDocuments: () -> Void = { AppModel.shared.saveAllTabs() }

    init(git: Git, projectRoot: String, repositories: [GitRepository], repository: GitRepository) {
        self.git = git
        self.projectRoot = projectRoot
        self.repositories = repositories
        self.repository = repository
        reload()
    }

    var changes: [GitFileChange] { snapshot?.documentChanges ?? [] }
    var selectedChanges: [GitFileChange] { changes.filter { checked.contains($0.path) } }

    var branchLabel: String {
        guard let snapshot else { return "" }
        return snapshot.branch ?? "detached HEAD"
    }

    /// Why committing is impossible right now, if it is.
    var blockReason: String? {
        if let operation {
            return "\(operation) is in progress. Finish it in Terminal or another Git app, then commit here."
        }
        if snapshot?.hasConflicts == true { return "Resolve the conflicted files before committing." }
        return nil
    }

    var canCommit: Bool {
        !isCommitting && !isLoading && identity != nil && blockReason == nil
            && !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !selectedChanges.isEmpty
    }

    func isChecked(_ change: GitFileChange) -> Bool { checked.contains(change.path) }

    func setChecked(_ change: GitFileChange, _ value: Bool) {
        userChoices[change.path] = value
        if value { checked.insert(change.path) } else { checked.remove(change.path) }
    }

    func setAllChecked(_ value: Bool) {
        for change in changes { setChecked(change, value) }
    }

    /// Reloads in the background when files may have changed, keeping the sheet usable.
    func refresh() {
        guard !isCommitting else { return }
        reload(showsProgress: false)
    }

    func reload(showsProgress: Bool = true) {
        loadTask?.cancel()
        if showsProgress { isLoading = true }
        let git = git
        let repo = repository
        let root = projectRoot
        loadTask = Task { [weak self] in
            let (snapshot, identity, operation) = await runDetached {
                (GitDiscovery.status(git: git, repository: repo, projectRoot: root, timeout: 60),
                 GitOperations.identity(git: git, repository: repo.root),
                 GitOperations.operationInProgress(git: git, repository: repo.root))
            }
            guard let self, !Task.isCancelled, self.repository == repo else { return }
            self.isLoading = false
            self.loadFailed = snapshot == nil
            self.snapshot = snapshot
            self.identity = identity
            self.operation = operation
            if identity == nil || identity?.isConfigured == false {
                if self.identityName.isEmpty { self.identityName = identity?.name ?? "" }
                if self.identityEmail.isEmpty { self.identityEmail = identity?.email ?? "" }
            }
            let changes = snapshot?.documentChanges ?? []
            let defaults = GitStatusSnapshot.checkedByDefault(changes)
            self.checked = Set(changes.filter { self.userChoices[$0.path] ?? defaults.contains($0.path) }.map(\.path))
            if let selection = self.selection, changes.contains(where: { $0.path == selection }) {
                self.loadDiff()
            } else {
                self.selection = changes.first { $0.isMarkdown }?.path ?? changes.first?.path
                if self.selection == nil { self.diff = nil }
            }
        }
    }

    private func loadDiff() {
        diffTask?.cancel()
        guard let path = selection, let change = changes.first(where: { $0.path == path }) else {
            diff = nil
            return
        }
        let git = git
        let repo = repository.root
        let hasHead = snapshot?.head != nil
        diffTask = Task { [weak self] in
            let result = await runDetached {
                GitOperations.diff(git: git, repository: repo, change: change, hasHead: hasHead)
            }
            guard let self, !Task.isCancelled, self.selection == path else { return }
            self.diff = result
        }
    }

    func saveIdentity() {
        let name = identityName.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = identityEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !email.isEmpty else { return }
        let git = git
        let repo = repository.root
        errorText = nil
        Task { [weak self] in
            let error = await runDetached { GitOperations.setIdentity(git: git, repository: repo, name: name, email: email) }
            guard let self else { return }
            if let error { self.errorText = error } else { self.isEditingIdentity = false }
            self.reload()
        }
    }

    func commit() {
        guard canCommit else { return }
        saveDocuments()
        let git = git
        let repo = repository
        let changes = selectedChanges
        let message = GitOperations.message(summary: summary, description: details)
        let branch = branchLabel
        isCommitting = true
        errorText = nil
        confirmation = nil
        // Not tied to the sheet: closing it must not interrupt a commit halfway.
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                GitOperations.commit(git: git, repository: repo.root, changes: changes, message: message)
            }.value
            // The sidebar updates even when the sheet was closed while committing.
            GitModel.shared.refreshNow()
            guard let self else { return }
            self.isCommitting = false
            switch result {
            case .success(let hash):
                var note = "Committed"
                if !hash.isEmpty { note += " \(hash)" }
                if !branch.isEmpty { note += " on \(branch)" }
                self.confirmation = note + "."
                self.summary = ""
                self.details = ""
                self.userChoices = [:]
                self.reload()
            case .failure(let error):
                self.errorText = error.message
            }
        }
    }
}

// MARK: - Views

/// Presents the commit sheet for the main window.
struct CommitSheetPresenter: ViewModifier {
    func body(content: Content) -> some View {
        let git = GitModel.shared
        content.sheet(item: Binding(
            get: { git.commitSession },
            set: { if $0 == nil { git.commitSheetClosed() } }
        )) { session in
            CommitSheet(session: session)
        }
    }
}

struct CommitToolbarButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.showCommitSheet() } label: {
            Label("Commit…", systemImage: "checkmark.circle")
        }
        .help(model.helpText("Commit changes", .commit))
    }
}

/// A letter for a changed file, or a dot for a folder that contains changes.
struct GitBadgeView: View {
    let path: String
    let isFolder: Bool

    var body: some View {
        let git = GitModel.shared
        if isFolder {
            if git.folderHasChanges(path) {
                Circle()
                    .fill(Color.secondary.opacity(0.7))
                    .frame(width: 6, height: 6)
                    .padding(.trailing, 3)
                    .help("Contains changes")
                    .accessibilityLabel("Contains changes")
            }
        } else if let kind = git.badge(for: path) {
            GitKindLabel(kind: kind)
        }
    }
}

struct GitKindLabel: View {
    let kind: GitChangeKind

    var body: some View {
        Text(kind.letter)
            .font(.system(.caption, design: .monospaced, weight: .semibold))
            .foregroundStyle(kind.color)
            .frame(minWidth: 12)
            .help(kind.help)
            .accessibilityLabel(kind.label)
    }
}

struct CommitSheet: View {
    @Bindable var session: CommitSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetHeightLimit) private var heightLimit
    @FocusState private var summaryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            Divider()
            HSplitView {
                fileList
                    .frame(minWidth: 220, idealWidth: 290, maxWidth: 420, maxHeight: .infinity, alignment: .top)
                diffPane
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity)
            Divider()
            messageArea
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        // Never larger than the window it is on, down to the window's minimum size.
        .frame(
            minWidth: WindowLayout.minWidth - 40, idealWidth: 920,
            minHeight: min(460, heightLimit), idealHeight: min(700, heightLimit), maxHeight: heightLimit
        )
        .onAppear { summaryFocused = true }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                if session.repositories.count > 1 {
                    Picker("Repository", selection: $session.repository) {
                        ForEach(session.repositories) { repo in
                            Text(relativeName(repo)).tag(repo)
                        }
                    }
                    .fixedSize()
                    // The commit and its result belong to the repository it started in.
                    .disabled(session.isCommitting)
                } else {
                    Label(session.repository.name, systemImage: "folder")
                        .font(.headline)
                }
                if !session.branchLabel.isEmpty {
                    Label(session.branchLabel, systemImage: "arrow.triangle.branch")
                        .foregroundStyle(.secondary)
                        .help(session.snapshot?.branch == nil ? "HEAD is not on a branch" : "Current branch")
                    if session.snapshot?.head == nil {
                        Text("No commits yet").foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if session.isLoading { ProgressView().controlSize(.small) }
            }
            identityRow
        }
    }

    private func relativeName(_ repo: GitRepository) -> String {
        if repo.root.hasPrefix(session.projectRoot + "/") {
            return String(repo.root.dropFirst(session.projectRoot.count + 1))
        }
        return repo.name
    }

    @ViewBuilder
    private var identityRow: some View {
        if let identity = session.identity, !session.isEditingIdentity {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                Text("Author:").foregroundStyle(.secondary)
                Text("\(identity.name) <\(identity.email)>")
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !identity.isConfigured {
                    Text("Guessed from your Mac account.").foregroundStyle(.secondary)
                }
                Spacer()
                Button(identity.isConfigured ? "Change…" : "Set for This Repository…") {
                    session.identityName = identity.name
                    session.identityEmail = identity.email
                    session.isEditingIdentity = true
                }
                .controlSize(.small)
            }
            .font(.callout)
        } else if !session.isLoading || session.isEditingIdentity {
            VStack(alignment: .leading, spacing: 6) {
                if session.identity == nil {
                    Label("Git has no name and email for commits in this repository.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                HStack(spacing: 8) {
                    TextField("Name", text: $session.identityName)
                        .frame(width: 180)
                    TextField("Email", text: $session.identityEmail)
                        .frame(width: 220)
                    Button("Set for This Repository") { session.saveIdentity() }
                        .disabled(session.identityName.trimmingCharacters(in: .whitespaces).isEmpty
                            || session.identityEmail.trimmingCharacters(in: .whitespaces).isEmpty)
                    if session.isEditingIdentity, session.identity != nil {
                        Button("Cancel") { session.isEditingIdentity = false }
                    }
                }
                .textFieldStyle(.roundedBorder)
                Text("Saved in this repository’s Git configuration only. Other repositories are not affected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    // MARK: Files

    private var fileList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(countLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                let allChecked = !session.changes.isEmpty && session.selectedChanges.count == session.changes.count
                Button(allChecked ? "Deselect All" : "Select All") { session.setAllChecked(!allChecked) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(session.changes.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            List(selection: $session.selection) {
                ForEach(session.changes) { change in
                    CommitFileRow(change: change, isChecked: Binding(
                        get: { session.isChecked(change) },
                        set: { session.setChecked(change, $0) }
                    ))
                    .tag(change.path)
                }
            }
            .listStyle(.inset)
            .frame(maxHeight: .infinity)
            .overlay {
                if !session.isLoading, session.changes.isEmpty {
                    ContentUnavailableView(
                        session.loadFailed ? "Status Unavailable" : "No Changes",
                        systemImage: session.loadFailed ? "exclamationmark.triangle" : "checkmark.circle",
                        description: Text(session.loadFailed ? "Git could not read this repository." : "No Markdown or image changes to commit.")
                    )
                }
            }
        }
    }

    private var countLabel: String {
        Self.countLabel(selected: session.selectedChanges.count, total: session.changes.count)
    }

    static func countLabel(selected: Int, total: Int) -> String {
        total == 0 ? "No changed files" : "\(selected) of \(total) selected"
    }

    // MARK: Diff

    @ViewBuilder
    private var diffPane: some View {
        if let diff = session.diff {
            if diff.isBinary || diff.lines.isEmpty {
                ContentUnavailableView(diff.note ?? "No Differences", systemImage: diff.isBinary ? "doc.zipper" : "doc")
            } else {
                DiffView(diff: diff)
            }
        } else if session.selection == nil {
            ContentUnavailableView("No File Selected", systemImage: "doc.text", description: Text("Select a file to see its changes."))
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Message

    private var messageArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Summary", text: $session.summary, prompt: Text("Summary (required)"))
                    .textFieldStyle(.roundedBorder)
                    .focused($summaryFocused)
                let count = session.summary.count
                if count > 50 {
                    // Past 72 characters a symbol joins the color, so the warning never relies on hue alone.
                    HStack(spacing: 3) {
                        if count > 72 { Image(systemName: "exclamationmark.triangle.fill") }
                        Text("\(count)")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(count > 72 ? .orange : .secondary)
                    .help("Short summaries of 50 characters or fewer read best in Git history.")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(count > 72 ? "\(count) characters, longer than 72" : "\(count) characters")
                }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $session.details)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                if session.details.isEmpty {
                    Text("Description (optional)")
                        .foregroundStyle(Color(nsColor: .placeholderTextColor))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 70)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            .accessibilityLabel("Description")

            statusLine

            HStack {
                Spacer()
                Button(session.confirmation == nil ? "Cancel" : "Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    // Closing mid-commit would hide how it ended; the commit itself can't be stopped.
                    .disabled(session.isCommitting)
                Button(commitTitle) { session.commit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!session.canCommit)
                    .help("Commit the checked files (⌘↩)")
            }
        }
    }

    private var commitTitle: String {
        Self.commitTitle(count: session.selectedChanges.count, isCommitting: session.isCommitting)
    }

    static func commitTitle(count: Int, isCommitting: Bool) -> String {
        if isCommitting { return "Committing…" }
        guard count > 0 else { return "Commit" }
        return String(AttributedString(localized: "Commit ^[\(count) File](inflect: true)").characters)
    }

    @ViewBuilder
    private var statusLine: some View {
        if let error = session.errorText {
            ScrollView {
                Text(error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 80)
            .fixedSize(horizontal: false, vertical: true)
        } else if let reason = session.blockReason {
            Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
        } else if let confirmation = session.confirmation {
            Label(confirmation, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
        }
    }
}

private struct CommitFileRow: View {
    let change: GitFileChange
    @Binding var isChecked: Bool

    var body: some View {
        HStack(spacing: 6) {
            Toggle("Include \(change.name)", isOn: $isChecked)
                .toggleStyle(.checkbox)
                .labelsHidden()
            GitKindLabel(kind: change.kind)
            VStack(alignment: .leading, spacing: 1) {
                Text(change.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                let folder = (change.path as NSString).deletingLastPathComponent
                if let original = change.originalPath {
                    Text("from \(original)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                } else if !folder.isEmpty {
                    Text(folder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
        .help("\(change.kind.label): \(change.path)")
    }
}

/// A unified diff with added and removed lines colored.
struct DiffView: View {
    let diff: GitDiff

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in
                    DiffLine(text: line)
                }
                if let note = diff.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }
            .padding(.vertical, 6)
            .textSelection(.enabled)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct DiffLine: View {
    let text: String

    var body: some View {
        let style = Self.style(for: text)
        Text(text.isEmpty ? " " : text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(style.foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .background(style.background)
    }

    private static func style(for line: String) -> (foreground: Color, background: Color) {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ")
            || line.hasPrefix("new file") || line.hasPrefix("deleted file") || line.hasPrefix("similarity")
            || line.hasPrefix("rename ") || line.hasPrefix("old mode") || line.hasPrefix("new mode") {
            return (.secondary, .clear)
        }
        if line.hasPrefix("@@") { return (.blue, Color.blue.opacity(0.06)) }
        if line.hasPrefix("+") { return (.primary, Color.green.opacity(0.16)) }
        if line.hasPrefix("-") { return (.primary, Color.red.opacity(0.16)) }
        if line.hasPrefix("\\") { return (.secondary, .clear) }
        return (.primary, .clear)
    }
}
