import AppKit
import Testing
@testable import LexMD

/// Open documents whose files change under the app, text that cannot be saved, and link updates
/// that meet open documents; part of the serialized suite.
extension TabCommandTests {
    private func openProject(_ folder: TestFolder, files: Int) async throws -> (AppModel, (String) -> String) {
        let model = AppModel.shared
        model.open(folder.url)
        try await waitUntil { FileScanner.paths(in: model.tree).files.count == files }
        let root = FileScanner.canonicalPath(folder.url.path)
        return (model, { root + "/" + $0 })
    }

    private func type(_ text: String, in model: AppModel) {
        model.editor.textView.string = text
        model.editor.onTextChange?(text)
    }

    /// Another app renames or moves open documents: they are followed, and autosave writes to
    /// the new place instead of recreating the old file.
    @Test func followsDocumentsMovedByOtherApps() async throws {
        let folder = try TestFolder()
        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try folder.write("a.md", "# A\n")
        try folder.write("b.md", "# B\n")
        let (model, path) = try await openProject(folder, files: 2)
        model.open(URL(fileURLWithPath: path("a.md")))
        model.openInNewTab(path("b.md"))
        type("# B edited\n", in: model)

        // Finder moves the open document, and renames the one in the background tab.
        try FileManager.default.moveItem(atPath: path("b.md"), toPath: path("sub") + "/b2.md")
        try FileManager.default.moveItem(atPath: path("a.md"), toPath: path("a2.md"))
        model.saveNow()
        #expect(model.currentFile?.path == path("sub/b2.md"))
        #expect(!FileManager.default.fileExists(atPath: path("b.md")), "autosave did not recreate the old file")
        #expect(try String(contentsOfFile: path("sub/b2.md"), encoding: .utf8) == "# B edited\n")
        #expect(model.tabStore.list.tabs.map(\.path) == [path("a2.md"), path("sub/b2.md")])
        #expect(model.history.allSatisfy { !$0.hasSuffix("/b.md") })
        #expect(model.selectedPath == path("sub/b2.md"))
        #expect(model.tabStore.missing.isEmpty)
        model.closeTabsForProjectChange()
    }

    /// A deleted document keeps its text and is marked; nothing is written until there are
    /// unsaved changes, which then put it back.
    @Test func deletedDocumentIsMarkedAndKeepsItsText() async throws {
        let folder = try TestFolder()
        try folder.write("a.md", "# A\n")
        try folder.write("b.md", "# B\n")
        let (model, path) = try await openProject(folder, files: 2)
        model.open(URL(fileURLWithPath: path("a.md")))
        model.openInNewTab(path("b.md"))

        try FileManager.default.removeItem(atPath: path("b.md"))
        model.followMovedDocuments()
        model.saveNow()
        #expect(!FileManager.default.fileExists(atPath: path("b.md")), "no edits: nothing is recreated")
        #expect(model.isCurrentDocumentMissing)
        #expect(model.subtitle.contains("No longer on disk"))
        #expect(model.text == "# B\n")

        type("# B kept\n", in: model)
        model.saveNow()
        #expect(try String(contentsOfFile: path("b.md"), encoding: .utf8) == "# B kept\n")
        #expect(!model.isCurrentDocumentMissing)
        model.closeTabsForProjectChange()
    }

