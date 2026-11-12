import Foundation

/// A file or folder that moved from one absolute path to another.
struct PathMove: Hashable, Sendable {
    var from: String
    var to: String

    /// The new location of `path` when it is the moved item or inside it.
    func map(_ path: String) -> String? {
        if path == from { return to }
        if path.hasPrefix(from + "/") { return to + path.dropFirst(from.count) }
        return nil
    }

    var inverse: PathMove { PathMove(from: to, to: from) }
}

/// One replacement in a text, in UTF-16 offsets.
struct TextEdit: Equatable, Sendable {
    var range: NSRange
    var replacement: String

    /// Applies non-overlapping edits, last first so earlier ranges stay valid.
    static func apply(_ edits: [TextEdit], to text: String) -> String {
        let result = NSMutableString(string: text)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            result.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return result as String
    }
}

/// A link target found in Markdown source.
struct LinkOccurrence: Equatable {
    enum Kind: Equatable { case inline, reference, wiki }
    var kind: Kind
    /// The destination (for wiki links, the target name), without angle brackets.
    var range: NSRange
    var isAngle = false
}

// MARK: - Scanner

/// Finds link destinations in Markdown while skipping front matter, fenced and indented code,
/// and code spans.
enum MarkdownLinkScanner {
    private struct Line {
        var start: Int
        var end: Int
    }

    private static let backslash: UInt16 = 92, backtick: UInt16 = 96, tilde: UInt16 = 126
    private static let openBracket: UInt16 = 91, closeBracket: UInt16 = 93
    private static let openParen: UInt16 = 40, closeParen: UInt16 = 41
    private static let lessThan: UInt16 = 60, greaterThan: UInt16 = 62
    private static let space: UInt16 = 32, tab: UInt16 = 9, newline: UInt16 = 10, carriageReturn: UInt16 = 13
    private static let colon: UInt16 = 58, pipe: UInt16 = 124, hash: UInt16 = 35, caret: UInt16 = 94

    static func links(in text: String) -> [LinkOccurrence] {
        let s = Array(text.utf16)
        let lines = lineRanges(s)
        let prose = proseLines(s, lines)
        var result: [LinkOccurrence] = []
        var segment: (start: Int, end: Int)?
        for (index, line) in lines.enumerated() {
            if prose[index], !isBlank(s, line) {
                if let definition = referenceDefinition(s, line) { result.append(definition) }
                segment = (segment?.start ?? line.start, line.end)
            } else if let current = segment {
                scanInline(s, from: current.start, to: current.end, into: &result)
                segment = nil
            }
        }
        if let current = segment { scanInline(s, from: current.start, to: current.end, into: &result) }
        return result.sorted { $0.range.location < $1.range.location }
    }

    private static func lineRanges(_ s: [UInt16]) -> [Line] {
        var lines: [Line] = []
        var start = 0
        for i in 0..<s.count where s[i] == newline {
            let end = i > start && s[i - 1] == carriageReturn ? i - 1 : i
            lines.append(Line(start: start, end: end))
            start = i + 1
        }
        if start <= s.count {
            var end = s.count
            if end > start, s[end - 1] == carriageReturn { end -= 1 }
            lines.append(Line(start: start, end: end))
        }
        return lines
    }

    private static func isBlank(_ s: [UInt16], _ line: Line) -> Bool {
        (line.start..<line.end).allSatisfy { s[$0] == space || s[$0] == tab }
    }

    /// Indentation in columns and the offset after leading whitespace and blockquote markers.
    private static func indentation(_ s: [UInt16], _ line: Line) -> (columns: Int, content: Int) {
        var columns = 0
        var i = line.start
        while i < line.end, s[i] == space || s[i] == tab {
            columns = s[i] == tab ? (columns / 4 + 1) * 4 : columns + 1
            i += 1
        }
        var content = i
        while content < line.end, s[content] == greaterThan {
            content += 1
            while content < line.end, s[content] == space || s[content] == tab { content += 1 }
        }
        return (columns, content)
    }

