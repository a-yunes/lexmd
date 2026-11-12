import AppKit
import Foundation
import Testing
import WebKit
@testable import LexMD
@testable import LexMDRendering

/// Outline headings, wiki links, the project link index, broken-link checks, and link completion.
@MainActor
struct OutlineLinkTests {
    // MARK: Headings

    @Test func headingsMatchPreviewIDs() {
        let source = """
        ---
        title: Sample
        ---
        # Title

        Intro with a [link](#title).

        Setext Heading
        ==============

        ```swift
        # not a heading
        ```

            # indented code, not a heading

        ## Same
        ## Same
        Sub *emphasis* and `code`
        -------------------------

        > ### Quoted
        - #### In a list

        ## Café, naïve & 日本語 🎉
        ##
        """
        let headings = DocumentStructure.analyze(source).headings
        #expect(headings.map(\.title) == ["Title", "Setext Heading", "Same", "Same", "Sub emphasis and `code`", "Quoted", "In a list", "Café, naïve & 日本語 🎉", ""])
        #expect(headings.map(\.level) == [1, 1, 2, 2, 2, 3, 4, 2, 2])
        #expect(headings.map(\.slug) == ["title", "setext-heading", "same", "same-1", "sub-emphasis-and-code", "quoted", "in-a-list", "café-naïve--日本語-", "section"])
        #expect(headings.map(\.line) == [4, 8, 17, 18, 19, 22, 23, 25, 26])
        let ns = source as NSString
        #expect(ns.substring(with: headings[0].range) == "# Title")
        #expect(ns.substring(with: headings[1].range).hasPrefix("Setext Heading\n==="))

        // The preview gives headings exactly these ids.
        let html = MarkdownHTML.render(source)
        let pattern = try! NSRegularExpression(pattern: #"<h[1-6] id="([^"]*)""#)
        let ids = pattern.matches(in: html, range: NSRange(location: 0, length: (html as NSString).length))
            .map { (html as NSString).substring(with: $0.range(at: 1)) }
        #expect(ids == headings.map(\.slug))
    }

    @Test func sourceRangesHandleMultibyteText() {
        let source = "Ünïcödé 🎉 [linkё](târget.md) and [[Wïki]]\n"
        let structure = DocumentStructure.analyze(source)
        let ns = source as NSString
        #expect(structure.links.map { ns.substring(with: $0.range) } == ["[linkё](târget.md)", "[[Wïki]]"])
    }

    // MARK: Wiki links

    @Test func wikiLinkParsing() {
        let source = """
        See [[Name]], [[ Other | the label ]], [[Doc#Some Heading]], [[folder/Deep]] and [[#Local]].
        In a table: [[Name\\|alias]]. Not links: [[]], [[ ]], [[a
        b]], `[[code]]`, ``[[double `tick`]]``.

        ```
        [[fenced]]
        ```

            [[indented]]

        <div>[[html]]</div>
        """
        let links = WikiLink.parse(in: source)
        #expect(links.map(\.target) == ["Name", "Other", "Doc", "folder/Deep", "", "Name"])
        #expect(links.map(\.alias) == [nil, "the label", nil, nil, nil, "alias"])
        #expect(links.map(\.heading) == [nil, nil, "Some Heading", nil, "Local", nil])
        #expect(links.map(\.label) == ["Name", "the label", "Doc › Some Heading", "folder/Deep", "Local", "alias"])
        let ns = source as NSString
        #expect(links.map { ns.substring(with: $0.targetRange) } == ["Name", "Other", "Doc", "folder/Deep", "", "Name"])
        #expect(ns.substring(with: links[1].range) == "[[ Other | the label ]]")
    }

    @Test func wikiLinkResolution() {
        let resolver = WikiLinkResolver(root: "/p", paths: [
            "/p/Notes.md", "/p/a/Index.md", "/p/b/Index.md", "/p/b/c/Deep.md", "/p/a/x/Index.md", "/p/Café.markdown",
        ])
        #expect(resolver.resolve("notes", from: "/p/a/doc.md") == "/p/Notes.md")
        #expect(resolver.resolve("NOTES.md", from: nil) == "/p/Notes.md")
        #expect(resolver.resolve("café", from: nil) == "/p/Café.markdown")
        // Several files share a name: the one nearest the linking document wins.
        #expect(resolver.resolve("index", from: "/p/b/c/Deep.md") == "/p/b/Index.md")
        #expect(resolver.resolve("index", from: "/p/a/x/y.md") == "/p/a/x/Index.md")
        #expect(resolver.resolve("index", from: "/p/a/doc.md") == "/p/a/Index.md")
        #expect(resolver.resolve("index", from: nil) == "/p/a/Index.md")
        // Folders: relative to the document, then the root, then any path ending with it.
        #expect(resolver.resolve("b/index", from: "/p/a/doc.md") == "/p/b/Index.md")
        #expect(resolver.resolve("x/Index", from: "/p/b/c/Deep.md") == "/p/a/x/Index.md")
        #expect(resolver.resolve("../Notes", from: "/p/a/doc.md") == "/p/Notes.md")
        #expect(resolver.resolve("c/deep", from: "/p/b/Index.md") == "/p/b/c/Deep.md")
        #expect(resolver.resolve("/b/c/Deep", from: "/p/a/doc.md") == "/p/b/c/Deep.md")
        #expect(resolver.resolve("missing", from: nil) == nil)
        #expect(resolver.resolve("y/Index", from: nil) == nil)
        #expect(resolver.isAmbiguous("/p/b/Index.md"))
        #expect(!resolver.isAmbiguous("/p/Notes.md"))
    }

    @Test func wikiLinksRenderInPreview() throws {
        let folder = try TestFolder()
        let root = FileScanner.canonicalPath(folder.url.path)
        try FileManager.default.createDirectory(atPath: root + "/notes", withIntermediateDirectories: true)
        try "# Target\n\n## Part One\n".write(toFile: root + "/notes/My Target.md", atomically: true, encoding: .utf8)
        let source = "[[my target]] [[My Target#Part One|part]] [[Nope]] `[[my target]]` [[My Target#Missing]] [[#Here]] [x [[my target]]](y.md)\n\n# Here\n"
        try folder.write("Doc.md", source)
        let snapshot = LinkIndexBuilder.build(root: root, previous: LinkIndexSnapshot(), changed: nil)
        let context = LinkContext(documentPath: root + "/Doc.md", source: source, snapshot: snapshot)
        let html = MarkdownHTML.render(source, links: context)
        #expect(html.contains(#"<a class="lexmd-wiki" href="notes/My%20Target.md">my target</a>"#))
        #expect(html.contains(#"<a class="lexmd-wiki" href="notes/My%20Target.md#part-one">part</a>"#))
        #expect(html.contains(#"<span class="lexmd-wiki lexmd-missing" title="No document named “Nope”">Nope</span>"#))
        #expect(html.contains("<code>[[my target]]</code>"))
        #expect(html.contains(#"<a class="lexmd-wiki lexmd-broken" href="notes/My%20Target.md#missing">My Target › Missing</a>"#))
        #expect(html.contains(##"<a class="lexmd-wiki" href="#here">Here</a>"##))
        // No links inside links; y.md does not exist, so the outer link is marked.
        #expect(html.contains(#"<a href="y.md" class="lexmd-broken">x [[my target]]</a>"#))
        // Without a link context, wiki links stay text.
        #expect(MarkdownHTML.render(source).contains("[[my target]] [[My Target#Part One|part]]"))
    }

    // MARK: Math and footnotes

    @Test func wikiLinksAndMathCoexist() throws {
        let folder = try TestFolder()
        let root = FileScanner.canonicalPath(folder.url.path)
        try folder.write("Doc.md", "# Doc\n\n## Euler $e^x$\n")
        let source = """
        Inline $[[x]]$ stays math. [[Doc|label $a^2$]] renders math. [[Doc#Euler $e^x$]] links.
        Here [[a$]] and [[b$]] is math.

        Note[^1] and [[^1]] and [[^nope]].

        $$
        # not a heading [[Doc]]
        $$

        [^1]: See [[Doc]] and [gone](gone.md).

        # Heading with $x_1_$ and [[Doc]]
        """
        try folder.write("Page.md", source)
        let snapshot = LinkIndexBuilder.build(root: root, previous: LinkIndexSnapshot(), changed: nil)
        let context = LinkContext(documentPath: root + "/Page.md", source: source, snapshot: snapshot)
        let html = MarkdownHTML.render(source, links: context)

        // Math wins over wiki brackets inside it or cutting through it.
        #expect(html.contains(#"<span class="lexmd-math" data-tex="[[x]]">$[[x]]$</span>"#))
        #expect(html.contains(#"Here [[a<span class="lexmd-math" data-tex="]] and [[b">$]] and [[b$</span>]] is math."#))
        // A label holding math renders the math inside the link.
        #expect(html.contains(#"<a class="lexmd-wiki" href="Doc.md">label <span class="lexmd-math" data-tex="a^2">$a^2$</span></a>"#))
        // A heading with math links to the id the preview gives that heading.
        #expect(html.contains(#"<a class="lexmd-wiki" href="Doc.md#euler-ex">Doc › Euler <span class="lexmd-math" data-tex="e^x">"#))
        #expect(MarkdownHTML.render("## Euler $e^x$").contains(#"<h2 id="euler-ex">"#))
        // Footnote references stay footnotes; `[[^label]]` is never a document link.
        #expect(html.contains(##"Note<sup class="footnote-ref"><a href="#fn-1""##))
        #expect(html.contains(##"and [<sup class="footnote-ref"><a href="#fn-1" id="fnref-1-2""##))
        #expect(html.contains("and [[^nope]]."))
        // Footnote bodies get wiki links and broken-link marks too.
        let footnotes = try #require(html.components(separatedBy: "<section class=\"footnotes\">").last)
        #expect(footnotes.contains(#"See <a class="lexmd-wiki" href="Doc.md">Doc</a> and <a href="gone.md" class="lexmd-broken">gone</a>"#))
        // No placeholder survives into the page, attributes included.
        #expect(!html.unicodeScalars.contains("\u{E000}") && !html.unicodeScalars.contains("\u{E001}"))

        // The outline and link checks see the same document as the preview.
        let structure = DocumentStructure.analyze(source)
        #expect(structure.headings.map(\.title) == ["Heading with $x_1_$ and [[Doc]]"])
        let pattern = try NSRegularExpression(pattern: #"<h[1-6] id="([^"]*)""#)
        let ids = pattern.matches(in: html, range: NSRange(location: 0, length: (html as NSString).length))
            .map { (html as NSString).substring(with: $0.range(at: 1)) }
        #expect(ids == structure.headings.map(\.slug))
        let ns = source as NSString
        #expect(structure.links.filter { $0.kind == .wiki }.map { ns.substring(with: $0.range) } == [
            "[[Doc|label $a^2$]]", "[[Doc#Euler $e^x$]]", "[[Doc]]", "[[Doc]]",
        ])
        #expect(WikiLink.parse(in: "$[[x]]$ and [[y]] and [[^z]]").map(\.target) == ["y"])
        let problems = OutlineAnalysis.make(source: source, context: context).problems
        #expect(problems.map(\.message) == ["File not found: gone.md"])
        #expect(snapshot.incoming[root + "/Doc.md"]?.count == 4)
    }

