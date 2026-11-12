import AppKit
import Foundation
import Testing
import WebKit
@testable import LexMD
@testable import LexMDRendering

/// Math, footnotes, and front matter in the Markdown renderer.
struct MarkdownRenderingTests {
    private func math(_ html: String) -> [String] {
        var found: [String] = []
        var rest = html[...]
        while let range = rest.range(of: "data-tex=\"") {
            let tail = rest[range.upperBound...]
            guard let end = tail.firstIndex(of: "\"") else { break }
            found.append(String(tail[..<end]))
            rest = tail[end...]
        }
        return found
    }

    @Test func inlineMath() {
        let html = MarkdownHTML.render("Euler: $e^{i\\pi} + 1 = 0$ and $x$.")
        #expect(math(html) == ["e^{i\\pi} + 1 = 0", "x"])
        #expect(html.contains("<span class=\"lexmd-math\" data-tex=\"x\">$x$</span>"))
        #expect(!html.contains("\u{E000}"))
    }

    @Test func currencyIsNotMath() {
        for text in ["It costs $5 and $10.", "Between $20,000 and $30,000 a year.", "Pay $5 now, $6 later",
                     "a $ b $ c", "x$ and $y", "From $3 to 4$5", "Just one $dollar sign", "$ spaced$", "$spaced $"] {
            #expect(math(MarkdownHTML.render(text)).isEmpty, "\(text)")
        }
    }

    @Test func escapedDollars() {
        let html = MarkdownHTML.render("Prices \\$5 and \\$10, and \\$x\\$ is text.")
        #expect(math(html).isEmpty)
        #expect(html.contains("Prices $5 and $10, and $x$ is text."))
        #expect(math(MarkdownHTML.render("$a \\$ b$")) == ["a \\$ b"])
    }

    @Test func codeIsNotMath() {
        let source = """
        Inline `$x$` code, then é `$y$` and $z$.

        ```
        $code$ in a fence
        ```

            $indented$ code

        - item with `$a$` and $b$
        > quote with $c$

        <div>$raw$ html</div>
        """
        let html = MarkdownHTML.render(source)
        #expect(math(html) == ["z", "b", "c"])
        #expect(html.contains("<code>$x$</code>"))
        #expect(html.contains("$code$ in a fence"))
        #expect(html.contains("$indented$ code"))
        #expect(html.contains("<div>$raw$ html</div>"))
    }

    @Test func markdownInsideMathIsLeftAlone() {
        let html = MarkdownHTML.render("$a*b$ and $c*d$, also $x_1 + y_2$ and $\\{a\\}$.")
        #expect(math(html) == ["a*b", "c*d", "x_1 + y_2", "\\{a\\}"])
        #expect(!html.contains("<em>"))
    }

    @Test func displayMath() {
        let html = MarkdownHTML.render("""
        Before.

        $$
        \\int_0^1 x\\,dx
          = \\frac{1}{2}
        $$

        After $$a+b$$ inline.
        """)
        #expect(html.contains("<div class=\"lexmd-math lexmd-display\" data-tex=\"\\int_0^1 x\\,dx\n  = \\frac{1}{2}\">"))
        #expect(html.contains("<span class=\"lexmd-math lexmd-display\" data-tex=\"a+b\">"))
        #expect(!html.contains("<p><div"))
    }

    @Test func mathDoesNotCrossBlankLines() {
        #expect(math(MarkdownHTML.render("$a\n\nb$")).isEmpty)
        #expect(math(MarkdownHTML.render("$$a\n\nb$$")).isEmpty)
        #expect(math(MarkdownHTML.render("$a\nb$")) == ["a\nb"])
        #expect(math(MarkdownHTML.render("$$$$")).isEmpty)
    }

    @Test func mathFence() {
        let html = MarkdownHTML.render("```math\nx^2 < y\n```")
        #expect(html.contains("<div class=\"lexmd-math lexmd-display\" data-tex=\"x^2 &lt; y\">x^2 &lt; y</div>"))
        #expect(!html.contains("codeblock"))
    }

    @Test func mathIsEscaped() {
        let html = MarkdownHTML.render("$a<b \"c\" & d$")
        #expect(html.contains("data-tex=\"a&lt;b &quot;c&quot; &amp; d\""))
        #expect(!html.contains("<b "))
    }

