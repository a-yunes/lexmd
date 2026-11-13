import AppKit
import LexMDRendering

/// Lightweight regex-based Markdown styling for the source editor.
@MainActor
enum MarkdownHighlighter {
    private struct FontKey: Hashable {
        var size: CGFloat
        var bold: Bool
        var italic: Bool
    }

    /// Fonts already made, since highlighting asks for one per heading and emphasis span.
    private static var fonts: [FontKey: NSFont] = [:]

    static func font(size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
        let key = FontKey(size: size, bold: bold, italic: italic)
        if let font = fonts[key] { return font }
        var font = NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
        if italic {
            let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
            font = NSFont(descriptor: descriptor, size: size) ?? font
        }
        fonts[key] = font
        return font
    }

    private static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.28
        return style
    }()

    static func baseAttributes(size: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: font(size: size), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraphStyle]
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static let codeColor = dynamic(
        light: NSColor(srgbRed: 0.42, green: 0.27, blue: 0.75, alpha: 1),
        dark: NSColor(srgbRed: 0.75, green: 0.66, blue: 1.0, alpha: 1)
    )
    static let markerColor = NSColor.tertiaryLabelColor
    static let accentColor = NSColor.controlAccentColor

    private static func re(_ pattern: String, _ options: NSRegularExpression.Options = [.anchorsMatchLines]) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// A fence closes on a run of the same character at least as long as the opening one,
    /// with nothing but spaces after it (CommonMark), as link updates and completion read it.
    private static let fence = re(#"^[ ]{0,3}((?<c>[`~])\k<c>{2,})[^\n]*\n?[\s\S]*?(?:^[ ]{0,3}\1\k<c>*[ \t\r]*$|\z)"#)
    private static let comment = re(#"<!--[\s\S]*?-->"#)
    private static let inlineCode = re(#"(`+)(?!`)([^\n]+?)(?<!`)\1(?!`)"#)
    private static let heading = re(#"^(#{1,6})([ \t]+[^\n]*|$)"#)
    private static let bold = re(#"(\*\*|__)(?=\S)([^\n]+?)(?<=\S)\1"#)
    private static let italic = re(#"(?<![\*_\w\\])([\*_])(?=[^\s\*_])([^\n]*?[^\s\\])\1(?![\*_\w])"#)
    private static let strike = re(#"~~(?=\S)([^\n]+?)(?<=\S)~~"#)
    private static let link = re(#"(!?\[)([^\]\n]*)(\]\()([^)\n]*)(\))"#)
    private static let reference = re(#"^[ ]{0,3}(\[[^\]\n]+\]:)[ \t]+(\S+)"#)
    private static let bareURL = re(#"<?\bhttps?://[^\s<>()\]]+>?"#)
    private static let quote = re(#"^[ \t]*(>[> \t]*)([^\n]*)$"#)
    private static let list = re(#"^[ \t]*([-*+]|\d+[.)])(?=[ \t])([ \t]+\[[ xX]\])?"#)
    private static let rule = re(#"^[ ]{0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
    private static let tablePipe = re(#"^[ \t]*\|.*$"#)
    private static let pipe = re(#"\|"#, [])

    /// Finds the multi-line constructs (front matter, fenced code, comments) over the whole text.
    static func blocks(in string: String) -> MarkdownBlocks {
        let ns = string as NSString
        let full = NSRange(location: 0, length: ns.length)
        var blocks = MarkdownBlocks()
        var covered = IndexSet()
        func add(_ r: NSRange, _ kind: MarkdownBlocks.Kind) {
            let head = ns.lineRange(for: NSRange(location: r.location, length: 0))
            let tail = ns.lineRange(for: NSRange(location: max(r.location, NSMaxRange(r) - 1), length: 0))
            var closed = false
            if kind == .fence, r.length > head.length {
                let line = ns.substring(with: tail).trimmingCharacters(in: .whitespacesAndNewlines)
                closed = line.hasPrefix("```") || line.hasPrefix("~~~")
            }
            blocks.items.append(.init(kind: kind, range: r, head: head, tail: tail, closed: closed))
            covered.insert(integersIn: r.location..<NSMaxRange(r))
        }
        func isCovered(_ r: NSRange) -> Bool {
            r.length > 0 && covered.intersects(integersIn: r.location..<NSMaxRange(r))
        }
        if let split = FrontMatter.split(string) {
            // Through the end of the closing line, without its line break.
            var end = split.length
            if end > 0, ns.character(at: end - 1) == 0x0A { end -= 1 }
            if end > 0, ns.character(at: end - 1) == 0x0D { end -= 1 }
            add(NSRange(location: 0, length: end), .frontMatter)
        }
        fence.enumerateMatches(in: string, range: full) { m, _, _ in
            if let r = m?.range, r.length > 0, !isCovered(r) { add(r, .fence) }
        }
        comment.enumerateMatches(in: string, range: full) { m, _, _ in
            if let r = m?.range, r.length > 0, !isCovered(r) { add(r, .comment) }
        }
        return blocks
    }

    /// Styles `limit` (or the whole text). Pass `blocks` from an earlier call, kept current with
    /// `MarkdownBlocks.shift`, to skip rescanning the whole text for multi-line constructs.
    @discardableResult
    static func highlight(
        _ storage: NSTextStorage, size: CGFloat, in limit: NSRange? = nil, blocks known: MarkdownBlocks? = nil
    ) -> MarkdownBlocks {
        let full = NSRange(location: 0, length: storage.length)
        let range = limit.map { NSIntersectionRange($0, full) } ?? full
        // Patterns run over just the restyled text. Searches never look outside their range,
        // so matching a copy of it finds the same matches, without copying the whole document.
        let string = range == full ? storage.string : storage.mutableString.substring(with: range)
        let blocks = known ?? Self.blocks(in: range == full ? string : storage.string)
        guard full.length > 0 else { return blocks }
        let offset = range.location
        let local = NSRange(location: 0, length: range.length)

        storage.beginEditing()
        defer { storage.endEditing() }
        storage.setAttributes(baseAttributes(size: size), range: range)

        var protected = IndexSet()
        func isProtected(_ r: NSRange) -> Bool {
            r.length > 0 && protected.intersects(integersIn: r.location..<NSMaxRange(r))
        }
        func color(_ r: NSRange, _ c: NSColor) {
            guard r.location != NSNotFound, r.length > 0 else { return }
            storage.addAttribute(.foregroundColor, value: c, range: r)
        }

        for block in blocks.items {
            protected.insert(integersIn: block.range.location..<NSMaxRange(block.range))
            let clipped = NSIntersectionRange(block.range, range)
            guard clipped.length > 0 else { continue }
            switch block.kind {
            case .frontMatter:
                color(clipped, .secondaryLabelColor)
            case .comment:
                color(clipped, markerColor)
            case .fence:
                color(clipped, codeColor)
                color(NSIntersectionRange(block.head, range), markerColor)
                if block.closed { color(NSIntersectionRange(block.tail, range), markerColor) }
            }
        }

        func each(_ regex: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
            regex.enumerateMatches(in: string, range: local) { m, _, _ in
                guard let m = m?.adjustingRanges(offset: offset), !isProtected(m.range) else { return }
                body(m)
            }
        }

        each(inlineCode) { m in
            color(m.range, codeColor)
            color(m.range(at: 1), markerColor)
            let closing = NSRange(location: NSMaxRange(m.range) - m.range(at: 1).length, length: m.range(at: 1).length)
            color(closing, markerColor)
            protected.insert(integersIn: m.range.location..<NSMaxRange(m.range))
        }

        each(heading) { m in
            let level = m.range(at: 1).length
            let scale: CGFloat = [1.5, 1.3, 1.15, 1.05, 1, 1][level - 1]
            storage.addAttribute(.font, value: font(size: (size * scale).rounded(), bold: true), range: m.range)
            color(m.range(at: 1), markerColor)
        }

        each(rule) { m in color(m.range, markerColor) }

        each(quote) { m in
            color(m.range(at: 2), .secondaryLabelColor)
            color(m.range(at: 1), accentColor)
        }

        each(list) { m in
            color(m.range(at: 1), accentColor)
            color(m.range(at: 2), accentColor)
        }

        each(tablePipe) { m in
            pipe.enumerateMatches(in: string, range: NSRange(location: m.range.location - offset, length: m.range.length)) { p, _, _ in
                if let p { color(NSRange(location: p.range.location + offset, length: p.range.length), markerColor) }
            }
        }

        func restyle(_ r: NSRange, bold: Bool? = nil, italic: Bool? = nil) {
            guard r.length > 0 else { return }
            storage.enumerateAttribute(.font, in: r) { value, sub, _ in
                let current = value as? NSFont ?? font(size: size)
                let traits = current.fontDescriptor.symbolicTraits
                let isBold = bold ?? traits.contains(.bold)
                let isItalic = italic ?? traits.contains(.italic)
                storage.addAttribute(.font, value: font(size: current.pointSize, bold: isBold, italic: isItalic), range: sub)
            }
        }

        each(bold) { m in
            restyle(m.range, bold: true)
            let marker = m.range(at: 1)
            color(marker, markerColor)
            color(NSRange(location: NSMaxRange(m.range) - marker.length, length: marker.length), markerColor)
        }

        each(italic) { m in
            restyle(m.range, italic: true)
            color(m.range(at: 1), markerColor)
            color(NSRange(location: NSMaxRange(m.range) - 1, length: 1), markerColor)
        }

        each(strike) { m in
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range)
            color(m.range, .secondaryLabelColor)
        }

        each(bareURL) { m in color(m.range, .linkColor) }

        each(link) { m in
            color(m.range(at: 1), markerColor)
            color(m.range(at: 2), .linkColor)
            color(m.range(at: 3), markerColor)
            color(m.range(at: 4), markerColor)
            color(m.range(at: 5), markerColor)
        }

        each(reference) { m in
            color(m.range(at: 1), .linkColor)
            color(m.range(at: 2), markerColor)
        }
        return blocks
    }
}

/// Front matter, fenced code, and comments in the editor text, with their opening and closing lines.
struct MarkdownBlocks {
    enum Kind { case frontMatter, fence, comment }

    struct Item {
        let kind: Kind
        var range: NSRange
        var head: NSRange
        var tail: NSRange
        let closed: Bool
    }

    var items: [Item] = []

    /// Lines whose edits can open, close, or move a block, so the whole text must be rescanned.
    private static let delimiters = ["```", "~~~", "<!--", "-->", "---"]

    static func linesHaveDelimiter(_ text: String) -> Bool {
        delimiters.contains { text.contains($0) }
    }

    /// Whether an edit of `old` (in pre-edit offsets) touches a block's opening or closing line.
    func touchesBoundary(_ old: NSRange) -> Bool {
        func touches(_ a: NSRange) -> Bool { old.location <= NSMaxRange(a) && a.location <= NSMaxRange(old) }
        return items.contains { touches($0.head) || touches($0.tail) }
    }

    /// Updates offsets after `old` was replaced by text `delta` characters longer.
    mutating func shift(replacing old: NSRange, delta: Int) {
        for i in items.indices {
            if items[i].range.location >= NSMaxRange(old) {
                items[i].range.location += delta
                items[i].head.location += delta
                items[i].tail.location += delta
            } else if NSMaxRange(items[i].range) > old.location {
                // The edit is inside the block, between its opening and closing lines.
                items[i].range.length += delta
                items[i].tail.location += delta
            }
        }
    }
}
