import Foundation
import Testing
@testable import LexMD
@testable import LexMDRendering

/// The page the Quick Look extension returns.
struct QuickLookPageTests {
    private func page(_ markdown: String, in folder: TestFolder, name: String = "Doc.md") throws -> QuickLookPage {
        let file = try folder.write(name, markdown)
        return try QuickLookPage.make(contentsOf: file)
    }

    @Test func rendersLikeTheAppWithoutScripts() throws {
        let folder = try TestFolder()
        let source = """
        ---
        title: Plan
        tags: [a, b]
        ---
        # Heading

        - [x] done
        - [ ] open

        | A | B |
        |---|--:|
        | 1 | 2 |

        > [!NOTE]
        > Remember this.

        Euler $e^x$ and a note[^1].

        [^1]: The note.

        ```mermaid
        flowchart LR
          A --> B
        ```

        <script>alert(1)</script>
        """
        let html = try page(source, in: folder).html
        let body = MarkdownHTML.render(source)
        #expect(html.contains("<article id=\"content\">\(body)</article>"))
        #expect(html.contains(#"<div class="properties">"#))
        #expect(html.contains(#"<ul class="tasks">"#))
        #expect(html.contains(#"<div class="table-wrap">"#))
        #expect(html.contains(#"<div class="callout callout-note">"#))
        #expect(html.contains(#"<section class="footnotes">"#))
        #expect(html.contains(#"<span class="lexmd-math" data-tex="e^x">$e^x$</span>"#))
        #expect(html.contains(#"<div class="lexmd-diagram">"#))
        #expect(html.contains("flowchart LR"))
        // Styles from the app, light and dark, and a policy that blocks scripts and the network.
        #expect(html.contains(PreviewStyle.page))
        #expect(html.contains(PreviewStyle.standalone))
        #expect(!html.contains("::-webkit-scrollbar { width: 0"), "only the in-app preview hides scroll bars")
        #expect(html.contains(PreviewStyle.rendering))
        #expect(html.contains("@media (prefers-color-scheme: dark)"))
        #expect(html.contains("default-src 'none'"))
        #expect(!html.contains("script-src"))
        #expect(html.contains("<title>Doc.md</title>"))
    }