    @Test func mathInHeadingsLinksAndImages() {
        let html = MarkdownHTML.render("# Euler $e^x$\n\n![$x$ plot](a.png) [cost](https://example.com/?a=$b$c)")
        #expect(html.contains("<h1 id=\"euler-ex\">Euler <span class=\"lexmd-math\""))
        #expect(html.contains("alt=\"$x$ plot\""))
        #expect(html.contains("href=\"https://example.com/?a=$b$c\""))
        #expect(!html.contains("\u{E000}"))
    }

    @Test func diagramsKeepTheirSource() {
        let html = MarkdownHTML.render("```mermaid\nflowchart LR\n  A --> B\n```\n\n```Pele\npie\n```\n\n```swift\nlet a = 1\n```")
        #expect(html.contains("<div class=\"lexmd-diagram\"><div class=\"codeblock\"><span class=\"lang\">mermaid</span>"))
        #expect(html.contains("A --&gt; B"))
        #expect(html.contains("<div class=\"lexmd-diagram\"><div class=\"codeblock\"><span class=\"lang\">Pele</span>"))
        #expect(html.components(separatedBy: "lexmd-diagram").count == 3)
    }

    // MARK: Footnotes

    @Test func footnotes() {
        let html = MarkdownHTML.render("""
        Text with a note[^1] and another[^Note], then[^1] again.

        [^1]: First note.
        [^note]: Second note with *emphasis*
        and a lazy line.

            Second paragraph with $m$.

        After the notes.
        """)
        #expect(html.contains("<sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1\" aria-label=\"Footnote 1\">1</a></sup>"))
        #expect(html.contains("<a href=\"#fn-2\" id=\"fnref-2\""))
        #expect(html.contains("<a href=\"#fn-1\" id=\"fnref-1-2\""))
        #expect(html.contains("<p>After the notes.</p>"))
        let section = String(html[html.range(of: "<section class=\"footnotes\">")!.lowerBound...])
        #expect(section.contains("<li id=\"fn-1\">\n<p>First note. <a href=\"#fnref-1\" class=\"footnote-back\""))
        #expect(section.contains("href=\"#fnref-1-2\""))
        #expect(section.contains("<em>emphasis</em>"))
        #expect(section.contains("and a lazy line."))
        #expect(section.contains("<p>Second paragraph with <span class=\"lexmd-math\" data-tex=\"m\">$m$</span>"))
        #expect(!html[..<html.range(of: "<section")!.lowerBound].contains("First note"))
        #expect(html.hasSuffix("</section>\n"))
    }

    @Test func footnoteEdgeCases() {
        // Undefined references stay literal; unreferenced definitions are dropped.
        let html = MarkdownHTML.render("Missing[^x] here.\n\n[^unused]: Never cited.")
        #expect(html.contains("Missing[^x] here."))
        #expect(!html.contains("footnotes"))
        #expect(!html.contains("Never cited"))

        // References and definitions inside code are left alone.
        let code = MarkdownHTML.render("Ref `[^1]` in code.\n\n```\n[^1]: not a note\n```\n")
        #expect(code.contains("<code>[^1]</code>"))
        #expect(code.contains("[^1]: not a note"))
        #expect(!code.contains("footnote"))

        // A definition cannot interrupt a paragraph.
        let lazy = MarkdownHTML.render("Note[^a].\n[^a]: inside the paragraph")
        #expect(!lazy.contains("footnote-ref"))

        // Labels are escaped and footnotes are numbered by first reference.
        let order = MarkdownHTML.render("B[^b] A[^a]\n\n[^a]: Alpha 1 < 2\n[^b]: Beta\n")
        #expect(order.range(of: "<li id=\"fn-1\">\n<p>Beta")!.lowerBound < order.range(of: "<li id=\"fn-2\">\n<p>Alpha 1 &lt; 2")!.lowerBound)
    }

    // MARK: Front matter

