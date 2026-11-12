import AppKit
import Testing
@testable import LexMD

/// Image paste and drop, smart paste, table editing, focus mode, typewriter scrolling, and spelling.
@MainActor
struct EditorFeatureTests {
    /// An editor in a window, so it has an undo manager.
    @MainActor
    private final class Harness {
        let editor = EditorController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)

        init(_ text: String, selection: NSRange? = nil) {
            window.isReleasedWhenClosed = false
            window.contentView = editor.scrollView
            editor.load(text)
            if let selection { editor.textView.setSelectedRange(selection) }
            window.makeFirstResponder(editor.textView)
        }

        var text: String { editor.textView.string }
        var selection: NSRange { editor.textView.selectedRange() }

        func undo() {
            editor.textView.undoManager?.undo()
        }

        func select(_ substring: String) {
            editor.textView.setSelectedRange((text as NSString).range(of: substring))
        }
    }

    private static func pasteboard() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("LexMDTests-\(UUID().uuidString)"))
        board.clearContents()
        return board
    }

    private static func pngData() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        return rep.representation(using: .png, properties: [:])!
    }

    private static let pasteDate = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 9, minute: 14))!

    // MARK: Images

    @Test func pastedImageIsSavedUnderAUniqueNameAndLinked() throws {
        let folder = try TestFolder()
        let docs = folder.url.appendingPathComponent("Notes Ü", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let document = docs.appendingPathComponent("doc.md")
        try "Hi\n".write(to: document, atomically: true, encoding: .utf8)
        let harness = Harness("Hi\n", selection: NSRange(location: 3, length: 0))
        harness.editor.imageContext = { ImageContext(document: document, root: folder.url, folder: "my assets") }

        // An existing file with the first name must survive.
        let assets = docs.appendingPathComponent("my assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let existing = assets.appendingPathComponent("image-2026-11-12-0914.png")
        try Data("keep".utf8).write(to: existing)

        let board = Self.pasteboard()
        board.setData(Self.pngData(), forType: .png)
        #expect(harness.editor.paste(from: board, date: Self.pasteDate))
        #expect(harness.text == "Hi\n![](my%20assets/image-2026-11-12-0914-2.png)")
        #expect(try Data(contentsOf: existing) == Data("keep".utf8))
        #expect(try Data(contentsOf: assets.appendingPathComponent("image-2026-11-12-0914-2.png")) == Self.pngData())

        harness.undo()
        #expect(harness.text == "Hi\n")
    }

    @Test func pastedTIFFBecomesPNGInANewFolder() throws {
        let folder = try TestFolder()
        let document = try folder.write("doc.md", "")
        let harness = Harness("")
        harness.editor.imageContext = { ImageContext(document: document, root: nil, folder: "/img/") }
        let image = NSImage(data: Self.pngData())!
        let board = Self.pasteboard()
        board.setData(image.tiffRepresentation!, forType: .tiff)
        #expect(harness.editor.paste(from: board, date: Self.pasteDate))
        #expect(harness.text == "![](img/image-2026-11-12-0914.png)")
        let saved = try Data(contentsOf: folder.url.appendingPathComponent("img/image-2026-11-12-0914.png"))
        #expect(saved.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func droppedImageInsideProjectIsLinkedInPlace() throws {
        let folder = try TestFolder()
        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent("pics"), withIntermediateDirectories: true)
        let document = try folder.write("docs/readme.md", "A\n")
        try folder.writePNG("pics/фото (1).png")
        let image = folder.url.appendingPathComponent("pics/фото (1).png")
        let harness = Harness("A\n")
        harness.editor.imageContext = { ImageContext(document: document, root: folder.url, folder: "assets") }

        let board = Self.pasteboard()
        board.writeObjects([image as NSURL])
        #expect(harness.editor.dropImages(from: board, at: 0))
        #expect(harness.text == "![](../pics/%D1%84%D0%BE%D1%82%D0%BE%20%281%29.png)A\n")
        #expect(!FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("docs/assets").path))
        harness.undo()
        #expect(harness.text == "A\n")
    }

    @Test func droppedImageOutsideProjectIsCopiedWithoutOverwriting() throws {
        let project = try TestFolder()
        let outside = try TestFolder()
        let document = try project.write("doc.md", "")
        try outside.writePNG("shot.png")
        try FileManager.default.createDirectory(at: project.url.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try project.write("assets/shot.png", "existing")
        let harness = Harness("")
        harness.editor.imageContext = { ImageContext(document: document, root: project.url, folder: "assets") }

        let board = Self.pasteboard()
        board.writeObjects([outside.url.appendingPathComponent("shot.png") as NSURL])
        #expect(harness.editor.dropImages(from: board, at: 0))
        #expect(harness.text == "![](assets/shot-2.png)")
        #expect(try String(contentsOf: project.url.appendingPathComponent("assets/shot.png"), encoding: .utf8) == "existing")
        #expect(FileManager.default.fileExists(atPath: project.url.appendingPathComponent("assets/shot-2.png").path))
    }

    @Test func nonImageDropsAndMissingDocumentKeepDefaultBehavior() throws {
        let folder = try TestFolder()
        let document = try folder.write("doc.md", "")
        let other = try folder.write("other.md", "# Other")
        let harness = Harness("")
        let board = Self.pasteboard()
        board.writeObjects([other as NSURL])
        harness.editor.imageContext = { ImageContext(document: document, root: folder.url, folder: "assets") }
        #expect(!harness.editor.dropImages(from: board, at: 0))

        // Without an open document, images fall through to the text view.
        harness.editor.imageContext = { nil }
        let image = Self.pasteboard()
        image.setData(Self.pngData(), forType: .png)
        #expect(!harness.editor.paste(from: image))
        #expect(harness.text.isEmpty)
    }

    @Test func imagePathsAreRelativeAndEncoded() {
        let directory = URL(fileURLWithPath: "/tmp/LexMDNoSuch/a/b")
        #expect(ImageStore.relativePath(from: directory, to: URL(fileURLWithPath: "/tmp/LexMDNoSuch/a/b/x.png")) == "x.png")
        #expect(ImageStore.relativePath(from: directory, to: URL(fileURLWithPath: "/tmp/LexMDNoSuch/a/c/x.png")) == "../c/x.png")
        #expect(ImageStore.encodePath("my assets/日本 a:b#c?.png") == "my%20assets/%E6%97%A5%E6%9C%AC%20a%3Ab%23c%3F.png")
        #expect(ImageStore.pastedName(date: Self.pasteDate, ext: "png") == "image-2026-11-12-0914.png")
        #expect(Array(ImageStore.candidates(for: "a.b.png").prefix(3)) == ["a.b.png", "a.b-2.png", "a.b-3.png"])
    }

    // MARK: Smart paste

    @Test func urlPastedOverSelectionMakesALink() {
        let harness = Harness("See the docs here.")
        harness.select("docs")
        let board = Self.pasteboard()
        board.setString(" https://example.com/a_(b)?q=1 \n", forType: .string)
        #expect(harness.editor.paste(from: board))
        #expect(harness.text == "See the [docs](https://example.com/a_(b)?q=1) here.")
        #expect(harness.selection == NSRange(location: 45, length: 0))
        harness.undo()
        #expect(harness.text == "See the docs here.")
    }

    @Test func urlLinksHandleUnbalancedParenthesesAndSkipPlainPastes() {
        #expect(SmartPaste.link(text: "x", url: "https://e.com/a)") == "[x](<https://e.com/a)>)")
        #expect(SmartPaste.url(in: "mailto:me@example.com") == "mailto:me@example.com")
        #expect(SmartPaste.url(in: "https://a.com b") == nil)
        #expect(SmartPaste.url(in: "not a url") == nil)

        // No selection, or a selection that is itself a URL: paste normally.
        let harness = Harness("one https://old.example")
        let board = Self.pasteboard()
        board.setString("https://example.com", forType: .string)
        #expect(!harness.editor.paste(from: board))
        harness.select("https://old.example")
        #expect(!harness.editor.paste(from: board))
        #expect(harness.text == "one https://old.example")
    }

    @Test func tsvBecomesATableWithEscapedPipesAndEmptyCells() {
        let harness = Harness("Intro\n")
        harness.editor.textView.setSelectedRange(NSRange(location: 6, length: 0))
        let board = Self.pasteboard()
        board.setString("Name\tNote\r\nA|B\t\r\n\"two\nlines\"\t\"say \"\"hi\"\"\"\r\n", forType: .string)
        #expect(harness.editor.paste(from: board))
        #expect(harness.text == """
        Intro
        | Name         | Note     |
        | ------------ | -------- |
        | A\\|B         |          |
        | two<br>lines | say "hi" |
        """)
        harness.undo()
        #expect(harness.text == "Intro\n")
    }

    @Test func tsvDetectionRejectsIndentedCodeAndSingleRows() {
        #expect(SmartPaste.tsvRows("\tfoo\n\tbar\n") == nil)
        #expect(SmartPaste.tsvRows("a\tb\n") == nil)
        #expect(SmartPaste.tsvRows("a\tb\nc\n") == nil)
        #expect(SmartPaste.tsvRows("plain text") == nil)
        #expect(SmartPaste.tsvRows("\"open\tb\nc\td") == [["\"open", "b"], ["c", "d"]])
    }

    @Test func htmlTableBecomesAMarkdownTable() throws {
        let html = """
        <html><head><style>td { color: red }</style></head><body>
        <table><thead><tr><th>A</th><th colspan="2">B C</th></tr></thead>
        <tbody><tr><td>1 | 2</td><td></td><td>x
        y</td></tr></tbody></table></body></html>
        """
        let rows = try #require(SmartPaste.htmlRows(html))
        #expect(rows == [["A", "B C", ""], ["1 | 2", "", "x y"]])
        #expect(SmartPaste.table(rows: rows) == """
        | A      | B C |     |
        | ------ | --- | --- |
        | 1 \\| 2 |     | x y |
        """)
        #expect(SmartPaste.htmlRows("<p>Intro</p><table><tr><td>a</td><td>b</td></tr></table>") == nil)

        let harness = Harness("")
        let board = Self.pasteboard()
        board.setString(html, forType: .html)
        board.setString("A B C 1 | 2 x y", forType: .string)
        #expect(harness.editor.paste(from: board))
        #expect(harness.text.hasPrefix("| A      | B C |     |\n"))
    }

    @Test func smartPasteIsOffInsideFencedCode() {
        let harness = Harness("```\nword\n```\n")
        harness.select("word")
        let board = Self.pasteboard()
        board.setString("a\tb\nc\td\n", forType: .string)
        #expect(!harness.editor.paste(from: board))
        board.clearContents()
        board.setString("https://example.com", forType: .string)
        #expect(!harness.editor.paste(from: board))
    }

    @Test func focusModeRefreshesAfterTheDocumentIsReplaced() {
        let harness = Harness("one\n\ntwo\n")
        harness.editor.isFocusModeEnabled = true
        #expect(harness.editor.focusState.paragraph == NSRange(location: 0, length: 4))
        harness.editor.load("other\n\ntext\n")
        #expect(harness.editor.focusState.paragraph == NSRange(location: 0, length: 6))
        #expect(!harness.editor.focusState.isStale)
    }

    // MARK: Tables

    @Test func formatTableAlignsColumnsAndKeepsAlignmentRow() {
        let harness = Harness("Text\n\n|a|b|c\n|:-|-:|:-:|\n|longer|x|\n|1|2|3|4\n\nAfter", selection: NSRange(location: 8, length: 0))
        harness.editor.formatTable()
        #expect(harness.text == """
        Text

        | a      |   b |  c  |     |
        | :----- | --: | :-: | --- |
        | longer |   x |     |     |
        | 1      |   2 |  3  | 4   |

        After
        """)
        #expect(Self.matchesFullHighlight(harness.editor))
        harness.undo()
        #expect(harness.text == "Text\n\n|a|b|c\n|:-|-:|:-:|\n|longer|x|\n|1|2|3|4\n\nAfter")
    }

    @Test func formatTableUsesDisplayWidth() {
        let harness = Harness("| 名前 | 😀 | x |\n|-|-|-|\n| ab | 👍🏽 | é |", selection: NSRange(location: 2, length: 0))
        harness.editor.formatTable()
        #expect(harness.text == """
        | 名前 | 😀  | x   |
        | ---- | --- | --- |
        | ab   | 👍🏽  | é   |
        """)
    }

    @Test func displayWidthCountsWideCharactersAsTwo() {
        #expect(MarkdownTable.displayWidth("abc") == 3)
        #expect(MarkdownTable.displayWidth("日本語") == 6)
        #expect(MarkdownTable.displayWidth("한국") == 4)
        #expect(MarkdownTable.displayWidth("ｱ") == 1)
        #expect(MarkdownTable.displayWidth("Ａ") == 2)
        #expect(MarkdownTable.displayWidth("😀👍🏽🇯🇵") == 6)
        #expect(MarkdownTable.displayWidth("❤️") == 2)
        #expect(MarkdownTable.displayWidth("e\u{301}") == 1)
    }

    @Test func tabMovesBetweenCellsAndAddsARow() {
        let original = "| a | b |\n|---|---|\n| c | d |"
        let harness = Harness(original + "\n", selection: NSRange(location: 2, length: 0))
        let view = harness.editor.textView
        func tab(_ backward: Bool = false) -> Bool {
            harness.editor.textView(view, doCommandBy: backward ? #selector(NSResponder.insertBacktab(_:)) : #selector(NSResponder.insertTab(_:)))
        }
        func selected() -> String { (harness.text as NSString).substring(with: harness.selection) }

        #expect(tab())
        #expect(selected() == "b")
        #expect(harness.text == "| a   | b   |\n| --- | --- |\n| c   | d   |\n")
        harness.undo()
        #expect(harness.text == original + "\n")

        harness.editor.textView.setSelectedRange(NSRange(location: 6, length: 0))
        #expect(tab())
        #expect(selected() == "c")
        #expect(tab())
        #expect(selected() == "d")
        #expect(tab())
        #expect(harness.text == "| a   | b   |\n| --- | --- |\n| c   | d   |\n|     |     |\n")
        #expect(harness.selection == NSRange(location: 44, length: 0))
        #expect(tab(true))
        #expect(selected() == "d")
        #expect(tab(true))
        #expect(tab(true))
        #expect(selected() == "b")
        #expect(tab(true))
        #expect(tab(true))
        #expect(selected() == "a")
        #expect(Self.matchesFullHighlight(harness.editor))
    }

    @Test func tabOutsideTablesAndInCodeKeepsDefaultBehavior() {
        let text = "Plain | text\n\n```\n| a | b |\n|---|---|\n```\n"
        let harness = Harness(text, selection: NSRange(location: 2, length: 0))
        let view = harness.editor.textView
        #expect(!harness.editor.textView(view, doCommandBy: #selector(NSResponder.insertTab(_:))))
        view.setSelectedRange(NSRange(location: 20, length: 0))
        #expect(!harness.editor.textView(view, doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(harness.text == text)
    }

    @Test func tableParsingHandlesEscapesAndIndent() {
        #expect(MarkdownTable.cells("| a \\| b | `c` |") == ["a \\| b", "`c`"])
        #expect(MarkdownTable.cells("a | b") == ["a", "b"])
        #expect(MarkdownTable.alignments("|:--|--:|:-:|---|") == [.left, .right, .center, .none])
        #expect(MarkdownTable.alignments("| --- | text |") == nil)
        #expect(MarkdownTable.alignments("---") == nil)
        let table = MarkdownTable(lines: ["  | x | y |", "  |---|---|"])
        #expect(table?.formatted().text == "  | x   | y   |\n  | --- | --- |")
    }

    // MARK: Focus and typewriter

    @Test func focusModeUsesRenderingAttributesOnly() throws {
        let text = "# Title\n\nFirst **para**\ncontinues.\n\nSecond `para`.\n"
        let harness = Harness(text, selection: NSRange(location: 12, length: 0))
        let storage = harness.editor.textView.textStorage!
        let before = NSAttributedString(attributedString: storage)
        harness.editor.isFocusModeEnabled = true
        #expect(harness.editor.focusState.paragraph == NSRange(location: 9, length: 26))
        #expect(storage.isEqual(to: before))
        harness.editor.textView.setSelectedRange(NSRange(location: 40, length: 0))
        #expect(harness.editor.focusState.paragraph == NSRange(location: 36, length: 15))
        #expect(storage.isEqual(to: before))
        let dimmed = try #require(harness.editor.textView.textLayoutManager)
        var colored = 0
        dimmed.enumerateRenderingAttributes(from: dimmed.documentRange.location, reverse: false) { _, attributes, _ in
            if attributes[.foregroundColor] != nil { colored += 1 }
            return true
        }
        #expect(colored > 0)

        harness.editor.textView.insertText("x", replacementRange: NSRange(location: 40, length: 0))
        #expect(Self.matchesFullHighlight(harness.editor))
        harness.editor.isFocusModeEnabled = false
        #expect(harness.editor.focusState.paragraph == nil)
    }

    @Test func focusParagraphIsTheRunOfNonBlankLines() {
        let text = "a\nb\n\n  \nc\n" as NSString
        #expect(EditorController.focusParagraph(in: text, at: 0) == NSRange(location: 0, length: 4))
        #expect(EditorController.focusParagraph(in: text, at: 4) == NSRange(location: 4, length: 1))
        #expect(EditorController.focusParagraph(in: text, at: 8) == NSRange(location: 8, length: 2))
        #expect(EditorController.focusParagraph(in: text, at: text.length) == NSRange(location: 10, length: 0))
    }

    @Test func typewriterScrollingAddsBottomSpaceAndCentersOffsets() {
        let harness = Harness(String(repeating: "line\n", count: 200))
        harness.editor.isTypewriterScrollingEnabled = true
        #expect(harness.editor.textView.bottomOverscroll > 200)
        #expect(harness.editor.textView.textContainerOrigin.y == 30)
        harness.editor.isTypewriterScrollingEnabled = false
        #expect(harness.editor.textView.bottomOverscroll == 0)
        #expect(EditorController.centeredOffset(caretMidY: 1000, visibleHeight: 600, documentHeight: 5000, topInset: 0) == 700)
        #expect(EditorController.centeredOffset(caretMidY: 100, visibleHeight: 600, documentHeight: 5000, topInset: 0) == 0)
        #expect(EditorController.centeredOffset(caretMidY: 4990, visibleHeight: 600, documentHeight: 5000, topInset: 0) == 4400)
    }

    // MARK: Undo and reload

    @Test func replacingTheTextDropsUndoStepsForTheOldText() throws {
        let harness = Harness("Hello world\n", selection: NSRange(location: 11, length: 0))
        harness.editor.textView.insertText(" and more", replacementRange: harness.selection)
        let undoManager = try #require(harness.editor.textView.undoManager)
        #expect(undoManager.canUndo)
        harness.editor.replaceText("Rewritten elsewhere\n")
        #expect(!undoManager.canUndo)
        harness.undo()
        #expect(harness.text == "Rewritten elsewhere\n")
    }

    @Test func textUndoIsSeparateFromTheWindowsFileUndo() throws {
        let harness = Harness("One\n", selection: NSRange(location: 3, length: 0))
        let editor = harness.editor
        let window = harness.window
        #expect(editor.textView.undoManager === editor.undoManager)
        let windowUndo = try #require(window.undoManager)
        #expect(windowUndo !== editor.undoManager)

        // A file operation registers on the window, as AppModel.fileUndoManager does.
        final class Flag { var undone = false }
        let flag = Flag()
        windowUndo.registerUndo(withTarget: flag) { $0.undone = true }

        editor.textView.insertText(" two", replacementRange: harness.selection)
        #expect(editor.undoManager.canUndo)

        // Undo from the focused editor reverts text, not the file operation.
        #expect(window.firstResponder === editor.textView)
        #expect(editor.textView.tryToPerform(Selector(("undo:")), with: nil))
        #expect(harness.text == "One\n")
        #expect(!flag.undone)

        // Loading or reloading a document clears only the text history.
        editor.textView.insertText("!", replacementRange: NSRange(location: 0, length: 0))
        editor.load("Other\n")
        editor.replaceText("Reloaded\n")
        #expect(!editor.undoManager.canUndo)
        #expect(windowUndo.canUndo)

        // With focus elsewhere, Undo reaches the file operation.
        window.makeFirstResponder(nil)
        #expect(window.tryToPerform(Selector(("undo:")), with: nil))
        #expect(flag.undone)
        #expect(harness.text == "Reloaded\n")
    }

    // MARK: Input methods

    @Test func pasteWhileComposingIsLeftToTheTextView() {
        let harness = Harness("Text\n", selection: NSRange(location: 4, length: 0))
        let view = harness.editor.textView
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())
        let board = Self.pasteboard()
        board.setString("a\tb\nc\td\n", forType: .string)
        #expect(!harness.editor.paste(from: board))
        #expect(harness.text == "Textか\n")
    }

    // MARK: Spelling

    @Test func spellingSkipsCodeURLsAndFrontMatter() {
        let text = """
        ---
        titel: x
        ---
        Helo `wrld` and https://exampel.com/pth and [lnk](http://exampel.org).

        ```
        codde
        ```
        """ as NSString
        func excluded(_ word: String) -> Bool {
            EditorController.isExcludedFromSpelling(text.range(of: word), in: text, blocks: nil)
        }
        #expect(excluded("titel"))
        #expect(excluded("wrld"))
        #expect(excluded("exampel.com"))
        #expect(excluded("exampel.org"))
        #expect(excluded("codde"))
        #expect(!excluded("Helo"))
        #expect(!excluded("lnk"))

        let harness = Harness(text as String)
        let view = harness.editor.textView
        #expect(harness.editor.responds(to: #selector(NSTextViewDelegate.textView(_:shouldSetSpellingState:range:))))
        #expect(harness.editor.textView(view, shouldSetSpellingState: 1, range: text.range(of: "wrld")) == 0)
        #expect(harness.editor.textView(view, shouldSetSpellingState: 1, range: text.range(of: "Helo")) == 1)
        #expect(!view.isContinuousSpellCheckingEnabled, "off by default, as checking a whole document on load is costly")
        #expect(!view.isGrammarCheckingEnabled)
    }

    // MARK: Helpers

    private static func matchesFullHighlight(_ editor: EditorController) -> Bool {
        let storage = editor.textView.textStorage!
        let reference = NSTextStorage(string: storage.string)
        MarkdownHighlighter.highlight(reference, size: editor.fontSize)
        for key in [NSAttributedString.Key.foregroundColor, .font, .strikethroughStyle] {
            var index = 0
            while index < storage.length {
                var a = NSRange(), b = NSRange()
                let left = storage.attribute(key, at: index, effectiveRange: &a) as? NSObject
                let right = reference.attribute(key, at: index, effectiveRange: &b) as? NSObject
                if left != right { return false }
                index = min(NSMaxRange(a), NSMaxRange(b))
            }
        }
        return true
    }
}