    private static func fence(_ s: [UInt16], _ line: Line, at start: Int) -> (char: UInt16, count: Int)? {
        guard start < line.end, s[start] == backtick || s[start] == tilde else { return nil }
        let char = s[start]
        var i = start
        while i < line.end, s[i] == char { i += 1 }
        let count = i - start
        guard count >= 3 else { return nil }
        if char == backtick, (i..<line.end).contains(where: { s[$0] == backtick }) { return nil }
        return (char, count)
    }

    private static func isListItem(_ s: [UInt16], _ line: Line, at start: Int) -> Bool {
        guard start < line.end else { return false }
        let c = s[start]
        if c == 45 || c == 42 || c == 43 { // - * +
            return start + 1 == line.end || s[start + 1] == space || s[start + 1] == tab
        }
        var i = start
        while i < line.end, s[i] >= 48, s[i] <= 57 { i += 1 }
        guard i > start, i - start <= 9, i < line.end, s[i] == 46 || s[i] == closeParen else { return false }
        return i + 1 == line.end || s[i + 1] == space || s[i + 1] == tab
    }

    /// Marks lines that hold Markdown prose rather than code or front matter.
    private static func proseLines(_ s: [UInt16], _ lines: [Line]) -> [Bool] {
        var prose = Array(repeating: true, count: lines.count)
        var index = 0
        // YAML front matter.
        if let first = lines.first, String(utf16CodeUnits: Array(s[first.start..<first.end]), count: first.end - first.start) == "---" {
            if let close = lines.indices.dropFirst().first(where: {
                let line = lines[$0]
                let text = String(utf16CodeUnits: Array(s[line.start..<line.end]), count: line.end - line.start)
                return text == "---" || text == "..."
            }) {
                for i in 0...close { prose[i] = false }
                index = close + 1
            }
        }
        var openFence: (char: UInt16, count: Int)?
        var inIndentedCode = false
        var previousBlank = true
        var listContext = false
        while index < lines.count {
            let line = lines[index]
            defer { index += 1 }
            let blank = isBlank(s, line)
            let (columns, content) = indentation(s, line)
            if let open = openFence {
                prose[index] = false
                if let close = fence(s, line, at: content), close.char == open.char, close.count >= open.count,
                   (content + close.count..<line.end).allSatisfy({ s[$0] == space || s[$0] == tab }) {
                    openFence = nil
                }
                continue
            }
            if !blank, let open = fence(s, line, at: content) {
                // Fences are honored at any indentation so code inside list items stays untouched.
                openFence = open
                prose[index] = false
                inIndentedCode = false
                previousBlank = false
                continue
            }
            if inIndentedCode {
                if blank || columns >= 4 {
                    prose[index] = false
                    continue
                }
                inIndentedCode = false
            }
            if blank {
                previousBlank = true
                continue
            }
            if columns >= 4, previousBlank, !listContext {
                inIndentedCode = true
                prose[index] = false
                continue
            }
            if columns < 4 {
                listContext = isListItem(s, line, at: content) || (listContext && !previousBlank)
            }
            previousBlank = false
        }
        return prose
    }

    /// `[label]: destination` at the start of a line. Footnotes (`[^1]:`) are not links.
    private static func referenceDefinition(_ s: [UInt16], _ line: Line) -> LinkOccurrence? {
        var i = line.start
        var spaces = 0
        while i < line.end, s[i] == space, spaces < 4 { i += 1; spaces += 1 }
        guard spaces <= 3, i < line.end, s[i] == openBracket else { return nil }
        i += 1
        guard i < line.end, s[i] != caret, s[i] != closeBracket else { return nil }
        while i < line.end, s[i] != closeBracket {
            if s[i] == openBracket { return nil }
            i += s[i] == backslash ? 2 : 1
        }
        guard i + 1 < line.end, s[i] == closeBracket, s[i + 1] == colon else { return nil }
        i += 2
        while i < line.end, s[i] == space || s[i] == tab { i += 1 }
        guard i < line.end else { return nil }
        if s[i] == lessThan {
            var j = i + 1
            while j < line.end, s[j] != greaterThan, s[j] != lessThan { j += s[j] == backslash ? 2 : 1 }
            guard j < line.end, s[j] == greaterThan else { return nil }
            return LinkOccurrence(kind: .reference, range: NSRange(location: i + 1, length: j - i - 1), isAngle: true)
        }
        var j = i
        while j < line.end, s[j] > space { j += 1 }
        return LinkOccurrence(kind: .reference, range: NSRange(location: i, length: j - i))
    }

