import Foundation
import LexMDRendering
import Markdown

/// A heading with the id the preview gives it.
struct HeadingInfo: Hashable, Sendable {
    var level: Int
    var title: String
    var slug: String
    /// 1-based line in the full source.
    var line: Int
    /// The heading's markup in the source (UTF-16).
    var range: NSRange
}

/// A link, image, or wiki link in a document.
struct LinkOccurrence: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case link, image, wiki }
    var kind: Kind
    /// The link destination as written, or the wiki link's target.
    var destination: String
    var wiki: WikiLink?
    /// 1-based line in the full source.
    var line: Int
    /// The link's markup in the source (UTF-16).
    var range: NSRange
}

/// Headings, links, and anchor ids of a Markdown document, from one parse.
struct DocumentStructure: Sendable {
    var headings: [HeadingInfo] = []
    var links: [LinkOccurrence] = []
    /// `id` and `name` attributes in raw HTML, which links may also target.
    var htmlIDs: Set<String> = []

    /// Every anchor a `#fragment` can point to in this document.
    var anchors: Set<String> { Set(headings.map(\.slug)).union(htmlIDs) }

    static func analyze(_ source: String) -> DocumentStructure {
        let split = FrontMatter.split(source)
        let (body, lineOffset, frontMatterLength) = (split?.rest ?? source, split?.lineCount ?? 0, split?.length ?? 0)
        let lines = SourceLines(source)
        var walker = StructureWalker(lines: lines, lineOffset: lineOffset)
        walker.visit(Document(parsing: body))
        var result = walker.structure

        // Math and footnote references render in place of their source (see MarkdownExtensions),
        // so headings and links inside them do not exist in the preview.
        let extensions = MarkdownExtensions(body)
        let replaced = utf16Ranges(extensions.itemRanges, in: body).map {
            NSRange(location: $0.location + frontMatterLength, length: $0.length)
        }
        if !replaced.isEmpty {
            result.headings.removeAll { heading in replaced.contains { contains($0, heading.range) } }
            result.links.removeAll { link in replaced.contains { overlapsPartly(link.range, $0) } }
        }
        assignSlugs(&result.headings, extensions: extensions)

        // Wiki links live in plain text, so code, raw HTML, and front matter are skipped, and so
        // is any link whose target is math or that math cuts through.
        var masked = walker.masked
        if frontMatterLength > 0 { masked.append(NSRange(location: 0, length: frontMatterLength)) }
        masked.sort { $0.location < $1.location }
        for link in WikiLink.scan(source) where !overlaps(link.range, masked) {
            guard !replaced.contains(where: { overlapsPartly(link.range, $0) || NSIntersectionRange($0, link.targetRange).length > 0 }) else { continue }
            result.links.append(LinkOccurrence(
                kind: .wiki, destination: link.target, wiki: link,
                line: lines.line(at: link.range.location), range: link.range
            ))
        }
        result.links.sort { $0.range.location < $1.range.location }
        return result
    }

    /// Heading ids as the preview assigns them: from the heading text with math as written.
    private static func assignSlugs(_ headings: inout [HeadingInfo], extensions: MarkdownExtensions) {
        if !extensions.items.isEmpty {
            var collector = HeadingTextCollector()
            collector.visit(Document(parsing: extensions.source))
            if collector.titles.count == headings.count {
                for index in headings.indices { headings[index].title = extensions.restore(collector.titles[index]) }
            }
        }
        var slugger = HeadingSlugger()
        for index in headings.indices { headings[index].slug = slugger.slug(for: headings[index].title) }
    }

    private static func contains(_ outer: NSRange, _ inner: NSRange) -> Bool {
        inner.location >= outer.location && NSMaxRange(inner) <= NSMaxRange(outer)
    }

    /// Overlapping without strictly holding the other: a link inside math or a footnote
    /// reference, or math that starts inside a link and ends after it. A link holding whole
    /// math (a math label) is fine.
    private static func overlapsPartly(_ range: NSRange, _ other: NSRange) -> Bool {
        NSIntersectionRange(range, other).length > 0 && !(contains(range, other) && range != other)
    }

    /// Converts sorted UTF-8 byte ranges of `text` to UTF-16 ranges in one pass.
    private static func utf16Ranges(_ ranges: [Range<Int>], in text: String) -> [NSRange] {
        guard !ranges.isEmpty else { return [] }
        let targets = Set(ranges.flatMap { [$0.lowerBound, $0.upperBound] }).sorted()
        var map: [Int: Int] = [:]
        var next = 0, utf8 = 0, utf16 = 0
        for scalar in text.unicodeScalars {
            while next < targets.count, targets[next] <= utf8 { map[targets[next]] = utf16; next += 1 }
            guard next < targets.count else { break }
            utf8 += UTF8.width(scalar)
            utf16 += UTF16.width(scalar)
        }
        while next < targets.count { map[targets[next]] = utf16; next += 1 }
        return ranges.compactMap { range in
            guard let lower = map[range.lowerBound], let upper = map[range.upperBound] else { return nil }
            return NSRange(location: lower, length: upper - lower)
        }
    }