    @Test func exportsResolveWikiLinks() async throws {
        let folder = try TestFolder()
        let root = FileScanner.canonicalPath(folder.url.path)
        try FileManager.default.createDirectory(atPath: root + "/notes", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/out", withIntermediateDirectories: true)
        try "# Target\n\n## Part One\n".write(toFile: root + "/notes/My Target.md", atomically: true, encoding: .utf8)
        let source = "See [[my target]], [[My Target#Part One|part]], [[Nope]], [gone](gone.md), and [[My Target#Missing]].\n"
        try folder.write("Doc.md", source)
        let snapshot = LinkIndexBuilder.build(root: root, previous: LinkIndexSnapshot(), changed: nil)
        var links = LinkContext(documentPath: root + "/Doc.md", source: source, snapshot: snapshot)
        links.marksBrokenLinks = false
        let document = ExportDocument(markdown: source, baseURL: URL(fileURLWithPath: root), title: "Doc", links: links)

        // Links point at the documents from wherever the export is saved, with heading fragments.
        let html = try await Exporter.exportHTML(document, to: URL(fileURLWithPath: root + "/out/Doc.html")).html
        let body = try #require(html.components(separatedBy: "<article id=\"content\">").last)
        #expect(body.contains(#"<a class="lexmd-wiki" href="../notes/My%20Target.md">my target</a>"#))
        #expect(body.contains(#"<a class="lexmd-wiki" href="../notes/My%20Target.md#part-one">part</a>"#))
        #expect(body.contains(#"<a class="lexmd-wiki" href="../notes/My%20Target.md#missing">My Target › Missing</a>"#))
        // Unresolved wiki links stay styled text; broken links are not marked in exports.
        #expect(body.contains(#"<span class="lexmd-wiki lexmd-missing" title="No document named “Nope”">Nope</span>"#))
        #expect(body.contains(#"gone.md">gone</a>"#))
        #expect(!body.contains("lexmd-broken"))
        #expect(html.contains(".lexmd-missing"), "the missing style travels with the page")
    }

    // MARK: Index and backlinks

    @Test func backlinksAcrossFiles() async throws {
        let folder = try TestFolder()
        let root = FileScanner.canonicalPath(folder.url.path)
        try FileManager.default.createDirectory(atPath: root + "/c", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/node_modules", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/.hidden", withIntermediateDirectories: true)
        try folder.write("b.md", "# New Name\n")
        try folder.write("a.md", "Intro\n\nGo to [B](b.md#old-name) now.\n")
        try folder.write("c/c.md", "See [[B]] and [again](../b.md).\n")
        try folder.write("d.md", "[self](d.md) [[d]] `[[b]]`\n\n```\n[b](b.md)\n```\n")
        try folder.write("node_modules/n.md", "[[b]]\n")
        try folder.write(".hidden/h.md", "[[b]]\n")
        try folder.writePNG("pic.png")

        let index = LinkIndex()
        index.delay = .zero
        var updates = 0
        index.onUpdate = { _ in updates += 1 }
        index.setRoot(root)
        await index.waitUntilIdle()
        var snapshot = index.snapshot
        #expect(snapshot.markdownPaths == [root + "/a.md", root + "/b.md", root + "/c/c.md", root + "/d.md"])
        #expect(snapshot.imagePaths == [root + "/pic.png"])
        let incoming = snapshot.incoming[root + "/b.md"] ?? []
        #expect(incoming.map(\.source) == [root + "/a.md", root + "/c/c.md", root + "/c/c.md"])
        #expect(incoming.map(\.line) == [3, 1, 1])
        #expect(snapshot.incoming[root + "/d.md"] == nil, "self links are not backlinks")

        let backlinks = Backlink.load(incoming, root: root)
        #expect(backlinks.map(\.context) == ["Go to [B](b.md#old-name) now.", "See [[B]] and [again](../b.md).", "See [[B]] and [again](../b.md)."])
        #expect(backlinks.map(\.name) == ["a", "c", "c"])
        #expect(backlinks.map(\.folder) == ["", "c", "c"])

        // The heading was renamed: the link still counts as a backlink, and a.md reports it.
        let aSource = try String(contentsOfFile: root + "/a.md", encoding: .utf8)
        var problems = OutlineAnalysis.make(source: aSource, context: LinkContext(documentPath: root + "/a.md", source: aSource, snapshot: snapshot)).problems
        #expect(problems.map(\.message) == ["No heading “#old-name” in b.md"])
        #expect(problems.first?.line == 3)
        #expect(problems.first.map { (aSource as NSString).substring(with: $0.range) } == "[B](b.md#old-name)")

        // Incremental updates: rename the heading back, and drop c.md's links.
        let version = snapshot.structureVersion
        try folder.write("b.md", "# Old Name\n")
        try folder.write("c/c.md", "No links now.\n")
        index.update(paths: [root + "/b.md", root + "/c/c.md"])
        await index.waitUntilIdle()
        snapshot = index.snapshot
        #expect(snapshot.structureVersion > version)
        #expect(snapshot.incoming[root + "/b.md"]?.map(\.source) == [root + "/a.md"])
        problems = OutlineAnalysis.make(source: aSource, context: LinkContext(documentPath: root + "/a.md", source: aSource, snapshot: snapshot)).problems
        #expect(problems.isEmpty)

        // A deleted file disappears from the index and its links stop counting.
        try FileManager.default.removeItem(atPath: root + "/a.md")
        index.update(paths: [root + "/a.md"])
        await index.waitUntilIdle()
        #expect(index.snapshot.incoming[root + "/b.md"] == nil)
        #expect(!index.snapshot.markdownPaths.contains(root + "/a.md"))

        // A full refresh reuses unchanged documents and finds new ones.
        try folder.write("e.md", "[[b]]\n")
        index.refresh()
        await index.waitUntilIdle()
        #expect(index.snapshot.incoming[root + "/b.md"]?.map(\.source) == [root + "/e.md"])
        #expect(updates == 5, "one reset and four index updates")
    }

    @Test func largeProjectsStayBounded() async throws {
        let folder = try TestFolder()
        let root = FileScanner.canonicalPath(folder.url.path)
        // Heavy work runs off the main actor, which the preview tests share.
        let (snapshot, seconds) = await runDetached { () -> (LinkIndexSnapshot, Double) in
            for i in 0..<1500 {
                try? "# Doc \(i)\n\nSee [[doc\((i + 1) % 1500)]] and [prev](doc\((i + 1499) % 1500).md).\n"
                    .write(toFile: root + "/doc\(i).md", atomically: false, encoding: .utf8)
            }
            let start = Date()
            let snapshot = LinkIndexBuilder.build(root: root, previous: LinkIndexSnapshot(), changed: nil)
            return (snapshot, Date().timeIntervalSince(start))
        }
        #expect(snapshot.documents.count == 1500)
        #expect(snapshot.incoming[root + "/doc0.md"]?.count == 2)
        #expect(seconds < 20)
        // A rescan with nothing changed reuses every document.
        let again = await runDetached { LinkIndexBuilder.build(root: root, previous: snapshot, changed: nil) }
        #expect(again.structureVersion == snapshot.structureVersion)
        #expect(again.documents == snapshot.documents)
    }

    // MARK: Broken links

    @Test func brokenLinkDetection() throws {
        let folder = try TestFolder()
        let root = FileScanner.canonicalPath(folder.url.path)
        try folder.write("other.md", "# Other\n## Sub\n")
        try folder.write("my file.md", "# Spaced\n")
        try folder.writePNG("pic.png")
        try FileManager.default.createDirectory(atPath: root + "/sub", withIntermediateDirectories: true)
        let source = """
        # Intro

        [ok](other.md) [missing](nope.md) [anchor](#intro) [bad anchor](#nowhere)
        [file anchor](other.md#sub) [bad file anchor](other.md#gone) [web](https://example.com/x.md)
        [mail](mailto:a@b.c) ![img](pic.png) ![no image](none.png) [[other]] [[ghost]] [[other#Sub]]
        [[other#Nope]] [spaced](my%20file.md) [angle](<my file.md>) <a id="raw"></a> [raw](#raw)
        [folder](sub/) [query](other.md?x=1) [self](doc.md#intro) [self bad](doc.md#zzz) [[#Intro]] [[#Outro]]
        [absolute](\(root)/other.md) [ref][r] `[code](nope.md)`

        [r]: missing-ref.md
        """
        try folder.write("doc.md", source)
        let snapshot = LinkIndexBuilder.build(root: root, previous: LinkIndexSnapshot(), changed: nil)
        let context = LinkContext(documentPath: root + "/doc.md", source: source, snapshot: snapshot)
        let problems = OutlineAnalysis.make(source: source, context: context).problems
        #expect(problems.map(\.target) == [
            "nope.md", "#nowhere", "other.md#gone", "none.png", "[[ghost]]", "[[other#Nope]]", "doc.md#zzz", "[[#Outro]]", "missing-ref.md",
        ])
        #expect(problems.map(\.message) == [
            "File not found: nope.md", "No heading “#nowhere” in this document", "No heading “#gone” in other.md",
            "File not found: none.png", "No document named “ghost”", "No heading “Nope” in other.md",
            "No heading “#zzz” in this document", "No heading “Outro” in this document", "File not found: missing-ref.md",
        ])
        #expect(problems.map(\.line) == [3, 3, 4, 5, 5, 6, 7, 7, 8])

        // The preview marks the same links; images are only listed, and a missing wiki link is styled as missing.
        let html = MarkdownHTML.render(source, links: context)
        #expect(html.components(separatedBy: "lexmd-broken").count - 1 == 7)
        #expect(html.contains(#"<a href="nope.md" class="lexmd-broken">"#))
        #expect(html.contains(#"<a href="other.md">ok</a>"#))
        var off = context
        off.marksBrokenLinks = false
        #expect(!MarkdownHTML.render(source, links: off).contains("lexmd-broken"))
    }

    @Test func linkDestinations() {
        #expect(LinkDestination("https://x.y/a.md", folder: "/p") == .external)
        #expect(LinkDestination("//cdn/x.png", folder: "/p") == .external)
        #expect(LinkDestination("mailto:a@b", folder: "/p") == .external)
        #expect(LinkDestination("#a%20b", folder: "/p") == .anchor("a b"))
        #expect(LinkDestination("", folder: "/p") == LinkDestination.none)
        #expect(LinkDestination("#", folder: "/p") == LinkDestination.none)
        #expect(LinkDestination("../x/./y.md#h", folder: "/p/q") == .file("/p/x/y.md", fragment: "h"))
        #expect(LinkDestination("a%20b.md?v=1", folder: "/p") == .file("/p/a b.md", fragment: nil))
        #expect(LinkDestination("a.md", folder: nil) == LinkDestination.none)
        #expect(LinkDestination("/private/tmp/a.md", folder: nil) == .file("/private/tmp/a.md", fragment: nil))
        #expect(LinkPaths.relative("/p/a/b/c.md", from: "/p/a/x") == "../b/c.md")
        #expect(LinkPaths.relative("/p/c.md", from: "/p") == "c.md")
        #expect(LinkPaths.encode("../My Doc (1).md") == "../My%20Doc%20%281%29.md")
    }

    // MARK: Completion

    @Test func completionContexts() {
        func context(_ text: String) -> CompletionContext? {
            EditorCompletion.context(in: text as NSString, caret: (text as NSString).length)
        }
        #expect(context("See [a](")?.kind == .path(image: false))
        #expect(context("See [a](")?.query == "")
        #expect(context("See [a](")?.range == NSRange(location: 8, length: 0))
        #expect(context("![a [b]](im")?.kind == .path(image: true))
        #expect(context("![a [b]](im")?.query == "im")
        #expect(context("[a](../doc.md#se")?.kind == .heading(file: "../doc.md"))
        #expect(context("[a](../doc.md#se")?.query == "se")
        #expect(context("[a](../doc.md#se")?.range == NSRange(location: 14, length: 2))
        #expect(context("[a](#x")?.kind == .heading(file: ""))
        #expect(context("x [[Na")?.kind == .wiki)
        #expect(context("x [[Na")?.query == "Na")
        #expect(context("x [[Na")?.trigger == 2)
        #expect(context("[[My Name#He")?.kind == .wikiHeading(name: "My Name"))
        #expect(context("[[#He")?.kind == .wikiHeading(name: ""))
        #expect(context("[[Name|al") == nil)
        #expect(context("[a](b.md) more") == nil)
        #expect(context("[a](b c") == nil)
        #expect(context("[[x]] y") == nil)
        #expect(context("[a](https:") == nil)
        #expect(context("`[[x") == nil)
        #expect(context("`a` [[x")?.kind == .wiki)
        #expect(context("```\n[[x") == nil)
        #expect(context("```\ncode\n```\n[[x")?.kind == .wiki)
        #expect(context("[[a]] then [b](")?.kind == .path(image: false))
        #expect(context("plain text") == nil)
    }

    @Test func completionRanking() {
        func candidate(_ name: String, _ path: String, group: Int = 0, weight: Int = 0) -> EditorCompletion.Candidate {
            EditorCompletion.Candidate(
                item: CompletionItem(id: path, kind: group == 0 ? .document : .image, title: name, insertion: path),
                keys: [name, path], group: group, weight: weight
            )
        }
        let candidates = [
            candidate("Roadmap.md", "Roadmap.md", weight: -10),
            candidate("big-guide.md", "docs/big-guide.md", weight: -17),
            candidate("guide.png", "images/guide.png", group: 1, weight: -16),
            candidate("Getting Started.md", "Getting Started.md", weight: -18),
            candidate("Guide.md", "docs/Guide.md", weight: -13),
            candidate("Glossary.md", "ref/Glossary.md", weight: -15),
        ]
        func titles(_ query: String) -> [String] { EditorCompletion.rank(query, candidates).map(\.title) }
        // Prefix matches first, Markdown before images, then word starts, then scattered letters.
        #expect(titles("guide") == ["Guide.md", "guide.png", "big-guide.md"])
        #expect(titles("GUI") == ["Guide.md", "guide.png", "big-guide.md"])
        #expect(titles("gs").first == "Getting Started.md")
        #expect(titles("docs/") == ["Guide.md", "big-guide.md"])
        #expect(titles("zzz").isEmpty)
        // An empty query keeps every candidate, nearest (highest weight) first.
        #expect(titles("") == ["Roadmap.md", "Guide.md", "Glossary.md", "big-guide.md", "Getting Started.md", "guide.png"])
        #expect(EditorCompletion.rank("", candidates, limit: 2).count == 2)
    }

    @Test func returnContinuesListsUnlessSuggestionsShow() {
        let editor = EditorController()
        let completion = EditorCompletion(textView: editor.textView)
        var enabled = true
        completion.isEnabled = { enabled }
        completion.provider = { context in
            guard context.kind == .wiki else { return [] }
            return EditorCompletion.rank(context.query, ["Alpha", "Beta"].map {
                EditorCompletion.Candidate(item: CompletionItem(id: $0, kind: .document, title: $0, insertion: $0), keys: [$0])
            })
        }
        editor.onCommand = { completion.handle($0) }
        let textView = editor.textView
        func type(_ text: String) { textView.insertText(text, replacementRange: textView.selectedRange()) }
        func press(_ selector: Selector) { textView.doCommand(by: selector) }

        editor.load("- item")
        textView.setSelectedRange(NSRange(location: 6, length: 0))
        press(#selector(NSResponder.insertNewline(_:)))
        #expect(textView.string == "- item\n- ")
        #expect(!completion.isVisible)

        // With suggestions showing, arrows move and Return accepts instead of adding a line.
        type("[[")
        #expect(completion.isVisible)
        #expect(completion.list.items.map(\.title) == ["Alpha", "Beta"])
        press(#selector(NSResponder.moveDown(_:)))
        #expect(completion.list.selection == 1)
        type("a")
        #expect(completion.list.items.map(\.title) == ["Alpha", "Beta"])
        #expect(completion.list.selection == 0)
        type("l")
        #expect(completion.list.items.map(\.title) == ["Alpha"])
        press(#selector(NSResponder.insertNewline(_:)))
        #expect(textView.string == "- item\n- [[Alpha]]")
        #expect(!completion.isVisible)
        press(#selector(NSResponder.insertNewline(_:)))
        #expect(textView.string == "- item\n- [[Alpha]]\n- ")

        // Escape hides the list for this link; Return then works as usual.
        type("[[")
        #expect(completion.isVisible)
        press(#selector(NSResponder.cancelOperation(_:)))
        #expect(!completion.isVisible)
        type("B")
        #expect(!completion.isVisible)
        press(#selector(NSResponder.insertNewline(_:)))
        #expect(textView.string == "- item\n- [[Alpha]]\n- [[B\n- ")

        // Tab accepts, and an existing `]]` is reused rather than doubled.
        type("[[]]")
        textView.setSelectedRange(NSRange(location: textView.selectedRange().location - 2, length: 0))
        type("b")
        #expect(completion.isVisible)
        press(#selector(NSResponder.insertTab(_:)))
        #expect(textView.string.hasSuffix("- [[Beta]]"))
        #expect(textView.selectedRange().location == (textView.string as NSString).length)

        // Moving the caret out of the link closes the list; nothing shows when turned off.
        type(" [[")
        #expect(completion.isVisible)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(!completion.isVisible)
        enabled = false
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        type("A")
        #expect(!completion.isVisible)
        press(#selector(NSResponder.insertNewline(_:)))
        #expect(textView.string.hasSuffix("[[A\n- "))
    }

    // MARK: Preview

    @Test func previewRevealsAndReportsHeadings() async throws {
        let folder = try TestFolder()
        try folder.write("Target.md", "# Target\n")
        let preview = PreviewController(allowsRemoteContent: false)
        var reported: [String] = []
        var opened: [URL] = []
        preview.onHeadingChange = { reported.append($0) }
        preview.onOpenURL = { opened.append($0) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = preview.webView

        let filler = String(repeating: "<p>Text</p>\n", count: 120)
        let html = "<h1 id=\"top\">Top</h1>\n\(filler)<h2 id=\"part-two\">Part Two</h2>\n<div class=\"lexmd-diagram\"><h3 id=\"drawn\">Drawn</h3></div>\n\(filler)<p><a id=\"wiki\" class=\"lexmd-wiki\" href=\"Target.md#target\">Target</a></p>"
        preview.render(html: html, baseURL: folder.url, resetScroll: true)
        try await waitUntil { reported.last == "top" }

        preview.revealHeading("part-two", smooth: false)
        try await waitUntil { reported.last == "part-two" }
        let top = try await preview.webView.callAsyncJavaScript(
            "return document.getElementById('part-two').getBoundingClientRect().top", arguments: [:], in: nil, contentWorld: .page
        ) as? Double
        #expect(abs((top ?? 999) - 20) < 30)
        // Headings drawn inside a diagram are not document headings.
        _ = try await preview.webView.callAsyncJavaScript("window.scrollBy(0, 60)", arguments: [:], in: nil, contentWorld: .page)
        try await Task.sleep(for: .milliseconds(400))
        #expect(reported.last == "part-two")
        #expect(!reported.contains("drawn"))

        // A pending heading is revealed after the next render.
        preview.revealHeading("top", smooth: false, afterRender: true)
        preview.render(html: html + "<p>more</p>", baseURL: folder.url, resetScroll: false)
        try await waitUntil { reported.last == "top" }

        // Links keep their fragment so the app can open a document at a heading.
        _ = try await preview.webView.callAsyncJavaScript("document.getElementById('wiki').click()", arguments: [:], in: nil, contentWorld: .page)
        try await waitUntil { !opened.isEmpty }
        #expect(opened.first?.isFileURL == true)
        #expect(opened.first?.fragment == "target")
        #expect(FileScanner.canonicalPath(opened.first?.path ?? "") == FileScanner.canonicalPath(folder.url.appendingPathComponent("Target.md").path))
    }
}
