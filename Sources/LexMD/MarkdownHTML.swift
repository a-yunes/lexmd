import Foundation
import Markdown

enum MarkdownHTML {
    static func render(_ source: String) -> String {
        var body = source
        var prefix = ""
        if let (frontMatter, rest) = splitFrontMatter(source) {
            prefix = "<pre class=\"frontmatter\"><code>\(escape(frontMatter))</code></pre>\n"
            body = rest
        }
        let document = Document(parsing: body)
        var renderer = HTMLRenderer()
        renderer.visit(document)
        return prefix + renderer.result
    }

    static func wordCount(_ source: String) -> Int {
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

    private static func splitFrontMatter(_ source: String) -> (String, String)? {
        guard source.hasPrefix("---\n") || source.hasPrefix("---\r\n") else { return nil }
        let lines = source.components(separatedBy: "\n")
        guard lines.count > 2 else { return nil }
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
            let front = lines[1..<i].joined(separator: "\n")
            let rest = lines[(i + 1)...].joined(separator: "\n")
            return (front, rest)
        }
        return nil
    }

    static func escape(_ s: String) -> String {
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
    private var slugCounts: [String: Int] = [:]
    private var inTableHead = false
    private var alignments: [Table.ColumnAlignment?] = []
    private var column = 0

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
        let id = slug(for: heading.plainText)
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
        let langClass = language.isEmpty ? "" : " class=\"language-\(esc(language))\""
        let label = language.isEmpty ? "" : "<span class=\"lang\">\(esc(language))</span>"
        result += "<div class=\"codeblock\">\(label)<button class=\"copy\" type=\"button\">Copy</button><pre><code\(langClass)>\(esc(code))</code></pre></div>\n"
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
        let href = link.destination.map { " href=\"\(esc($0))\"" } ?? ""
        let title = link.title.map { " title=\"\(esc($0))\"" } ?? ""
        result += "<a\(href)\(title)>\(capture(link))</a>"
    }

    mutating func visitImage(_ image: Image) {
        let src = image.source.map { " src=\"\(esc($0))\"" } ?? ""
        let title = image.title.map { " title=\"\(esc($0))\"" } ?? ""
        result += "<img\(src) alt=\"\(esc(image.plainText))\"\(title) loading=\"lazy\">"
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
