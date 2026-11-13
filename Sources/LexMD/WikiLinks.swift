import Foundation

/// A `[[Name]]`, `[[Name|label]]`, `[[Name#Heading]]` or `[[folder/Name]]` reference.
struct WikiLink: Hashable, Sendable {
    /// The document name or path as written, trimmed. Empty for `[[#Heading]]`.
    var target: String
    var heading: String?
    var alias: String?
    /// The whole `[[...]]` in the scanned text (UTF-16).
    var range: NSRange
    /// `target` in the scanned text (UTF-16), for rewriting the name in place.
    var targetRange: NSRange

    /// The text shown for the link.
    var label: String {
        if let alias { return alias }
        guard let heading else { return target }
        return target.isEmpty ? heading : "\(target) › \(heading)"
    }

    private static let pattern = try! NSRegularExpression(pattern: #"\[\[([^\[\]\n\r]+?)\]\]"#)

    /// Finds wiki links in a document, skipping code spans, code blocks, raw HTML, and front matter.
    static func parse(in source: String) -> [WikiLink] {
        DocumentStructure.analyze(source).links.compactMap(\.wiki)
    }

    /// Finds wiki links in plain text with no Markdown structure (for example, one text run).
    static func scan(_ text: String) -> [WikiLink] {
        let ns = text as NSString
        guard ns.length >= 5, text.contains("[[") else { return [] }
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            make(inner: match.range(at: 1), in: ns, whole: match.range)
        }
    }

    private static func make(inner: NSRange, in text: NSString, whole: NSRange) -> WikiLink? {
        let body = text.substring(with: inner) as NSString
        var reference = NSRange(location: 0, length: body.length)
        var alias: String?
        let pipe = body.range(of: "|")
        if pipe.location != NSNotFound {
            reference.length = pipe.location
            // Tables escape the pipe as `\|`.
            if reference.length > 0, body.character(at: reference.length - 1) == 0x5C { reference.length -= 1 }
            let rest = body.substring(from: pipe.location + 1).trimmingCharacters(in: .whitespaces)
            alias = rest.isEmpty ? nil : rest
        }
        var targetPart = reference
        var heading: String?
        let hash = body.range(of: "#", range: reference)
        if hash.location != NSNotFound {
            targetPart.length = hash.location - reference.location
            let headingText = body.substring(with: NSRange(location: hash.location + 1, length: NSMaxRange(reference) - hash.location - 1))
                .trimmingCharacters(in: .whitespaces)
            heading = headingText.isEmpty ? nil : headingText
        }
        let rawTarget = body.substring(with: targetPart)
        let target = rawTarget.trimmingCharacters(in: .whitespaces)
        // `[[^label]]` is footnote syntax, not a document.
        guard !target.isEmpty || heading != nil, !target.hasPrefix("^") else { return nil }
        let leading = (rawTarget as NSString).length - ((rawTarget.drop { $0 == " " || $0 == "\t" }) as Substring).utf16.count
        let targetRange = NSRange(location: inner.location + targetPart.location + leading, length: (target as NSString).length)
        return WikiLink(target: target, heading: heading, alias: alias, range: whole, targetRange: targetRange)
    }
}

/// GitHub-style heading ids, matching the ids `MarkdownHTML` gives headings.
struct HeadingSlugger {
    private var counts: [String: Int] = [:]

    /// The id for a heading's text, without numbering duplicates.
    static func base(_ text: String) -> String {
        var slug = ""
        for c in text.lowercased() {
            if c.isLetter || c.isNumber { slug.append(c) }
            else if c == " " || c == "-" || c == "_" { slug.append("-") }
        }
        return slug.isEmpty ? "section" : slug
    }

    /// The id for the next heading in document order; repeats get `-1`, `-2`, and so on.
    mutating func slug(for text: String) -> String {
        let slug = Self.base(text)
        let n = counts[slug, default: 0]
        counts[slug] = n + 1
        return n == 0 ? slug : "\(slug)-\(n)"
    }
}

/// Resolves wiki-link targets to Markdown files in a project.
///
/// A bare name matches any file with that name (without extension), ignoring case; when several
/// match, the one closest to the linking document wins. A name with a folder matches relative to
/// the linking document, then the project root, then any file whose path ends with it.
struct WikiLinkResolver: Sendable {
    let root: String
    private var byName: [String: [String]] = [:]
    private var byStem: [String: String] = [:]