    /// Opening another project with text that still can't be written asks first: Cancel stays,
    /// Discard goes on, and Save to Folder keeps the text elsewhere.
    @Test func projectSwitchAsksAboutTextThatCannotBeSaved() async throws {
        let folder = try TestFolder()
        let other = try TestFolder()
        let kept = try TestFolder()
        try folder.write("a.md", "# A\n")
        try other.write("c.md", "# C\n")
        let (model, path) = try await openProject(folder, files: 1)
        model.open(URL(fileURLWithPath: path("a.md")))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path("a.md"))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path("a.md")) }
        type("# A unsaved\n", in: model)
        model.saveNow()
        #expect(model.saveError != nil)

        let ask = AppModel.askAboutUnsavedText
        defer { AppModel.askAboutUnsavedText = ask }
        var asked: [[String]] = []
        var answer = UnsavedTextChoice.cancel
        AppModel.askAboutUnsavedText = { documents, _, reply in
            asked.append(documents.map(\.path))
            reply(answer)
        }

        model.open(other.url)
        #expect(asked == [[path("a.md")]])
        #expect(model.rootURL?.path == FileScanner.canonicalPath(folder.url.path), "Cancel keeps the project open")
        #expect(model.text == "# A unsaved\n")

        answer = .saveToFolder(kept.url)
        model.open(other.url)
        #expect(model.rootURL?.path == FileScanner.canonicalPath(other.url.path))
        #expect(try String(contentsOf: kept.url.appendingPathComponent("a.md"), encoding: .utf8) == "# A unsaved\n")
        model.closeTabsForProjectChange()
    }

    /// Undo of a link update from the window also reverts the open document's part, and redo
    /// applies it again.
    @Test func undoingALinkUpdateRevertsTheOpenDocument() async throws {
        let folder = try TestFolder()
        try folder.write("a.md", "See [old](old.md).\n")
        try folder.write("old.md", "# Old\n")
        let (model, path) = try await openProject(folder, files: 2)
        model.open(URL(fileURLWithPath: path("a.md")))
        let host = EditorHost(model)
        defer {
            host.restore()
        }
        let undo = try #require(model.fileUndoManager)
        undo.removeAllActions()

        let move = PathMove(from: path("old.md"), to: path("new.md"))
        try FileOperations.move(URL(fileURLWithPath: move.from), to: URL(fileURLWithPath: move.to))
        let files = [path("a.md"), path("new.md")]
        let context = LinkUpdater.context(root: FileScanner.canonicalPath(folder.url.path), move: move, markdownFiles: files)
        let plan = LinkUpdater.plan(markdownFiles: files, context: context, overrides: [path("a.md"): model.text])
        model.applyLinkUpdate(plan, context: context)
        #expect(model.text == "See [old](new.md).\n")
        // Undo groups close when the event ends.
        try await Task.sleep(for: .milliseconds(100))

        undo.undo()
        #expect(model.text == "See [old](old.md).\n")
        try await Task.sleep(for: .milliseconds(100))
        undo.redo()
        #expect(model.text == "See [old](new.md).\n")
        undo.removeAllActions()
        model.editor.undoManager.removeAllActions()
        model.closeTabsForProjectChange()
    }

    /// A file opened and edited while a link update rewrites it gets the new links in memory,
    /// so autosave does not write the old ones back.
    @Test func linkUpdateReachesADocumentOpenedDuringTheRewrite() async throws {
        let folder = try TestFolder()
        try folder.write("a.md", "See [old](old.md).\n")
        try folder.write("c.md", "# C\n")
        try folder.write("old.md", "# Old\n")
        let (model, path) = try await openProject(folder, files: 3)
        model.open(URL(fileURLWithPath: path("c.md")))

        let move = PathMove(from: path("old.md"), to: path("new.md"))
        try FileOperations.move(URL(fileURLWithPath: move.from), to: URL(fileURLWithPath: move.to))
        let files = [path("a.md"), path("c.md"), path("new.md")]
        let context = LinkUpdater.context(root: FileScanner.canonicalPath(folder.url.path), move: move, markdownFiles: files)
        let plan = LinkUpdater.plan(markdownFiles: files, context: context, overrides: [:])
        model.applyLinkUpdate(plan, context: context)
        // Before the rewrite runs, the reader switches to a.md and starts typing.
        model.open(URL(fileURLWithPath: path("a.md")))
        type("Typed. See [old](old.md).\n", in: model)

        try await waitUntil { model.text.contains("new.md") }
        #expect(model.text == "Typed. See [old](new.md).\n")
        model.saveNow()
        #expect(try String(contentsOfFile: path("a.md"), encoding: .utf8) == "Typed. See [old](new.md).\n")
        model.closeTabsForProjectChange()
    }
}
