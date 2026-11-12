import Foundation
import Testing
@testable import LexMD

/// Records what would have gone to the Trash.
private actor RecycleLog {
    var urls: [URL] = []
    func add(_ new: [URL]) { urls += new }
}

struct FileOperationsTests {
    @Test func nameProblems() {
        #expect(FileOperations.problem(with: "") != nil)
        #expect(FileOperations.problem(with: ".") != nil)
        #expect(FileOperations.problem(with: "..") != nil)
        #expect(FileOperations.problem(with: "a/b") != nil)
        #expect(FileOperations.problem(with: "a:b") != nil)
        #expect(FileOperations.problem(with: ".hidden.md") != nil)
        #expect(FileOperations.problem(with: "line\nbreak.md") != nil)
        #expect(FileOperations.problem(with: String(repeating: "é", count: 200)) != nil, "over 255 bytes")
        #expect(FileOperations.problem(with: "Notes – draft (2).md") == nil)
        #expect(FileOperations.problem(with: "日本語のノート.md") == nil)
    }

    @Test func extensionIsKeptUnlessTyped() {
        #expect(FileOperations.finalName("New", original: "old.md", isDirectory: false) == "New.md")
        #expect(FileOperations.finalName("  New  ", original: "old.markdown", isDirectory: false) == "New.markdown")
        #expect(FileOperations.finalName("New.txt", original: "old.md", isDirectory: false) == "New.txt")
        #expect(FileOperations.finalName("v1.2 notes", original: "old.md", isDirectory: false) == "v1.2 notes.md")
        #expect(FileOperations.finalName("guides.v2", original: "docs", isDirectory: true) == "guides.v2")
    }

    @Test func renameChecks() throws {
        let folder = try TestFolder()
        let notes = try folder.write("notes.md", "x")
        try folder.write("taken.md", "y")
        #expect(FileOperations.checkRename(notes, isDirectory: false, to: "notes") == .unchanged)
        #expect(FileOperations.checkRename(notes, isDirectory: false, to: "Guide") == .valid(name: "Guide.md", leavesSidebar: false))
        #expect(FileOperations.checkRename(notes, isDirectory: false, to: "notes.txt") == .valid(name: "notes.txt", leavesSidebar: true))
        guard case .invalid(let message) = FileOperations.checkRename(notes, isDirectory: false, to: "taken") else {
            Issue.record("a name in use must be refused")
            return
        }
        #expect(message.contains("taken.md"))
        guard case .invalid = FileOperations.checkRename(notes, isDirectory: false, to: "a/b") else {
            Issue.record("a slash must be refused")
            return
        }
    }

    @Test func caseOnlyRenameWorks() throws {
        let folder = try TestFolder()
        let notes = try folder.write("notes.md", "keep me")
        // On a case-insensitive volume "Notes.md" already "exists" as the same file.
        #expect(FileOperations.checkRename(notes, isDirectory: false, to: "Notes") == .valid(name: "Notes.md", leavesSidebar: false))
        let renamed = folder.url.appendingPathComponent("Notes.md")
        try FileOperations.move(notes, to: renamed)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
        #expect(names == ["Notes.md"])
        #expect(try String(contentsOf: renamed, encoding: .utf8) == "keep me")
    }

    @Test func moveNeverReplaces() throws {
        let folder = try TestFolder()
        let a = try folder.write("a.md", "a")
        let b = try folder.write("b.md", "b")
        #expect(throws: (any Error).self) { try FileOperations.move(a, to: b) }
        #expect(try String(contentsOf: a, encoding: .utf8) == "a")
        #expect(try String(contentsOf: b, encoding: .utf8) == "b")
    }

