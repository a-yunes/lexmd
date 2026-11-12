import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LexMD

/// Sidebar, Open Quickly, and project folder behavior through the shared app model. These
/// tests extend `TabCommandTests` so they run one at a time with the other app model tests.
extension TabCommandTests {
    @Test func largeProjectsFilterInTheBackground() async throws {
        let folder = try TestFolder()
        for name in ["alpha.md", "beta.md", "gamma.md"] { try folder.write(name, "# \(name)\n") }
        let model = AppModel.shared
        model.open(folder.url)
        try await waitUntil { model.tree.count == 3 }
        let threshold = AppModel.backgroundFilterThreshold
        AppModel.backgroundFilterThreshold = 0
        defer { AppModel.backgroundFilterThreshold = threshold }

        model.filter = "a"
        model.filter = "al"
        model.filter = "alp"
        try await waitUntil { model.visibleRows.map(\.node.name) == ["alpha.md"] }
        model.filter = ""
        #expect(model.visibleRows.count == 3, "clearing the filter shows every row right away")
        model.closeTabsForProjectChange()
    }

    @Test func expandedFoldersAreRememberedPerProject() async throws {
        let first = try TestFolder()
        let second = try TestFolder()
        for folder in [first, second] {
            try FileManager.default.createDirectory(at: folder.url.appendingPathComponent("docs"), withIntermediateDirectories: true)
            try folder.write("docs/a.md", "# A\n")
            try folder.write("docs/b.md", "# B\n")
        }
        let model = AppModel.shared
        let docs = { (folder: TestFolder) in FileScanner.canonicalPath(folder.url.appendingPathComponent("docs").path) }

        model.open(first.url)
        model.expanded.insert(docs(first))
        model.open(second.url)
        #expect(!model.expanded.contains(docs(first)))
        model.expanded.remove(docs(second))
        model.open(first.url)
        #expect(model.expanded.contains(docs(first)), "switching projects keeps the other project's folders")
        model.open(second.url)
        #expect(!model.expanded.contains(docs(second)))

        let stored = UserDefaults.standard.dictionary(forKey: AppModel.Keys.expandedByProject) ?? [:]
        #expect(Set(stored.keys).isSubset(of: Set(model.recentFolders)), "only recent projects are remembered")
        model.closeTabsForProjectChange()
    }

    @Test func openQuicklyRefreshesWhenFilesChange() async throws {
        let folder = try TestFolder()
        try folder.write("note one.md", "# One\n")
        try folder.write("note two.md", "# Two\n")
        let model = AppModel.shared
        model.open(folder.url)
        try await waitUntil { model.tree.count == 2 }
        let path = { FileScanner.canonicalPath(folder.url.appendingPathComponent($0).path) }

        model.toggleQuickSearch(mode: .files)
        model.quickQuery = "note"
        try await waitUntil { !model.isQuickSearching && model.quickResults.files.count == 2 }
        model.moveQuickSelection(1)
        let selected = model.quickResults.files[model.quickSelection].path

        try folder.write("note three.md", "# Three\n")
        model.rescan()
        try await waitUntil { !model.isQuickSearching && model.quickResults.files.count == 3 }
        #expect(model.quickResults.files[model.quickSelection].path == selected, "the selected file stays selected")
        #expect(model.quickResults.files.contains { $0.path == path("note three.md") })

        model.closeQuickSearch()
        model.closeTabsForProjectChange()
    }

    @Test func movedProjectFolderIsFollowedWithUnsavedText() async throws {
        let folder = try TestFolder()
        try folder.write("a.md", "# A\n")
        let model = AppModel.shared
        model.open(folder.url)
        try await waitUntil { model.tree.count == 1 }
        model.open(URL(fileURLWithPath: FileScanner.canonicalPath(folder.url.appendingPathComponent("a.md").path)))
        model.text = "# A, edited\n"

        let moved = folder.url.deletingLastPathComponent().appendingPathComponent("LexMDTests-moved-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.moveItem(at: folder.url, to: moved)
        model.projectFolderChanged()

        let newRoot = FileScanner.canonicalPath(moved.path)
        #expect(model.rootURL?.path == newRoot)
        #expect(model.currentFile?.path == newRoot + "/a.md")
        #expect(model.tabStore.list.tabs.map(\.path) == [newRoot + "/a.md"])
        #expect(try String(contentsOfFile: newRoot + "/a.md", encoding: .utf8) == "# A, edited\n", "autosave writes to the moved file")
        try await waitUntil { model.tree.first?.id == newRoot + "/a.md" }
        model.closeTabsForProjectChange()
    }

    @Test func trashedOrDeletedProjectFolderClosesTheProject() async throws {
        let folder = try TestFolder()
        try folder.write("a.md", "# A\n")
        let trash = try TestFolder()
        let model = AppModel.shared
        model.open(folder.url)
        try await waitUntil { model.tree.count == 1 }
        model.open(URL(fileURLWithPath: FileScanner.canonicalPath(folder.url.appendingPathComponent("a.md").path)))
        model.text = "# A, edited\n"

        // A folder moved to a Trash keeps the unsaved text there, so Put Back restores it.
        let trashFolder = trash.url.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashFolder, withIntermediateDirectories: true)
        let trashed = trashFolder.appendingPathComponent("project")
        try FileManager.default.moveItem(at: folder.url, to: trashed)
        model.projectFolderChanged()
        #expect(model.rootURL == nil)
        #expect(model.currentFile == nil)
        #expect(model.tree.isEmpty)
        #expect(try String(contentsOf: trashed.appendingPathComponent("a.md"), encoding: .utf8) == "# A, edited\n")

        // A deleted folder without unsaved text closes right away.
        let other = try TestFolder()
        try other.write("b.md", "# B\n")
        model.open(other.url)
        try await waitUntil { model.tree.count == 1 }
        try FileManager.default.removeItem(at: other.url)
        model.projectFolderChanged()
        #expect(model.rootURL == nil)
    }
}

