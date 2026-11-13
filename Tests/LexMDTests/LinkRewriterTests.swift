import AppKit
import Foundation
import Testing
@testable import LexMD

/// Rewrites `text` of a document now at `path` (previously at the move's old location if it moved).
private func rewrite(_ text: String, at path: String, _ moves: [PathMove], wiki: WikiRenames = WikiRenames()) -> String {
    let context = LinkRewriter.Context(moves: moves, wiki: wiki)
    let edits = LinkRewriter.edits(in: text, oldPath: context.oldLocation(of: path), newPath: path, context: context)
    return TextEdit.apply(edits, to: text)
}

private let rename = PathMove(from: "/p/notes.md", to: "/p/guide.md")

/// Wiki renames for one move, given the project's documents after the move.
private func wikiRenames(_ move: PathMove, files: [String], root: String = "/p") -> WikiRenames {
    WikiRenames(root: root, moves: [move], markdownFiles: files, movedFiles: [(move.from, move.to)])
}

struct LinkRewriterTests {
    @Test func renameUpdatesLinksToTheFile() {
        #expect(rewrite("See [notes](notes.md).", at: "/p/index.md", [rename]) == "See [notes](guide.md).")
        #expect(rewrite("[a](./notes.md) and [b](notes.md \"Title\")", at: "/p/index.md", [rename])
            == "[a](./guide.md) and [b](guide.md \"Title\")")
        #expect(rewrite("[other](other.md)", at: "/p/index.md", [rename]) == "[other](other.md)")
    }

    @Test func relativePathsUpAndDownFolders() {
        let move = PathMove(from: "/p/docs/b/y.md", to: "/p/y.md")
        #expect(rewrite("[y](../b/y.md)", at: "/p/docs/a/x.md", [move]) == "[y](../../y.md)")
        #expect(rewrite("[y](docs/b/y.md)", at: "/p/index.md", [move]) == "[y](y.md)")
        let down = PathMove(from: "/p/top.md", to: "/p/deep/er/top.md")
        #expect(rewrite("[t](../top.md)", at: "/p/docs/x.md", [down]) == "[t](../deep/er/top.md)")
    }

    @Test func anchorsAndQueriesAreKept() {
        #expect(rewrite("[s](notes.md#setup) [q](notes.md?plain=1#L4)", at: "/p/index.md", [rename])
            == "[s](guide.md#setup) [q](guide.md?plain=1#L4)")
        #expect(rewrite("[top](#top)", at: "/p/notes.md", [rename]) == "[top](#top)")
    }

    @Test func imagesInMovedFoldersAreUpdated() {
        let move = PathMove(from: "/p/img", to: "/p/assets/img")
        #expect(rewrite("![shot](img/shot.png)", at: "/p/index.md", [move]) == "![shot](assets/img/shot.png)")
        #expect(rewrite("[![badge](img/b.svg)](notes.md)", at: "/p/index.md", [move, rename])
            == "[![badge](assets/img/b.svg)](guide.md)")
    }

    @Test func referenceDefinitions() {
        let text = "Read [the notes][n].\n\n[n]: notes.md \"Notes\"\n  [m]: <notes.md#a>\n[^1]: notes.md is a footnote\n"
        let expected = "Read [the notes][n].\n\n[n]: guide.md \"Notes\"\n  [m]: <guide.md#a>\n[^1]: notes.md is a footnote\n"
        #expect(rewrite(text, at: "/p/index.md", [rename]) == expected)
    }

    @Test func angleBracketsAndPercentEncoding() {
        let spaced = PathMove(from: "/p/my notes.md", to: "/p/new name.md")
        #expect(rewrite("[a](<my notes.md>)", at: "/p/i.md", [spaced]) == "[a](<new name.md>)")
        #expect(rewrite("[a](my%20notes.md)", at: "/p/i.md", [spaced]) == "[a](new%20name.md)")
        // A raw link that gains a space stays valid by encoding it.
        let gainsSpace = PathMove(from: "/p/notes.md", to: "/p/new notes.md")
        #expect(rewrite("[a](notes.md)", at: "/p/i.md", [gainsSpace]) == "[a](new%20notes.md)")
    }

    @Test func nonASCIINames() {
        let move = PathMove(from: "/p/café.md", to: "/p/naïve notes.md")
        #expect(rewrite("[a](café.md)", at: "/p/i.md", [move]) == "[a](naïve%20notes.md)")
        #expect(rewrite("[a](caf%C3%A9.md)", at: "/p/i.md", [move]) == "[a](na%C3%AFve%20notes.md)")
        #expect(rewrite("[a](<café.md>)", at: "/p/i.md", [move]) == "[a](<naïve notes.md>)")
        let into = PathMove(from: "/p/a.md", to: "/p/Über/a.md")
        #expect(rewrite("[a](a.md)", at: "/p/i.md", [into]) == "[a](Über/a.md)")
    }

    @Test func codeIsNeverTouched() {
        let text = """
        Prose [a](notes.md) and `[b](notes.md)` and ``code `[c](notes.md)` here``.

        ```markdown
        [d](notes.md)
        ```

        ~~~~
        [e](notes.md)
        ~~~
        still code [f](notes.md)
        ~~~~

            [g](notes.md) indented code

        - item [h](notes.md)

            [i](notes.md) list continuation

          ```
          [j](notes.md) fenced in a list
          ```
        [[notes]] `[[notes]]`
        """
        let result = rewrite(text, at: "/p/index.md", [rename], wiki: wikiRenames(rename, files: ["/p/index.md", "/p/guide.md"]))
        #expect(result.contains("Prose [a](guide.md)"))
        #expect(result.contains("`[b](notes.md)`"))
        #expect(result.contains("`[c](notes.md)`"))
        #expect(result.contains("[d](notes.md)"))
        #expect(result.contains("[e](notes.md)"))
        #expect(result.contains("still code [f](notes.md)"))
        #expect(result.contains("    [g](notes.md) indented code"))
        #expect(result.contains("- item [h](guide.md)"))
        #expect(result.contains("[i](guide.md) list continuation"))
        #expect(result.contains("[j](notes.md) fenced in a list"))
        #expect(result.contains("[[guide]] `[[notes]]`"))
    }

    @Test func frontMatterAndEscapesAreLeftAlone() {
        let text = "---\nlink: [x](notes.md)\n---\n\\[not a link](notes.md) [yes](notes.md)\n"
        #expect(rewrite(text, at: "/p/i.md", [rename]) == "---\nlink: [x](notes.md)\n---\n\\[not a link](notes.md) [yes](guide.md)\n")
    }

    @Test func externalURLsAreNeverTouched() {
        let text = """
        [web](https://example.com/notes.md) <https://example.com/notes.md> [mail](mailto:a@example.com)
        [abs](/p/notes.md) [scheme](lexmd-doc:///p/notes.md) [proto](//example.com/notes.md)
        """
        #expect(rewrite(text, at: "/p/i.md", [rename]) == text)
        #expect(LinkRewriter.isExternal("HTTP://x"))
        #expect(!LinkRewriter.isExternal("notes.md"))
        #expect(!LinkRewriter.isExternal("dir/a:b.md"))
    }

    @Test func linksInsideAMovedFileAreRebased() {
        let move = PathMove(from: "/p/a/doc.md", to: "/p/b/c/doc.md")
        let text = "[s](../shared/s.md) ![i](img.png) [self](doc.md#x) [w](https://x.y) [t](#top)"
        #expect(rewrite(text, at: "/p/b/c/doc.md", [move])
            == "[s](../../shared/s.md) ![i](../../a/img.png) [self](doc.md#x) [w](https://x.y) [t](#top)")
    }

    @Test func movingAFolderKeepsLinksWithinIt() {
        let move = PathMove(from: "/p/docs", to: "/p/guides/docs")
        let text = "[b](b.md) [r](../readme.md) [n](sub/n.md)"
        #expect(rewrite(text, at: "/p/guides/docs/a.md", [move]) == "[b](b.md) [r](../../readme.md) [n](sub/n.md)")
        #expect(rewrite("[a](docs/a.md)", at: "/p/readme.md", [move]) == "[a](guides/docs/a.md)")
    }

    @Test func parenthesesAndLineEndings() {
        let move = PathMove(from: "/p/a(1).md", to: "/p/b(2).md")
        #expect(rewrite("[x](a(1).md)", at: "/p/i.md", [move]) == "[x](b(2).md)")
        #expect(rewrite("one [a](notes.md)\r\ntwo [b](notes.md)\r\n", at: "/p/i.md", [rename])
            == "one [a](guide.md)\r\ntwo [b](guide.md)\r\n")
    }

    @Test func wikiLinksFollowRenames() {
        let move = PathMove(from: "/p/docs/Old Name.md", to: "/p/docs/New Name.md")
        let wiki = wikiRenames(move, files: ["/p/docs/New Name.md", "/p/x.md", "/p/Other.md"])
        let text = "[[Old Name]] [[old name|label]] [[Old Name#Heading]] [[Old Name#H|l]] ![[Old Name]] [[docs/Old Name]] [[Old Name.md]] [[Other]] [[#Local]]"
        #expect(rewrite(text, at: "/p/x.md", [move], wiki: wiki)
            == "[[New Name]] [[New Name|label]] [[New Name#Heading]] [[New Name#H|l]] ![[New Name]] [[docs/New Name]] [[New Name.md]] [[Other]] [[#Local]]")
        #expect(rewrite("| [[Old Name\\|alias]] |", at: "/p/x.md", [move], wiki: wiki) == "| [[New Name\\|alias]] |")
    }

    @Test func wikiLinksFollowFolderMoves() {
        let move = PathMove(from: "/p/docs", to: "/p/guides")
        let wiki = WikiRenames(root: "/p", moves: [move], markdownFiles: ["/p/guides/a.md", "/p/i.md"],
                               movedFiles: [("/p/docs/a.md", "/p/guides/a.md"), ("/p/docs/pic.png", "/p/guides/pic.png")])
        #expect(wiki.rename("docs/a", oldDocument: "/p/i.md", newDocument: "/p/i.md") == "guides/a")
        #expect(wiki.rename("/docs/a", oldDocument: "/p/i.md", newDocument: "/p/i.md") == "/guides/a")
        #expect(wiki.rename("a", oldDocument: "/p/i.md", newDocument: "/p/i.md") == nil, "the name still finds it")
        #expect(wiki.rename("docs/pic.png", oldDocument: "/p/i.md", newDocument: "/p/i.md") == "guides/pic.png")
        #expect(wiki.rename("pic.png", oldDocument: "/p/i.md", newDocument: "/p/i.md") == nil)
    }

    @Test func wikiLinksToAnotherFileWithTheSameNameStay() {
        // Two notes.md: from /p/two/x.md the bare name means the closer one, which did not move.
        let move = PathMove(from: "/p/one/notes.md", to: "/p/one/guide.md")
        let wiki = wikiRenames(move, files: ["/p/one/guide.md", "/p/two/notes.md", "/p/two/x.md", "/p/one/y.md"])
        #expect(wiki.rename("notes", oldDocument: "/p/two/x.md", newDocument: "/p/two/x.md") == nil)
        #expect(wiki.rename("notes", oldDocument: "/p/one/y.md", newDocument: "/p/one/y.md") == "guide")
        #expect(wiki.rename("one/notes", oldDocument: "/p/two/x.md", newDocument: "/p/two/x.md") == "one/guide")
    }

    @Test func wikiLinkNeedsAFolderWhenTheNewNameIsTaken() {
        // After the rename, a bare "b" would mean /p/b.md, so the link keeps a folder.
        let move = PathMove(from: "/p/sub/a.md", to: "/p/sub/b.md")
        let wiki = wikiRenames(move, files: ["/p/sub/b.md", "/p/b.md", "/p/x.md"])
        #expect(wiki.rename("a", oldDocument: "/p/x.md", newDocument: "/p/x.md") == "sub/b")
    }

    @Test func mathAndFootnotesAreNeverRewritten() {
        let wiki = wikiRenames(rename, files: ["/p/guide.md", "/p/i.md"])
        let text = "Math $[a](notes.md)$ and $[[notes]]$, footnote[^notes] [[^notes]], then [[notes]] and [b](notes.md).\n\n$$\n[c](notes.md)\n$$\n\n[^notes]: See notes.md\n"
        let result = rewrite(text, at: "/p/i.md", [rename], wiki: wiki)
        #expect(result.contains("Math $[a](notes.md)$ and $[[notes]]$, footnote[^notes] [[^notes]], then [[guide]] and [b](guide.md)."))
        #expect(result.contains("[c](notes.md)"))
        #expect(result.contains("[^notes]: See notes.md"))
    }

    @Test func htmlIsLeftAlone() {
        let text = "<div>\n[a](notes.md)\n</div>\n\nText <span>[[notes]]</span> [b](notes.md)\n"
        let result = rewrite(text, at: "/p/i.md", [rename], wiki: wikiRenames(rename, files: ["/p/guide.md", "/p/i.md"]))
        #expect(result.contains("<div>\n[a](notes.md)\n</div>"))
        #expect(result.contains("[b](guide.md)"))
    }

    @Test func pathHelpers() {
        #expect(LinkRewriter.normalize("/p/a/../b/./c.md") == "/p/b/c.md")
        #expect(LinkRewriter.relativePath(from: "/p/a/b", to: "/p/c/d.md") == "../../c/d.md")
        #expect(LinkRewriter.relativePath(from: "/p", to: "/p") == ".")
        #expect(PathMove(from: "/p/a", to: "/p/b").map("/p/ab/c.md") == nil)
        #expect(PathMove(from: "/p/a", to: "/p/b").map("/p/a/c.md") == "/p/b/c.md")
    }
}