    private static func scanInline(_ s: [UInt16], from start: Int, to end: Int, into result: inout [LinkOccurrence]) {
        var openers: [Int] = []
        var i = start
        while i < end {
            let c = s[i]
            if c == backslash {
                i += 2
            } else if c == backtick {
                var run = i
                while run < end, s[run] == backtick { run += 1 }
                let count = run - i
                if let close = closingBackticks(s, from: run, to: end, count: count) {
                    i = close + count
                } else {
                    i = run
                }
            } else if c == lessThan, let close = autolinkEnd(s, from: i, to: end) {
                i = close + 1
            } else if c == openBracket, i + 1 < end, s[i + 1] == openBracket, let wiki = wikiLink(s, from: i, to: end) {
                if let occurrence = wiki.occurrence { result.append(occurrence) }
                i = wiki.end
            } else if c == openBracket {
                openers.append(i)
                i += 1
            } else if c == closeBracket {
                i += 1
                guard openers.popLast() != nil else { continue }
                guard i < end, s[i] == openParen, let link = inlineDestination(s, from: i + 1, to: end) else { continue }
                if link.range.length > 0 {
                    result.append(LinkOccurrence(kind: .inline, range: link.range, isAngle: link.isAngle))
                }
                i = link.end
            } else {
                i += 1
            }
        }
    }

    private static func closingBackticks(_ s: [UInt16], from start: Int, to end: Int, count: Int) -> Int? {
        var i = start
        while i < end {
            guard s[i] == backtick else { i += 1; continue }
            var run = i
            while run < end, s[run] == backtick { run += 1 }
            if run - i == count { return i }
            i = run
        }
        return nil
    }

    /// `<scheme:...>` autolinks, which never hold relative links.
    private static func autolinkEnd(_ s: [UInt16], from start: Int, to end: Int) -> Int? {
        var i = start + 1
        var sawColon = false
        while i < end {
            let c = s[i]
            if c == greaterThan { return sawColon ? i : nil }
            if c <= space || c == lessThan { return nil }
            if c == colon { sawColon = true }
            i += 1
        }
        return nil
    }

    /// `[[target#heading|label]]`; the occurrence covers only the target.
    private static func wikiLink(_ s: [UInt16], from start: Int, to end: Int) -> (occurrence: LinkOccurrence?, end: Int)? {
        var i = start + 2
        var targetEnd: Int?
        while i + 1 < end {
            let c = s[i]
            if c == newline || c == openBracket { return nil }
            if c == closeBracket {
                guard s[i + 1] == closeBracket else { return nil }
                break
            }
            if targetEnd == nil {
                if c == pipe || c == hash { targetEnd = i }
                if c == backslash, s[i + 1] == pipe { targetEnd = i }
            }
            i += 1
        }
        guard i + 1 < end, s[i] == closeBracket, s[i + 1] == closeBracket, i > start + 2 else { return nil }
        let targetStop = targetEnd ?? i
        let range = NSRange(location: start + 2, length: targetStop - start - 2)
        return (range.length > 0 ? LinkOccurrence(kind: .wiki, range: range) : nil, i + 2)
    }