@MainActor
struct ProjectFolderChangeTests {
    @Test func classifiesTheFolderLocation() {
        #expect(ProjectFolderChange(original: "/p/docs", current: "/p/docs") == .unchanged)
        #expect(ProjectFolderChange(original: "/p/docs", current: "/p/notes") == .moved(to: "/p/notes"))
        #expect(ProjectFolderChange(original: "/p/docs", current: "/Users/me/.Trash/docs") == .trashed(at: "/Users/me/.Trash/docs"))
        #expect(ProjectFolderChange(original: "/Volumes/X/docs", current: "/Volumes/X/.Trashes/501/docs") == .trashed(at: "/Volumes/X/.Trashes/501/docs"))
        #expect(ProjectFolderChange(original: "/p/docs", current: nil) == .removed)
    }

    @Test func watcherFollowsItsFolder() throws {
        let parent = try TestFolder()
        let folder = parent.url.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let watcher = try #require(DirectoryWatcher(path: FileScanner.canonicalPath(folder.path)) { _ in })
        #expect(watcher.folderLocation() == FileScanner.canonicalPath(folder.path))

        let renamed = parent.url.appendingPathComponent("renamed")
        try FileManager.default.moveItem(at: folder, to: renamed)
        #expect(watcher.folderLocation() == FileScanner.canonicalPath(renamed.path))

        try FileManager.default.removeItem(at: renamed)
        #expect(watcher.folderLocation() == nil)
        try FileManager.default.createDirectory(at: renamed, withIntermediateDirectories: true)
        #expect(watcher.folderLocation() == nil, "a new folder at the same path is a different folder")
    }
}

struct SidebarShortcutTests {
    @Test func sidebarCommandsHaveRemappablePlainKeyDefaults() throws {
        let rename = try #require(ShortcutAction.renameInSidebar.defaultShortcut)
        let trash = try #require(ShortcutAction.trashInSidebar.defaultShortcut)
        #expect(rename.string == "return" && rename.display == "↩")
        #expect(trash.string == "cmd+delete" && trash.display == "⌘⌫")
        #expect(Shortcut(string: rename.string) == rename)
        #expect(rename.matches(.return, modifiers: []))
        #expect(!rename.matches(.return, modifiers: .command))
        #expect(rename.matches(.return, modifiers: .capsLock), "lock keys do not matter")
        #expect(trash.matches(.delete, modifiers: .command))
        #expect(!trash.matches(.delete, modifiers: []))
        #expect(ShortcutAction.renameInSidebar.allowsPlainKeys && !ShortcutAction.renameItem.allowsPlainKeys)
    }

    @Test func recordingAcceptsPlainReturnOnlyWhereAllowed() throws {
        func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
            ))
        }
        #expect(Shortcut(event: try key(36, "\r")) == nil)
        #expect(Shortcut(event: try key(36, "\r"), allowingPlainKeys: true)?.string == "return")
        #expect(Shortcut(event: try key(0, "a"), allowingPlainKeys: true) == nil, "plain letters type in the list")
        #expect(Shortcut(event: try key(51, "\u{7F}", .command))?.string == "cmd+delete")
    }
}

struct DocumentTextTests {
    @Test func searchReadsFilesLikeTheEditor() throws {
        let folder = try TestFolder()
        let file = folder.url.appendingPathComponent("wide.md")
        let text = "# Überschrift\nneedle\n"
        try #require(text.data(using: .utf16)).write(to: file)
        #expect(QuickSearchEngine.read(file.path) == text)
        let results = QuickSearchEngine.run(
            query: "needle", options: SearchOptions(),
            files: [SearchableFile(path: file.path, name: "wide.md", folder: "")], overrides: [:], currentPath: nil
        )
        #expect(results.hits.map(\.line) == [2])
    }
}