struct LinkUpdaterTests {
    @Test func planAndRewriteOnDiskWithUndo() throws {
        let folder = try TestFolder()
        let root = FileScanner.canonicalPath(folder.url.path)
        try FileManager.default.createDirectory(atPath: root + "/docs", withIntermediateDirectories: true)
        try folder.write("index.md", "Start at [guide](docs/old.md) and [[old]].\r\n")
        try folder.write("docs/old.md", "Back to [index](../index.md). ![pic](pic.png)\n")
        try folder.write("docs/other.md", "[o](old.md#top) `[c](old.md)`\n")
        // Latin-1 files and UTF-8 files with a byte order mark are written back the same way.
        let latin = "Caf\u{E9} [l](docs/old.md)\n"
        try latin.data(using: .isoLatin1)!.write(to: URL(fileURLWithPath: root + "/latin.md"))
        try (Data([0xEF, 0xBB, 0xBF]) + "[b](docs/old.md)\n".data(using: .utf8)!).write(to: URL(fileURLWithPath: root + "/bom.md"))

        let move = PathMove(from: root + "/docs/old.md", to: root + "/moved/new.md")
        try FileManager.default.createDirectory(atPath: root + "/moved", withIntermediateDirectories: true)
        try FileOperations.move(URL(fileURLWithPath: move.from), to: URL(fileURLWithPath: move.to))
        let files = [root + "/index.md", root + "/moved/new.md", root + "/docs/other.md", root + "/latin.md", root + "/bom.md"]

        let context = LinkUpdater.context(root: root, move: move, markdownFiles: files)
        let plan = LinkUpdater.plan(markdownFiles: files, context: context, overrides: [:])
        #expect(plan.linkCount == 6)
        #expect(plan.files.count == 5)

        let result = LinkUpdater.rewrite(files, context: context)
        #expect(result.failed.isEmpty)
        #expect(try String(contentsOfFile: root + "/index.md", encoding: .utf8) == "Start at [guide](moved/new.md) and [[new]].\r\n")
        #expect(try String(contentsOfFile: root + "/moved/new.md", encoding: .utf8) == "Back to [index](../index.md). ![pic](../docs/pic.png)\n")
        #expect(try String(contentsOfFile: root + "/docs/other.md", encoding: .utf8) == "[o](../moved/new.md#top) `[c](old.md)`\n")
        #expect(try Data(contentsOf: URL(fileURLWithPath: root + "/latin.md")) == "Caf\u{E9} [l](moved/new.md)\n".data(using: .isoLatin1))
        #expect(try Data(contentsOf: URL(fileURLWithPath: root + "/bom.md")).prefix(3) == Data([0xEF, 0xBB, 0xBF]))

        // Undo restores files that were not edited since; edited ones are reported and kept.
        try "edited by hand\n".write(toFile: root + "/docs/other.md", atomically: true, encoding: .utf8)
        let skipped = LinkUpdater.restore(result.written, forward: false)
        #expect(skipped == [root + "/docs/other.md"])
        #expect(try String(contentsOfFile: root + "/index.md", encoding: .utf8) == "Start at [guide](docs/old.md) and [[old]].\r\n")
        #expect(try String(contentsOfFile: root + "/docs/other.md", encoding: .utf8) == "edited by hand\n")
        // Redo applies them again.
        #expect(LinkUpdater.restore(result.written, forward: true) == [root + "/docs/other.md"])
        #expect(try String(contentsOfFile: root + "/index.md", encoding: .utf8) == "Start at [guide](moved/new.md) and [[new]].\r\n")
    }

