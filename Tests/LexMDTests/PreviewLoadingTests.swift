import AppKit
import Foundation
import Testing
import WebKit
@testable import LexMD
@testable import LexMDRendering

/// Page loads, reloads, and render timing in the live preview.
@MainActor
@Suite(.serialized)
struct PreviewLoadingTests {
    private func makePreview(allowsRemoteContent: Bool = false) -> (PreviewController, NSWindow) {
        let preview = PreviewController(allowsRemoteContent: allowsRemoteContent)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = preview.webView
        return (preview, window)
    }

    @Test func reloadsInQuickSuccessionStillShowTheDocument() async throws {
        let (preview, window) = makePreview()
        defer { window.contentView = nil }
        preview.setAllowsRemoteContent(true)
        preview.setAllowsRemoteContent(false)
        preview.setAllowsRemoteContent(true)
        preview.render(html: "<h1>Shown</h1>", baseURL: nil, resetScroll: true)
        try await waitUntil(seconds: 10) { try await page(preview, "return document.querySelector('#content h1') !== null") as? Bool == true }
        #expect(preview.isPageLoaded)
        #expect(try await page(preview, "return document.querySelector('meta[http-equiv]').content.indexOf('https:') >= 0") as? Bool == true)
    }

    @Test func scrollPositionWaitsForTheNextDocument() async throws {
        let (preview, window) = makePreview()
        defer { window.contentView = nil }
        // A restored tab sets its scroll position before its document has rendered; the page
        // finishing its load in between must not use it up on the empty page.
        preview.pendingScrollFraction = 0.5
        try await waitUntil { preview.isPageLoaded }
        try await Task.sleep(for: .milliseconds(200))
        let long = (0..<200).map { "<p>Paragraph \($0)</p>" }.joined(separator: "\n")
        preview.render(html: long, baseURL: nil, resetScroll: true)
        try await waitUntil(seconds: 10) { try await page(preview, "return window.scrollY > 0") as? Bool == true }
        let fraction = try #require(try await page(preview, "return window.scrollY / (document.documentElement.scrollHeight - window.innerHeight)") as? Double)
        #expect(abs(fraction - 0.5) < 0.02)
    }

    @Test func aRenderSharesOneMathBudget() async throws {
        let (preview, window) = makePreview()
        defer { window.contentView = nil }
        preview.render(html: MarkdownHTML.render("Load $x$."), baseURL: nil, resetScroll: true)
        try await waitUntil { try await page(preview, "return document.querySelector('.katex') !== null") as? Bool == true }

        // Each block holds new math, so a budget per block would typeset everything at once.
        let count = 1500
        let source = (0..<count).map { #"Block $\sum_{k=0}^{n} \frac{k^{\#($0)}}{\sqrt{\#($0) + k}}$."# }.joined(separator: "\n\n")
        let counts = try #require(try await world(preview, """
            lexmdRender(html, '', true);
            return [document.querySelectorAll('.lexmd-math.rendered').length, document.querySelectorAll('.lexmd-math').length];
            """, ["html": MarkdownHTML.render(source)]) as? [Int])
        #expect(counts[1] == count)
        #expect(counts[0] < count, "math past the budget is queued")
        // The rest is typeset in slices (slow here, as hidden pages throttle timers) or on demand.
        _ = try await world(preview, "return lexmdRenderAll()")
        #expect(try await page(preview, "return document.querySelectorAll('.lexmd-math.rendered').length") as? Int == count)
    }

    @Test func metaRefreshInMarkupDoesNotOpenDocuments() async throws {
        let folder = try TestFolder()
        let target = try folder.write("other.md", "# Other\n")
        let (preview, window) = makePreview()
        defer { window.contentView = nil }
        var opened: [URL] = []
        preview.onOpenURL = { opened.append($0) }
        preview.render(html: "<h1>Doc</h1>\n<meta http-equiv=\"refresh\" content=\"0;url=\(target.absoluteString)\">", baseURL: folder.url, resetScroll: true)
        try await waitUntil { try await page(preview, "return document.querySelector('#content h1') !== null") as? Bool == true }
        try await Task.sleep(for: .milliseconds(1500))
        #expect(opened.isEmpty, "markup navigated to \(opened)")
    }
}

/// Records what a scheme handler answers.
private final class RecordingSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var response: URLResponse?
    var data = Data()
    var finished = false
    var error: (any Error)?

    init(_ request: URLRequest) { self.request = request }
    func didReceive(_ response: URLResponse) { self.response = response }
    func didReceive(_ data: Data) { self.data.append(data) }
    func didFinish() { finished = true }
    func didFailWithError(_ error: any Error) { self.error = error }
}

@MainActor
@Suite(.serialized)
struct DocumentSchemeHandlerTests {
    @Test func servesFilesAndRangesAndHonorsStop() async throws {
        let folder = try TestFolder()
        try folder.writePNG("image.png")
        let file = folder.url.appendingPathComponent("image.png")
        let bytes = try Data(contentsOf: file)
        let url = try #require(DocumentSchemeHandler.url(for: file))
        let handler = DocumentSchemeHandler()
        let webView = WKWebView()

        let whole = RecordingSchemeTask(URLRequest(url: url))
        handler.webView(webView, start: whole)
        try await waitUntil(seconds: 10) { whole.finished }
        #expect((whole.response as? HTTPURLResponse)?.statusCode == 200)
        #expect(whole.data == bytes)

        var request = URLRequest(url: url)
        request.setValue("bytes=1-4", forHTTPHeaderField: "Range")
        let part = RecordingSchemeTask(request)
        handler.webView(webView, start: part)
        try await waitUntil(seconds: 10) { part.finished }
        #expect((part.response as? HTTPURLResponse)?.statusCode == 206)
        #expect((part.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range") == "bytes 1-4/\(bytes.count)")
        #expect(part.data == bytes.subdata(in: 1..<5))

        // The file is read off the main thread, so a request stopped meanwhile is never answered.
        let stopped = RecordingSchemeTask(URLRequest(url: url))
        handler.webView(webView, start: stopped)
        handler.webView(webView, stop: stopped)
        try await Task.sleep(for: .milliseconds(300))
        #expect(stopped.response == nil && !stopped.finished && stopped.error == nil)

        // Only media is served.
        let script = RecordingSchemeTask(URLRequest(url: try #require(DocumentSchemeHandler.url(for: try folder.write("run.sh", "echo")))))
        handler.webView(webView, start: script)
        try await waitUntil(seconds: 10) { script.error != nil }
        #expect(script.response == nil)
    }
}

/// Evaluates JavaScript in the page world, where document markup lives.
@MainActor
private func page(_ preview: PreviewController, _ body: String) async throws -> Any? {
    try await preview.webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
}

/// Evaluates JavaScript in LexMD's content world.
@MainActor
private func world(_ preview: PreviewController, _ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
    try await preview.webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .world(name: "LexMD"))
}
