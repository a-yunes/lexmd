import AppKit
import SwiftUI
import Testing
@testable import LexMD

/// Opening documents in tabs through the app model, as the sidebar menu and New Tab do.
@MainActor
@Suite(.serialized)
struct TabCommandTests {
    @Test func openInNewTabAndNewTabFromOpenQuickly() async throws {
        let folder = try TestFolder()
        try folder.write("a.md", "# A\n")
        try folder.write("b.md", "# B\n")
        try folder.write("c.md", "# C\n")
        let model = AppModel.shared
        model.open(folder.url)
        try await waitUntil { model.tree.count == 3 }
        let path = { FileScanner.canonicalPath(folder.url.appendingPathComponent($0).path) }

        model.open(URL(fileURLWithPath: path("a.md")))
        #expect(model.tabStore.list.count == 1)
        #expect(model.showsTabBar, "the tab bar shows by default, even with one document")

        // Sidebar: Open in New Tab.
        model.openInNewTab(path("b.md"))
        #expect(model.tabStore.list.tabs.map(\.path) == [path("a.md"), path("b.md")])
        #expect(model.currentFile?.path == path("b.md"))

        // New Tab: Open Quickly, then the picked file opens in another tab.
        model.newTab()
        #expect(model.isQuickSearchVisible && model.quickOpensInNewTab)
        model.quickQuery = "c"
        try await waitUntil { model.quickResults.files.first?.path == path("c.md") }
        model.activateQuickSelection()
        #expect(model.tabStore.list.count == 3)
        #expect(model.currentFile?.path == path("c.md"))
        #expect(!model.quickOpensInNewTab)

        model.closeTabsForProjectChange()
    }

    /// The sidebar row menu, through the real list: the menu the list builds for a clicked row, and
    /// the selection change a secondary click can make before the menu's command runs.
    @Test func openInNewTabFromRowMenu() async throws {
        let folder = try TestFolder()
        try folder.write("a.md", "# A\n")
        try folder.write("b.md", "# B\n")
        let model = AppModel.shared
        model.open(folder.url)
        try await waitUntil { model.tree.count == 2 }
        let path = { FileScanner.canonicalPath(folder.url.appendingPathComponent($0).path) }
        model.open(URL(fileURLWithPath: path("a.md")))
        #expect(model.currentFile?.path == path("a.md"))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: SidebarView().environment(model))
        window.contentView = host
        defer { window.contentView = nil }
        try await waitUntil(seconds: 10) { Self.table(in: host)?.numberOfRows ?? 0 >= 3 }
        let table = try #require(Self.table(in: host))
        let row = table.rect(ofRow: table.numberOfRows - 1)
        let point = table.convert(NSPoint(x: row.midX, y: row.midY), to: nil)
        let click = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))

        // The list may move its selection to the clicked row as the menu opens. That must not
        // open the row in the active tab, or Open in New Tab finds it already showing.
        let previousEvent = AppModel.currentEvent
        AppModel.currentEvent = { click }
        model.selectedPath = path("b.md")
        AppModel.currentEvent = previousEvent
        #expect(model.currentFile?.path == path("a.md"))
        #expect(model.selectedPath == path("a.md"))
        #expect(model.tabStore.list.tabs.map(\.path) == [path("a.md")])

        let menu = try #require(table.menu(for: click))
        let index = try #require(menu.items.firstIndex { $0.title == "Open in New Tab" })
        menu.performActionForItem(at: index)
        #expect(model.tabStore.list.tabs.map(\.path) == [path("a.md"), path("b.md")])
        #expect(model.currentFile?.path == path("b.md"))
        #expect(model.selectedPath == path("b.md"))

        // A Command-click still opens a row in a new tab, and a plain selection opens in place.
        let commandClick = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        try folder.write("c.md", "# C\n")
        AppModel.currentEvent = { commandClick }
        model.selectedPath = path("c.md")
        AppModel.currentEvent = previousEvent
        #expect(model.tabStore.list.tabs.map(\.path) == [path("a.md"), path("b.md"), path("c.md")])
        model.selectedPath = path("a.md")
        #expect(model.tabStore.list.count == 3)
        #expect(model.currentFile?.path == path("a.md"))

        model.closeTabsForProjectChange()
    }

    /// A new sidebar tree (after any rescan) does not walk the project again for the link index;
    /// file events update it. Opening the same folder again does rescan it.
    @Test func newSidebarTreeDoesNotRescanTheLinkIndex() async throws {
        let folder = try TestFolder()
        try folder.write("a.md", "# A\n")
        let model = AppModel.shared
        model.open(folder.url)
        try await waitUntil { model.tree.count == 1 && !model.outline.index.isBuilding }
        #expect(model.outline.index.snapshot.markdownPaths.count == 1)

        let extra = FileNode(url: folder.url.appendingPathComponent("b.md"), name: "b.md", children: nil)
        model.tree = model.tree + [extra]
        #expect(!model.outline.index.isBuilding)
        model.open(folder.url)
        #expect(model.outline.index.isBuilding)
        await model.outline.index.waitUntilIdle()
        model.closeTabsForProjectChange()
    }

    /// Text typed while a document moves to the Trash, and text a tab could not save, go with the
    /// documents to the Trash; autosave never recreates the trashed file at its old place.
    @Test func trashKeepsTextThatWasNotSaved() async throws {
        let folder = try TestFolder()
        let trash = try TestFolder()
        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try folder.write("notes/a.md", "# A\n")
        try folder.write("notes/b.md", "# B\n")
        try folder.write("c.md", "# C\n")
        let model = AppModel.shared
        model.open(folder.url)
        try await waitUntil { !model.tree.isEmpty }
        let path = { FileScanner.canonicalPath(folder.url.appendingPathComponent($0).path) }
        model.open(URL(fileURLWithPath: path("notes/b.md")))
        model.openInNewTab(path("notes/a.md"))
        let bTab = try #require(model.tabStore.list.tab(withPath: path("notes/b.md")))
        model.tabStore.list.update(bTab.id) { $0.state.unsavedText = "# B unsaved\n" }

        let gate = AsyncStream<Void>.makeStream()
        let trashRoot = FileScanner.canonicalPath(trash.url.path)
        model.sidebarFiles.recycler = { urls in
            for await _ in gate.stream { break }
            var result: [URL: URL] = [:]
            for url in urls {
                let destination = URL(fileURLWithPath: trashRoot).appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: destination)
                result[url] = destination
            }
            return result
        }
        defer { model.sidebarFiles.recycler = FileOperations.systemRecycler }

        model.moveToTrash(URL(fileURLWithPath: path("notes")))
        model.editor.textView.string = "# A typed during the move\n"
        model.editor.onTextChange?(model.editor.textView.string)
        model.saveNow()
        gate.continuation.yield()
        try await waitUntil { model.currentFile == nil || model.currentFile?.path == path("c.md") || !model.tabStore.list.tabs.contains { $0.path.hasPrefix(path("notes")) } }

        #expect(!FileManager.default.fileExists(atPath: path("notes/a.md")), "autosave did not recreate it")
        #expect(try String(contentsOfFile: trashRoot + "/notes/a.md", encoding: .utf8) == "# A typed during the move\n")
        #expect(try String(contentsOfFile: trashRoot + "/notes/b.md", encoding: .utf8) == "# B unsaved\n")
        #expect(model.tabStore.list.isEmpty)
        model.closeTabsForProjectChange()
    }

    private static func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for sub in view.subviews { if let found = table(in: sub) { return found } }
        return nil
    }
}