    @Test func attachesLocalImagesAndDropsRemoteOnes() throws {
        let folder = try TestFolder()
        try folder.writePNG("pic.png")
        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent("img dir"), withIntermediateDirectories: true)
        try folder.writePNG("img dir/b.png")
        let source = """
        ![Local](pic.png) ![Again](./pic.png "title") ![Spaced](img%20dir/b.png)

        ![Remote](https://example.com/x.png) ![Protocol](//example.com/y.png)

        <img src="https://example.com/z.png" srcset="https://example.com/z2.png 2x" alt="Raw remote">
        <img src='img dir/b.png' srcset="img%20dir/b.png 2x">

        ![Missing](nope.png) ![Text](notes.txt)

        ![Inline](data:image/png;base64,iVBORw0KGgo=)
        """
        let result = try page(source, in: folder)
        let html = result.html
        #expect(result.images.map(\.identifier) == ["image-1", "image-2"])
        #expect(result.images.map { $0.fileURL.lastPathComponent } == ["pic.png", "b.png"])
        #expect(result.images.allSatisfy { $0.contentType == .png && !$0.data.isEmpty })
        #expect(html.contains(#"<img src="cid:image-1" alt="Local""#))
        #expect(html.contains(#"<img src="cid:image-1" alt="Again" title="title""#))
        #expect(html.contains(#"<img src="cid:image-2" alt="Spaced""#))
        #expect(html.contains(#"<img src="cid:image-2">"#))
        #expect(!html.contains("example.com"))
        #expect(!html.contains("srcset"))
        #expect(html.contains(#"<span class="lexmd-image-omitted">Remote</span>"#))
        #expect(html.contains(#"<span class="lexmd-image-omitted">Raw remote</span>"#))
        #expect(html.contains(#"<span class="lexmd-image-omitted">Missing</span>"#))
        #expect(html.contains(#"<span class="lexmd-image-omitted">Text</span>"#))
        #expect(html.contains(#"src="data:image/png;base64,iVBORw0KGgo=""#))
    }

    @Test func readsImagesThroughSymlinks() throws {
        let folder = try TestFolder()
        try folder.writePNG("real.png")
        let link = folder.url.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder.url.appendingPathComponent("real.png"))
        #expect(QuickLookPage.readImage(link, limit: 1 << 20) != nil, "the app's preview shows symlinked images too")
        #expect(QuickLookPage.readImage(link, limit: 1) == nil)
        #expect(QuickLookPage.readImage(folder.url, limit: 1 << 20) == nil)
    }

    @Test func capsTotalImageSize() throws {
        let folder = try TestFolder()
        let file = folder.url.appendingPathComponent("Doc.md")
        let markdown = "![a](a.png) ![b](b.png) ![c](c.png)"
        let big = QuickLookPage.maxImageBytes / 2 + 1
        var asked: [String] = []
        let result = QuickLookPage.make(data: Data(markdown.utf8), fileURL: file) { url, limit in
            asked.append(url.lastPathComponent)
            return big <= limit ? Data(count: big) : nil
        }
        #expect(asked == ["a.png", "b.png", "c.png"])
        #expect(result.images.map { $0.fileURL.lastPathComponent } == ["a.png"])
        #expect(result.html.contains(#"<span class="lexmd-image-omitted">b</span>"#))
    }

    @Test func capsLargeFilesWithANote() throws {
        let line = String(repeating: "word ", count: 19) + "\n"
        let lines = QuickLookPage.maxInputBytes / line.utf8.count + 10
        let markdown = String(repeating: line, count: lines)
        let file = URL(fileURLWithPath: "/tmp/Big.md")
        let result = QuickLookPage.make(data: Data(markdown.utf8), fileSize: markdown.utf8.count, fileURL: file)
        #expect(result.isTruncated)
        #expect(result.html.contains(#"<p class="lexmd-ql-note">"#))
        #expect(result.html.utf8.count < markdown.utf8.count + 100_000)

        let small = QuickLookPage.make(data: Data("# Small".utf8), fileURL: file)
        #expect(!small.isTruncated)
        #expect(!small.html.contains(#"<p class="lexmd-ql-note">"#))
    }

    @Test func emptyFileShowsThePlaceholder() throws {
        let result = QuickLookPage.make(data: Data(), fileURL: URL(fileURLWithPath: "/tmp/Empty.md"))
        #expect(result.html.contains(#"<article id="content"></article>"#))
    }

    @Test func classifiesImageSources() {
        let folder = URL(fileURLWithPath: "/docs/notes")
        typealias Source = QuickLookPage.ImageSource
        #expect(Source("a.png", folder: folder) == .local(URL(fileURLWithPath: "/docs/notes/a.png")))
        #expect(Source("../img/a%20b.JPG?x=1#y", folder: folder) == .local(URL(fileURLWithPath: "/docs/img/a b.JPG")))
        #expect(Source("/abs/a.gif", folder: folder) == .local(URL(fileURLWithPath: "/abs/a.gif")))
        #expect(Source("file:///abs/a.svg", folder: folder) == .local(URL(fileURLWithPath: "/abs/a.svg")))
        #expect(Source("HTTPS://example.com/a.png", folder: folder) == .remote)
        #expect(Source("//example.com/a.png", folder: folder) == .remote)
        #expect(Source("data:image/png;base64,AA==", folder: folder) == .inline)
        #expect(Source("data:text/html,hi", folder: folder) == .unsupported)
        #expect(Source("notes.md", folder: folder) == .unsupported)
        #expect(Source("", folder: folder) == .unsupported)
    }
}

/// The app's preview page and the Quick Look page share one stylesheet.
struct SharedStyleTests {
    @Test func appPreviewEmbedsTheSharedStyles() {
        let page = PreviewTemplate.html(allowsRemoteContent: false)
        #expect(page.contains("<base id=\"lexmd-base\" href=\"\">\n<style>\n" + PreviewStyle.page + "\n</style>\n"))
        #expect(page.contains("<style>\n" + PreviewStyle.rendering + "</style>\n"))
    }
}
