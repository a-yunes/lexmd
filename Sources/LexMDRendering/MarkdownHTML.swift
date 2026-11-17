import Foundation
import Markdown

/// Resolves wiki links and marks broken links while rendering. The app's `LinkContext` conforms.
package protocol MarkdownLinkRendering {
    /// The markup for one text run, with wiki links as links. `restore` turns placeholders back into source.
    mutating func html(forText text: String, restore: (String) -> String) -> String
    /// The class attribute for a Markdown link, or "" when it needs none.
    mutating func linkClass(forDestination destination: String) -> String
}

package enum MarkdownHTML {
    /// `links` resolves wiki links and marks broken local links; without it they render as text.
    package static func render(_ source: String, links: (any MarkdownLinkRendering)? = nil) -> String {
        render(source, links: links, sourceLines: false)
    }

    /// HTML whose blocks say which lines of the source they were rendered from, and how many
    /// lines the source has.
    package struct SourceMapped: Sendable {
        package var html: String
        package var lineCount: Int
    }

    /// Renders for the live preview: each innermost block (a paragraph, a heading, a table row, a
    /// code block) carries `data-line`, the line of `source` it starts on (the first line is 1),
    /// and `data-end`, its last line, when it spans several. The preview and the editor use them
    /// to scroll to the same place.
    package static func renderWithSourceLines(_ source: String, links: (any MarkdownLinkRendering)? = nil) -> SourceMapped {
        SourceMapped(html: render(source, links: links, sourceLines: true), lineCount: LineIndex(utf8: Array(source.utf8)).count)
    }

    private static func render(_ source: String, links: (any MarkdownLinkRendering)?, sourceLines: Bool) -> String {
        guard let split = FrontMatter.split(source) else {
            return renderBody(source, footnotes: true, links: links, lineOffset: sourceLines ? 0 : nil)
        }
        let lines = sourceLines ? " data-line=\"1\" data-end=\"\(split.lineCount)\"" : ""
        let properties = FrontMatter.html(split.yaml, attributes: lines)
            ?? "<pre\(lines) class=\"frontmatter\"><code>\(escape(split.yaml))</code></pre>\n"
        return properties + renderBody(split.rest, footnotes: true, links: links, lineOffset: sourceLines ? split.lineCount : nil)
    }

    /// Renders Markdown with math, diagrams, and optionally footnotes (see `MarkdownExtensions`).
    /// Footnote bodies get the same link context, so their wiki links and broken links render too.
    /// With `lineOffset`, the number of lines before `source` in its document, blocks carry
    /// their lines.
    package static func renderBody(
        _ source: String, footnotes: Bool, links: (any MarkdownLinkRendering)? = nil, lineOffset: Int? = nil
    ) -> String {
        let extensions = MarkdownExtensions(source, footnotes: footnotes)
        let document = extensions.document ?? Document(parsing: extensions.source)
        var renderer = HTMLRenderer()
        renderer.extensions = extensions
        renderer.links = links
        renderer.lineOffset = lineOffset
        renderer.visit(document)
        return extensions.finish(renderer.result) + extensions.footnotesHTML { renderBody($0, footnotes: false, links: links) }
    }

    /// Fenced code in these languages is drawn as a diagram by the preview.
    package static func isDiagram(_ language: String) -> Bool {
        ["mermaid", "pele"].contains(language.lowercased())
    }

    package static func wordCount(_ source: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in source.unicodeScalars {
            let isSpace = CharacterSet.whitespacesAndNewlines.contains(scalar)
            if isSpace {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        return count
    }

    /// The reader's preferred language as a BCP 47 tag for `<html lang>`, so VoiceOver reads the
    /// page in the right voice. Falls back to "en".
    package static func languageTag(preferred: [String] = Locale.preferredLanguages) -> String {
        let tag = preferred.first ?? ""
        let valid = !tag.isEmpty && tag.utf8.count <= 35
            && tag.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "-") }
        return valid ? tag : "en"
    }

    package static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }
}

private struct HTMLRenderer: MarkupWalker {
    var result = ""
    var links: (any MarkdownLinkRendering)?
    private var linkDepth = 0
    private var slugCounts: [String: Int] = [:]
    private var inTableHead = false
    private var alignments: [Table.ColumnAlignment?] = []
    private var column = 0
    var extensions = MarkdownExtensions("")
    /// Lines before the rendered text (front matter), when blocks carry their lines.
    var lineOffset: Int?

