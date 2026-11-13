import Foundation
import LexMDRendering
import Observation

/// A heading of an indexed document.
struct IndexedHeading: Hashable, Sendable {
    var slug: String
    var title: String
    var level: Int
    var line: Int
}

/// A link from an indexed document to another Markdown document.
struct IndexedLink: Hashable, Sendable {
    enum Target: Hashable, Sendable {
        /// A Markdown link, already resolved to an absolute path.
        case path(String)
        /// A wiki link target, resolved against the current set of files.
        case wiki(String)
    }
    var target: Target
    var line: Int
    var range: NSRange
}

/// What the index keeps per Markdown file: headings and outgoing document links, no text.
struct IndexedDocument: Hashable, Sendable {
    var modified: Date?
    var size: Int
    var headings: [IndexedHeading]
    var links: [IndexedLink]
}

/// One place that links to a document.
struct LinkReference: Hashable, Sendable {
    var source: String
    var line: Int
    var range: NSRange
}

/// An immutable view of a project's documents, headings, and links.
struct LinkIndexSnapshot: Sendable {
    var root: String?
    var documents: [String: IndexedDocument] = [:]
    /// Markdown paths, sorted.
    var markdownPaths: [String] = []
    /// Image paths, sorted.
    var imagePaths: [String] = []
    var resolver: WikiLinkResolver
    /// Links into each document, keyed by the target's path.
    var incoming: [String: [LinkReference]] = [:]
    /// Changes whenever files appear or disappear or a document's headings change.
    var structureVersion = 0

    init(root: String? = nil) {
        self.root = root
        resolver = WikiLinkResolver(root: root ?? "/", paths: [])
    }

    /// The Markdown file a wiki link target names.
    func resolve(_ target: String, from documentPath: String?) -> String? {
        resolver.resolve(target, from: documentPath)
    }
}

