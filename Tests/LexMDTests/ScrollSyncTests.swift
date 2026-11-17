import AppKit
import Foundation
import Testing
import WebKit
@testable import LexMD
@testable import LexMDRendering

/// A pane whose document is `scale` points tall per source position.
@MainActor
private final class FakePane: ScrollSyncPane {
    var scale: CGFloat
    var view: CGFloat = 400
    var height: CGFloat = 10_000
    var scroll: CGFloat = 0
    var isReady = true
    var followed: [CGFloat] = []
    var reportsScrolling: Bool?

    init(scale: CGFloat) { self.scale = scale }

    var syncMetrics: ScrollMetrics? { isReady ? ScrollMetrics(scroll: scroll, view: view, max: height - view) : nil }
    func sourcePosition(at offset: CGFloat) -> Double? { Double(offset / scale) }
    func offset(ofSourcePosition position: Double) -> CGFloat? { CGFloat(position) * scale }
    func followScroll(to scroll: CGFloat) {
        self.scroll = scroll
        followed.append(scroll)
    }
    func setReportsScrolling(_ reports: Bool) { reportsScrolling = reports }

    /// The source position at mid-height, where both panes show the same source.
    var middle: Double { Double((scroll + view / 2) / scale) }
}

/// Who leads, who follows, and how the follower gets there, with panes that only do arithmetic.
@MainActor
struct ScrollSyncTests {
    private func sync(reducesMotion: Bool = true) -> (ScrollSync, editor: FakePane, preview: FakePane) {
        let editor = FakePane(scale: 20), preview = FakePane(scale: 50)
        let sync = ScrollSync(reducesMotion: { reducesMotion })
        sync.connect(editor: editor, preview: preview)
        sync.isEnabled = true
        return (sync, editor, preview)
    }

    @Test func theFollowerShowsTheSameSourceAtMidHeight() {
        let (sync, editor, preview) = sync()
        editor.scroll = 1000
        sync.paneScrolled(.editor, input: true)
        #expect(preview.middle == editor.middle)
        #expect(preview.scroll == 2800)

        preview.scroll = 4000
        sync.paneScrolled(.preview, input: true)
        #expect(editor.middle == preview.middle)
    }

    @Test func itOnlyRunsWhileEnabledAndTellsThePreview() {
        // Turned on before the panes are connected, as the model's view mode is at launch.
        let early = ScrollSync()
        early.isEnabled = true
        let late = FakePane(scale: 50)
        early.connect(editor: FakePane(scale: 20), preview: late)
        #expect(late.reportsScrolling == true)

        let (sync, editor, preview) = sync()
        #expect(preview.reportsScrolling == true)
        sync.isEnabled = false
        #expect(preview.reportsScrolling == false)
        editor.scroll = 1000
        sync.paneScrolled(.editor, input: true)
        #expect(preview.followed.isEmpty)
    }

    /// After a pane follows, its layout settles and moves it a little. Without the reader's
    /// input that doesn't take the lead back until the leader has been still for a moment.
    @Test func aFollowerOnlyTakesTheLeadWithInputWhileTheOtherHoldsIt() {
        let (sync, editor, preview) = sync()
        let start = Date()
        preview.scroll = 3000
        sync.paneScrolled(.preview, input: true, at: start)
        let followed = editor.scroll

        editor.scroll = followed + 7
        sync.paneScrolled(.editor, input: false, at: start + 0.1)
        #expect(preview.followed.isEmpty, "settling isn't the reader")

        sync.paneScrolled(.editor, input: true, at: start + 0.2)
        #expect(preview.followed.count == 1, "the reader's own scroll takes the lead at once")

        preview.scroll += 5
        sync.paneScrolled(.preview, input: false, at: start + 0.2 + ScrollSync.hold + 0.01)
        #expect(editor.middle == preview.middle, "once the lead lapses, any scroll leads")
    }

