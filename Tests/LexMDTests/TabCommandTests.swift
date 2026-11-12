import Foundation
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
        let alwaysShow = model.tabStore.alwaysShowTabBar
        defer { model.tabStore.alwaysShowTabBar = alwaysShow }
        model.tabStore.alwaysShowTabBar = false
        #expect(!model.showsTabBar, "a single document shows no tab bar")
        model.tabStore.alwaysShowTabBar = true
        #expect(model.showsTabBar, "unless Always show tab bar is on")
        model.tabStore.alwaysShowTabBar = false

        // Sidebar: Open in New Tab.
        model.openInNewTab(path("b.md"))
        #expect(model.tabStore.list.tabs.map(\.path) == [path("a.md"), path("b.md")])
        #expect(model.currentFile?.path == path("b.md"))
        #expect(model.showsTabBar, "two documents show the tab bar")

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

    @Test func returnWhileSearchingOpensTheTypedQuerysResult() async throws {
        let folder = try TestFolder()
        try folder.write("alpha.md", "# A\n")
        try folder.write("beta.md", "# B\n")
        let model = AppModel.shared
        model.open(folder.url)
        try await waitUntil { model.tree.count == 2 }
        let path = { FileScanner.canonicalPath(folder.url.appendingPathComponent($0).path) }

        model.toggleQuickSearch(mode: .files)
        model.quickQuery = "alpha"
        try await waitUntil { !model.isQuickSearching && model.quickResults.files.first?.path == path("alpha.md") }
        #expect(model.searchFiles?.count == 2, "the tree's files are listed once and reused")

        // The list still shows "alpha" when Return arrives right after typing "beta".
        model.quickQuery = "beta"
        model.activateQuickSelection()
        #expect(model.isQuickSearchVisible)
        try await waitUntil { model.currentFile?.path == path("beta.md") }
        #expect(!model.isQuickSearchVisible)

        model.tree = []
        #expect(model.searchFiles == nil, "a new tree lists its files again")
        model.closeTabsForProjectChange()
    }

    @Test func sidebarRowsTrackTheFilterAndRescansKeepUp() async throws {
        let folder = try TestFolder()
        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try folder.write("docs/guide.md", "# Guide\n")
        try folder.write("docs/notes.md", "# Notes\n")
        try folder.write("readme.md", "# Readme\n")
        let model = AppModel.shared
        model.open(folder.url)
        try await waitUntil { model.tree.count == 2 }
        let docs = FileScanner.canonicalPath(folder.url.appendingPathComponent("docs").path)

        model.setExpanded(subtreeOf: model.displayTree, false)
        #expect(model.visibleRows.map(\.node.name) == ["docs", "readme.md"])
        model.setExpanded(subtreeOf: model.displayTree, true)
        #expect(model.visibleRows.map(\.node.name) == ["docs", "guide.md", "notes.md", "readme.md"])
        #expect(model.visibleRows.first?.isExpanded == true)

        model.filter = "gui"
        #expect(model.isFiltering && !model.canToggleAllFolders)
        #expect(model.visibleRows.map(\.node.name) == ["docs", "guide.md"])
        model.filter = "  "
        #expect(!model.isFiltering)
        model.filter = ""
        #expect(model.visibleRows.count == 4)
        #expect(model.expanded.contains(docs))

        // Requests that arrive while a scan runs are folded into one more scan, not lost.
        try folder.write("docs/new.md", "# New\n")
        for _ in 0..<5 { model.rescan() }
        try await waitUntil { model.visibleRows.contains { $0.node.name == "new.md" } }

        model.closeTabsForProjectChange()
    }
}
