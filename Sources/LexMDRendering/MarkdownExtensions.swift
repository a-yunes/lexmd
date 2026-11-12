import Foundation
import Markdown

/// Math and footnote syntax that cmark does not parse. Before parsing, each `$math$`,
/// `$$display$$`, and `[^ref]` outside code and raw HTML is swapped for a private-use token;
/// footnote definitions are lifted out. After rendering, tokens become HTML.
///
/// Math follows pandoc: an opening `$` is not followed by whitespace, a closing `$` is not
/// preceded by whitespace or followed by a digit, `\$` is a literal dollar, and math never spans
/// a blank line. Code spans and blocks take precedence over math.
package struct MarkdownExtensions {
    package enum Item: Equatable {
        case math(tex: String, display: Bool, source: String)
        case footnoteRef(number: Int, occurrence: Int, source: String)

        package var source: String {
            switch self {
            case .math(_, _, let source), .footnoteRef(_, _, let source): return source
            }
        }
    }

    package struct Footnote: Equatable {
        var label: String
        var body: String
        var references = 0
    }

    /// The source with tokens in place of extension syntax.
    package private(set) var source: String
    package private(set) var items: [Item] = []
    /// The UTF-8 byte range in the original source that each item replaced.
    package private(set) var itemRanges: [Range<Int>] = []
    /// Referenced footnotes in numbering order.
    package private(set) var footnotes: [Footnote] = []
    /// The parse of `source` when scanning parsed it and replaced nothing, so it need not be parsed again.
    package private(set) var document: Document?

    package static let tokenStart: Unicode.Scalar = "\u{E000}"
    package static let tokenEnd: Unicode.Scalar = "\u{E001}"

    package init(_ source: String, footnotes allowFootnotes: Bool = true) {
        self.source = source
        let mayHaveMath = source.utf8.contains(0x24)
        let mayHaveFootnotes = allowFootnotes && Self.containsFootnoteMarker(source.utf8)
        guard mayHaveMath || mayHaveFootnotes else { return }

        let bytes = Array(source.utf8)
        let lineStarts = Self.lineStarts(bytes)
        let parsed = Document(parsing: source)
        var skip = Self.protectedRanges(parsed, bytes: bytes, lineStarts: lineStarts)
        var definitions: [String: Footnote] = [:]
        var blanked: [Range<Int>] = []
        if mayHaveFootnotes {
            (definitions, blanked) = Self.footnoteDefinitions(bytes, lineStarts: lineStarts, protected: skip)
            skip = Self.merge(skip + blanked)
        }

        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var numbers: [String: Int] = [:]
        var i = 0
        var next = 0 // index into skip
        func emitToken(_ item: Item, _ range: Range<Int>) {
            out.append(contentsOf: Array("\(Self.tokenStart)\(items.count)\(Self.tokenEnd)".utf8))
            items.append(item)
            itemRanges.append(range)
        }
        while i < bytes.count {
            while next < skip.count, skip[next].upperBound <= i { next += 1 }
            let barrier = next < skip.count ? skip[next].lowerBound : bytes.count
            if next < skip.count, skip[next].contains(i) {
                let range = skip[next]
                if blanked.contains(where: { $0.overlaps(range) }) {
                    // Keep line breaks so neighboring blocks stay apart.
                    out.append(contentsOf: bytes[range].filter { $0 == 0x0A })
                } else {
                    out.append(contentsOf: bytes[range])
                }
                i = range.upperBound
                continue
            }
            let byte = bytes[i]
            if byte == 0x5C, i + 1 < barrier { // backslash escape
                out.append(byte)
                out.append(bytes[i + 1])
                i += 2
                continue
            }
            if byte == 0x24, mayHaveMath, let (end, item) = Self.math(bytes, at: i, limit: barrier) {
                emitToken(item, i..<end)
                i = end
                continue
            }
            if byte == 0x5B, i + 1 < barrier, bytes[i + 1] == 0x5E,
               let (end, label) = Self.footnoteLabel(bytes, at: i, limit: barrier),
               definitions[label] != nil {
                let number: Int
                if let existing = numbers[label] {
                    number = existing
                } else {
                    number = footnotes.count + 1
                    numbers[label] = number
                    footnotes.append(definitions[label]!)
                }
                footnotes[number - 1].references += 1
                let raw = String(decoding: bytes[i..<end], as: UTF8.self)
                emitToken(.footnoteRef(number: number, occurrence: footnotes[number - 1].references, source: raw), i..<end)
                i = end
                continue
            }
            out.append(byte)
            i += 1
        }
        if !items.isEmpty || !blanked.isEmpty {
            self.source = String(decoding: out, as: UTF8.self)
        } else {
            document = parsed
        }
    }

    /// Whether the text holds `[^`.
    private static func containsFootnoteMarker(_ utf8: String.UTF8View) -> Bool {
        var previous: UInt8 = 0
        for byte in utf8 {
            if byte == 0x5E, previous == 0x5B { return true }
            previous = byte
        }
        return false
    }

    // MARK: Tokens

    /// Calls `body` for each token in `text`, with the token's range and item.
    package func forEachToken(in text: String, _ body: (Range<String.Index>, Item) -> Void) {
        guard !items.isEmpty else { return }
        var index = text.startIndex
        while let start = text[index...].firstIndex(where: { $0.unicodeScalars.first == Self.tokenStart }) {
            let digitsStart = text.index(after: start)
            guard let end = text[digitsStart...].firstIndex(where: { $0.unicodeScalars.first == Self.tokenEnd }) else { return }
            index = text.index(after: end)
            if let n = Int(text[digitsStart..<end]), items.indices.contains(n) {
                body(start..<index, items[n])
            }
        }
    }

    /// Whether text holds a placeholder.
    package static func containsToken(_ text: String) -> Bool {
        text.unicodeScalars.contains(tokenStart)
    }

    /// Puts the original syntax back, for attributes, slugs, and other plain-text contexts.
    package func restore(_ text: String) -> String {
        guard !items.isEmpty, text.unicodeScalars.contains(Self.tokenStart) else { return text }
        var out = ""
        var last = text.startIndex
        forEachToken(in: text) { range, item in
            out += text[last..<range.lowerBound]
            out += item.source
            last = range.upperBound
        }
        return out + text[last...]
    }

    /// Replaces tokens in rendered HTML. A paragraph holding only display math becomes a block.
    package func finish(_ html: String) -> String {
        guard !items.isEmpty, html.unicodeScalars.contains(Self.tokenStart) else { return html }
        var out = ""
        out.reserveCapacity(html.utf8.count)
        var last = html.startIndex
        forEachToken(in: html) { range, item in
            var lower = range.lowerBound
            var upper = range.upperBound
            var block = false
            if case .math(_, true, _) = item,
               html[last..<lower].hasSuffix("<p>"), html[upper...].hasPrefix("</p>") {
                lower = html.index(lower, offsetBy: -3)
                upper = html.index(upper, offsetBy: 4)
                block = true
            }
            out += html[last..<lower]
            out += Self.html(for: item, block: block)
            last = upper
        }
        return out + html[last...]
    }

    package static func html(for item: Item, block: Bool = false) -> String {
        let esc = MarkdownHTML.escape
        switch item {
        case let .math(tex, display, source):
            if display {
                let tag = block ? "div" : "span"
                return "<\(tag) class=\"lexmd-math lexmd-display\" data-tex=\"\(esc(tex))\">\(esc(source))</\(tag)>"
            }
            return "<span class=\"lexmd-math\" data-tex=\"\(esc(tex))\">\(esc(source))</span>"
        case let .footnoteRef(number, occurrence, _):
            let id = occurrence == 1 ? "fnref-\(number)" : "fnref-\(number)-\(occurrence)"
            return "<sup class=\"footnote-ref\"><a href=\"#fn-\(number)\" id=\"\(id)\" aria-label=\"Footnote \(number)\">\(number)</a></sup>"
        }
    }

    /// The footnotes section, given each footnote's rendered body.
    package func footnotesHTML(_ renderBody: (String) -> String) -> String {
        guard !footnotes.isEmpty else { return "" }
        var html = "<section class=\"footnotes\">\n<ol>\n"
        for (index, note) in footnotes.enumerated() {
            let number = index + 1
            var backs = ""
            for occurrence in 1...max(note.references, 1) {
                let id = occurrence == 1 ? "fnref-\(number)" : "fnref-\(number)-\(occurrence)"
                let mark = occurrence == 1 ? "↩\u{FE0E}" : "↩\u{FE0E}<sup>\(occurrence)</sup>"
                backs += " <a href=\"#\(id)\" class=\"footnote-back\" aria-label=\"Back to reference \(number)\">\(mark)</a>"
            }
            var body = renderBody(note.body).trimmingCharacters(in: .whitespacesAndNewlines)
            if body.hasSuffix("</p>") {
                body.insert(contentsOf: backs, at: body.index(body.endIndex, offsetBy: -4))
            } else {
                body += "\n<p>\(backs.dropFirst())</p>"
            }
            html += "<li id=\"fn-\(number)\">\n\(body)\n</li>\n"
        }
        return html + "</ol>\n</section>\n"
    }

    // MARK: Scanning

    private static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }
    private static func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }

    /// True when a line break at `i` is followed by a blank line.
    private static func blankLineFollows(_ bytes: [UInt8], _ i: Int, limit: Int) -> Bool {
        var j = i + 1
        while j < limit, bytes[j] == 0x20 || bytes[j] == 0x09 || bytes[j] == 0x0D { j += 1 }
        return j >= limit || bytes[j] == 0x0A
    }

    /// Math starting at the `$` at `start`, ending before `limit`.
    package static func math(_ bytes: [UInt8], at start: Int, limit: Int) -> (Int, Item)? {
        let display = start + 1 < limit && bytes[start + 1] == 0x24
        var j = start + (display ? 2 : 1)
        let contentStart = j
        if !display {
            guard j < limit, !isSpace(bytes[j]) else { return nil }
        }
        while j < limit {
            let b = bytes[j]
            if b == 0x5C { j += 2; continue }
            if b == 0x0A, blankLineFollows(bytes, j, limit: limit) { return nil }
            if b == 0x24 {
                if display {
                    if j + 1 < limit, bytes[j + 1] == 0x24 {
                        let tex = String(decoding: bytes[contentStart..<j], as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !tex.isEmpty else { return nil }
                        let source = String(decoding: bytes[start..<(j + 2)], as: UTF8.self)
                        return (j + 2, .math(tex: tex, display: true, source: source))
                    }
                    return nil // a lone `$` inside display math ends nothing
                }
                // The first unescaped `$` closes inline math or nothing.
                guard !isSpace(bytes[j - 1]), !(j + 1 < limit && isDigit(bytes[j + 1])) else { return nil }
                let tex = String(decoding: bytes[contentStart..<j], as: UTF8.self)
                let source = String(decoding: bytes[start...j], as: UTF8.self)
                return (j + 1, .math(tex: tex, display: false, source: source))
            }
            j += 1
        }
        return nil
    }

    /// A `[^label]` reference at `start`, with the label normalized for lookup.
    private static func footnoteLabel(_ bytes: [UInt8], at start: Int, limit: Int) -> (Int, String)? {
        var j = start + 2
        while j < limit, j - start < 200 {
            let b = bytes[j]
            if b == 0x5D {
                guard j > start + 2 else { return nil }
                if j + 1 < limit, bytes[j + 1] == 0x3A { return nil } // a definition, not a reference
                return (j + 1, normalize(String(decoding: bytes[(start + 2)..<j], as: UTF8.self)))
            }
            if isSpace(b) || b == 0x5B || b == 0x5C { return nil }
            j += 1
        }
        return nil
    }

    private static func normalize(_ label: String) -> String { label.lowercased() }

    /// Byte offsets where each line starts.
    private static func lineStarts(_ bytes: [UInt8]) -> [Int] {
        var starts = [0]
        for (i, b) in bytes.enumerated() where b == 0x0A { starts.append(i + 1) }
        return starts
    }

    /// Byte ranges of code and raw HTML, where extension syntax is left alone.
    private static func protectedRanges(_ document: Document, bytes: [UInt8], lineStarts: [Int]) -> [Range<Int>] {
        var collector = ProtectedRangeCollector()
        collector.visit(document)
        func offset(_ location: SourceLocation) -> Int {
            let line = min(max(location.line, 1), lineStarts.count)
            return min(lineStarts[line - 1] + max(location.column - 1, 0), bytes.count)
        }
        var ranges: [Range<Int>] = []
        for (range, isBlock) in collector.ranges {
            var lower = offset(range.lowerBound)
            var upper = max(offset(range.upperBound), lower)
            if isBlock {
                // Blocks cover whole lines, including any container prefix.
                while lower > 0, bytes[lower - 1] != 0x0A { lower -= 1 }
                while upper < bytes.count, bytes[upper] != 0x0A { upper += 1 }
            }
            if upper > lower { ranges.append(lower..<upper) }
        }
        return merge(ranges)
    }

    private static func merge(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var merged: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Finds GitHub-style footnote definitions: `[^label]: text` at the start of a line (up to
    /// three spaces in), after a blank line, a heading, or another definition. Indented lines and
    /// lazy continuation lines belong to the definition. Returns the definitions and their ranges.
    private static func footnoteDefinitions(_ bytes: [UInt8], lineStarts: [Int], protected: [Range<Int>])
        -> ([String: Footnote], [Range<Int>]) {
        func lineEnd(_ start: Int) -> Int {
            var j = start
            while j < bytes.count, bytes[j] != 0x0A { j += 1 }
            return j
        }
        func text(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
        func isBlank(_ start: Int, _ end: Int) -> Bool { bytes[start..<end].allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D } }
        func indent(_ start: Int, _ end: Int) -> Int {
            var width = 0
            for b in bytes[start..<end] {
                if b == 0x20 { width += 1 } else if b == 0x09 { width += 4 - width % 4 } else { break }
            }
            return width
        }
        func isProtected(_ offset: Int) -> Bool {
            var low = 0, high = protected.count
            while low < high {
                let mid = (low + high) / 2
                if protected[mid].upperBound <= offset { low = mid + 1 } else { high = mid }
            }
            return low < protected.count && protected[low].contains(offset)
        }

        /// The label and where the text starts if the line opens a definition.
        func opening(_ start: Int, _ end: Int) -> (String, Int)? {
            var j = start
            while j < end, j - start < 3, bytes[j] == 0x20 { j += 1 }
            guard j + 2 < end, bytes[j] == 0x5B, bytes[j + 1] == 0x5E else { return nil }
            let labelStart = j + 2
            var k = labelStart
            while k < end, bytes[k] != 0x5D {
                if isSpace(bytes[k]) || bytes[k] == 0x5B { return nil }
                k += 1
            }
            guard k < end, k > labelStart, k + 1 < end, bytes[k + 1] == 0x3A else { return nil }
            var textStart = k + 2
            while textStart < end, bytes[textStart] == 0x20 || bytes[textStart] == 0x09 { textStart += 1 }
            return (normalize(text(labelStart..<k)), textStart)
        }

        var definitions: [String: Footnote] = [:]
        var ranges: [Range<Int>] = []
        var line = 0
        var previousAllows = true // start of document
        while line < lineStarts.count {
            let start = lineStarts[line]
            let end = lineEnd(start)
            guard !isProtected(start), let (label, textStart) = opening(start, end) else {
                let blank = start >= end || isBlank(start, end)
                let trimmed = bytes[start..<end].drop(while: { $0 == 0x20 })
                previousAllows = blank || (trimmed.first == 0x23 && !isProtected(start))
                line += 1
                continue
            }
            guard previousAllows else { line += 1; continue }
            var body = [text(textStart..<end)]
            var last = end
            var next = line + 1
            var pendingBlank: [String] = []
            while next < lineStarts.count {
                let s = lineStarts[next]
                let e = lineEnd(s)
                if s >= bytes.count { break }
                if isBlank(s, e) {
                    pendingBlank.append("")
                    next += 1
                    continue
                }
                let width = indent(s, e)
                if width >= 4 {
                    // Indented continuation, possibly after blank lines.
                    var k = s
                    var removed = 0
                    while k < e, removed < 4 {
                        if bytes[k] == 0x09 { removed = 4 } else { removed += 1 }
                        k += 1
                    }
                    body += pendingBlank
                    body.append(text(k..<e))
                } else if pendingBlank.isEmpty, opening(s, e) == nil {
                    body.append(text(s..<e)) // lazy continuation of the first paragraph
                } else {
                    break
                }
                pendingBlank = []
                last = e
                next += 1
            }
            if definitions[label] == nil {
                definitions[label] = Footnote(label: label, body: body.joined(separator: "\n"))
            }
            ranges.append(start..<last)
            previousAllows = true
            line = next - pendingBlank.count
        }
        return (definitions, ranges)
    }
}

/// Collects source ranges of code and raw HTML. The flag marks block-level nodes.
private struct ProtectedRangeCollector: MarkupWalker {
    var ranges: [(SourceRange, Bool)] = []

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        if let range = codeBlock.range { ranges.append((range, true)) }
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        if let range = html.range { ranges.append((range, true)) }
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        if let range = inlineCode.range { ranges.append((range, false)) }
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        if let range = inlineHTML.range { ranges.append((range, false)) }
    }
}

/// Simple YAML front matter (scalar values and flat lists) shown as a properties table.
package enum FrontMatter {
    package enum Value: Equatable {
        case scalar(String)
        case list([String])
    }

    /// The key-value pairs, or nil when the YAML uses anything beyond scalars and flat lists.
    package static func properties(_ yaml: String) -> [(key: String, value: Value)]? {
        var result: [(key: String, value: Value)] = []
        var listKey: String?
        var listItems: [String] = []
        func closeList() {
            if let key = listKey { result.append((key, listItems.isEmpty ? .scalar("") : .list(listItems))) }
            listKey = nil
            listItems = []
        }
        for rawLine in yaml.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("- ") || trimmed == "-" {
                guard listKey != nil, let item = scalar(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)),
                      !looksLikeMapping(item.raw) else { return nil }
                listItems.append(item.value)
                continue
            }
            guard line.first.map({ !$0.isWhitespace }) == true, let colon = keyEnd(line) else { return nil }
            closeList()
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let rest = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty || rest.hasPrefix("#") {
                listKey = key
            } else if rest.hasPrefix("[") {
                guard let items = flowList(rest) else { return nil }
                result.append((key, .list(items)))
            } else {
                guard let value = scalar(rest) else { return nil }
                result.append((key, .scalar(value.value)))
            }
        }
        closeList()
        return result.isEmpty ? nil : result
    }

    package static func html(_ yaml: String) -> String? {
        guard let properties = properties(yaml) else { return nil }
        let esc = MarkdownHTML.escape
        var rows = ""
        for (key, value) in properties {
            let cell: String
            switch value {
            case .scalar(let text): cell = esc(text)
            case .list(let items): cell = items.map { "<span class=\"tag\">\(esc($0))</span>" }.joined(separator: " ")
            }
            rows += "<tr><th scope=\"row\">\(esc(key))</th><td>\(cell)</td></tr>\n"
        }
        return "<div class=\"properties\"><table>\n<tbody>\n\(rows)</tbody>\n</table></div>\n"
    }

    /// The colon after a plain key like `title` or `published date`.
    private static func keyEnd(_ line: String) -> String.Index? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon]
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || " _-.".contains($0) }) else { return nil }
        let after = line.index(after: colon)
        guard after == line.endIndex || line[after] == " " || line[after] == "\t" else { return nil }
        return colon
    }

    private static func looksLikeMapping(_ raw: String) -> Bool {
        guard !raw.hasPrefix("\""), !raw.hasPrefix("'") else { return false }
        return keyEnd(raw) != nil
    }

    /// A plain or quoted scalar. Block scalars, anchors, tags, and nested flows are not simple.
    private static func scalar(_ raw: String) -> (value: String, raw: String)? {
        guard let first = raw.first else { return ("", raw) }
        if "|>&*!{[%@`".contains(first) { return nil }
        if first == "\"" || first == "'" {
            guard raw.count >= 2, raw.last == first else { return nil }
            var inner = String(raw.dropFirst().dropLast())
            if first == "'" {
                inner = inner.replacingOccurrences(of: "''", with: "'")
            } else {
                guard !inner.contains("\\") || inner.range(of: #"\\[^"\\]"#, options: .regularExpression) == nil else { return nil }
                inner = inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            }
            return (inner, raw)
        }
        var value = raw
        if let comment = value.range(of: " #") { value = String(value[..<comment.lowerBound]) }
        value = value.trimmingCharacters(in: .whitespaces)
        if value.contains(": ") { return nil }
        return (value, raw)
    }

    /// A one-line `[a, b, "c"]` list of scalars.
    private static func flowList(_ raw: String) -> [String]? {
        guard raw.hasSuffix("]") else { return nil }
        let inner = raw.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        if inner.isEmpty { return [] }
        if inner.contains("[") || inner.contains("{") { return nil }
        var items: [String] = []
        for part in inner.split(separator: ",", omittingEmptySubsequences: false) {
            let piece = part.trimmingCharacters(in: .whitespaces)
            guard let item = scalar(piece), !piece.isEmpty else { return nil }
            items.append(item.value)
        }
        return items
    }
}
