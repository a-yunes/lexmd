import Foundation

enum QuickMode: Hashable, Sendable {
    /// ⇧⌘F: file names and contents.
    case everything
    /// ⌘P: file names only, with recent files when the query is empty.
    case files
}

struct SearchOptions: Equatable, Sendable {
    var caseSensitive = false
    var wholeWord = false
    var regex = false
}

/// One text match inside a Markdown file.
struct SearchHit: Identifiable, Equatable, Sendable {
    let id: Int
    let path: String
    let name: String
    let folder: String
    /// 1-based line number.
    let line: Int
    /// Index of this match among all matches in the file (used to re-locate it after edits).
    let occurrence: Int
    /// The full source line and the match within it.
    let lineText: String
    let lineMatch: NSRange
    /// A trimmed excerpt for list rows, and the match within it.
    let snippet: String
    let snippetMatch: NSRange
}

/// A file whose name fuzzily matches the query.
struct FileMatch: Identifiable, Equatable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let folder: String
    let score: Int
    /// Character offsets in `name` that matched the query.
    let matched: [Int]
}

struct QuickSearchResults: Sendable {
    var files: [FileMatch] = []
    var hits: [SearchHit] = []
    var hitCounts: [String: Int] = [:]
    var truncated = false
    var error: String?

    var hitFileCount: Int { hitCounts.count }
}

struct SearchableFile: Sendable {
    let path: String
    let name: String
    let folder: String
}

enum QuickSearchEngine {
    static let maxHitsPerFile = 200
    static let maxHits = 3000

    static func regex(for query: String, options: SearchOptions) throws -> NSRegularExpression {
        var pattern = options.regex ? query : NSRegularExpression.escapedPattern(for: query)
        if options.wholeWord { pattern = "\\b(?:\(pattern))\\b" }
        var flags: NSRegularExpression.Options = [.anchorsMatchLines]
        if !options.caseSensitive { flags.insert(.caseInsensitive) }
        return try NSRegularExpression(pattern: pattern, options: flags)
    }