    private func esc(_ s: String) -> String { MarkdownHTML.escape(s) }

    /// An innermost block's lines in the document as attributes: ` data-line="N"` for the line
    /// it starts on, and ` data-end="M"` for its last line when it spans several. "" without
    /// source lines. Blocks that only hold other blocks (lists, quotes) carry none.
    private func lines(of markup: Markup) -> String {
        guard let lineOffset, let range = markup.range else { return "" }
        let lines = extensions.originalLines(of: range)
        let start = lines.lowerBound + lineOffset
        return " data-line=\"\(start)\"" + (lines.count > 1 ? " data-end=\"\(lines.upperBound + lineOffset)\"" : "")
    }

    private mutating func capture(_ markup: Markup) -> String {
        let saved = result
        result = ""
        descendInto(markup)
        let out = result
        result = saved
        return out
    }

    private mutating func slug(for text: String) -> String {
        var slug = ""
        for c in text.lowercased() {
            if c.isLetter || c.isNumber { slug.append(c) }
            else if c == " " || c == "-" || c == "_" { slug.append("-") }
        }
        if slug.isEmpty { slug = "section" }
        let n = slugCounts[slug, default: 0]
        slugCounts[slug] = n + 1
        return n == 0 ? slug : "\(slug)-\(n)"
    }

    // MARK: Blocks

    mutating func visitHeading(_ heading: Heading) {
        let id = slug(for: extensions.restore(heading.plainText))
        let inner = capture(heading)
        result += "<h\(heading.level)\(lines(of: heading)) id=\"\(esc(id))\">\(inner)</h\(heading.level)>\n"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        // A paragraph that is one display formula renders as a block of its own.
        if paragraph.childCount == 1, let text = paragraph.child(at: 0) as? Text,
           let math = extensions.soleDisplayMath(in: text.string) {
            result += MarkdownExtensions.html(for: math, block: true, attributes: lines(of: paragraph)) + "\n"
            return
        }
        result += "<p\(lines(of: paragraph))>\(capture(paragraph))</p>\n"
    }

    private static let calloutTitles = ["NOTE": "Note", "TIP": "Tip", "IMPORTANT": "Important", "WARNING": "Warning", "CAUTION": "Caution"]