/// Builds link index snapshots off the main thread.
enum LinkIndexBuilder {
    static let maxDocuments = 20_000
    static let maxImages = 20_000
    static let maxFileSize = 2 << 20
    static let maxLinksPerDocument = 2_000
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "svg", "webp", "avif", "heic", "heif", "bmp", "tif", "tiff", "ico",
    ]

    static func isImage(path: String) -> Bool {
        imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Scans `root` (when `changed` is nil) or re-reads only `changed`, reusing unchanged entries.
    static func build(root: String, previous: LinkIndexSnapshot, changed: Set<String>?) -> LinkIndexSnapshot {
        var documents: [String: IndexedDocument] = [:]
        var images: Set<String> = []
        var headingsChanged = false
        let reuse = previous.root == root

        if let changed {
            documents = reuse ? previous.documents : [:]
            images = Set(reuse ? previous.imagePaths : [])
            for raw in changed {
                guard !Task.isCancelled else { return previous }
                let path = raw.standardizedPath
                guard path.hasPrefix(root + "/") else { continue }
                let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey])
                let exists = values?.isRegularFile == true && !FileScanner.isIgnored(path, root: root)
                if FileScanner.isMarkdown(path: path) {
                    if exists {
                        let document = read(path, modified: values?.contentModificationDate, size: values?.fileSize ?? 0)
                        if documents[path]?.headings != document.headings { headingsChanged = true }
                        if documents[path] == nil, documents.count >= maxDocuments { continue }
                        documents[path] = document
                    } else {
                        documents[path] = nil
                    }
                } else if isImage(path: path) {
                    if exists { images.insert(path) } else { images.remove(path) }
                }
            }
        } else {
            let (files, found) = enumerate(root)
            guard !Task.isCancelled else { return previous }
            images = found
            for (path, stamp) in files {
                guard !Task.isCancelled else { return previous }
                if reuse, let old = previous.documents[path], old.modified == stamp.modified, old.size == stamp.size {
                    documents[path] = old
                } else {
                    let document = read(path, modified: stamp.modified, size: stamp.size)
                    if previous.documents[path]?.headings != document.headings { headingsChanged = true }
                    documents[path] = document
                }
            }
        }

        var snapshot = LinkIndexSnapshot(root: root)
        snapshot.documents = documents
        snapshot.markdownPaths = documents.keys.sorted()
        snapshot.imagePaths = images.sorted()
        let pathsChanged = !reuse || snapshot.markdownPaths != previous.markdownPaths || snapshot.imagePaths != previous.imagePaths
        snapshot.resolver = pathsChanged || !reuse ? WikiLinkResolver(root: root, paths: snapshot.markdownPaths) : previous.resolver
        snapshot.incoming = incoming(documents, resolver: snapshot.resolver)
        snapshot.structureVersion = previous.structureVersion + (pathsChanged || headingsChanged ? 1 : 0)
        return snapshot
    }

    /// Reads one document's headings and links.
    static func read(_ path: String, modified: Date?, size: Int) -> IndexedDocument {
        guard size <= maxFileSize, let data = FileManager.default.contents(atPath: path) else {
            return IndexedDocument(modified: modified, size: size, headings: [], links: [])
        }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return document(text, path: path, modified: modified, size: size)
    }

    static func document(_ text: String, path: String, modified: Date? = nil, size: Int = 0) -> IndexedDocument {
        let structure = DocumentStructure.analyze(text)
        let folder = (path as NSString).deletingLastPathComponent
        var links: [IndexedLink] = []
        for link in structure.links {
            guard links.count < maxLinksPerDocument else { break }
            switch link.kind {
            case .wiki:
                guard let wiki = link.wiki, !wiki.target.isEmpty else { continue }
                links.append(IndexedLink(target: .wiki(wiki.target), line: link.line, range: link.range))
            case .link:
                guard case .file(let target, _) = LinkDestination(link.destination, folder: folder),
                      FileScanner.isMarkdown(path: target), target != path else { continue }
                links.append(IndexedLink(target: .path(target), line: link.line, range: link.range))
            case .image:
                continue
            }
        }
        let headings = structure.headings.map { IndexedHeading(slug: $0.slug, title: $0.title, level: $0.level, line: $0.line) }
        return IndexedDocument(modified: modified, size: size, headings: headings, links: links)
    }

    private static func incoming(_ documents: [String: IndexedDocument], resolver: WikiLinkResolver) -> [String: [LinkReference]] {
        var result: [String: [LinkReference]] = [:]
        for (source, document) in documents {
            for link in document.links {
                let target: String?
                switch link.target {
                case .path(let path): target = path
                case .wiki(let name): target = resolver.resolve(name, from: source)
                }
                guard let target, target != source, documents[target] != nil else { continue }
                result[target, default: []].append(LinkReference(source: source, line: link.line, range: link.range))
            }
        }
        for key in result.keys {
            result[key]?.sort { ($0.source, $0.line, $0.range.location) < ($1.source, $1.line, $1.range.location) }
        }
        return result
    }

    private struct Stamp {
        var modified: Date?
        var size: Int
    }

    /// Lists Markdown files and images under `root`, skipping the folders the sidebar skips.
    private static func enumerate(_ root: String) -> ([String: Stamp], Set<String>) {
        var files: [String: Stamp] = [:]
        var images: Set<String> = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root, isDirectory: true), includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return (files, images) }
        let library = FileManager.default.homeDirectoryForCurrentUser.path + "/Library"
        var budget = 400_000
        for case let url as URL in enumerator {
            budget -= 1
            guard budget > 0, !Task.isCancelled else { break }
            let path = url.path
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if path == library || FileScanner.isIgnored(path, root: root) { enumerator.skipDescendants() }
                continue
            }
            if FileScanner.isMarkdown(path: path) {
                guard files.count < maxDocuments else { continue }
                if values?.isSymbolicLink == true {
                    let target = url.resolvingSymlinksInPath()
                    let resolved = try? target.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey])
                    guard resolved?.isRegularFile == true else { continue }
                    files[path] = Stamp(modified: resolved?.contentModificationDate, size: resolved?.fileSize ?? 0)
                } else if values?.isRegularFile == true {
                    files[path] = Stamp(modified: values?.contentModificationDate, size: values?.fileSize ?? 0)
                }
            } else if isImage(path: path), images.count < maxImages {
                images.insert(path)
            }
        }
        return (files, images)
    }
}

/// Keeps a project's link index current, rebuilding off the main thread as files change.
@MainActor
@Observable
final class LinkIndex {
    @ObservationIgnored private(set) var snapshot = LinkIndexSnapshot()
    private(set) var isBuilding = false
    /// Called with the previous snapshot after each update.
    @ObservationIgnored var onUpdate: ((LinkIndexSnapshot) -> Void)?

    @ObservationIgnored private(set) var root: String?
    @ObservationIgnored private var needsFullScan = false
    @ObservationIgnored private var pendingPaths: Set<String> = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    /// Debounce before re-reading after a change, so bursts of file events coalesce.
    @ObservationIgnored var delay: Duration = .milliseconds(300)