    @Test func frontMatterTable() {
        let html = MarkdownHTML.render("""
        ---
        title: "Hello: World"
        date: 2026-11-12
        tags: [swift, "mac os", markdown]
        authors:
          - Ann
          - 'Bob O''Neil'
        empty:
        note: <script>alert(1)</script> # trailing comment
        # a comment line
        ---
        # Body
        """)
        #expect(html.hasPrefix("<div class=\"properties\"><table>"))
        #expect(html.contains("<tr><th scope=\"row\">title</th><td>Hello: World</td></tr>"))
        #expect(html.contains("<tr><th scope=\"row\">date</th><td>2026-11-12</td></tr>"))
        #expect(html.contains("<td><span class=\"tag\">swift</span> <span class=\"tag\">mac os</span> <span class=\"tag\">markdown</span></td>"))
        #expect(html.contains("<span class=\"tag\">Ann</span> <span class=\"tag\">Bob O'Neil</span>"))
        #expect(html.contains("<th scope=\"row\">empty</th><td></td>"))
        #expect(html.contains("<td>&lt;script&gt;alert(1)&lt;/script&gt;</td>"))
        #expect(html.contains("<h1 id=\"body\">Body</h1>"))
        #expect(!html.contains("frontmatter"))
    }

    @Test func complexFrontMatterFallsBack() {
        let cases = [
            "meta:\n  nested: value",
            "summary: |\n  Block text",
            "list:\n  - a: 1",
            "anchor: &a value",
            "flow: {a: 1}",
            "nested: [a, [b]]",
            "  indented: key",
            "not yaml at all",
        ]
        for yaml in cases {
            let html = MarkdownHTML.render("---\n\(yaml)\n---\nBody")
            #expect(html.hasPrefix("<pre class=\"frontmatter\"><code>"), "\(yaml)")
            #expect(html.contains("<p>Body</p>"))
        }
    }

    @Test func frontMatterBoundaries() {
        let crlf = MarkdownHTML.render("---\r\ntitle: A\r\ntags: [x]\r\n---\r\nBody\r\n")
        #expect(crlf.hasPrefix("<div class=\"properties\">"))
        #expect(crlf.contains("<td>A</td>"))
        #expect(crlf.contains("<p>Body</p>"))
        // The closing line may carry spaces; an empty block falls back to source.
        #expect(MarkdownHTML.render("---\n---  \nBody").hasPrefix("<pre class=\"frontmatter\"><code></code></pre>\n<p>Body</p>"))
        #expect(MarkdownHTML.render("---\ntitle: A\n---").hasPrefix("<div class=\"properties\">"))
        // Without a closing line, or with only two lines, there is none.
        for source in ["---\n---", "---\ntitle: A\n", "---\ntitle: A\n--- x\nBody", "---"] {
            let html = MarkdownHTML.render(source)
            #expect(!html.contains("properties") && !html.contains("frontmatter"), "\(source)")
        }
        // Text after the block keeps its lines and line endings.
        #expect(MarkdownHTML.render("---\na: b\n---\nOne\n\nTwo $x$\n").hasSuffix("<p>One</p>\n<p>Two <span class=\"lexmd-math\" data-tex=\"x\">$x$</span></p>\n"))
    }

    @Test func scanningReusesItsParseWhenNothingIsReplaced() {
        #expect(MarkdownExtensions("Costs $5 and `$x$` in code.").document != nil)
        #expect(MarkdownExtensions("Undefined[^x] note.").document != nil)
        #expect(MarkdownExtensions("Math $x$.").document == nil)
        #expect(MarkdownExtensions("Plain text.").document == nil)
        #expect(MarkdownHTML.render("Costs $5 and `$x$`.") == "<p>Costs $5 and <code>$x$</code>.</p>\n")
    }

    @Test func libraryMarkersAreFoundByBytes() {
        #expect(PreviewController.contains("<p>é</p><div class=\"lexmd-diagram\">", "class=\"lexmd-diagram\""))
        #expect(!PreviewController.contains("<p>class=&quot;lexmd-math</p>", "class=\"lexmd-math"))
        #expect(!PreviewController.contains("", "x"))
    }

    // MARK: Vendor files