    /// The kind of callout a quote is, from the `[!KIND]` its first paragraph starts with, and
    /// that marker's length.
    private static func callout(_ blockQuote: BlockQuote) -> (kind: String, markerLength: Int)? {
        guard let paragraph = blockQuote.child(at: 0) as? Paragraph, let text = paragraph.child(at: 0) as? Text,
              text.string.hasPrefix("[!"), let close = text.string.firstIndex(of: "]") else { return nil }
        let kind = text.string[text.string.index(text.string.startIndex, offsetBy: 2)..<close].uppercased()
        guard calloutTitles[kind] != nil else { return nil }
        return (kind, text.string.distance(from: text.string.startIndex, to: close) + 1)
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        guard let (kind, markerLength) = Self.callout(blockQuote), let first = blockQuote.child(at: 0) else {
            result += "<blockquote>\n\(capture(blockQuote))</blockquote>\n"
            return
        }
        // The first paragraph without its marker; a marker on a line of its own leaves none.
        var opening = String(capture(first).dropFirst(markerLength))
        while opening.first == "\n" || opening.first == " " { opening.removeFirst() }
        let saved = result
        result = ""
        for child in blockQuote.children.dropFirst() { visit(child) }
        let rest = result
        result = saved
        result += "<div class=\"callout callout-\(kind.lowercased())\"><div class=\"callout-title\">\(Self.calloutTitles[kind] ?? "")</div>\n"
        result += opening.isEmpty ? "\n" : "<p\(lines(of: first))>\(opening)</p>\n"
        result += rest + "</div>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        let language = codeBlock.language?.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        var code = codeBlock.code
        if code.hasSuffix("\n") { code.removeLast() }
        if language.lowercased() == "math" {
            result += MarkdownExtensions.html(for: .math(tex: code, display: true, source: code), block: true, attributes: lines(of: codeBlock)) + "\n"
            return
        }
        let langClass = language.isEmpty ? "" : " class=\"language-\(esc(language))\""
        let label = language.isEmpty ? "" : "<span class=\"lang\">\(esc(language))</span>"
        let isDiagram = MarkdownHTML.isDiagram(language)
        let block = "<div\(isDiagram ? "" : lines(of: codeBlock)) class=\"codeblock\">\(label)<button class=\"copy\" type=\"button\">Copy</button><pre><code\(langClass)>\(esc(code))</code></pre></div>"
        result += isDiagram ? "<div\(lines(of: codeBlock)) class=\"lexmd-diagram\">\(block)</div>\n" : block + "\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        result += html.rawHTML
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        result += "<hr\(lines(of: thematicBreak))>\n"
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) {
        let start = orderedList.startIndex != 1 ? " start=\"\(orderedList.startIndex)\"" : ""
        result += "<ol\(start)>\n\(capture(orderedList))</ol>\n"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
        let isTaskList = unorderedList.listItems.contains { $0.checkbox != nil }
        result += "<ul\(isTaskList ? " class=\"tasks\"" : "")>\n\(capture(unorderedList))</ul>\n"
    }

    mutating func visitListItem(_ listItem: ListItem) {
        if let checkbox = listItem.checkbox {
            let checked = checkbox == .checked
            result += "<li class=\"task\(checked ? " done" : "")\"><input type=\"checkbox\" disabled\(checked ? " checked" : "")>"
        } else {
            result += "<li>"
        }
        result += capture(listItem)
        result += "</li>\n"
    }

    mutating func visitTable(_ table: Table) {
        alignments = table.columnAlignments
        result += "<div class=\"table-wrap\"><table>\n\(capture(table))</table></div>\n"
    }

    mutating func visitTableHead(_ tableHead: Table.Head) {
        inTableHead = true
        column = 0
        result += "<thead><tr\(lines(of: tableHead))>\(capture(tableHead))</tr></thead>\n"
        inTableHead = false
    }

    mutating func visitTableBody(_ tableBody: Table.Body) {
        guard tableBody.childCount > 0 else { return }
        result += "<tbody>\n\(capture(tableBody))</tbody>\n"
    }

    mutating func visitTableRow(_ tableRow: Table.Row) {
        column = 0
        result += "<tr\(lines(of: tableRow))>\(capture(tableRow))</tr>\n"
    }

    mutating func visitTableCell(_ tableCell: Table.Cell) {
        let tag = inTableHead ? "th" : "td"
        var attributes = ""
        if column < alignments.count, let alignment = alignments[column] {
            switch alignment {
            case .left: attributes = " style=\"text-align:left\""
            case .center: attributes = " style=\"text-align:center\""
            case .right: attributes = " style=\"text-align:right\""
            }
        }
        if tableCell.colspan > 1 { attributes += " colspan=\"\(tableCell.colspan)\"" }
        column += 1
        result += "<\(tag)\(attributes)>\(capture(tableCell))</\(tag)>"
    }

    // MARK: Inlines

    mutating func visitText(_ text: Text) {
        if linkDepth == 0, links != nil {
            result += links!.html(forText: text.string, restore: extensions.restore)
            return
        }
        result += esc(text.string)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        result += "<em>\(capture(emphasis))</em>"
    }

    mutating func visitStrong(_ strong: Strong) {
        result += "<strong>\(capture(strong))</strong>"
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        result += "<del>\(capture(strikethrough))</del>"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        result += "<code>\(esc(inlineCode.code))</code>"
    }

    mutating func visitLink(_ link: Link) {
        let destination = link.destination.map { extensions.restore($0) }
        let href = destination.map { " href=\"\(esc($0))\"" } ?? ""
        let title = link.title.map { " title=\"\(esc(extensions.restore($0)))\"" } ?? ""
        var linkClass = ""
        if let destination { linkClass = links?.linkClass(forDestination: destination) ?? "" }
        linkDepth += 1
        result += "<a\(href)\(title)\(linkClass)>\(capture(link))</a>"
        linkDepth -= 1
    }

    mutating func visitImage(_ image: Image) {
        let src = image.source.map { " src=\"\(esc(extensions.restore($0)))\"" } ?? ""
        let title = image.title.map { " title=\"\(esc(extensions.restore($0)))\"" } ?? ""
        result += "<img\(src) alt=\"\(esc(extensions.restore(image.plainText)))\"\(title) loading=\"lazy\">"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        result += inlineHTML.rawHTML
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        result += "\n"
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        result += "<br>\n"
    }

    mutating func visitSymbolLink(_ symbolLink: SymbolLink) {
        result += "<code>\(esc(symbolLink.destination ?? ""))</code>"
    }
}
