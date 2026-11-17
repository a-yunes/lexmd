import Foundation
import Testing
@testable import LexMDRendering

/// Rendered blocks carry the source line they start on, so the editor and preview can scroll
/// to the same place.
struct SourceLineTests {
    /// Each tagged element's tag name and line, in document order; `-N` follows the line of a
    /// block that ends on a later line N.
    private func lines(_ markdown: String) -> [String] {
        let html = MarkdownHTML.renderWithSourceLines(markdown).html
        let regex = try! NSRegularExpression(pattern: #"<([a-z0-9]+) data-line="(\d+)"(?: data-end="(\d+)")?"#)
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).map {
            let end = $0.range(at: 3).location == NSNotFound ? "" : "-" + ns.substring(with: $0.range(at: 3))
            return "\(ns.substring(with: $0.range(at: 1)))\(ns.substring(with: $0.range(at: 2)))\(end)"
        }
    }

    @Test func blocksCarryTheLineTheyStartOn() {
        #expect(lines("# Title\n\nA paragraph\nthat wraps.\n\n- one\n- two\n\n> quote\n\n---\n") ==
            ["h11", "p3-4", "p6", "p7", "p9", "hr11"], "lists and quotes carry none of their own")
    }

    @Test func frontMatterCountsTowardTheLines() {
        let result = lines("---\ntitle: Notes\n---\n# After\n")
        #expect(result.first?.hasSuffix("1-3") == true, "the properties table covers the front matter's lines")
        #expect(result.last == "h14")
    }

    @Test func mathOverSeveralLinesKeepsLaterLinesInPlace() {
        #expect(lines("Intro\n\n$$\nx^2\n+ y\n$$\n\n# After\n") == ["p1", "div3-6", "h18"])
        #expect(lines("Inline $a$ and $b$.\n\n## Next\n") == ["p1", "h23"])
    }

    @Test func footnoteDefinitionsKeepLaterLinesInPlace() {
        let result = lines("Text[^1].\n\n[^1]: A note\n  that continues.\n\n# After\n")
        #expect(result.contains("h16"))
        #expect(result.first == "p1")
    }

    @Test func tablesTagTheirRows() {
        #expect(lines("| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n") == ["tr1", "tr3", "tr4"])
    }

    @Test func calloutsAndDiagramsCarryTheirLines() {
        #expect(lines("> [!NOTE]\n> Remember this.\n") == ["p1-2"])
        let diagram = MarkdownHTML.renderWithSourceLines("```mermaid\nflowchart LR\n  A --> B\n```\n").html
        #expect(diagram.hasPrefix("<div data-line=\"1\" data-end=\"4\" class=\"lexmd-diagram\"><div class=\"codeblock\">"))
        #expect(lines("```swift\nlet x = 1\n```\n\n```math\nx\n```\n") == ["div1-3", "div5-7"])
    }

    @Test func exportsAndQuickLookCarryNoLines() {
        #expect(!MarkdownHTML.render("# A\n\nText\n").contains("data-line"))
    }

    @Test func theLineCountComesWithTheMarkup() {
        #expect(MarkdownHTML.renderWithSourceLines("one\ntwo\n").lineCount == 3, "the empty line after the last break counts")
        #expect(MarkdownHTML.renderWithSourceLines("one").lineCount == 1)
    }

    /// Callouts and display math are recognized in the parsed document, with or without lines.
    @Test func calloutsAndDisplayMathRenderTheSameWithLines() {
        #expect(MarkdownHTML.render("> [!TIP]\n> Try it.\n\n> [!NOTE]\n>\n> Later.\n\n> Plain quote\n") == """
            <div class="callout callout-tip"><div class="callout-title">Tip</div>
            <p>Try it.</p>
            </div>
            <div class="callout callout-note"><div class="callout-title">Note</div>

            <p>Later.</p>
            </div>
            <blockquote>
            <p>Plain quote</p>
            </blockquote>

            """)
        let math = MarkdownHTML.renderWithSourceLines("$$x$$\n\nInline $$y$$ here.\n").html
        #expect(math.hasPrefix("<div data-line=\"1\" class=\"lexmd-math lexmd-display\""))
        #expect(math.contains("<p data-line=\"3\">Inline <span class=\"lexmd-math lexmd-display\""))
    }
}

/// One definition of a line for the editor, the renderer and search.
struct LineIndexTests {
    @Test func linesEndAtEveryKindOfLineBreak() {
        #expect(LineIndex("a\nb\r\nc\rd").starts == [0, 2, 5, 7])
        #expect(LineIndex("").starts == [0])
        #expect(LineIndex("a\n").count == 2)
        #expect(LineIndex("a\r").count == 2)
        #expect(LineIndex(utf8: Array("é\nb".utf8)).starts == [0, 3], "byte offsets")
        #expect(LineIndex("é\nb").starts == [0, 2], "UTF-16 offsets")
    }

    @Test func offsetsAndLines() {
        let index = LineIndex("one\ntwo\nthree")
        #expect(index.line(at: 0) == 0)
        #expect(index.line(at: 3) == 0, "the line break belongs to its line")
        #expect(index.line(at: 4) == 1)
        #expect(index.line(at: 100) == 2)
        #expect(index.start(ofLine: 2) == 8)
        #expect(index.start(ofLine: 9) == 8)
        #expect(index.start(ofLine: -1) == 0)
    }
}