    private static func skipWhitespace(_ s: [UInt16], _ i: inout Int, _ end: Int) {
        var newlines = 0
        while i < end {
            if s[i] == space || s[i] == tab || s[i] == carriageReturn {
                i += 1
            } else if s[i] == newline, newlines == 0 {
                newlines += 1
                i += 1
            } else {
                break
            }
        }
    }

    /// Parses `destination "title")` after the opening parenthesis of an inline link.
    private static func inlineDestination(_ s: [UInt16], from start: Int, to end: Int) -> (range: NSRange, isAngle: Bool, end: Int)? {
        var i = start
        skipWhitespace(s, &i, end)
        let range: NSRange
        var isAngle = false
        if i < end, s[i] == lessThan {
            var j = i + 1
            while j < end, s[j] != greaterThan, s[j] != newline, s[j] != lessThan { j += s[j] == backslash ? 2 : 1 }
            guard j < end, s[j] == greaterThan else { return nil }
            range = NSRange(location: i + 1, length: j - i - 1)
            isAngle = true
            i = j + 1
        } else {
            let destinationStart = i
            var depth = 0
            while i < end {
                let c = s[i]
                if c == backslash, i + 1 < end { i += 2; continue }
                if c <= space || c == 127 { break }
                if c == openParen { depth += 1 }
                if c == closeParen {
                    if depth == 0 { break }
                    depth -= 1
                }
                i += 1
            }
            guard depth == 0, i <= end else { return nil }
            range = NSRange(location: destinationStart, length: i - destinationStart)
        }
        skipWhitespace(s, &i, end)
        if i < end, s[i] == 34 || s[i] == 39 || s[i] == openParen { // " ' (
            let close = s[i] == openParen ? closeParen : s[i]
            var j = i + 1
            while j < end, s[j] != close { j += s[j] == backslash ? 2 : 1 }
            guard j < end else { return nil }
            i = j + 1
            skipWhitespace(s, &i, end)
        }
        guard i < end, s[i] == closeParen else { return nil }
        return (range, isAngle, i + 1)
    }
}

// MARK: - Rewriting

/// How wiki link targets change when files are renamed or moved.
struct WikiRenames: Sendable {
    struct Entry: Sendable {
        /// Paths relative to the project root; Markdown files without their extension.
        var oldPath: String
        var newPath: String
    }

    var entries: [Entry] = []
    /// Lowercased names that other files share, so bare `[[Name]]` links to them are ambiguous.
    var ambiguousNames: Set<String> = []

    /// Builds the table from moved files (absolute paths) and the files left in place.
    init(root: String, moved: [(old: String, new: String)], otherFiles: [String]) {
        entries = moved.compactMap { pair in
            guard let old = Self.wikiPath(pair.old, root: root), let new = Self.wikiPath(pair.new, root: root) else { return nil }
            return Entry(oldPath: old, newPath: new)
        }
        let movedNames = Set(entries.map { Self.lastComponent($0.oldPath).lowercased() })
        let otherNames = Set(otherFiles.compactMap { Self.wikiPath($0, root: root) }.map { Self.lastComponent($0).lowercased() })
        ambiguousNames = movedNames.intersection(otherNames)
    }

    init() {}

    static func wikiPath(_ path: String, root: String) -> String? {
        guard path.hasPrefix(root + "/") else { return nil }
        let relative = String(path.dropFirst(root.count + 1))
        return FileScanner.isMarkdown(path: relative) ? (relative as NSString).deletingPathExtension : relative
    }