    /// Non-empty matches of `regex` in `text`, in order.
    static func matches(of regex: NSRegularExpression, in text: String) -> [NSRange] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map(\.range)
            .filter { $0.length > 0 }
    }

    static func run(
        query: String,
        options: SearchOptions,
        files: [SearchableFile],
        overrides: [String: String],
        currentPath: String?,
        filesOnly: Bool = false
    ) -> QuickSearchResults {
        var results = QuickSearchResults()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return results }

        if filesOnly {
            results.files = fuzzyFiles(query: trimmed, files: files, limit: 60)
            return results
        }
        if !options.regex {
            results.files = fuzzyFiles(query: trimmed, files: files)
        }

        let regex: NSRegularExpression
        do {
            regex = try Self.regex(for: options.regex ? query : trimmed, options: options)
        } catch {
            results.error = "Invalid regular expression"
            return results
        }

        // The open document first, then tree order.
        var ordered = files
        if let currentPath, let index = ordered.firstIndex(where: { $0.path == currentPath }) {
            ordered.insert(ordered.remove(at: index), at: 0)
        }

        var nextID = 0
        for file in ordered {
            if Task.isCancelled { break }
            if results.hits.count >= maxHits { results.truncated = true; break }
            guard let text = overrides[file.path] ?? read(file.path) else { continue }

            let found = matches(of: regex, in: text)
            guard !found.isEmpty else { continue }
            let ns = text as NSString
            let lineStarts = Self.lineStarts(text)
            var count = 0
            for (occurrence, range) in found.enumerated() {
                if count >= maxHitsPerFile || results.hits.count >= maxHits {
                    results.truncated = true
                    break
                }
                let lineIndex = Self.lineIndex(for: range.location, in: lineStarts)
                let lineStart = lineStarts[lineIndex]
                var lineEnd = lineIndex + 1 < lineStarts.count ? lineStarts[lineIndex + 1] - 1 : ns.length
                if lineEnd > lineStart, ns.character(at: lineEnd - 1) == 13 { lineEnd -= 1 }
                let lineText = ns.substring(with: NSRange(location: lineStart, length: max(0, lineEnd - lineStart)))
                let lineLength = (lineText as NSString).length
                let matchStart = min(range.location - lineStart, lineLength)
                let lineMatch = NSRange(location: matchStart, length: min(range.length, lineLength - matchStart))
                let (snippet, snippetMatch) = Self.snippet(lineText, match: lineMatch)
                results.hits.append(SearchHit(
                    id: nextID, path: file.path, name: file.name, folder: file.folder,
                    line: lineIndex + 1, occurrence: occurrence,
                    lineText: lineText, lineMatch: lineMatch,
                    snippet: snippet, snippetMatch: snippetMatch
                ))
                nextID += 1
                count += 1
            }
            results.hitCounts[file.path] = found.count
        }
        return results
    }

    /// A file's text, reused from the cache while the file is unchanged.
    static func read(_ path: String) -> String? {
        TextCache.shared.text(at: path)
    }

    static func lineStarts(_ text: String) -> [Int] {
        var starts = [0]
        var index = 0
        for unit in text.utf16 {
            index += 1
            if unit == 10 { starts.append(index) }
        }
        return starts
    }

    static func lineIndex(for location: Int, in starts: [Int]) -> Int {
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Trims leading indentation and, for matches far into a long line, the text before them.
    static func snippet(_ line: String, match: NSRange) -> (String, NSRange) {
        let ns = line as NSString
        var lead = 0
        while lead < ns.length, lead < match.location, let scalar = UnicodeScalar(ns.character(at: lead)),
              CharacterSet.whitespaces.contains(scalar) {
            lead += 1
        }
        var start = lead
        if match.location - start > 48 {
            start = ns.rangeOfComposedCharacterSequence(at: match.location - 28).location
        }
        let end = min(ns.length, max(start + 240, NSMaxRange(match)))
        var text = ns.substring(with: NSRange(location: start, length: end - start))
        var offset = match.location - start
        if start > lead {
            text = "…" + text
            offset += 1
        }
        let length = min(match.length, (text as NSString).length - offset)
        return (text, NSRange(location: offset, length: max(0, length)))
    }

    // MARK: Fuzzy file names

    static func fuzzyFiles(query: String, files: [SearchableFile], limit: Int = 6) -> [FileMatch] {
        let compact = query.replacingOccurrences(of: " ", with: "")
        guard !compact.isEmpty else { return [] }
        var matches: [FileMatch] = []
        for (index, file) in files.enumerated() {
            // A newer query supersedes this one; stop instead of finishing the whole project.
            if index % 256 == 0, Task.isCancelled { break }
            let base = (file.name as NSString).deletingPathExtension
            // A query that includes the extension ("readme.md") matches the full name.
            let nameMatch = fuzzy(compact, in: base) ?? fuzzy(compact, in: file.name)
            let pathMatch = file.folder.isEmpty ? nil
                : fuzzy(compact, in: file.folder + "/" + base) ?? fuzzy(compact, in: file.folder + "/" + file.name)
            // Prefer a match on the name; fall back to the folder path (shown without letter highlights).
            if let (score, indices) = nameMatch, pathMatch.map({ score >= $0.0 - 6 }) ?? true {
                matches.append(FileMatch(path: file.path, name: base, folder: file.folder, score: score, matched: indices))
            } else if let (score, _) = pathMatch {
                matches.append(FileMatch(path: file.path, name: base, folder: file.folder, score: score - 6, matched: []))
            }
        }
        return matches
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.name.count < $1.name.count }
            .prefix(limit)
            .map { $0 }
    }

    /// Scores `query` against `candidate`: contiguous substrings rank highest (more so at word
    /// starts and prefixes); otherwise a tight subsequence match is accepted.
    static func fuzzy(_ query: String, in candidate: String) -> (Int, [Int])? {
        let q = query.lowercased().map { $0 }
        let original = Array(candidate)
        let lower = original.map { Character($0.lowercased().first.map(String.init) ?? String($0)) }
        guard !q.isEmpty, q.count <= lower.count else { return nil }
        // Both passes below need every query character in order, so most candidates end here.
        var next = 0
        for character in lower where character == q[next] {
            next += 1
            if next == q.count { break }
        }
        guard next == q.count else { return nil }

        func isWordStart(_ i: Int) -> Bool {
            if i == 0 { return true }
            let before = original[i - 1]
            return " -_./".contains(before) || (before.isLowercase && original[i].isUppercase)
        }

        // 1. Contiguous substring, preferring one that starts a word.
        var best: (Int, Int)?
        if q.count <= lower.count {
            for start in 0...(lower.count - q.count) where lower[start..<(start + q.count)].elementsEqual(q) {
                let score = 12 * q.count + (start == 0 ? 25 : 0) + (isWordStart(start) ? 12 : 0) - lower.count / 10
                if best == nil || score > best!.1 { best = (start, score) }
            }
        }
        if let (start, score) = best {
            return (score, Array(start..<(start + q.count)))
        }

        // 2. Best subsequence alignment (dynamic programming), rewarding word starts and runs,
        //    so "skrev" matches "SKetches/rough-REView". Loose scatters are rejected.
        let n = lower.count, m = q.count
        let none = Int.min / 4
        var best2 = Array(repeating: Array(repeating: none, count: n), count: m)
        var from = Array(repeating: Array(repeating: -1, count: n), count: m)
        for j in 0..<n where lower[j] == q[0] {
            best2[0][j] = 1 + (isWordStart(j) ? 8 : 0) + (j == 0 ? 6 : 0) - min(j, 6)
        }
        if m > 1 {
            for i in 1..<m {
                for j in i..<n where lower[j] == q[i] {
                    for k in (i - 1)..<j where best2[i - 1][k] > none {
                        let gap = j - k - 1
                        var value = best2[i - 1][k] + 1 + (isWordStart(j) ? 8 : 0)
                        value += gap == 0 ? 6 : -min(gap, 6)
                        if value > best2[i][j] {
                            best2[i][j] = value
                            from[i][j] = k
                        }
                    }
                }
            }
        }
        guard let end = (0..<n).max(by: { best2[m - 1][$0] < best2[m - 1][$1] }), best2[m - 1][end] > none else {
            return nil
        }
        var indices = [end]
        var j = end
        for i in stride(from: m - 1, to: 0, by: -1) {
            j = from[i][j]
            indices.insert(j, at: 0)
        }
        let score = best2[m - 1][end] - n / 12
        return score >= m * 4 ? (score, indices) : nil
    }
}

/// File contents keyed by path and modification date, so repeated searches skip unchanged
/// files. The cache is size-limited and the system may evict it under memory pressure.
final class TextCache: @unchecked Sendable {
    static let shared = TextCache()

    private final class Entry {
        let modified: Date
        let text: String

        init(modified: Date, text: String) {
            self.modified = modified
            self.text = text
        }
    }

    private let cache = NSCache<NSString, Entry>()

    private init() {
        cache.totalCostLimit = 48 << 20
    }

    func text(at path: String) -> String? {
        let key = path as NSString
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let modified, let entry = cache.object(forKey: key), entry.modified == modified {
            return entry.text
        }
        guard let text = Self.decode(path) else { return nil }
        if let modified {
            cache.setObject(Entry(modified: modified, text: text), forKey: key, cost: text.utf8.count)
        }
        return text
    }

    private static func decode(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        return try? String(contentsOf: url, encoding: .isoLatin1)
    }
}