    /// Panes that start out of line close the distance over a moment instead of jumping.
    @Test func aFollowerOutOfLineGlidesIntoLine() {
        let (sync, editor, preview) = sync(reducesMotion: false)
        let start = Date()
        editor.scroll = 1000
        sync.paneScrolled(.editor, input: true, at: start)
        #expect(preview.scroll == 0, "the first step stays where the follower was")

        #expect(sync.step(at: start + ScrollSync.catchUp / 2))
        #expect(abs(preview.scroll - (2800 - 2800 / 8)) < 0.01, "an eighth of the distance is left halfway through")
        #expect(!sync.step(at: start + ScrollSync.catchUp + 0.001))
        #expect(preview.scroll == 2800)

        // In line already: it follows at once.
        editor.scroll = 1010
        sync.paneScrolled(.editor, input: true, at: start + ScrollSync.catchUp + 0.01)
        #expect(preview.middle == editor.middle)
    }

    @Test func theLeaderKeepsMovingWhileTheFollowerGlides() {
        let (sync, editor, preview) = sync(reducesMotion: false)
        let start = Date()
        editor.scroll = 1000
        sync.paneScrolled(.editor, input: true, at: start)
        editor.scroll = 1100
        sync.paneScrolled(.editor, input: true, at: start + ScrollSync.catchUp / 2)
        #expect(abs(preview.scroll - (3050 - 2800 / 8)) < 0.01, "the new place, less what is left of the starting distance")
        sync.step(at: start + ScrollSync.catchUp + 0.001)
        #expect(preview.middle == editor.middle)
    }

    @Test func aPaneThatCannotSayWhereItIsIsLeftAlone() {
        let (sync, editor, preview) = sync()
        preview.isReady = false
        editor.scroll = 1000
        sync.paneScrolled(.editor, input: true)
        #expect(preview.followed.isEmpty)
        preview.scroll = 500
        sync.paneScrolled(.preview, input: true)
        #expect(editor.followed.isEmpty)
    }

    @Test func theGlideEasesOut() {
        #expect(ScrollSync.remaining(of: 400, after: 0) == 400)
        #expect(ScrollSync.remaining(of: 400, after: ScrollSync.catchUp / 2) == 50)
        #expect(ScrollSync.remaining(of: 400, after: ScrollSync.catchUp) == 0)
        #expect(ScrollSync.remaining(of: -400, after: 1) == 0)
    }

    /// The anchor is mid-height in the middle of a document and slides to the edges at its ends,
    /// and the scroll that shows a point is its inverse.
    @Test func theAnchorSlidesToTheEdgesAtTheEnds() {
        let view: CGFloat = 600
        for max: CGFloat in [200, 600, 5000] {
            #expect(ScrollMetrics(scroll: 0, view: view, max: max).anchorOffset == 0)
            #expect(ScrollMetrics(scroll: max, view: view, max: max).anchorOffset == view)
            #expect(ScrollMetrics(scroll: max / 2, view: view, max: max).anchorOffset == view / 2)
            var previous: CGFloat = -1
            for step in 0...200 {
                let metrics = ScrollMetrics(scroll: max * CGFloat(step) / 200, view: view, max: max)
                #expect(metrics.anchorPoint > previous, "the anchor moves down the document as it scrolls")
                previous = metrics.anchorPoint
                #expect(abs(metrics.scroll(showing: metrics.anchorPoint) - metrics.scroll) < 0.001)
            }
        }
        #expect(ScrollMetrics(scroll: 1000, view: view, max: 5000).anchorOffset == 300)
        #expect(ScrollMetrics(scroll: 150, view: view, max: 5000).anchorOffset == 150)
        #expect(ScrollMetrics(scroll: 0, view: view, max: 0).scroll(showing: 100) == 0)
    }

