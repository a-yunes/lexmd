import Foundation

/// Where YAML front matter ends: a first line of `---` and the next line that reads `---` once
/// trimmed, with LF or CRLF line ends. A document of just those two lines has none. The preview,
/// the outline, the editor's highlighting and link updates all use this one rule.
extension FrontMatter {
    package struct Split: Equatable {
        /// The YAML between the two `---` lines.
        package let yaml: String
        /// The document after the closing line.
        package let rest: String
        /// The lines the front matter spans, both `---` lines included.
        package let lineCount: Int
        /// The UTF-16 length of the front matter through the line break after its closing line.
        package let length: Int
    }

    /// Only the lines up to the closing one are examined.
    package static func split(_ source: String) -> Split? {
        guard source.hasPrefix("---\n") || source.hasPrefix("---\r\n") else { return nil }
        let utf8 = source.utf8
        let scalars = source.unicodeScalars
        guard let firstBreak = utf8.firstIndex(of: 0x0A) else { return nil }
        let frontStart = utf8.index(after: firstBreak)
        var start = frontStart
        var lineCount = 1
        while true {
            let end = utf8[start...].firstIndex(of: 0x0A) ?? utf8.endIndex
            lineCount += 1
            if utf8[start..<end].contains(0x2D),
               String(scalars[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
                if start == frontStart, end == utf8.endIndex { return nil }
                let yaml = start == frontStart ? "" : String(scalars[frontStart..<utf8.index(before: start)])
                let restStart = end == utf8.endIndex ? end : utf8.index(after: end)
                return Split(
                    yaml: yaml, rest: String(scalars[restStart...]), lineCount: lineCount,
                    length: source.utf16.distance(from: source.startIndex, to: restStart)
                )
            }
            guard end < utf8.endIndex else { return nil }
            start = utf8.index(after: end)
        }
    }
}
