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
}
