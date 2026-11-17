import AppKit
import Foundation
import Testing
import WebKit
@testable import LexMD

/// Renders hostile markup in the real preview and checks that nothing in it can act.
@MainActor
@Suite(.serialized)
struct PreviewSecurityTests {
    @Test func documentMarkupCannotRunScriptsOrNavigate() async throws {
        let folder = try TestFolder()
        try folder.writePNG("icon.png")
        try folder.write("evil.command", "#!/bin/sh\ntouch \"\(folder.url.path)/ran\"\n", executable: true)
        try folder.write("second.md", "# Second\n")

        let preview = PreviewController(allowsRemoteContent: false)
        var opened: [URL] = []
        preview.onOpenURL = { opened.append($0) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = preview.webView

        let html = """
        <h1>Title</h1>
        <p><img id="local" src="icon.png"></p>
        <p><img id="trap" src="missing.png" onerror="document.body.insertAdjacentHTML('afterbegin','<b id=ran>handler</b>')"></p>
        <script>document.body.insertAdjacentHTML('afterbegin','<b id=ran>script</b>')</script>
        <details open ontoggle="document.body.insertAdjacentHTML('afterbegin','<b id=ran>toggle</b>')"><summary>s</summary>x</details>
        <meta http-equiv="refresh" content="0;url=evil.command">
        <p><a id="run" href="evil.command">run</a> <a id="next" href="second.md">next</a> <a id="web" href="https://example.com">web</a></p>
        <p><img id="remote" src="https://example.com/remote.png"></p>
        """
        preview.render(html: html, baseURL: folder.url, resetScroll: true)

        // LexMD's own script (isolated world) renders the document.
        try await waitUntil { try await page(preview, "return document.querySelector('#content h1') !== null") as? Bool == true }
        // Let the broken image fail, the details element toggle, and the meta refresh fire.
        try await waitUntil { try await page(preview, "return document.getElementById('trap').complete") as? Bool == true }
        try await Task.sleep(for: .milliseconds(1500))

        #expect(try await page(preview, "return document.getElementById('ran') === null") as? Bool == true)
        #expect(try await page(preview, "return typeof (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.lexmd)") as? String == "undefined",
                "document markup cannot reach LexMD's message handler (clipboard)")
        #expect(opened.isEmpty, "nothing navigates without a click: \(opened)")
        #expect(!FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("ran").path))

        // Local images load through the document scheme; remote ones are blocked by default.
        try await waitUntil { try await page(preview, "return document.getElementById('local').naturalWidth") as? Int ?? 0 > 0 }
        #expect(try await page(preview, "return document.getElementById('remote').naturalWidth") as? Int == 0)

        // A real click reaches the app as a file URL; the app reveals rather than runs scripts.
        _ = try await page(preview, "document.getElementById('run').click()")
        try await waitUntil { !opened.isEmpty }
        let target = try #require(opened.first)
        #expect(target.isFileURL)
        #expect(FileScanner.canonicalPath(target.path) == FileScanner.canonicalPath(folder.url.appendingPathComponent("evil.command").path))
        #expect(!FileScanner.opensWithoutRunningCode(target))
    }

    @Test func templatePolicy() {
        let blocked = PreviewTemplate.html(allowsRemoteContent: false)
        #expect(blocked.contains("script-src 'none'"))
        #expect(blocked.contains("img-src lexmd-doc: data:;"))
        #expect(!blocked.contains("https:"))
        let allowed = PreviewTemplate.html(allowsRemoteContent: true)
        #expect(allowed.contains("img-src lexmd-doc: data: https:;"))
        #expect(allowed.contains("script-src 'none'"))
    }

    @Test func onlyViewerDocumentsOpenDirectly() throws {
        let folder = try TestFolder()
        let cases: [(String, Bool)] = [
            ("notes.txt", true), ("data.json", true), ("photo.png", true),
            ("run.command", false), ("tool.sh", false), ("page.html", false), ("link.webloc", false),
        ]
        for (name, expected) in cases {
            try folder.write(name, "x")
            #expect(FileScanner.opensWithoutRunningCode(folder.url.appendingPathComponent(name)) == expected, "\(name)")
        }
        try folder.write("marked.txt", "x", executable: true)
        #expect(!FileScanner.opensWithoutRunningCode(folder.url.appendingPathComponent("marked.txt")))
        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent("Fake.app"), withIntermediateDirectories: true)
        #expect(!FileScanner.opensWithoutRunningCode(folder.url.appendingPathComponent("Fake.app")))
    }

    @Test func documentURLsRoundTrip() throws {
        let file = URL(fileURLWithPath: "/tmp/A folder/Résumé #1.md")
        let url = try #require(DocumentSchemeHandler.url(for: file))
        #expect(url.scheme == "lexmd-doc")
        #expect(DocumentSchemeHandler.fileURL(for: url)?.path == file.path)
        #expect(DocumentSchemeHandler.fileURL(for: URL(string: "https://example.com/a")!) == nil)
    }

    @Test func byteRanges() {
        #expect(DocumentSchemeHandler.byteRange("bytes=0-99", size: 1000)! == (0, 99))
        #expect(DocumentSchemeHandler.byteRange("bytes=900-", size: 1000)! == (900, 999))
        #expect(DocumentSchemeHandler.byteRange("bytes=-100", size: 1000)! == (900, 999))
        #expect(DocumentSchemeHandler.byteRange("bytes=990-2000", size: 1000)! == (990, 999))
        #expect(DocumentSchemeHandler.byteRange("bytes=0-", size: 100 << 20)! == (0, (8 << 20) - 1))
        #expect(DocumentSchemeHandler.byteRange("bytes=1000-", size: 1000) == nil)
        #expect(DocumentSchemeHandler.byteRange("bytes=5-1", size: 1000) == nil)
        #expect(DocumentSchemeHandler.byteRange("bytes=0-1,4-5", size: 1000) == nil)
    }
}
