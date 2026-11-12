import AppKit
import Foundation
import PDFKit
import Testing
@testable import LexMD
@testable import LexMDRendering

@MainActor
@Suite(.serialized)
struct ExportTests {
    private static func longDocument() -> String {
        var markdown = "# Export Sample\n\nIntro with a [web link](https://example.com/page) and **bold** text.\n\n"
        for index in 1...45 {
            markdown += "## Section \(index)\n\nParagraph \(index) has enough words to wrap across a line or two "
            markdown += "so that the printed document needs several pages in total.\n\n"
        }
        markdown += "```swift\nlet answer = 42 // the last block\n```\n\n| Name | Value |\n| --- | ---: |\n| Final | 7 |\n"
        return markdown
    }

    // MARK: PDF

    @Test func pdfExportIsPaginatedAndContainsText() async throws {
        let folder = try TestFolder()
        let destination = folder.url.appendingPathComponent("Sample.pdf")
        let document = ExportDocument(markdown: Self.longDocument(), baseURL: folder.url, title: "Sample")
        try await Exporter.exportPDF(document, to: destination)

        let pdf = try #require(PDFDocument(url: destination))
        #expect(pdf.pageCount >= 3, "pages: \(pdf.pageCount)")
        let text = pdf.string ?? ""
        #expect(text.contains("Export Sample"))
        #expect(text.contains("Section 1"))
        #expect(text.contains("Section 45"))
        #expect(text.contains("let answer = 42"))
        #expect(text.contains("Final"))
        #expect(!text.contains("Copy"), "the code block's copy button is not printed")

        // A heading never ends a page; it moves to the next page with its paragraph.
        for index in 0..<pdf.pageCount {
            let lines = (pdf.page(at: index)?.string ?? "").split(whereSeparator: \.isNewline)
            let last = lines.last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            #expect(last.range(of: #"^Section \d+$"#, options: .regularExpression) == nil, "page \(index + 1) ends with \(last)")
        }

        // Pages use the user's paper size.
        let paper = Exporter.printInfo().paperSize
        let bounds = try #require(pdf.page(at: 0)).bounds(for: .mediaBox)
        #expect(abs(bounds.width - paper.width) < 1 && abs(bounds.height - paper.height) < 1, "\(bounds) vs \(paper)")

        // Links stay clickable.
        let links = (0..<pdf.pageCount).flatMap { pdf.page(at: $0)?.annotations ?? [] }.compactMap(\.url)
        #expect(links.contains(URL(string: "https://example.com/page")!), "links: \(links)")

        // Exporting again replaces the file.
        try await Exporter.exportPDF(ExportDocument(markdown: "# Short\n", baseURL: folder.url, title: "Short"), to: destination)
        let replaced = try #require(PDFDocument(url: destination))
        #expect(replaced.pageCount == 1)
        #expect(replaced.string?.contains("Short") == true)
    }

    @Test func pdfExportReportsWriteFailure() async throws {
        let folder = try TestFolder()
        let locked = folder.url.appendingPathComponent("Locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let document = ExportDocument(markdown: "# Locked\n", baseURL: folder.url, title: "Locked")
        await #expect(throws: (any Error).self) {
            try await Exporter.exportPDF(document, to: locked.appendingPathComponent("Locked.pdf"))
        }
        #expect(!FileManager.default.fileExists(atPath: locked.appendingPathComponent("Locked.pdf").path))
    }

    // MARK: HTML

    private static let hostileMarkdown = """
    # Hello

    <script>document.title = 'ran'</script>
    <img src="missing.png" onerror="alert(2)" onload = "alert(3)">
    <a href="javascript:alert(4)">bad link</a> <a href=" JaVaScRiPt:alert(5)">spaced</a>
    <iframe srcdoc="<script>alert(6)</script>"></iframe>
    <svg width="10" height="10"><a href="javascript:alert(7)"><rect width="10" height="10" onclick="alert(8)"/></a><script>alert(9)</script></svg>
    <xmp><script>alert(10)</script></xmp>
    <template><script>alert(11)</script></template>
    <noscript><script>alert(12)</script></noscript>

    ![local](icon.png)

    ![remote](https://example.com/remote.png)

    [next](second%20doc.md#part) and [anchor](#hello)

    ```js
    const a = "<script>";
    ```
    """