    /// Starts indexing a new project folder, or rescans the current one.
    func setRoot(_ newRoot: String?) {
        guard newRoot != root else { refresh(); return }
        root = newRoot
        generation += 1
        task?.cancel()
        task = nil
        isBuilding = false
        pendingPaths = []
        let previous = snapshot
        snapshot = LinkIndexSnapshot(root: newRoot)
        snapshot.structureVersion = previous.structureVersion + 1
        onUpdate?(previous)
        guard newRoot != nil else { return }
        needsFullScan = true
        start(after: .zero)
    }

    /// Rescans the whole folder, reusing documents whose modification date is unchanged.
    func refresh() {
        guard root != nil else { return }
        needsFullScan = true
        start(after: delay)
    }

    /// Re-reads specific files (added, changed, or removed).
    func update(paths: some Sequence<String>) {
        guard root != nil else { return }
        pendingPaths.formUnion(paths)
        guard !pendingPaths.isEmpty else { return }
        start(after: delay)
    }

    /// Waits until pending work is done (used by tests).
    func waitUntilIdle() async {
        while task != nil { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func start(after delay: Duration) {
        guard task == nil else { return }
        let generation = generation
        isBuilding = true
        task = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            while true {
                guard let self, self.generation == generation, !Task.isCancelled,
                      let job = self.takeJob() else { break }
                let previous = self.snapshot
                let next = await runDetached(priority: .utility) {
                    LinkIndexBuilder.build(root: job.root, previous: previous, changed: job.paths)
                }
                guard self.generation == generation, !Task.isCancelled else { return }
                self.snapshot = next
                self.onUpdate?(previous)
            }
            guard let self, self.generation == generation else { return }
            self.task = nil
            self.isBuilding = false
        }
    }

    private func takeJob() -> (root: String, paths: Set<String>?)? {
        guard let root else { return nil }
        if needsFullScan {
            needsFullScan = false
            pendingPaths = []
            return (root, nil)
        }
        guard !pendingPaths.isEmpty else { return nil }
        defer { pendingPaths = [] }
        return (root, pendingPaths)
    }
}

/// Where a Markdown link destination points.
enum LinkDestination: Equatable {
    /// A web address or another scheme; never checked.
    case external
    /// A heading or anchor in the same document.
    case anchor(String)
    /// A local file, with an optional `#fragment`.
    case file(String, fragment: String?)
    /// Nothing to check (empty, or relative with no document folder).
    case none

    private static let scheme = try! NSRegularExpression(pattern: #"^[A-Za-z][A-Za-z0-9+.\-]*:"#)

    init(_ raw: String, folder: String?) {
        let destination = raw.trimmingCharacters(in: .whitespaces)
        let ns = destination as NSString
        guard !destination.isEmpty else { self = .none; return }
        if destination.hasPrefix("//") || Self.scheme.firstMatch(in: destination, range: NSRange(location: 0, length: ns.length)) != nil {
            self = .external
            return
        }
        var pathPart = destination
        var fragment: String?
        if let hash = destination.firstIndex(of: "#") {
            pathPart = String(destination[..<hash])
            let rawFragment = String(destination[destination.index(after: hash)...])
            fragment = rawFragment.removingPercentEncoding ?? rawFragment
        }
        if let query = pathPart.firstIndex(of: "?") { pathPart = String(pathPart[..<query]) }
        let path = pathPart.removingPercentEncoding ?? pathPart
        if path.isEmpty {
            if let fragment, !fragment.isEmpty, !destination.hasPrefix("?") { self = .anchor(fragment) } else { self = .none }
            return
        }
        if path.hasPrefix("/") {
            self = .file(path.standardizedPath, fragment: fragment?.isEmpty == true ? nil : fragment)
        } else if let folder {
            self = .file((folder as NSString).appendingPathComponent(path).standardizedPath, fragment: fragment?.isEmpty == true ? nil : fragment)
        } else {
            self = .none
        }
    }
}

/// Checks links in one document against the file system and the project index. Built on the
/// main thread, used off it while rendering and analyzing.
struct LinkContext: Sendable, MarkdownLinkRendering {
    var documentPath: String?
    var snapshot: LinkIndexSnapshot
    /// Whether the preview marks broken local links.
    var marksBrokenLinks = true
    /// The current document's text, for its own anchors.
    var source: String
    private var ownAnchors: Set<String>?

    init(documentPath: String?, source: String, snapshot: LinkIndexSnapshot, marksBrokenLinks: Bool = true, anchors: Set<String>? = nil) {
        self.documentPath = documentPath
        self.source = source
        self.snapshot = snapshot
        self.marksBrokenLinks = marksBrokenLinks
        ownAnchors = anchors
    }

    var folder: String? { documentPath.map { ($0 as NSString).deletingLastPathComponent } }

