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