    @Test func rewritingASymlinkedDocumentKeepsTheLink() throws {
        let folder = try TestFolder()
        let root = FileScanner.canonicalPath(folder.url.path)
        try FileManager.default.createDirectory(atPath: root + "/shared", withIntermediateDirectories: true)
        try folder.write("shared/notes.md", "[x](../old.md)\n")
        try FileManager.default.createSymbolicLink(atPath: root + "/notes.md", withDestinationPath: "shared/notes.md")
        var file = try #require(TextFile.read(URL(fileURLWithPath: root + "/notes.md")))
        file.text = "[x](new.md)\n"
        try file.write(to: URL(fileURLWithPath: root + "/notes.md"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: root + "/notes.md") == "shared/notes.md")
        #expect(try String(contentsOfFile: root + "/shared/notes.md", encoding: .utf8) == "[x](new.md)\n")
        #expect(LinkUpdater.restore([RewrittenFile(path: root + "/notes.md", before: "[x](../old.md)\n", after: "[x](new.md)\n")], forward: false).isEmpty)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: root + "/notes.md") == "shared/notes.md")
    }

    @Test func planUsesUnsavedTextOfOpenDocuments() throws {
        let folder = try TestFolder()
        let root = FileScanner.canonicalPath(folder.url.path)
        try folder.write("a.md", "nothing on disk\n")
        try folder.write("new.md", "x")
        let move = PathMove(from: root + "/old.md", to: root + "/new.md")
        let context = LinkUpdater.context(root: root, move: move, markdownFiles: [root + "/a.md", root + "/new.md"])
        let plan = LinkUpdater.plan(markdownFiles: [root + "/a.md"], context: context, overrides: [root + "/a.md": "[x](old.md) [y](old.md)"])
        #expect(plan.files == [LinkUpdatePlan.File(path: root + "/a.md", count: 2)])
    }