    @Test func moveProblems() throws {
        let folder = try TestFolder()
        let root = folder.url.path
        try FileManager.default.createDirectory(atPath: root + "/docs/sub", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/other", withIntermediateDirectories: true)
        try folder.write("other/a.md", "x")
        try folder.write("a.md", "y")
        #expect(FileOperations.moveProblem(root + "/docs", into: root + "/docs") != nil)
        #expect(FileOperations.moveProblem(root + "/docs", into: root + "/docs/sub") != nil)
        #expect(FileOperations.moveProblem(root + "/a.md", into: root + "/other") != nil, "name collision")
        #expect(FileOperations.moveProblem(root + "/a.md", into: root + "/docs") == nil)
    }

    @Test func duplicateNames() {
        let none: (String) -> Bool = { _ in false }
        #expect(FileOperations.duplicateName(for: "Notes.md", isDirectory: false, exists: none) == "Notes copy.md")
        #expect(FileOperations.duplicateName(for: "Notes.md", isDirectory: false, exists: { $0 == "Notes copy.md" }) == "Notes copy 2.md")
        #expect(FileOperations.duplicateName(for: "Notes copy.md", isDirectory: false, exists: { $0 == "Notes copy.md" }) == "Notes copy 2.md")
        #expect(FileOperations.duplicateName(for: "Notes copy 2.md", isDirectory: false,
                                             exists: { ["Notes copy.md", "Notes copy 2.md"].contains($0) }) == "Notes copy 3.md")
        #expect(FileOperations.duplicateName(for: "docs.v2", isDirectory: true, exists: none) == "docs.v2 copy")
        #expect(FileOperations.duplicateName(for: "README", isDirectory: false, exists: none) == "README copy")
    }

    @Test func duplicateAndNewItemsOnDisk() throws {
        let folder = try TestFolder()
        let notes = try folder.write("Notes.md", "body")
        let copy = try FileOperations.duplicate(notes)
        #expect(copy.lastPathComponent == "Notes copy.md")
        #expect(try String(contentsOf: copy, encoding: .utf8) == "body")
        #expect(try FileOperations.duplicate(notes).lastPathComponent == "Notes copy 2.md")

        #expect(try FileOperations.createFile(in: folder.url).lastPathComponent == "Untitled.md")
        #expect(try FileOperations.createFile(in: folder.url).lastPathComponent == "Untitled 2.md")
        #expect(try FileOperations.createFolder(in: folder.url).lastPathComponent == "untitled folder")
        #expect(try FileOperations.createFolder(in: folder.url).lastPathComponent == "untitled folder 2")
    }

    @Test func moveToTrashGoesThroughTheRecycler() async throws {
        let folder = try TestFolder()
        let file = try folder.write("old.md", "x")
        let log = RecycleLog()
        let trashed = URL(fileURLWithPath: "/Trash/old.md")
        let recycler: FileOperations.Recycler = { urls in
            await log.add(urls)
            return Dictionary(uniqueKeysWithValues: urls.map { ($0, trashed) })
        }
        let result = try await FileOperations.moveToTrash(file, using: recycler)
        #expect(result == trashed)
        #expect(await log.urls == [file])
        #expect(FileManager.default.fileExists(atPath: file.path), "only the recycler moves files; nothing is deleted")

        struct Refused: Error {}
        let failing: FileOperations.Recycler = { _ in throw Refused() }
        await #expect(throws: Refused.self) { try await FileOperations.moveToTrash(file, using: failing) }
    }
}

struct FileTreeEditTests {
    private func file(_ path: String) -> FileNode { FileNode(url: URL(fileURLWithPath: path), name: (path as NSString).lastPathComponent) }
    private func folder(_ path: String, _ children: [FileNode]) -> FileNode {
        FileNode(url: URL(fileURLWithPath: path, isDirectory: true), name: (path as NSString).lastPathComponent, children: children)
    }

    @Test func movingBetweenFoldersPrunesAndCreates() {
        let tree = [
            folder("/r/a", [file("/r/a/x.md")]),
            folder("/r/b", [file("/r/b/y.md")]),
            file("/r/z.md"),
        ]
        let moved = FileTreeEdit.moving(tree, move: PathMove(from: "/r/a/x.md", to: "/r/c/d/x.md"), root: "/r")
        #expect(FileTreeEdit.node(at: "/r/a", in: moved) == nil, "an emptied folder leaves the tree")
        #expect(FileTreeEdit.node(at: "/r/c/d/x.md", in: moved)?.name == "x.md")
        #expect(moved.map(\.name) == ["b", "c", "z.md"], "folders first, sorted")

        let kept = FileTreeEdit.moving(tree, move: PathMove(from: "/r/a/x.md", to: "/r/x.md"), root: "/r", keep: ["/r/a"])
        #expect(FileTreeEdit.node(at: "/r/a", in: kept)?.children == [])
    }

    @Test func renamingAFolderRebasesChildren() {
        let tree = [folder("/r/docs", [folder("/r/docs/sub", [file("/r/docs/sub/n.md")])])]
        let moved = FileTreeEdit.moving(tree, move: PathMove(from: "/r/docs", to: "/r/guides"), root: "/r")
        #expect(FileTreeEdit.node(at: "/r/guides/sub/n.md", in: moved) != nil)
        #expect(FileTreeEdit.node(at: "/r/docs/sub/n.md", in: moved) == nil)
    }

    @Test func newEmptyFoldersAreShown() {
        let tree = [file("/r/a.md")]
        let shown = FileTreeEdit.addingFolders(["/r/new/inner"], to: tree, root: "/r")
        #expect(FileTreeEdit.node(at: "/r/new/inner", in: shown)?.children == [])
        #expect(FileTreeEdit.containsMarkdown(shown[0]) == false)
    }
}
