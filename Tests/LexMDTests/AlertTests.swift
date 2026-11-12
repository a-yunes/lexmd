import AppKit
import Testing
@testable import LexMD

/// Alert buttons, counts in user-facing text, and Git badge letters.
@MainActor
struct AlertTests {
    /// Escape triggers a refusal, Return never triggers a destructive button, and destructive
    /// buttons are marked.
    private func checkConventions(_ alert: NSAlert, destructive: Set<String>, escape: String?) {
        let titles = alert.buttons.map(\.title)
        #expect(Set(alert.buttons.filter(\.hasDestructiveAction).map(\.title)) == destructive, "\(titles)")
        #expect(alert.buttons.filter { $0.keyEquivalent == NSAlert.escapeKey }.map(\.title) == (escape.map { [$0] } ?? []))
        let defaults = alert.buttons.filter { $0.keyEquivalent == "\r" }
        #expect(defaults.count <= 1)
        #expect(defaults.allSatisfy { !$0.hasDestructiveAction }, "\(titles)")
        #expect(!alert.messageText.hasSuffix("."), "titles have no trailing period: \(alert.messageText)")
    }

    @Test func destructiveAlertsAreMarkedAndCancelWithEscape() {
        let trash = AppModel.trashConfirmation(name: "notes.md", isFolder: false)
        #expect(trash.buttons.map(\.title) == ["Move to Trash", "Cancel"])
        checkConventions(trash, destructive: [], escape: "Cancel")
        #expect(trash.buttons.first?.keyEquivalent == "\r", "Return confirms an undoable Move to Trash")

        let discard = AppModel.discardConfirmation("notes")
        #expect(discard.buttons.map(\.title) == ["Discard Changes", "Cancel"])
        checkConventions(discard, destructive: ["Discard Changes"], escape: "Cancel")

        let unsaved = AppModel.unsavedTextAlert([("/p/a.md", "x")], "quit")
        #expect(unsaved.buttons.map(\.title) == ["Save to Folder…", "Discard Changes", "Cancel"])
        #expect(unsaved.buttons[0].keyEquivalent == "\r", "keeping the text is the default")
        checkConventions(unsaved, destructive: ["Discard Changes"], escape: "Cancel")

        let missing = AppModel.missingProjectAlert(name: "p", documents: [("/p/a.md", "x"), ("/p/b.md", "y")])
        #expect(missing.informativeText.contains("Changes to 2 documents"))
        #expect(missing.buttons[0].keyEquivalent == "\r")
        checkConventions(missing, destructive: ["Discard Changes"], escape: nil)
    }

    @Test func makeDefaultMovesReturn() {
        let alert = NSAlert()
        alert.addDestructiveButton("Replace…")
        let copy = alert.addButton(withTitle: "Copy Command")
        alert.addCancelButton()
        alert.makeDefault(copy)
        checkConventions(alert, destructive: ["Replace…"], escape: "Cancel")
        #expect(copy.keyEquivalent == "\r")
    }

    @Test func linkUpdateAlertCountsAndRefusesWithEscape() {
        let one = AppModel.linkUpdateAlert(LinkUpdatePlan(files: [.init(path: "/p/a.md", count: 1)]), root: "/p")
        #expect(one.messageText == "Update 1 link in 1 document?")
        #expect(one.informativeText == "This link still points to the old location:\n\na.md (1)")
        checkConventions(one, destructive: [], escape: "Don’t Update")
        #expect(one.buttons[0].title == "Update" && one.buttons[0].keyEquivalent == "\r")

        let files = (1...10).map { LinkUpdatePlan.File(path: "/p/d\($0).md", count: 2) }
        let many = AppModel.linkUpdateAlert(LinkUpdatePlan(files: files), root: "/p")
        #expect(many.messageText == "Update 20 links in 10 documents?")
        #expect(many.informativeText.hasPrefix("These links still point"))
        #expect(many.informativeText.hasSuffix("d8.md (2)\nand 2 more"))
    }

