import AppKit
import Foundation
import Testing
@testable import LexMD

/// Known state bugs in the preview: work computed for one document is applied to another.
/// Each test passes while its bug exists and fails once the bug is fixed; then drop `withKnownIssue`.
/// See docs/state-machines.md.
extension TabCommandTests {
    /// Puts the shared preview in a window so its page loads and runs scripts like the app's.
    private func hostPreview(_ model: AppModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = model.preview.webView
        return window
    }

    private func pageText(_ model: AppModel) async throws -> String {
        try await model.preview.evaluate("return document.querySelector('#content')?.innerText ?? ''") as? String ?? ""
    }

    @Test func copyRichTextCopiesTheShownDocument() async throws {
        let folder = try TestFolder()
        try folder.write("a.md", "# Alpha document\n\nalpha body\n")
        try folder.write("b.md", "# Bravo document\n\nbravo body\n")
        let model = AppModel.shared
        let window = hostPreview(model)
        defer { window.contentView = nil; window.close() }
        model.open(folder.url)
        try await waitUntil { model.tree.count == 2 }
        let path = { FileScanner.canonicalPath(folder.url.appendingPathComponent($0).path) }
        model.open(URL(fileURLWithPath: path("a.md")))
        try await waitUntil {
            guard model.preview.isPageLoaded else { return false }
            return try await pageText(model).contains("alpha body")
        }

        let board = NSPasteboard(name: NSPasteboard.Name("LexMDTests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        model.open(URL(fileURLWithPath: path("b.md")))
        model.copyRichText(to: board)
        try await waitUntil { board.string(forType: .string) != nil }
        let copied = board.string(forType: .string) ?? ""
        #expect(copied.contains("bravo body"), "copied: \(copied)")
        model.closeTabsForProjectChange()
    }

    @Test func fastTabSwitchKeepsEachTabsPreviewPosition() async throws {
        let folder = try TestFolder()
        let long = { (name: String) in "# \(name)\n\n" + (1...200).map { "Paragraph \($0) of \(name).\n" }.joined(separator: "\n") }
        for name in ["a", "b", "c"] { try folder.write("\(name).md", long(name)) }
        let model = AppModel.shared
        let window = hostPreview(model)
        defer { window.contentView = nil; window.close() }
        let mode = model.viewMode
        model.setViewMode(.read)
        defer { model.setViewMode(mode) }
        model.open(folder.url)
        try await waitUntil { model.tree.count == 3 }
        let path = { FileScanner.canonicalPath(folder.url.appendingPathComponent($0).path) }
        model.open(URL(fileURLWithPath: path("a.md")))
        model.openInNewTab(path("b.md"))
        model.openInNewTab(path("c.md"))
        let ids = model.tabStore.list.tabs.map(\.id)
        // Visit B so it has a saved position near the top, then go to A and scroll it far down.
        model.selectTab(ids[1])
        try await waitUntil { (try await pageText(model)).contains("of b.") }
        model.selectTab(ids[0])
        try await waitUntil { (try await pageText(model)).contains("of a.") }
        _ = try await world(model.preview, "lexmdScroll(0.8); return true")
        try await Task.sleep(for: .milliseconds(300))
        let bBefore = model.tabStore.list.tab(ids[1])?.state.previewFraction ?? 0

        // A to B to C in one turn: B's page never renders.
        model.selectTab(ids[1])
        model.selectTab(ids[2])
        try await waitUntil { (try await pageText(model)).contains("of c.") }
        try await Task.sleep(for: .milliseconds(300))
        let bAfter = model.tabStore.list.tab(ids[1])?.state.previewFraction ?? 0
        #expect(abs(bAfter - bBefore) < 0.05, "B was \(bBefore), now \(bAfter)")
        model.closeTabsForProjectChange()
    }

    @Test func findIndexSurvivesATabSwitchInReadMode() async throws {
        let folder = try TestFolder()
        try folder.write("a.md", "# A\n\nfoo foo\n")
        try folder.write("b.md", "# B\n\n" + (1...10).map { "foo \($0)\n" }.joined(separator: "\n"))
        let model = AppModel.shared
        let window = hostPreview(model)
        defer { window.contentView = nil; window.close() }
        let mode = model.viewMode
        model.setViewMode(.read)
        defer { model.setViewMode(mode) }
        model.open(folder.url)
        try await waitUntil { model.tree.count == 2 }
        let path = { FileScanner.canonicalPath(folder.url.appendingPathComponent($0).path) }
        model.open(URL(fileURLWithPath: path("a.md")))
        model.openInNewTab(path("b.md"))
        let ids = model.tabStore.list.tabs.map(\.id)
        try await waitUntil { (try await pageText(model)).contains("foo 10") }
        model.showFind()
        model.findQuery = "foo"
        model.refreshFind(scroll: false)
        try await waitUntil { model.findCount == 10 }
        for _ in 0..<7 { model.findNext(true) }
        #expect(model.findIndex == 7)

        model.selectTab(ids[0])
        try await waitUntil { (try await pageText(model)).contains("foo foo") }
        model.selectTab(ids[1])
        try await waitUntil {
            guard model.findCount == 10 else { return false }
            return try await pageText(model).contains("foo 10")
        }
        try await Task.sleep(for: .milliseconds(300))
        let marked = try await model.preview.evaluate(
            "return Array.from(document.querySelectorAll('.lexmd-hit')).indexOf(document.querySelector('.lexmd-hit.current'))"
        ) as? Int
        #expect(model.findIndex == 7, "find bar index \(model.findIndex), page marks \(marked ?? -1)")
        #expect(marked == model.findIndex, "find bar index \(model.findIndex), page marks \(marked ?? -1)")
        model.closeFindBar()
        model.closeTabsForProjectChange()
    }

    @Test func headingLinkToAnOpenTabRevealsTheHeading() async throws {
        let folder = try TestFolder()
        let body = (1...150).map { "Line \($0).\n" }.joined(separator: "\n")
        try folder.write("a.md", "# A\n\n[x](b.md#target)\n")
        try folder.write("b.md", "# B\n\n" + body + "\n## Target\n\n" + body)
        let model = AppModel.shared
        let window = hostPreview(model)
        defer { window.contentView = nil; window.close() }
        let mode = model.viewMode
        model.setViewMode(.read)
        defer { model.setViewMode(mode) }
        model.open(folder.url)
        try await waitUntil { model.tree.count == 2 }
        let path = { FileScanner.canonicalPath(folder.url.appendingPathComponent($0).path) }
        model.open(URL(fileURLWithPath: path("b.md")))
        try await waitUntil {
            guard model.preview.isPageLoaded else { return false }
            return try await pageText(model).contains("Line 150")
        }
        model.openInNewTab(path("a.md"))
        try await waitUntil {
            let shown = try await pageText(model)
            return shown.contains("x") && !shown.contains("Line 1.")
        }

        model.openDocument(URL(fileURLWithPath: path("b.md")), fragment: "target")
        try await waitUntil { try await pageText(model).contains("Line 150") }
        try await Task.sleep(for: .milliseconds(500))
        let top = try await model.preview.evaluate("return document.getElementById('target').getBoundingClientRect().top") as? Double ?? -1
        #expect(abs(top) < 80, "the heading is \(top) px from the top")
        model.closeTabsForProjectChange()
    }
}
