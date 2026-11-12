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
        var body = source
        var prefix = ""
        if let (frontMatter, rest) = splitFrontMatter(source) {
            prefix = FrontMatter.html(frontMatter) ?? "<pre class=\"frontmatter\"><code>\(escape(frontMatter))</code></pre>\n"
            body = rest
        }
        return prefix + renderBody(body, footnotes: true, links: links)
    }

    /// Renders Markdown with math, diagrams, and optionally footnotes (see `MarkdownExtensions`).
    /// Footnote bodies get the same link context, so their wiki links and broken links render too.
    package static func renderBody(_ source: String, footnotes: Bool, links: (any MarkdownLinkRendering)? = nil) -> String {
        let extensions = MarkdownExtensions(source, footnotes: footnotes)
        let document = extensions.document ?? Document(parsing: extensions.source)
        var renderer = HTMLRenderer()
        renderer.extensions = extensions
        renderer.links = links
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

    /// The YAML between an opening `---` line and the next `---` line, and the text after it.
    /// Lines end at line feeds only, so a CRLF line keeps its carriage return. Only the lines up
    /// to the closing one are examined.
    private static func splitFrontMatter(_ source: String) -> (String, String)? {
        guard source.hasPrefix("---\n") || source.hasPrefix("---\r\n") else { return nil }
        let utf8 = source.utf8
        let scalars = source.unicodeScalars
        guard let firstBreak = utf8.firstIndex(of: 0x0A) else { return nil }
        let frontStart = utf8.index(after: firstBreak)
        var start = frontStart
        while true {
            let end = utf8[start...].firstIndex(of: 0x0A) ?? utf8.endIndex
            if utf8[start..<end].contains(0x2D),
               String(scalars[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
                // A document of just two lines has no front matter.
                if start == frontStart, end == utf8.endIndex { return nil }
                let front = start == frontStart ? "" : String(scalars[frontStart..<utf8.index(before: start)])
                let rest = end == utf8.endIndex ? "" : String(scalars[utf8.index(after: end)...])
                return (front, rest)
            }
            guard end < utf8.endIndex else { return nil }
            start = utf8.index(after: end)
        }
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

    private func esc(_ s: String) -> String { MarkdownHTML.escape(s) }

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
        result += "<h\(heading.level) id=\"\(esc(id))\">\(inner)</h\(heading.level)>\n"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        result += "<p>\(capture(paragraph))</p>\n"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        let inner = capture(blockQuote)
        let kinds = ["NOTE": "Note", "TIP": "Tip", "IMPORTANT": "Important", "WARNING": "Warning", "CAUTION": "Caution"]
        if inner.hasPrefix("<p>[!"), let close = inner.firstIndex(of: "]") {
            let start = inner.index(inner.startIndex, offsetBy: 5)
            let kind = String(inner[start..<close]).uppercased()
            if let title = kinds[kind] {
                var rest = String(inner[inner.index(after: close)...])
                while rest.first == "\n" || rest.first == " " { rest.removeFirst() }
                if rest.hasPrefix("</p>") { rest = String(rest.dropFirst(4)) } else { rest = "<p>" + rest }
                result += "<div class=\"callout callout-\(kind.lowercased())\"><div class=\"callout-title\">\(title)</div>\n\(rest)</div>\n"
                return
            }
        }
        result += "<blockquote>\n\(inner)</blockquote>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        let language = codeBlock.language?.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        var code = codeBlock.code
        if code.hasSuffix("\n") { code.removeLast() }
        if language.lowercased() == "math" {
            result += MarkdownExtensions.html(for: .math(tex: code, display: true, source: code), block: true) + "\n"
            return
        }
        let langClass = language.isEmpty ? "" : " class=\"language-\(esc(language))\""
        let label = language.isEmpty ? "" : "<span class=\"lang\">\(esc(language))</span>"
        let block = "<div class=\"codeblock\">\(label)<button class=\"copy\" type=\"button\">Copy</button><pre><code\(langClass)>\(esc(code))</code></pre></div>"
        result += MarkdownHTML.isDiagram(language) ? "<div class=\"lexmd-diagram\">\(block)</div>\n" : block + "\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        result += html.rawHTML
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        result += "<hr>\n"
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
        result += "<thead><tr>\(capture(tableHead))</tr></thead>\n"
        inTableHead = false
    }

    mutating func visitTableBody(_ tableBody: Table.Body) {
        guard tableBody.childCount > 0 else { return }
        result += "<tbody>\n\(capture(tableBody))</tbody>\n"
    }

    mutating func visitTableRow(_ tableRow: Table.Row) {
        column = 0
        result += "<tr>\(capture(tableRow))</tr>\n"
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