    @Test func countsAgreeWithTheirNouns() {
        #expect(AppModel.readingSummary(words: 0) == "0 words · 1 min read")
        #expect(AppModel.readingSummary(words: 1) == "1 word · 1 min read")
        #expect(AppModel.readingSummary(words: 690) == "690 words · 3 min read")

        #expect(CommitSheet.commitTitle(count: 0, isCommitting: false) == "Commit")
        #expect(CommitSheet.commitTitle(count: 1, isCommitting: false) == "Commit 1 File")
        #expect(CommitSheet.commitTitle(count: 3, isCommitting: false) == "Commit 3 Files")
        #expect(CommitSheet.commitTitle(count: 3, isCommitting: true) == "Committing…")
        #expect(CommitSheet.countLabel(selected: 0, total: 0) == "No changed files")
        #expect(CommitSheet.countLabel(selected: 1, total: 2) == "1 of 2 selected")

        #expect(AppModel.linkedImagesNote([]) == nil)
        #expect(AppModel.linkedImagesNote(["a.png"]) == "“a.png” was too large to embed, so the page links to it instead.")
        let two = AppModel.linkedImagesNote(["a.png", "b.png"])
        #expect(two?.hasPrefix("2 images were too large to embed, so the page links to them instead: “a.png”") == true)
        let four = AppModel.linkedImagesNote(["a", "b", "c", "d"])
        #expect(four?.hasSuffix("1 other.") == true)
        let six = AppModel.linkedImagesNote(["a", "b", "c", "d", "e", "f"])
        #expect(six?.hasSuffix("3 others.") == true)

        #expect(AppModel.listing(["a", "b"]) == "a\nb")
        #expect(AppModel.listing(["a", "b", "c"], limit: 2) == "a\nb\nand 1 more")
    }

    /// Untracked files read differently from files added to the index, without relying on color.
    @Test func gitBadgesTellUntrackedFromAdded() {
        #expect(GitChangeKind.added.letter == "A")
        #expect(GitChangeKind.untracked.letter == "?")
        #expect(GitChangeKind.untracked.label == "Untracked")
        #expect(GitChangeKind.untracked.help.hasPrefix("Untracked:"))
        let letters = GitChangeKind.allCases.map(\.letter)
        #expect(Set(letters).count == letters.count, "every kind has its own letter")
        #expect(GitChangeKind.allCases.allSatisfy { $0.help.hasPrefix($0.label + ":") })
    }
}

extension TabCommandTests {
    /// New Document creates "Untitled.md" next to the open document, or at the top of the project,
    /// selects it, and names it inline in the sidebar.
    @Test func newDocumentIsNamedInTheSidebar() async throws {
        let folder = try TestFolder()
        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try folder.write("docs/a.md", "# A\n")
        try folder.write("b.md", "# B\n")
        let model = AppModel.shared
        model.open(folder.url)
        try await waitUntil { FileScanner.paths(in: model.tree).files.count == 2 }
        let root = FileScanner.canonicalPath(folder.url.path)
        let mode = model.viewMode
        // Renames register undo on the window.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let previousSuperview = model.editor.scrollView.superview
        window.contentView = model.editor.scrollView
        defer {
            window.contentView = nil
            if let previousSuperview { previousSuperview.addSubview(model.editor.scrollView) }
            model.setViewMode(mode)
        }
        model.setViewMode(.read)

        model.open(URL(fileURLWithPath: root + "/docs/a.md"))
        model.filter = "zzz"
        model.newDocument()
        let created = root + "/docs/Untitled.md"
        #expect(FileManager.default.fileExists(atPath: created))
        #expect(model.filter.isEmpty, "the filter would hide the new row")
        #expect(model.selectedPath == created)
        #expect(model.currentFile?.path == created)
        #expect(model.sidebarFiles.renamingPath == created)
        #expect(model.sidebarFiles.renameIsNewDocument)

        model.commitRename(created, to: "Plan")
        #expect(FileManager.default.fileExists(atPath: root + "/docs/Plan.md"))
        #expect(!FileManager.default.fileExists(atPath: created))
        #expect(model.currentFile?.path == root + "/docs/Plan.md")
        #expect(model.sidebarFiles.renamingPath == nil)
        #expect(model.viewMode == .split, "naming a new document starts writing in it")

        model.closeTabsForProjectChange()
        model.newDocument()
        #expect(model.sidebarFiles.renamingPath == root + "/Untitled.md", "without a document, it goes at the top")
        model.cancelRename()
        #expect(FileManager.default.fileExists(atPath: root + "/Untitled.md"))
        model.closeTabsForProjectChange()
    }
}

@MainActor
struct CountedTests {
    @Test func countsUseTheMatchingNounForm() {
        #expect(counted(1, "word") == "1 word")
        #expect(counted(0, "word") == "0 words")
        #expect(counted(1234, "word") == "1,234 words")
        #expect(counted(2, "match", plural: "matches") == "2 matches")
        #expect(AppModel.readingSummary(words: 1) == "1 word · 1 min read")
    }
}