    private static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// The new target for a wiki link target, or nil when it does not change.
    func rename(_ target: String) -> String? {
        guard !entries.isEmpty else { return nil }
        var name = target.trimmingCharacters(in: .whitespaces)
        var leadingSlash = ""
        if name.hasPrefix("/") {
            leadingSlash = "/"
            name.removeFirst()
        }
        var suffix = ""
        if FileScanner.isMarkdown(path: name) {
            suffix = "." + (name as NSString).pathExtension
            name = (name as NSString).deletingPathExtension
        }
        guard !name.isEmpty else { return nil }
        let lower = name.lowercased()
        let replacement: String
        if lower.contains("/") {
            let matches = entries.filter {
                let old = $0.oldPath.lowercased()
                return old == lower || old.hasSuffix("/" + lower)
            }
            guard matches.count == 1, let entry = matches.first else { return nil }
            if entry.oldPath.lowercased() == lower {
                guard entry.oldPath != entry.newPath else { return nil }
                replacement = entry.newPath
            } else {
                let count = lower.split(separator: "/").count
                let oldSuffix = entry.oldPath.split(separator: "/").suffix(count).joined(separator: "/")
                replacement = entry.newPath.split(separator: "/").suffix(count).joined(separator: "/")
                guard oldSuffix != replacement else { return nil }
            }
        } else {
            guard !ambiguousNames.contains(lower) else { return nil }
            let matches = entries.filter { Self.lastComponent($0.oldPath).lowercased() == lower }
            guard matches.count == 1, let entry = matches.first,
                  Self.lastComponent(entry.oldPath) != Self.lastComponent(entry.newPath) else { return nil }
            replacement = Self.lastComponent(entry.newPath)
        }
        guard replacement != name else { return nil }
        return leadingSlash + replacement + suffix
    }
}

enum LinkRewriter {
    /// Everything that moved, plus the wiki link table derived from it.
    struct Context: Sendable {
        var moves: [PathMove]
        var wiki = WikiRenames()

        func newLocation(of path: String) -> String {
            for move in moves { if let mapped = move.map(path) { return mapped } }
            return path
        }

        func oldLocation(of path: String) -> String {
            for move in moves { if let mapped = move.inverse.map(path) { return mapped } }
            return path
        }
    }

    /// Edits that keep a document's links pointing at the same files after the moves.
    /// `oldPath` is where the document was; `newPath` is where it is now.
    static func edits(in text: String, oldPath: String, newPath: String, context: Context) -> [TextEdit] {
        let ns = text as NSString
        let oldDirectory = (oldPath as NSString).deletingLastPathComponent
        let newDirectory = (newPath as NSString).deletingLastPathComponent
        var edits: [TextEdit] = []
        for link in MarkdownLinkScanner.links(in: text) {
            let raw = ns.substring(with: link.range)
            let replacement: String?
            switch link.kind {
            case .inline, .reference:
                replacement = rewriteDestination(raw, isAngle: link.isAngle, oldDirectory: oldDirectory,
                                                 newDirectory: newDirectory, context: context)
            case .wiki:
                replacement = context.wiki.rename(raw)
            }
            if let replacement, replacement != raw {
                edits.append(TextEdit(range: link.range, replacement: replacement))
            }
        }
        return edits
    }