    /// The current document's anchors, computed once.
    mutating func anchors() -> Set<String> {
        if let ownAnchors { return ownAnchors }
        let anchors = DocumentStructure.analyze(source).anchors
        ownAnchors = anchors
        return anchors
    }

    /// Heading anchors of another document, or nil when they are unknown.
    private func anchors(of path: String) -> Set<String>? {
        snapshot.documents[path].map { Set($0.headings.map(\.slug)) }
    }

    /// Why a Markdown link destination is broken, or nil when it works or is not checked.
    mutating func problem(forDestination destination: String) -> String? {
        switch LinkDestination(destination, folder: folder) {
        case .external, .none:
            return nil
        case .anchor(let fragment):
            return anchors().contains(fragment) ? nil : "No heading “#\(fragment)” in this document"
        case .file(let path, let fragment):
            if path == documentPath {
                guard let fragment else { return nil }
                return anchors().contains(fragment) ? nil : "No heading “#\(fragment)” in this document"
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                return "File not found: \((path as NSString).lastPathComponent)"
            }
            if let fragment, !isDirectory.boolValue, FileScanner.isMarkdown(path: path),
               let anchors = anchors(of: path), !anchors.contains(fragment) {
                return "No heading “#\(fragment)” in \((path as NSString).lastPathComponent)"
            }
            return nil
        }
    }

    /// The document a wiki link opens: nil target means the current document.
    func resolve(_ link: WikiLink) -> (found: Bool, path: String?) {
        if link.target.isEmpty { return (documentPath != nil, documentPath) }
        let path = snapshot.resolve(link.target, from: documentPath)
        return (path != nil, path)
    }

    /// Why a wiki link is broken, or nil when it works.
    mutating func problem(for link: WikiLink) -> String? {
        let (found, path) = resolve(link)
        guard found, let path else { return "No document named “\(link.target)”" }
        guard let heading = link.heading else { return nil }
        let slug = HeadingSlugger.base(heading)
        let known = path == documentPath ? anchors() : anchors(of: path)
        guard let known, !known.contains(slug), !known.contains(heading) else { return nil }
        return "No heading “\(heading)” in \(path == documentPath ? "this document" : (path as NSString).lastPathComponent)"
    }

    /// The preview markup for the text of one Markdown text run, with wiki links as links.
    ///
    /// The text may hold math and footnote placeholders (see `MarkdownExtensions`); `restore`
    /// turns them back into source. A placeholder in a link's target means the brackets belong
    /// to math or a footnote, so it stays text. One in the label stays, so the math renders.
    mutating func html(forText text: String, restore: (String) -> String = { $0 }) -> String {
        let links = WikiLink.scan(text).filter { !MarkdownExtensions.containsToken($0.target) }
        guard !links.isEmpty else { return MarkdownHTML.escape(text) }
        let ns = text as NSString
        var out = ""
        var last = 0
        for var link in links {
            out += MarkdownHTML.escape(ns.substring(with: NSRange(location: last, length: link.range.location - last)))
            let label = link.label
            link.heading = link.heading.map(restore)
            out += html(for: link, label: label)
            last = NSMaxRange(link.range)
        }
        out += MarkdownHTML.escape(ns.substring(from: last))
        return out
    }

    private mutating func html(for link: WikiLink, label rawLabel: String) -> String {
        let label = MarkdownHTML.escape(rawLabel)
        let (found, path) = resolve(link)
        guard found, let path else {
            let title = MarkdownHTML.escape("No document named “\(link.target)”")
            return "<span class=\"lexmd-wiki lexmd-missing\" title=\"\(title)\">\(label)</span>"
        }
        var href = ""
        if path != documentPath || link.heading == nil, let folder {
            href = LinkPaths.encode(LinkPaths.relative(path, from: folder))
        }
        if let heading = link.heading {
            let known = path == documentPath ? anchors() : anchors(of: path)
            let slug = known?.contains(heading) == true ? heading : HeadingSlugger.base(heading)
            href += "#" + LinkPaths.encodeFragment(slug)
        }
        let broken = marksBrokenLinks && problem(for: link) != nil
        return "<a class=\"lexmd-wiki\(broken ? " lexmd-broken" : "")\" href=\"\(MarkdownHTML.escape(href))\">\(label)</a>"
    }

    /// The class attribute for a rendered Markdown link, marking it when broken.
    mutating func linkClass(forDestination destination: String) -> String {
        guard marksBrokenLinks, problem(forDestination: destination) != nil else { return "" }
        return " class=\"lexmd-broken\""
    }
}