    @Test func htmlExportIsStandaloneAndSafe() async throws {
        let folder = try TestFolder()
        try folder.writePNG("icon.png")
        let destination = folder.url.appendingPathComponent("Out.html")
        let document = ExportDocument(markdown: Self.hostileMarkdown, baseURL: folder.url, title: "A <b> & \"c\"")
        let result = try await Exporter.exportHTML(document, to: destination)
        let html = try String(contentsOf: destination, encoding: .utf8)

        #expect(!html.lowercased().contains("<script"))
        #expect(html.range(of: #"\son[a-z]+\s*="#, options: [.regularExpression, .caseInsensitive]) == nil)
        #expect(!html.lowercased().contains("javascript:"))
        #expect(!html.contains("<iframe") && !html.contains("srcdoc") && !html.contains("<template"))
        #expect(html.contains(#"<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none';"#))
        #expect(html.contains("<title>A &lt;b&gt; &amp; &quot;c&quot;</title>"))
        #expect(html.contains(#"src="data:image/png;base64,"#))
        #expect(html.contains(#"src="https://example.com/remote.png""#))
        #expect(html.contains(#"href="second%20doc.md#part""#))
        #expect(html.contains(##"href="#hello""##))
        #expect(html.contains("&lt;script&gt;"), "code keeps its text, escaped")
        #expect(html.contains("prefers-color-scheme: dark"))
        #expect(html.contains("@media print"))
        #expect(!html.contains("lexmd-doc:"))
        #expect(!html.contains("lexmd-res-"))
        #expect(!html.contains(#"class="copy""#))
        #expect(result.linkedImages.isEmpty)
    }

    @Test func htmlExportLinksImagesOverTheLimits() async throws {
        let folder = try TestFolder()
        try folder.writePNG("one.png")
        try folder.writePNG("two.png")
        let size = try #require(try FileManager.default.attributesOfItem(atPath: folder.url.appendingPathComponent("one.png").path)[.size] as? Int)
        let markdown = "![one](one.png)\n\n![two](two.png)\n\n![again](one.png)\n"
        let document = ExportDocument(markdown: markdown, baseURL: folder.url, title: "Images")

        // Each image fits on its own, but only one fits in the total.
        let outFolder = folder.url.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: outFolder, withIntermediateDirectories: true)
        let limited = try await Exporter.exportHTML(
            document, to: outFolder.appendingPathComponent("Images.html"),
            limits: .init(perImage: size, total: size + size / 2)
        )
        let html = try String(contentsOf: outFolder.appendingPathComponent("Images.html"), encoding: .utf8)
        #expect(limited.linkedImages == ["two.png"])
        #expect(html.components(separatedBy: "data:image/png;base64,").count - 1 == 2, "one.png is embedded twice")
        #expect(html.contains(#"src="../two.png""#))