    static func isExternal(_ destination: String) -> Bool {
        if destination.hasPrefix("/") || destination.hasPrefix("~") || destination.hasPrefix("\\") { return true }
        guard let first = destination.unicodeScalars.first, first.isASCII, CharacterSet.letters.contains(first) else { return false }
        for scalar in destination.unicodeScalars.dropFirst() {
            if scalar == ":" { return true }
            guard scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) || "+.-".unicodeScalars.contains(scalar) else { return false }
        }
        return false
    }

    /// The rewritten destination, or nil when it stays as is.
    static func rewriteDestination(
        _ raw: String, isAngle: Bool, oldDirectory: String, newDirectory: String, context: Context
    ) -> String? {
        guard !raw.isEmpty, !raw.hasPrefix("#"), !raw.hasPrefix("?"), !isExternal(raw) else { return nil }
        var pathPart = raw
        var suffix = ""
        if let index = raw.firstIndex(where: { $0 == "#" || $0 == "?" }) {
            pathPart = String(raw[..<index])
            suffix = String(raw[index...])
        }
        let unescaped = unescape(pathPart)
        let decoded = unescaped.contains("%") ? (unescaped.removingPercentEncoding ?? unescaped) : unescaped
        let wasEncoded = decoded != unescaped
        guard !decoded.isEmpty else { return nil }

        let oldTarget = normalize(oldDirectory + "/" + decoded)
        let newTarget = context.newLocation(of: oldTarget)
        guard newTarget != oldTarget || newDirectory != oldDirectory else { return nil }
        var relative = relativePath(from: newDirectory, to: newTarget)
        if trimmedRelative(relative) == trimmedRelative(decoded) { return nil }
        if decoded.hasPrefix("./"), !relative.hasPrefix("../"), relative != "." { relative = "./" + relative }
        if decoded.hasSuffix("/"), !relative.hasSuffix("/") { relative += "/" }

        let encoded: String
        if isAngle {
            encoded = relative.replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E")
        } else if wasEncoded {
            encoded = relative.addingPercentEncoding(withAllowedCharacters: encodedPathAllowed) ?? relative
        } else {
            encoded = escapeRaw(relative)
        }
        return encoded + suffix
    }

    private static let encodedPathAllowed: CharacterSet = {
        var set = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        set.insert(charactersIn: "-._~/!$&'*+,;=:@()")
        return set
    }()

    /// Keeps a raw destination valid: spaces, angle brackets and unbalanced parentheses are encoded.
    private static func escapeRaw(_ path: String) -> String {
        var depth = 0
        var balanced = true
        for character in path {
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1; if depth < 0 { balanced = false } }
        }
        if depth != 0 { balanced = false }
        var result = ""
        for character in path {
            switch character {
            case " ": result += "%20"
            case "<": result += "%3C"
            case ">": result += "%3E"
            case "(" where !balanced: result += "%28"
            case ")" where !balanced: result += "%29"
            default:
                if character.unicodeScalars.allSatisfy({ $0.value < 0x20 || $0.value == 0x7F }) {
                    result += character.unicodeScalars.map { String(format: "%%%02X", $0.value) }.joined()
                } else {
                    result.append(character)
                }
            }
        }
        return result
    }

    /// Removes CommonMark backslash escapes before ASCII punctuation.
    private static func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var result = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            if character == "\\", let next = iterator.next() {
                if next.isASCII, next.isPunctuation || next.isSymbol {
                    result.append(next)
                } else {
                    result.append(character)
                    result.append(next)
                }
            } else {
                result.append(character)
            }
        }
        return result
    }

    private static func trimmedRelative(_ path: String) -> String {
        var path = path
        while path.hasPrefix("./") { path.removeFirst(2) }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Resolves `.` and `..` without touching the file system.
    static func normalize(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if !components.isEmpty { components.removeLast() }
                continue
            }
            components.append(component)
        }
        return "/" + components.joined(separator: "/")
    }

    static func relativePath(from directory: String, to target: String) -> String {
        let base = directory.split(separator: "/")
        let goal = target.split(separator: "/")
        var common = 0
        while common < base.count, common < goal.count, base[common] == goal[common] { common += 1 }
        let parts = Array(repeating: "..", count: base.count - common) + goal[common...].map(String.init)
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }
}

// MARK: - Planning and writing

/// A text file read with its encoding and byte order mark, so it can be written back the same way.
struct TextFile: Sendable {
    var text: String
    var encoding: String.Encoding
    var hasBOM: Bool

    static func read(_ url: URL) -> TextFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let bytes = [UInt8](data.prefix(3))
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF,
           let text = String(data: data.dropFirst(3), encoding: .utf8) {
            return TextFile(text: text, encoding: .utf8, hasBOM: true)
        }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE,
           let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            return TextFile(text: text, encoding: .utf16LittleEndian, hasBOM: true)
        }
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF,
           let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            return TextFile(text: text, encoding: .utf16BigEndian, hasBOM: true)
        }
        if let text = String(data: data, encoding: .utf8) { return TextFile(text: text, encoding: .utf8, hasBOM: false) }
        if let text = String(data: data, encoding: .isoLatin1) { return TextFile(text: text, encoding: .isoLatin1, hasBOM: false) }
        return nil
    }

    /// Writes atomically next to the original, keeping its permissions and other attributes.
    func write(to url: URL) throws {
        guard var data = text.data(using: encoding) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        if hasBOM {
            switch encoding {
            case .utf8: data = Data([0xEF, 0xBB, 0xBF]) + data
            case .utf16LittleEndian: data = Data([0xFF, 0xFE]) + data
            case .utf16BigEndian: data = Data([0xFE, 0xFF]) + data
            default: break
            }
        }
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).lexmd-\(UUID().uuidString)")
        try data.write(to: temporary)
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}

