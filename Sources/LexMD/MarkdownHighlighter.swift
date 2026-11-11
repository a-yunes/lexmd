import AppKit

/// Lightweight regex-based Markdown styling for the source editor.
@MainActor
enum MarkdownHighlighter {
    static func font(size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
        var font = NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
        if italic {
            let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
            font = NSFont(descriptor: descriptor, size: size) ?? font
        }
        return font
    }

    static func paragraphStyle(size: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.28
        return style
    }

    static func baseAttributes(size: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: font(size: size), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraphStyle(size: size)]
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

    private static let frontMatter = re(#"\A---[ \t]*\n[\s\S]*?\n---[ \t]*$"#)
    private static let fence = re(#"^[ ]{0,3}(`{3,}|~{3,})[^\n]*\n?[\s\S]*?(?:^[ ]{0,3}\1[ \t]*$|\z)"#)
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

    static func highlight(_ storage: NSTextStorage, size: CGFloat, in limit: NSRange? = nil) {
        let string = storage.string
        let full = NSRange(location: 0, length: storage.length)
        let range = limit ?? full
        guard full.length > 0 else { return }

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

        // Block-level ranges are found over the whole text so partial highlights stay correct.
        frontMatter.enumerateMatches(in: string, range: full) { m, _, _ in
            guard let r = m?.range, NSIntersectionRange(r, range).length > 0 else { return }
            let clipped = NSIntersectionRange(r, range)
            color(clipped, .secondaryLabelColor)
            protected.insert(integersIn: r.location..<NSMaxRange(r))
        }
        fence.enumerateMatches(in: string, range: full) { m, _, _ in
            guard let r = m?.range, !isProtected(r) else { return }
            protected.insert(integersIn: r.location..<NSMaxRange(r))
            let clipped = NSIntersectionRange(r, range)
            guard clipped.length > 0 else { return }
            color(clipped, codeColor)
            let ns = string as NSString
            let first = ns.lineRange(for: NSRange(location: r.location, length: 0))
            color(NSIntersectionRange(first, range), markerColor)
            if r.length > first.length {
                let last = ns.lineRange(for: NSRange(location: max(r.location, NSMaxRange(r) - 1), length: 0))
                let fenceLine = ns.substring(with: last).trimmingCharacters(in: .whitespacesAndNewlines)
                if fenceLine.hasPrefix("```") || fenceLine.hasPrefix("~~~") {
                    color(NSIntersectionRange(last, range), markerColor)
                }
            }
        }
        comment.enumerateMatches(in: string, range: range) { m, _, _ in
            guard let r = m?.range, !isProtected(r) else { return }
            color(r, markerColor)
            protected.insert(integersIn: r.location..<NSMaxRange(r))
        }

        func each(_ regex: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
            regex.enumerateMatches(in: string, range: range) { m, _, _ in
                guard let m, !isProtected(m.range) else { return }
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
            pipe.enumerateMatches(in: string, range: m.range) { p, _, _ in
                if let p { color(p.range, markerColor) }
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
    }
}