    @Test func positionsMapToOffsetsInStraightLinesBetweenAnchors() {
        let map = PositionMap([(0, 0), (1, 40), (2, 100), (2, 130), (5, 190), (4, 500), (7, 400)])
        #expect(map.positions == [0, 1, 2, 2, 5, 7], "pairs that go backwards are left out")
        #expect(map.offset(of: 0.5) == 20)
        #expect(map.offset(of: 1.5) == 70)
        #expect(map.offset(of: 2) == 130, "a line that starts after a gap is at the gap's far side")
        #expect(map.offset(of: 3) == 150)
        #expect(map.offset(of: 99) == 400)
        #expect(map.position(at: 20) == 0.5)
        #expect(map.position(at: 115) == 2, "the gap between two blocks belongs to the line between them")
        #expect(map.position(at: 160) == 3.5)
        #expect(map.position(at: -5) == 0)
        #expect(map.position(at: 1000) == 7)
        #expect(PositionMap([]).offset(of: 1) == nil)
    }
}

/// The preview as a pane: it reports its layout and scrolls, and scrolls where it is told.
@MainActor
@Suite(.serialized)
struct ScrollSyncPreviewTests {
    /// Forty paragraphs, with a tall block of raw HTML after the tenth, which has no line of its own.
    private static let markdown: String = {
        var lines: [String] = []
        for i in 1...40 {
            lines.append("Paragraph \(i) with a few words.")
            lines.append("")
            if i == 10 {
                lines.append("<div style=\"height:3000px\"></div>")
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }()

    private static func line(of text: String) -> Int {
        markdown.components(separatedBy: "\n").firstIndex { $0.hasPrefix(text) }! + 1
    }

    private func render(_ markdown: String, in preview: PreviewController, resetScroll: Bool) {
        let rendered = MarkdownHTML.renderWithSourceLines(markdown)
        preview.render(html: rendered.html, baseURL: nil, resetScroll: resetScroll, lineCount: rendered.lineCount)
    }

    /// A preview that shows the document and has reported its layout.
    private func syncedPreview() async throws -> (PreviewController, NSWindow) {
        let preview = PreviewController(allowsRemoteContent: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = preview.webView
        preview.setReportsScrolling(true)
        render(Self.markdown, in: preview, resetScroll: true)
        let last = Self.line(of: "Paragraph 40 ")
        try await waitUntil {
            guard let offset = preview.offset(ofSourcePosition: Double(last)), let metrics = preview.syncMetrics else { return false }
            return offset > 3000 && metrics.max > 3000
        }
        return (preview, window)
    }

    private func edges(ofLine line: Int, in preview: PreviewController) async throws -> (top: CGFloat, bottom: CGFloat) {
        let rect = try await world(preview, """
            var r = document.querySelector('[data-line="\(line)"]').getBoundingClientRect();
            return [r.top + window.scrollY, r.bottom + window.scrollY]
            """) as? [Double] ?? [.nan, .nan]
        return (CGFloat(rect[0]), CGFloat(rect[1]))
    }

    private func pageScroll(_ preview: PreviewController) async throws -> CGFloat {
        CGFloat(try await world(preview, "return window.scrollY") as? Double ?? .nan)
    }

    /// A block spans its own lines: its first line is its top edge and the line after it its
    /// bottom edge, and the lines before the next block are the gap between them.
    @Test func blocksSpanTheirLines() async throws {
        let (preview, window) = try await syncedPreview()
        defer { window.contentView = nil }
        let target = Self.line(of: "Paragraph 25 ")
        let block = try await edges(ofLine: target, in: preview)
        let next = try await edges(ofLine: Self.line(of: "Paragraph 26 "), in: preview)
        let offset = { (position: Double) in try #require(preview.offset(ofSourcePosition: position)) }
        #expect(abs(try offset(Double(target)) - block.top) < 0.5)
        #expect(abs(try offset(Double(target) + 0.5) - (block.top + block.bottom) / 2) < 0.5)
        #expect(abs(try offset(Double(target) + 1) - block.bottom) < 0.5)
        #expect(abs(try offset(Double(target) + 1.5) - (block.bottom + next.top) / 2) < 0.5)
        #expect(abs(try #require(preview.sourcePosition(at: block.top + 1)) - Double(target)) < 0.2)

        // The tall block has no line of its own: it fills the gap after paragraph 10, which is
        // the three source lines (blank, the block, blank) before paragraph 11.
        let before = try await edges(ofLine: Self.line(of: "Paragraph 10 "), in: preview)
        let after = try await edges(ofLine: Self.line(of: "Paragraph 11 "), in: preview)
        #expect(after.top - before.bottom > 3000)
        #expect(abs(try offset(Double(Self.line(of: "Paragraph 10 ")) + 2.5) - (before.bottom + after.top) / 2) < 1)

        // Both ends of the page are both ends of the scale.
        let lines = Self.markdown.components(separatedBy: "\n").count
        let metrics = try #require(preview.syncMetrics)
        #expect(try offset(0) == 0)
        #expect(try offset(Double(lines + 2)) == metrics.max + metrics.view)
    }

    /// Typing above a block moves its lines but leaves the block itself in place.
    @Test func linesFollowEditsWithoutReplacingBlocks() async throws {
        let (preview, window) = try await syncedPreview()
        defer { window.contentView = nil }
        let target = Self.line(of: "Paragraph 20 ")
        let before = try #require(preview.offset(ofSourcePosition: Double(target)))
        _ = try await world(preview, "document.querySelector('[data-line=\"\(target)\"]').__kept = true; return true")
        render("New first paragraph.\n\n" + Self.markdown, in: preview, resetScroll: false)
        try await waitUntil {
            try await world(preview, "return document.querySelector('#content p').textContent") as? String == "New first paragraph."
        }
        let moved = try await world(preview, """
            var kept = Array.prototype.find.call(document.querySelectorAll('#content [data-line]'), function (e) { return e.__kept; });
            return kept ? kept.getAttribute('data-line') : null
            """) as? String
        #expect(moved == String(target + 2))
        // The page reports its layout again: the same block, two lines and one paragraph down.
        try await waitUntil { (preview.offset(ofSourcePosition: Double(target + 2)) ?? 0) > before }
    }

    /// Following the editor scrolls the page, and is not taken for the reader scrolling it.
    @Test func followingScrollsThePageWithoutReportingIt() async throws {
        let (preview, window) = try await syncedPreview()
        defer { window.contentView = nil }
        var reports: [Bool] = []
        preview.onReaderScroll = { reports.append($0) }

        for step in 1...30 { preview.followScroll(to: CGFloat(step) * 40) }
        try await waitUntil { try await pageScroll(preview) == 1200 }
        #expect(preview.syncMetrics?.scroll == 1200)
        // Other scrolls the page makes itself aren't the reader either.
        _ = try await world(preview, "lexmdScroll(0.5); return true")
        try await Task.sleep(for: .milliseconds(300))
        #expect(reports.isEmpty)
        #expect(abs((preview.syncMetrics?.scroll ?? 0) - (try await pageScroll(preview))) < 1, "the app still hears where the page is")
    }

    @Test func theReadersScrollsAreReportedWithTheirInput() async throws {
        let (preview, window) = try await syncedPreview()
        defer { window.contentView = nil }
        var reports: [Bool] = []
        preview.onReaderScroll = { reports.append($0) }

        _ = try await world(preview, "window.dispatchEvent(new WheelEvent('wheel')); window.scrollTo(0, 900); return true")
        try await waitUntil { !reports.isEmpty }
        #expect(reports == [true], "the reader used the wheel")
        #expect(preview.syncMetrics?.scroll == 900)

        // A scroll with no input that the page didn't make itself, as from VoiceOver, or the
        // page keeping its place when content above it loads.
        _ = try await world(preview, "window.scrollTo(0, 1500); return true")
        try await waitUntil { reports.count == 2 }
        #expect(reports == [true, false])
    }

    /// The page's scroll bar can be dragged, and dragging it is the reader scrolling.
    @Test func draggingTheScrollBarScrollsAndIsTheReader() async throws {
        let (preview, window) = try await syncedPreview()
        defer { window.contentView = nil }
        var reports: [Bool] = []
        preview.onReaderScroll = { reports.append($0) }
        let dragged = try await world(preview, """
            var track = document.getElementById('lexmd-track');
            var at = function (type, y) {
              return new MouseEvent(type, { bubbles: true, cancelable: true, clientX: window.innerWidth - 5, clientY: y, button: 0 });
            };
            track.dispatchEvent(at('mousedown', 20));
            window.dispatchEvent(at('mousemove', window.innerHeight / 2));
            window.dispatchEvent(at('mouseup', window.innerHeight / 2));
            var max = document.documentElement.scrollHeight - window.innerHeight;
            return window.scrollY / max;
            """) as? Double
        #expect(dragged.map { abs($0 - 0.5) < 0.1 } == true, "dragging the thumb to the middle scrolls halfway")
        try await waitUntil { !reports.isEmpty }
    }

    @Test func doubleClickAsksToEditTheBlock() async throws {
        let (preview, window) = try await syncedPreview()
        defer { window.contentView = nil }
        var requests: [(ClosedRange<Int>, String)] = []
        preview.onEditRequest = { requests.append(($0, $1)) }
        let target = Self.line(of: "Paragraph 7 ")
        _ = try await world(preview, """
            document.querySelector('[data-line="\(target)"]').dispatchEvent(new MouseEvent('dblclick', { bubbles: true }));
            return true
            """)
        try await waitUntil { !requests.isEmpty }
        #expect(requests.first?.0 == target...target)
    }

    /// A page that isn't asked to report sends nothing, so Preview Only costs nothing.
    @Test func aPageThatIsNotSyncingReportsNothing() async throws {
        let (preview, window) = try await syncedPreview()
        defer { window.contentView = nil }
        preview.setReportsScrolling(false)
        #expect(preview.syncMetrics == nil)
        var reports = 0
        preview.onReaderScroll = { _ in reports += 1 }
        _ = try await world(preview, "window.dispatchEvent(new WheelEvent('wheel')); window.scrollTo(0, 700); return true")
        try await Task.sleep(for: .milliseconds(300))
        #expect(reports == 0)
        #expect(preview.syncMetrics == nil)
    }
}

/// The editor as a pane.
@MainActor
struct ScrollSyncEditorTests {
    private func editor() -> (EditorController, NSWindow) {
        var text = ""
        for i in 1...300 { text += "Line \(i) has enough words to wrap now and then in a narrow editor window, twice over.\n" }
        let editor = EditorController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.scrollView
        editor.load(text)
        window.layoutIfNeeded()
        return (editor, window)
    }

    /// A wrapped line spans its rows: its number is its top edge and the next number its bottom
    /// edge, so the preview's paragraph and the editor's line up edge to edge.
    @Test func aLineSpansItsWrappedRows() throws {
        let (editor, window) = editor()
        defer { window.contentView = nil }
        let frame = try #require(editor.lineFrame(at: editor.lineIndex.start(ofLine: 119)))
        let top = try #require(editor.offset(ofSourcePosition: 120))
        let bottom = try #require(editor.offset(ofSourcePosition: 121))
        #expect(abs(top - frame.minY) < 1)
        #expect(bottom - top > frame.height * 1.5, "the line wraps")
        #expect(abs(try #require(editor.sourcePosition(at: (top + bottom) / 2)) - 120.5) < 0.01)

        // The ends of the scale are the ends of the document, padding included.
        let metrics = try #require(editor.syncMetrics)
        #expect(editor.sourcePosition(at: 0) == 0)
        #expect(editor.offset(ofSourcePosition: 0) == 0)
        // 300 lines and the empty one after the last line break, then the end of the document.
        #expect(editor.offset(ofSourcePosition: 303) == metrics.max + metrics.view)
        #expect(editor.sourcePosition(at: metrics.max + metrics.view) == 303)
    }

    /// With a preview that leads, the editor shows the same source at mid-height, and doesn't
    /// report the scroll that put it there.
    @Test func theEditorFollowsThePreview() async throws {
        let (editor, window) = editor()
        defer { window.contentView = nil }
        // Scrolls are reported once the layout from showing the window has settled.
        try await Task.sleep(for: .milliseconds(50))
        var reports: [Bool] = []
        editor.onScroll = { reports.append($0) }
        let preview = FakePane(scale: 50)
        let sync = ScrollSync(reducesMotion: { true })
        sync.connect(editor: editor, preview: preview)
        sync.isEnabled = true

        preview.scroll = 6000
        sync.paneScrolled(.preview, input: true)
        let metrics = try #require(editor.syncMetrics)
        #expect(abs(metrics.anchorOffset - metrics.view / 2) < 1)
        #expect(abs(try #require(editor.sourcePosition(at: metrics.anchorPoint)) - preview.middle) < 0.02)
        #expect(reports.isEmpty, "following isn't reported")

        // The reader scrolls the editor: reported, with whether they used the wheel or keys.
        // A scroll right after a layout change isn't reported, so each step scrolls until one is.
        let clip = editor.scrollView.contentView
        let scrollUntilReported = {
            let count = reports.count
            try await waitUntil {
                clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + 40))
                editor.scrollView.reflectScrolledClipView(clip)
                return reports.count > count
            }
        }
        try await scrollUntilReported()
        #expect(reports.allSatisfy { !$0 }, "no input: the reader didn't use the wheel or keys")
        (editor.scrollView as? EditorScrollView)?.onScrollWheel?()
        try await scrollUntilReported()
        #expect(reports.contains(true))
        try await scrollUntilReported()
        #expect(reports.filter { $0 }.count == 1, "input is reported once")
    }

    @Test func linesAndTheirRanges() {
        let (editor, window) = editor()
        defer { window.contentView = nil }
        let text = editor.textView.string as NSString
        let third = text.range(of: "Line 3 ").location
        let fifth = text.range(of: "Line 5 ").location
        #expect(editor.range(ofLines: 3...4) == NSRange(location: third, length: fifth - third))
        #expect(editor.range(ofLines: 301...301) == NSRange(location: text.length, length: 0))
        #expect(editor.range(ofLines: 300...999).upperBound == text.length)
    }

    /// In Split view the preview's scroll bar is the window's one scroll bar.
    @Test func splitViewHidesTheEditorsScrollBar() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        let workspace = WorkspaceContainer(editor: scroll, preview: NSView())
        workspace.setMode(.split)
        #expect(!scroll.hasVerticalScroller)
        workspace.setMode(.edit)
        #expect(scroll.hasVerticalScroller)
    }
}

extension TabCommandTests {
    /// Double-clicking a word in Preview Only shows the editor with that word selected.
    @Test func doubleClickInThePreviewEditsThatPlace() async throws {
        let folder = try TestFolder()
        try folder.write("a.md", "# Title\n\nSome words and more words here.\n\nLast words.\n")
        let model = AppModel.shared
        model.open(folder.url)
        try await waitUntil { model.tree.count == 1 }
        model.open(URL(fileURLWithPath: FileScanner.canonicalPath(folder.url.appendingPathComponent("a.md").path)))
        let host = EditorHost(model)
        defer { host.restore() }
        let mode = model.viewMode
        defer { model.setViewMode(mode) }
        model.setViewMode(.read)
        #expect(!model.scrollSync.isEnabled)

        model.editSource(5...5, word: "words")
        #expect(model.viewMode == .split)
        #expect(model.scrollSync.isEnabled, "the panes sync in Split view")
        let expected = (model.text as NSString).range(of: "words", options: .backwards)
        #expect(model.editor.textView.selectedRange() == expected, "the word in the clicked block, not an earlier one")

        model.editSource(3...3, word: "missing")
        #expect(model.editor.textView.selectedRange() == NSRange(location: (model.text as NSString).range(of: "Some").location, length: 0))
        model.closeTabsForProjectChange()
    }
}