/// Links that a move would change, per file.
struct LinkUpdatePlan: Sendable {
    struct File: Sendable, Equatable {
        var path: String
        var count: Int
    }

    var files: [File] = []
    var linkCount: Int { files.reduce(0) { $0 + $1.count } }
}

/// A file rewritten by a link update, kept for undo.
struct RewrittenFile: Sendable {
    var path: String
    var before: String
    var after: String
}

enum LinkUpdater {
    /// The rewrite context for a move. Folder moves list their contents for wiki links.
    /// `markdownFiles` are the project's Markdown files at their current locations.
    static func context(root: String, move: PathMove, markdownFiles: [String]) -> LinkRewriter.Context {
        var moved: [(old: String, new: String)] = []
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: move.to, isDirectory: &isDirectory), isDirectory.boolValue {
            let base = URL(fileURLWithPath: move.to, isDirectory: true)
            let enumerator = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            while let item = enumerator?.nextObject() as? URL {
                guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let relative = String(item.path.dropFirst(base.path.count))
                moved.append((move.from + relative, move.to + relative))
                if moved.count > 20_000 { break }
            }
        } else {
            moved.append((move.from, move.to))
        }
        let others = markdownFiles.filter { move.inverse.map($0) == nil }
        return LinkRewriter.Context(moves: [move], wiki: WikiRenames(root: root, moved: moved, otherFiles: others))
    }

    /// Counts the links that would change. `overrides` holds unsaved text for open documents.
    static func plan(markdownFiles: [String], context: LinkRewriter.Context, overrides: [String: String]) -> LinkUpdatePlan {
        var plan = LinkUpdatePlan()
        for path in markdownFiles {
            if Task.isCancelled { break }
            guard let text = overrides[path] ?? TextFile.read(URL(fileURLWithPath: path))?.text else { continue }
            let count = LinkRewriter.edits(in: text, oldPath: context.oldLocation(of: path), newPath: path, context: context).count
            if count > 0 { plan.files.append(.init(path: path, count: count)) }
        }
        return plan
    }

    /// Rewrites files on disk, returning what changed and the paths that could not be written.
    static func rewrite(_ paths: [String], context: LinkRewriter.Context) -> (written: [RewrittenFile], failed: [String]) {
        var written: [RewrittenFile] = []
        var failed: [String] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard var file = TextFile.read(url) else { failed.append(path); continue }
            let edits = LinkRewriter.edits(in: file.text, oldPath: context.oldLocation(of: path), newPath: path, context: context)
            guard !edits.isEmpty else { continue }
            let before = file.text
            file.text = TextEdit.apply(edits, to: before)
            do {
                try file.write(to: url)
                written.append(RewrittenFile(path: path, before: before, after: file.text))
            } catch {
                failed.append(path)
            }
        }
        return (written, failed)
    }

    /// Swaps file contents from `from` to `to` where the file still holds `from`. Used by undo and redo.
    static func restore(_ files: [RewrittenFile], forward: Bool) -> [String] {
        var skipped: [String] = []
        for record in files {
            let url = URL(fileURLWithPath: record.path)
            guard var file = TextFile.read(url), file.text == (forward ? record.before : record.after) else {
                skipped.append(record.path)
                continue
            }
            file.text = forward ? record.after : record.before
            do { try file.write(to: url) } catch { skipped.append(record.path) }
        }
        return skipped
    }
}