    @Test func vendorRouteStaysInsideTheVendorFolder() throws {
        let folder = try TestFolder()
        let root = folder.url.appendingPathComponent("Vendor", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("katex/fonts"), withIntermediateDirectories: true)
        try "a{}".write(to: root.appendingPathComponent("katex/style.css"), atomically: true, encoding: .utf8)
        try "font".write(to: root.appendingPathComponent("katex/fonts/A.woff2"), atomically: true, encoding: .utf8)
        try "alert(1)".write(to: root.appendingPathComponent("katex/code.js"), atomically: true, encoding: .utf8)
        try "secret".write(to: folder.url.appendingPathComponent("secret.css"), atomically: true, encoding: .utf8)
        try ".h{}".write(to: root.appendingPathComponent(".hidden.css"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.css"), withDestinationURL: folder.url.appendingPathComponent("secret.css"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: folder.url)

        func file(_ url: String) -> String? {
            VendorSchemeHandler.file(for: URL(string: url)!, in: root).map { try! String(contentsOf: $0, encoding: .utf8) }
        }
        #expect(file("lexmd-vendor:///katex/style.css") == "a{}")
        #expect(file("lexmd-vendor:///katex/fonts/A.woff2") == "font")
        let rejected = [
            "lexmd-vendor:///katex/code.js",               // scripts are never served
            "lexmd-vendor:///../secret.css",
            "lexmd-vendor:///katex/../../secret.css",
            "lexmd-vendor:///katex/%2E%2E/%2E%2E/secret.css",
            "lexmd-vendor:///katex%2F..%2F..%2Fsecret.css",
            "lexmd-vendor:///link.css",                    // symlink out of the folder
            "lexmd-vendor:///outside/secret.css",          // symlinked folder
            "lexmd-vendor:///.hidden.css",
            "lexmd-vendor:///katex",
            "lexmd-vendor:///",
            "lexmd-vendor://host/katex/style.css",
            "lexmd-vendor:///katex/style.css?x=1",
            "lexmd-doc:///katex/style.css",
            "lexmd-vendor:////etc/hosts.css",
        ]
        for url in rejected {
            #expect(file(url) == nil, "\(url)")
        }
        #expect(VendorAssets.file(at: "/etc/hosts", in: root) == nil)
        #expect(VendorAssets.file(at: "katex//style.css", in: root) == nil)
    }

    @Test func vendorFilesAreBundled() throws {
        let directory = try #require(VendorAssets.directory)
        #expect(VendorAssets.peleScript?.contains("Pele 1.13.0") == true)
        #expect(VendorAssets.katexScript?.isEmpty == false)
        #expect(VendorAssets.katexStyle?.contains("url(lexmd-vendor:///katex/fonts/KaTeX_Main-Regular.woff2)") == true)
        #expect(VendorSchemeHandler.file(for: URL(string: "lexmd-vendor:///katex/fonts/KaTeX_Main-Regular.woff2")!) != nil)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("pele/LICENSE").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("katex/LICENSE").path))
    }

    @Test func templatePolicyAllowsOnlyVendorFonts() {
        let html = PreviewTemplate.html(allowsRemoteContent: false)
        #expect(html.contains("script-src 'none'; style-src 'unsafe-inline';"))
        #expect(html.contains("font-src lexmd-doc: lexmd-vendor: data:;"))
        #expect(html.contains("<style id=\"lexmd-katex\">"))
    }
}

/// Diagrams and math in the real preview.
@MainActor
@Suite(.serialized)
struct PreviewRenderingTests {
    private func makePreview() -> (PreviewController, NSWindow) {
        let preview = PreviewController(allowsRemoteContent: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = preview.webView
        return (preview, window)
    }

    @Test func diagramsAndMathRender() async throws {
        let (preview, window) = makePreview()
        defer { window.contentView = nil }
        let html = MarkdownHTML.render("""
        # Rendered

        ```mermaid
        flowchart LR
          A[Start] --> B{Choice}
        ```

        Inline $x^2$ math.

        $$
        \\frac{a}{b}
        $$

        ```mermaid
        flowchart LR
          A[broken --
        ```

        Bad $\\frac{1}{$ math.
        """)
        preview.render(html: html, baseURL: nil, resetScroll: true)
        try await waitUntil { try await page(preview, "return document.querySelector('.lexmd-diagram svg') !== null && document.querySelectorAll('.lexmd-math .katex').length >= 2") as? Bool == true }

        #expect(try await page(preview, "return document.querySelector('.lexmd-diagram-view svg').textContent.indexOf('Start') >= 0") as? Bool == true)
        #expect(try await page(preview, "return document.querySelector('.lexmd-diagram-view .codeblock') === null") as? Bool == true)
        #expect(try await page(preview, "return document.querySelector('.lexmd-diagram-view svg').style.width.slice(-3)") as? String == "rem")
        #expect(try await page(preview, "return document.querySelector('span.lexmd-math .katex-mathml math') !== null") as? Bool == true)
        #expect(try await page(preview, "return document.querySelector('div.lexmd-math .katex-display') !== null") as? Bool == true)
        // A broken diagram keeps its source with a note; broken math shows its source.
        #expect(try await page(preview, "var d = document.querySelectorAll('.lexmd-diagram')[1]; return !!d.querySelector('pre code') && d.querySelector('.lexmd-render-error').textContent.indexOf('Diagram error') === 0") as? Bool == true)
        #expect(try await page(preview, "return document.querySelector('.katex-error').textContent") as? String == "\\frac{1}{")

        // KaTeX fonts load through the vendor route.
        try await waitUntil {
            try await page(preview, "var ok = false; document.fonts.forEach(function (f) { if (f.family === 'KaTeX_Main' && f.status === 'loaded') ok = true; }); return ok") as? Bool == true
        }

        // Re-rendering unchanged blocks keeps the existing SVG node.
        _ = try await page(preview, "document.querySelector('.lexmd-diagram-view svg').setAttribute('data-marker', '1')")
        preview.render(html: html + "<p>More</p>", baseURL: nil, resetScroll: false)
        try await waitUntil { try await page(preview, "return document.getElementById('content').lastElementChild.textContent") as? String == "More" }
        #expect(try await page(preview, "return document.querySelector('.lexmd-diagram-view svg').getAttribute('data-marker')") as? String == "1")

        // Everything queued can be finished on demand.
        #expect(try await world(preview, "return lexmdRenderAll()") as? Int == 0)
    }

    @Test func librariesLoadOnDemand() async throws {
        let (preview, window) = makePreview()
        defer { window.contentView = nil }
        let loaded = "return [typeof pele, typeof katex].join(',')"
        preview.render(html: MarkdownHTML.render("# Plain\n\nNo math or diagrams."), baseURL: nil, resetScroll: true)
        try await waitUntil { try await page(preview, "return document.querySelector('#content h1') !== null") as? Bool == true }
        #expect(try await world(preview, loaded) as? String == "undefined,undefined")

        preview.render(html: MarkdownHTML.render("Now $x$."), baseURL: nil, resetScroll: false)
        try await waitUntil { try await page(preview, "return document.querySelector('.katex') !== null") as? Bool == true }
        #expect(try await world(preview, loaded) as? String == "undefined,object")

        // After a page reload, KaTeX comes back as a user script and Pele loads on demand.
        preview.setAllowsRemoteContent(true)
        preview.render(html: MarkdownHTML.render("```mermaid\nflowchart LR\n  A --> B\n```\n\nAnd $y$."), baseURL: nil, resetScroll: true)
        try await waitUntil { try await page(preview, "return document.querySelector('.lexmd-diagram svg') !== null && document.querySelector('.katex') !== null") as? Bool == true }
        #expect(try await world(preview, loaded) as? String == "object,object")
        #expect(try await page(preview, "return typeof pele + typeof katex") as? String == "undefinedundefined", "libraries stay out of the page world")
    }

    @Test func manyBlocksRenderIncrementally() async throws {
        let (preview, window) = makePreview()
        defer { window.contentView = nil }
        var source = ""
        for i in 0..<60 { source += "```mermaid\nflowchart LR\n  A\(i)[Node \(i)] --> B\(i)\n```\n\nText $y_{\(i)}$.\n\n" }
        preview.render(html: MarkdownHTML.render(source), baseURL: nil, resetScroll: true)
        try await waitUntil(seconds: 20) { try await page(preview, "return document.querySelectorAll('.lexmd-diagram-view svg').length") as? Int == 60 }
        #expect(try await page(preview, "return document.querySelectorAll('.lexmd-math.rendered').length") as? Int == 60)
        // Ids stay unique per diagram.
        #expect(try await page(preview, "var ids = {}; var dup = 0; document.querySelectorAll('.lexmd-diagram-view [id]').forEach(function (e) { if (ids[e.id]) dup++; ids[e.id] = 1; }); return dup") as? Int == 0)
    }

    @Test func hostileDiagramsCannotAct() async throws {
        let (preview, window) = makePreview()
        defer { window.contentView = nil }
        let mark = "document.body.insertAdjacentHTML('afterbegin','<b id=ran>x</b>')"
        let html = MarkdownHTML.render("""
        ```mermaid
        flowchart LR
          A["<img src=x onerror=\\"\(mark)\\">"] --> B["<script>\(mark)</script>"]
          B --> C["<a href='javascript:\(mark)'>link</a>"]
          click A "javascript:\(mark)"
          click C "https://example.com" "tip"
          style A fill:url(javascript:alert(1))
        ```

        ```mermaid
        sequenceDiagram
          Alice->>Bob: <svg onload="\(mark)"><foreignObject><script>\(mark)</script></foreignObject></svg>
        ```
        """)
        preview.render(html: html, baseURL: nil, resetScroll: true)
        try await waitUntil { try await page(preview, "return document.querySelectorAll('.lexmd-diagram svg, .lexmd-render-error').length >= 2") as? Bool == true }
        try await Task.sleep(for: .milliseconds(500))

        // Crafted SVG straight through the sanitizer, as if a renderer returned it. Its payload
        // avoids tags, which would make the HTML parser leave the SVG.
        let act = "document.body.setAttribute('data-ran','1')"
        let crafted = """
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" onload="\(act)">
        <script>\(act)</script>
        <foreignObject><div xmlns="http://www.w3.org/1999/xhtml"><img src="x" onerror="\(act)"></div></foreignObject>
        <a href="javascript:\(act)"><text>a</text></a>
        <a xlink:href=" jav&#x09;ascript:alert(1)"><text>b</text></a>
        <a href="https://example.com/ok"><text>ok</text></a>
        <a><animate attributeName="href" to="javascript:alert(1)"/><set attributeName="href" to="javascript:alert(1)"/><text>c</text></a>
        <use href="lexmd-doc:///etc/hosts#x"/><use href="#local"/>
        <image href="https://example.com/x.png"/><image href="lexmd-doc:///tmp/x.png"/>
        <rect id="local" style="fill:red" onclick="\(act)" ONMOUSEOVER="\(act)"/>
        </svg>
        """
        let cleaned = try #require(try await world(preview, """
            var holder = document.createElement('div');
            holder.className = 'lexmd-diagram-view';
            holder.id = 'crafted';
            var tpl = document.createElement('template');
            tpl.innerHTML = markup;
            holder.appendChild(lexmdCleanSVG(tpl.content.firstElementChild));
            document.getElementById('content').appendChild(holder);
            return holder.innerHTML;
            """, ["markup": crafted]) as? String)
        #expect(cleaned.contains("https://example.com/ok"))
        #expect(cleaned.contains("href=\"#local\""))
        try await Task.sleep(for: .milliseconds(300))

        let audit = """
            var bad = [];
            document.querySelectorAll('#content *').forEach(function (el) {
              var name = el.localName.toLowerCase();
              if (el.closest('pre')) return;
              if (['script', 'foreignobject', 'animate', 'set', 'iframe', 'object', 'embed'].indexOf(name) >= 0) bad.push(name);
              for (var i = 0; i < el.attributes.length; i++) {
                var a = el.attributes[i], v = a.value.replace(/[\\s\\u0000-\\u001f]+/g, '').toLowerCase();
                if (/^on/i.test(a.name)) bad.push(name + ' ' + a.name);
                if (v.indexOf('javascript:') >= 0) bad.push(name + ' ' + a.name + '=' + a.value);
                if (/href$/i.test(a.name) && v.charAt(0) !== '#' && !/^(https?:|mailto:)/.test(v)) bad.push(name + ' ' + a.name + '=' + a.value);
              }
            });
            return bad.join('; ');
            """
        #expect(try await page(preview, audit) as? String == "")
        #expect(try await page(preview, "return document.getElementById('ran') === null && !document.body.hasAttribute('data-ran')") as? Bool == true)
        #expect(try await page(preview, "return document.querySelectorAll('.lexmd-diagram-view svg').length") as? Int ?? 0 >= 2)
    }
}

/// Evaluates JavaScript in the page world, where document markup lives.
@MainActor
private func page(_ preview: PreviewController, _ body: String) async throws -> Any? {
    try await preview.webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
}

/// Evaluates JavaScript in LexMD's own content world.
@MainActor
private func world(_ preview: PreviewController, _ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
    try await preview.webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .world(name: "LexMD"))
}