    init(root: String, paths: [String]) {
        self.root = root
        for path in paths {
            let stem = Self.stem(path).lowercased()
            byName[((stem as NSString).lastPathComponent), default: []].append(path)
            byStem[stem] = path
        }
    }

    /// The Markdown file a wiki link target names, or nil when there is none.
    func resolve(_ target: String, from documentPath: String?) -> String? {
        var name = target.trimmingCharacters(in: .whitespaces)
        if FileScanner.isMarkdown(path: name) { name = (name as NSString).deletingPathExtension }
        guard !name.isEmpty else { return nil }
        let key = name.lowercased()
        guard key.contains("/") else { return closest(byName[key] ?? [], to: documentPath) }

        let folder = documentPath.map { ($0 as NSString).deletingLastPathComponent }
        if let folder, !key.hasPrefix("/"),
           let path = byStem[(folder.lowercased() as NSString).appendingPathComponent(key).standardizedPath] {
            return path
        }
        let rooted = key.hasPrefix("/") ? String(key.dropFirst()) : key
        if let path = byStem[(root.lowercased() as NSString).appendingPathComponent(rooted).standardizedPath] {
            return path
        }
        let suffix = "/" + rooted
        let candidates = (byName[(rooted as NSString).lastPathComponent] ?? []).filter {
            Self.stem($0).lowercased().hasSuffix(suffix)
        }
        return closest(candidates, to: documentPath)
    }

    /// Whether more than one file shares this file's name, so links need its folder too.
    func isAmbiguous(_ path: String) -> Bool {
        (byName[(Self.stem(path).lowercased() as NSString).lastPathComponent]?.count ?? 0) > 1
    }

    /// The path without its extension.
    static func stem(_ path: String) -> String {
        (path as NSString).deletingPathExtension
    }

    private func closest(_ candidates: [String], to documentPath: String?) -> String? {
        guard candidates.count > 1 else { return candidates.first }
        let from = documentPath.map { Self.folders(of: $0) } ?? Self.folders(of: (root as NSString).appendingPathComponent("x"))
        return candidates.min { a, b in
            let fa = Self.folders(of: a), fb = Self.folders(of: b)
            let da = Self.distance(from, fa), db = Self.distance(from, fb)
            if da != db { return da < db }
            if fa.count != fb.count { return fa.count < fb.count }
            return a < b
        }
    }

    private static func folders(of path: String) -> [Substring] {
        (path as NSString).deletingLastPathComponent.split(separator: "/")
    }

    /// Steps through the folder tree from one folder to another.
    private static func distance(_ a: [Substring], _ b: [Substring]) -> Int {
        var common = 0
        while common < a.count, common < b.count, a[common] == b[common] { common += 1 }
        return (a.count - common) + (b.count - common)
    }
}

/// Relative paths and URLs between files, as written in Markdown link destinations.
enum LinkPaths {
    /// Characters left as they are in a link destination; spaces and parentheses are escaped.
    private static let destinationAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "()<>")
        return set
    }()

    /// The path to the file or folder `path` relative to the folder `from`, using `..` where
    /// needed; "." when they are the same folder. Both must be absolute and spelled the same way
    /// (canonicalize first when they may not be). Every relative link LexMD writes uses this.
    static func relative(_ path: String, from folder: String) -> String {
        let base = folder.split(separator: "/"), goal = path.split(separator: "/")
        var common = 0
        while common < base.count, common < goal.count, base[common] == goal[common] { common += 1 }
        let parts = Array(repeating: "..", count: base.count - common) + goal[common...].map(String.init)
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    /// A relative destination that can't be read as a URL: a colon in its first segment would
    /// make `a:b.md` a link with the scheme `a`, so such a path starts with `./`.
    static func guardingScheme(_ destination: String) -> String {
        let first = destination.prefix { $0 != "/" }
        return first.contains(":") ? "./" + destination : destination
    }

    /// Percent-encodes a relative path for use as a link destination.
    static func encode(_ path: String) -> String {
        guardingScheme(path.addingPercentEncoding(withAllowedCharacters: destinationAllowed) ?? path)
    }

    static func encodeFragment(_ fragment: String) -> String {
        fragment.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? fragment
    }
}

extension String {
    /// The absolute path with `.`, `..` and repeated slashes resolved, without touching the
    /// file system (unlike `standardizingPath`, which may drop a leading `/private`).
    var standardizedPath: String {
        var parts: [Substring] = []
        for part in split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }
}
