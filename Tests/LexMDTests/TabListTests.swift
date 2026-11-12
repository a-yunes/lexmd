import Foundation
import Testing
@testable import LexMD

struct TabListTests {
    private func paths(_ list: TabList) -> [String] { list.tabs.map(\.path) }

    @Test func openInsertsAfterTheActiveTab() {
        var list = TabList()
        list.replaceActive(with: "/p/a.md")
        #expect(paths(list) == ["/p/a.md"])
        list.open("/p/b.md")
        list.open("/p/c.md")
        #expect(paths(list) == ["/p/a.md", "/p/b.md", "/p/c.md"])
        list.activate(list.tabs[0].id)
        list.open("/p/d.md")
        #expect(paths(list) == ["/p/a.md", "/p/d.md", "/p/b.md", "/p/c.md"])
        #expect(list.active?.path == "/p/d.md")
    }

    @Test func replaceChangesOnlyTheActiveTab() {
        var list = TabList()
        list.open("/p/a.md")
        let b = list.open("/p/b.md")
        list.replaceActive(with: "/p/c.md")
        #expect(paths(list) == ["/p/a.md", "/p/c.md"])
        #expect(list.activeID == b.id)
    }

    @Test func closingPicksTheNeighbor() {
        var list = TabList()
        let a = list.open("/p/a.md")
        let b = list.open("/p/b.md")
        let c = list.open("/p/c.md")
        list.activate(b.id)
        #expect(list.close(b.id) == c.id, "the tab to the right")
        #expect(list.close(c.id) == a.id, "the last tab falls back to the left")
        let d = list.open("/p/d.md")
        #expect(list.close(a.id) == d.id, "closing an inactive tab keeps the active one")
        #expect(list.close(d.id) == nil)
        #expect(list.isEmpty)
    }

    @Test func reopenClosedTabs() {
        var list = TabList()
        let a = list.open("/p/a.md")
        let b = list.open("/p/gone.md")
        list.open("/p/c.md")
        list.close(a.id)
        list.close(b.id)
        let reopened = list.popClosed { $0 != "/p/gone.md" }
        #expect(reopened?.tab.path == "/p/a.md", "missing files are skipped")
        #expect(reopened?.index == 0)
        #expect(list.popClosed { _ in true } == nil)

        for i in 0..<30 { list.close(list.open("/p/\(i).md").id) }
        #expect(list.closed.count == TabList.closedLimit)
        #expect(list.popClosed { _ in true }?.tab.path == "/p/29.md")
    }

    @Test func nextAndPreviousWrapAround() {
        var list = TabList()
        let a = list.open("/p/a.md")
        #expect(list.neighbor(1) == nil, "a single tab has no neighbor")
        let b = list.open("/p/b.md")
        let c = list.open("/p/c.md")
        #expect(list.neighbor(1) == a.id)
        #expect(list.neighbor(-1) == b.id)
        list.activate(a.id)
        #expect(list.neighbor(-1) == c.id)
        #expect(list.neighbor(1) == b.id)
    }

    @Test func moveReorders() {
        var list = TabList()
        let a = list.open("/p/a.md")
        list.open("/p/b.md")
        list.open("/p/c.md")
        list.move(a.id, to: 2)
        #expect(paths(list) == ["/p/b.md", "/p/c.md", "/p/a.md"])
        list.move(a.id, to: -5)
        #expect(paths(list) == ["/p/a.md", "/p/b.md", "/p/c.md"])
    }

    @Test func remapFollowsRenamesEverywhere() {
        var list = TabList()
        let a = list.open("/p/docs/a.md")
        list.update(a.id) { $0.state.history = ["/p/x.md", "/p/docs/a.md"] }
        let b = list.open("/p/docs/b.md")
        list.close(b.id)
        let move = PathMove(from: "/p/docs", to: "/p/guides")
        list.remap { move.map($0) }
        #expect(paths(list) == ["/p/guides/a.md"])
        #expect(list.tab(a.id)?.state.history == ["/p/x.md", "/p/guides/a.md"])
        #expect(list.closed.first?.tab.path == "/p/guides/b.md")
    }

    @Test func removingTrashedDocuments() {
        var list = TabList()
        list.open("/p/keep.md")
        let gone = list.open("/p/docs/gone.md")
        #expect(list.removeAll { $0.hasPrefix("/p/docs/") } != gone.id)
        #expect(paths(list) == ["/p/keep.md"])
        #expect(list.closed.isEmpty, "trashed documents can't be reopened")
    }

    @Test func titlesTellApartSameNames() {
        var list = TabList()
        let a = list.open("/p/a/README.md")
        let b = list.open("/p/b/readme.md")
        let c = list.open("/p/notes.md")
        let titles = list.titles()
        #expect(titles[a.id] == "README · a")
        #expect(titles[b.id] == "readme · b")
        #expect(titles[c.id] == "notes")
    }

    @Test func restoreDropsMissingFiles() {
        let saved = ["/p/a.md", "/p/missing.md", "/elsewhere/b.md", "/p/c.md", "/p/a.md", "/p/d.txt", "/p/e.md"]
        let present: Set<String> = ["/p/a.md", "/p/c.md", "/p/e.md", "/elsewhere/b.md", "/p/d.txt"]
        let exists: (String) -> Bool = { present.contains($0) }

        let restored = TabList.restorable(paths: saved, active: 3, root: "/p", exists: exists)
        #expect(restored.paths == ["/p/a.md", "/p/c.md", "/p/e.md"])
        #expect(restored.active == 1, "the active tab keeps its place")

        let activeMissing = TabList.restorable(paths: saved, active: 1, root: "/p", exists: exists)
        #expect(activeMissing.active == 0, "a missing active tab falls back to the one before it")

        #expect(TabList.restorable(paths: ["/p/missing.md"], active: 0, root: "/p", exists: exists).paths.isEmpty)
    }
}