    private static func overlaps(_ range: NSRange, _ sorted: [NSRange]) -> Bool {
        for mask in sorted {
            if mask.location >= NSMaxRange(range) { break }
            if NSIntersectionRange(mask, range).length > 0 { return true }
        }
        return false
    }
}

/// Converts swift-markdown source locations (1-based lines, UTF-8 columns) to UTF-16 offsets.
struct SourceLines {
    private let text: NSString
    /// UTF-16 offset where each line starts.
    private(set) var starts: [Int] = [0]

    init(_ source: String) {
        text = source as NSString
        var offset = 0
        for unit in source.utf16 {
            offset += 1
            if unit == 0x0A { starts.append(offset) }
        }
    }

    /// The 1-based line containing a UTF-16 offset.
    func line(at offset: Int) -> Int {
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    /// The UTF-16 range of a 1-based line, without its line break.
    func range(ofLine line: Int) -> NSRange {
        guard line >= 1, line <= starts.count else { return NSRange(location: text.length, length: 0) }
        let start = starts[line - 1]
        var end = line < starts.count ? starts[line] - 1 : text.length
        if end > start, text.character(at: end - 1) == 0x0D { end -= 1 }
        return NSRange(location: start, length: max(0, end - start))
    }

    func string(ofLine line: Int) -> String {
        text.substring(with: range(ofLine: line))
    }

    /// The UTF-16 offset of a source location in the full text.
    func offset(line: Int, column: Int) -> Int {
        guard line >= 1, line <= starts.count else { return text.length }
        let lineRange = range(ofLine: line)
        let bytes = Array(text.substring(with: lineRange).utf8)
        let prefix = bytes.prefix(max(0, column - 1))
        return lineRange.location + String(decoding: prefix, as: UTF8.self).utf16.count
    }
}

/// Heading texts in document order.
private struct HeadingTextCollector: MarkupWalker {
    var titles: [String] = []

    mutating func visitHeading(_ heading: Heading) {
        titles.append(heading.plainText)
    }
}

private struct StructureWalker: MarkupWalker {
    let lines: SourceLines
    let lineOffset: Int
    var structure = DocumentStructure()
    var masked: [NSRange] = []

    init(lines: SourceLines, lineOffset: Int) {
        self.lines = lines
        self.lineOffset = lineOffset
    }

    private static let idPattern = try! NSRegularExpression(pattern: #"\b(?:id|name)\s*=\s*["']([^"']+)["']"#, options: [.caseInsensitive])

    private func nsRange(_ markup: Markup) -> NSRange? {
        guard let range = markup.range else { return nil }
        let start = lines.offset(line: range.lowerBound.line + lineOffset, column: range.lowerBound.column)
        let end = lines.offset(line: range.upperBound.line + lineOffset, column: range.upperBound.column)
        return NSRange(location: start, length: max(0, end - start))
    }

    private func line(_ markup: Markup) -> Int {
        (markup.range?.lowerBound.line ?? 1) + lineOffset
    }

    mutating func visitHeading(_ heading: Heading) {
        let title = heading.plainText
        structure.headings.append(HeadingInfo(
            level: heading.level, title: title, slug: "",
            line: line(heading), range: nsRange(heading) ?? NSRange(location: 0, length: 0)
        ))
        descendInto(heading)
    }

    mutating func visitLink(_ link: Link) {
        if let destination = link.destination, let range = nsRange(link) {
            structure.links.append(LinkOccurrence(kind: .link, destination: destination, line: line(link), range: range))
        }
        descendInto(link)
    }

    mutating func visitImage(_ image: Image) {
        if let source = image.source, let range = nsRange(image) {
            structure.links.append(LinkOccurrence(kind: .image, destination: source, line: line(image), range: range))
        }
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        if let range = nsRange(inlineCode) { masked.append(range) }
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        if let range = nsRange(codeBlock) { masked.append(range) }
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        if let range = nsRange(html) { masked.append(range) }
        collectIDs(html.rawHTML)
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        if let range = nsRange(inlineHTML) { masked.append(range) }
        collectIDs(inlineHTML.rawHTML)
    }

    private mutating func collectIDs(_ html: String) {
        let ns = html as NSString
        for match in Self.idPattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            structure.htmlIDs.insert(ns.substring(with: match.range(at: 1)))
        }
    }
}