    @Test func folderMoveListsItsFilesForWikiLinks() throws {
        let folder = try TestFolder()
        let root = FileScanner.canonicalPath(folder.url.path)
        try FileManager.default.createDirectory(atPath: root + "/guides", withIntermediateDirectories: true)
        try folder.write("guides/a.md", "x")
        try folder.writePNG("guides/p.png")
        let move = PathMove(from: root + "/docs", to: root + "/guides")
        let context = LinkUpdater.context(root: root, move: move, markdownFiles: [root + "/guides/a.md", root + "/i.md"])
        #expect(context.wiki.rename("docs/a", oldDocument: root + "/i.md", newDocument: root + "/i.md") == "guides/a")
        #expect(context.wiki.rename("docs/p.png", oldDocument: root + "/i.md", newDocument: root + "/i.md") == "guides/p.png")
        #expect(rewrite("[a](docs/a.md) ![p](docs/p.png)", at: root + "/i.md", context.moves, wiki: context.wiki)
            == "[a](guides/a.md) ![p](guides/p.png)")
    }
}

@MainActor
struct EditorLinkEditTests {
    @Test func editsInTheOpenDocumentAreOneUndoStep() async throws {
        let editor = EditorController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.scrollView
        let original = "[a](notes.md) text [b](notes.md#x)\n"
        editor.load(original)
        var reported = ""
        editor.onTextChange = { reported = $0 }
        let undo = try #require(editor.textView.undoManager)
        undo.groupsByEvent = false

        let context = LinkRewriter.Context(moves: [rename])
        let edits = LinkRewriter.edits(in: original, oldPath: "/p/i.md", newPath: "/p/i.md", context: context)
        undo.beginUndoGrouping()
        #expect(editor.replace(edits, actionName: "Update Links"))
        undo.endUndoGrouping()
        #expect(editor.textView.string == "[a](guide.md) text [b](guide.md#x)\n")
        #expect(reported == editor.textView.string, "the model hears about the change, so it autosaves")
        #expect(undo.undoActionName == "Update Links")

        undo.undo()
        #expect(editor.textView.string == original)
        try await waitUntil { reported == original }
        undo.redo()
        try await waitUntil { reported == "[a](guide.md) text [b](guide.md#x)\n" }
        undo.undo()
        try await waitUntil { reported == original }

        editor.restore(selection: NSRange(location: 500, length: 3), origin: nil)
        #expect(editor.textView.selectedRange() == NSRange(location: (original as NSString).length, length: 0))
    }
}