        // Over the per-image limit, every image is linked.
        let small = try await Exporter.exportHTML(
            document, to: folder.url.appendingPathComponent("Small.html"), limits: .init(perImage: 10, total: 1000)
        )
        #expect(small.linkedImages == ["one.png", "two.png"])
        let smallHTML = try String(contentsOf: folder.url.appendingPathComponent("Small.html"), encoding: .utf8)
        #expect(smallHTML.contains(#"src="one.png""#))
        #expect(!smallHTML.contains("data:image/png"))
    }

    @Test func relativePaths() {
        let folder = URL(fileURLWithPath: "/tmp/LexMD Export/docs", isDirectory: true)
        #expect(Exporter.relativePath(from: folder, to: URL(fileURLWithPath: "/tmp/LexMD Export/docs/a b.png")) == "a%20b.png")
        #expect(Exporter.relativePath(from: folder, to: URL(fileURLWithPath: "/tmp/LexMD Export/img/x#1.png")) == "../img/x%231.png")
        #expect(Exporter.relativePath(from: folder, to: URL(fileURLWithPath: "/tmp/LexMD Export/docs/c:d.png")) == "./c:d.png")
        #expect(Exporter.relativePath(from: folder, to: URL(fileURLWithPath: "/tmp/LexMD Export/docs/sub/../e.png")) == "e.png")
    }

    @Test func relativePathsToMissingFilesUnderSymlinkedFolders() throws {
        // Temporary folders live under /var, a symlink to /private/var.
        let folder = try TestFolder()
        let out = folder.url.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let missing = folder.url.appendingPathComponent("notes/Missing File.md")
        #expect(Exporter.relativePath(from: out, to: missing) == "../notes/Missing%20File.md")
    }

    // MARK: Rich text

    private static let richMarkdown = """
    # Heading One

    Some **bold** and *italic* text with a [link](https://example.com/rich) and `inline code`.

    - First item
    - Second item

    | Name | Value |
    | --- | --- |
    | Alpha | 1 |

    ```swift
    let value = 1
    ```

    <img src="x.png" onerror="alert(1)">
    """

    private func renderedPreview(_ markdown: String, folder: TestFolder) async throws -> (PreviewController, NSWindow) {
        let preview = PreviewController(allowsRemoteContent: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = preview.webView
        preview.render(html: MarkdownHTML.render(markdown), baseURL: folder.url, resetScroll: true)
        try await waitUntil {
            guard preview.isPageLoaded else { return false }
            return try await preview.evaluate("return document.querySelector('#content h1') !== null") as? Bool == true
        }
        return (preview, window)
    }

    @Test func richTextCopyPutsHTMLAndRTFOnPasteboard() async throws {
        let folder = try TestFolder()
        let (preview, window) = try await renderedPreview(Self.richMarkdown, folder: folder)
        defer { window.close() }
        let rich = try await Exporter.richText(from: preview, selection: true)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("LexMDTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        Exporter.write(rich, to: pasteboard)

        let types = pasteboard.types ?? []
        #expect(types.contains(.html) && types.contains(.rtf) && types.contains(.string))

        let html = try #require(pasteboard.string(forType: .html))
        #expect(html.contains("<h1") && html.contains("<strong") && html.contains("<table") && html.contains("<ul"))
        #expect(html.contains("Menlo"), "code keeps a monospaced font")
        #expect(html.contains(#"href="https://example.com/rich""#))
        #expect(!html.lowercased().contains("<script") && !html.contains("onerror") && !html.contains(">Copy<"))

        let text = try #require(pasteboard.string(forType: .string))
        #expect(text.contains("Heading One") && text.contains("Alpha") && text.contains("let value = 1"))
        #expect(!text.contains("Copy"))

        let rtf = try #require(pasteboard.data(forType: .rtf))
        let attributed = try #require(NSAttributedString(rtf: rtf, documentAttributes: nil))
        let string = attributed.string as NSString
        #expect(string.contains("Heading One") && string.contains("Second item") && string.contains("Alpha"))
        let bold = string.range(of: "bold")
        let boldFont = attributed.attribute(.font, at: bold.location, effectiveRange: nil) as? NSFont
        #expect(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        let link = string.range(of: "link")
        let url = attributed.attribute(.link, at: link.location, effectiveRange: nil)
        #expect((url as? URL)?.absoluteString == "https://example.com/rich" || (url as? String) == "https://example.com/rich")
        let code = string.range(of: "let value")
        let codeFont = attributed.attribute(.font, at: code.location, effectiveRange: nil) as? NSFont
        #expect(codeFont?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true, "\(String(describing: codeFont))")

        // Copying never touches the visible preview's content.
        #expect(try await preview.evaluate("return document.querySelectorAll('#content .copy').length") as? Int == 1)
    }

    @Test func richTextCopyUsesPreviewSelection() async throws {
        let folder = try TestFolder()
        let (preview, window) = try await renderedPreview(Self.richMarkdown, folder: folder)
        defer { window.close() }
        _ = try await preview.evaluate("window.getSelection().selectAllChildren(document.querySelector('#content table')); return true")
        let rich = try await Exporter.richText(from: preview, selection: true)
        #expect(rich.html.contains("<table") && rich.html.contains("Alpha"))
        #expect(!rich.html.contains("Heading One"))
        #expect(rich.text.contains("Alpha") && !rich.text.contains("Heading One"))

        // Without selection support (Editor Only mode), the whole document is copied.
        let whole = try await Exporter.richText(from: preview, selection: false)
        #expect(whole.html.contains("Heading One"))
    }

    @Test func richTextFromMarkdownSelection() async throws {
        let folder = try TestFolder()
        let document = ExportDocument(markdown: "Just **this** and `that`.", baseURL: folder.url, title: "Part")
        let rich = try await Exporter.richText(document)
        #expect(rich.html.contains("<strong") && rich.html.contains("this"))
        #expect(rich.text == "Just this and that.")
        let rtf = try #require(Exporter.rtfData(fromHTML: rich.rtfHTML))
        #expect(NSAttributedString(rtf: rtf, documentAttributes: nil)?.string == "Just this and that.")
    }

    // MARK: Diagrams and math

    private static let diagramMarkdown = """
    # Diagrams and Math

    Inline math $e^{i\\pi} + 1 = 0$ sits in this sentence.

    $$
    \\int_0^1 x^2 \\, dx = \\frac{1}{3}
    $$

    ```mermaid
    flowchart LR
      Start --> Finish
    ```
    """

    @Test func htmlExportEmbedsDiagramsMathAndFonts() async throws {
        let folder = try TestFolder()
        let destination = folder.url.appendingPathComponent("Math.html")
        let document = ExportDocument(markdown: Self.diagramMarkdown, baseURL: folder.url, title: "Math")
        try await Exporter.exportHTML(document, to: destination)
        let html = try String(contentsOf: destination, encoding: .utf8)

        #expect(html.contains("<svg"), "the diagram is exported as SVG")
        #expect(html.contains("lexmd-diagram-view"))
        #expect(!html.contains("Diagram error"))
        #expect(html.contains(#"class="katex""#) && html.contains("katex-display"))
        #expect(html.contains("application/x-tex"), "math keeps its MathML and TeX annotation")
        #expect(html.contains("src:url(data:font/woff2;base64,"))
        #expect(html.contains("font-family:KaTeX_Main"))
        #expect(!html.contains("font-family:KaTeX_Fraktur;font-style"), "unused font families are not embedded")
        let embedded = html.components(separatedBy: "data:font/woff2;base64,").count - 1
        #expect(embedded > 0 && embedded < 20, "embedded fonts: \(embedded)")
        #expect(!html.contains("lexmd-vendor:") && !html.contains("lexmd-doc:"))
        #expect(!html.lowercased().contains("<script"))
        // Diagram colors follow the color scheme in the standalone page.
        #expect(html.contains("--pele-fg: var(--text)") && html.contains("--diagram-bg: #1c1c1e"))

        // Without math, KaTeX's stylesheet is left out.
        let plain = folder.url.appendingPathComponent("Plain.html")
        try await Exporter.exportHTML(ExportDocument(markdown: "# Plain\n\nNo math.", baseURL: folder.url, title: "Plain"), to: plain)
        let plainHTML = try String(contentsOf: plain, encoding: .utf8)
        #expect(!plainHTML.contains("KaTeX") && !plainHTML.contains("lexmd-vendor:"))
    }

    @Test func pdfExportIncludesMathAndDiagrams() async throws {
        let folder = try TestFolder()
        let destination = folder.url.appendingPathComponent("Math.pdf")
        let document = ExportDocument(markdown: Self.diagramMarkdown, baseURL: folder.url, title: "Math")
        try await Exporter.exportPDF(document, to: destination)
        let pdf = try #require(PDFDocument(url: destination))
        let text = (pdf.string ?? "").replacingOccurrences(of: "\u{00A0}", with: " ")
        #expect(text.contains("Diagrams and Math"))
        #expect(text.contains("Start") && text.contains("Finish"), "diagram labels are printed")
        #expect(text.contains("π") || text.contains("𝜋"), "inline math is typeset: \(text)")
        #expect(text.contains("∫"), "display math is typeset")
        #expect(!text.contains("Diagram error") && !text.contains("not available"))
        #expect(!text.contains("$$") && !text.contains("\\int"), "no raw TeX is left")
    }

    @Test func printRenderingLoadsKaTeXFontsAndUsesLightDiagrams() async throws {
        let folder = try TestFolder()
        let renderer = OffscreenRenderer(allowsRemoteContent: false)
        try await renderer.load(ExportDocument(markdown: Self.diagramMarkdown, baseURL: folder.url, title: "Math"), forPrint: true)
        let loaded = try await renderer.preview.evaluate("""
            return Array.from(document.fonts).filter(function (f) { return f.family.indexOf('KaTeX') >= 0 && f.status === 'loaded'; }).length
            """) as? Int ?? 0
        #expect(loaded > 0, "KaTeX fonts are loaded before printing")
        #expect(try await renderer.preview.evaluate("return document.fonts.status") as? String == "loaded")
        let background = try await renderer.preview.evaluate(
            "return getComputedStyle(document.querySelector('.lexmd-diagram-view')).backgroundColor"
        ) as? String
        #expect(background == "rgb(255, 255, 255)")
    }

    @Test func kaTeXFontEmbeddingKeepsOnlyUsedFamilies() {
        let css = """
        .katex{font:normal 1.21em KaTeX_Main}\
        @font-face{font-display:block;font-family:KaTeX_Main;font-style:normal;font-weight:400;src:url(lexmd-vendor:///katex/fonts/KaTeX_Main-Regular.woff2) format("woff2"),url(lexmd-vendor:///katex/fonts/KaTeX_Main-Regular.woff) format("woff")}\
        @font-face{font-display:block;font-family:KaTeX_Script;font-style:normal;font-weight:400;src:url(lexmd-vendor:///katex/fonts/KaTeX_Script-Regular.woff2) format("woff2")}\
        @font-face{font-family:KaTeX_Main;font-weight:700;src:url(lexmd-vendor:///katex/fonts/Missing.woff2) format("woff2")}
        """
        let output = Exporter.embedKaTeXFonts(css, families: ["KaTeX_Main"])
        #expect(output.hasPrefix(".katex{font:normal 1.21em KaTeX_Main}"))
        #expect(output.components(separatedBy: "@font-face").count - 1 == 1, "missing files and unused families are dropped")
        #expect(output.contains("src:url(data:font/woff2;base64,"))
        #expect(!output.contains("lexmd-vendor:") && !output.contains("KaTeX_Script"))
        #expect(Exporter.withoutAppURLs("a{b:url(lexmd-doc:///x.png)} c{d:url( 'lexmd-vendor:///y')}") == "a{b:url(data:,)} c{d:url(data:,)}")
    }

    // MARK: Commands

    @Test func defaultShortcutsDoNotClash() {
        let shortcuts = ShortcutAction.allCases.compactMap(\.defaultShortcut).map(\.string)
        #expect(Set(shortcuts).count == shortcuts.count)
        #expect(ShortcutAction.exportPDF.defaultShortcut?.string == "shift+cmd+e")
        #expect(ShortcutAction.printDocument.defaultShortcut?.string == "option+cmd+p")
        #expect(ShortcutAction.copyRichText.defaultShortcut?.string == "option+cmd+c")
        #expect(ShortcutAction.exportHTML.defaultShortcut == nil)
    }
}
