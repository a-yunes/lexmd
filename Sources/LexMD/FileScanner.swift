import CoreServices
import Foundation
import UniformTypeIdentifiers

struct FileNode: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    var children: [FileNode]?
    /// Names of single-item folders merged into this row when compacting the tree.
    var parents: [String] = []

    var id: String { url.path }
    var displayName: String { (name as NSString).deletingPathExtension }
    /// Text used for filtering: merged folder names plus the item's own name.
    var searchLabel: String { (parents + [name]).joined(separator: "/") }
}

struct TreeRow: Identifiable {
    let node: FileNode
    let depth: Int
    /// Whether a folder row shows its children.
    var isExpanded = false
    var id: String { node.id }
}

enum FileScanner {
    static let markdownExtensions: [String] = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext", "mdx"]
    private static let extensionSet = Set(markdownExtensions)

    /// Heavy or generated directories that never hold documents worth browsing.
    private static let skippedDirectories: Set<String> = [
        "node_modules", "bower_components", "Pods", "Carthage", "DerivedData",
        "__pycache__", "venv", "site-packages", "vendor", "target",
    ]

    /// Resolves symlinks (including /tmp → /private/tmp) so paths compare reliably.
    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func isMarkdown(path: String) -> Bool {
        extensionSet.contains((path as NSString).pathExtension.lowercased())
    }

    /// Documents that open in a viewer without running code: images, media, PDFs, and plain text.
    /// Apps, scripts, executables, folders, and unknown types are excluded.
    static func opensWithoutRunningCode(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey, .isExecutableKey]),
              values.isRegularFile == true, values.isExecutable != true, let type = values.contentType,
              !type.conforms(to: .script), !type.conforms(to: .executable) else { return false }
        let safe: [UTType] = [.image, .audiovisualContent, .pdf, .plainText, .rtf, .json, .commaSeparatedText]
        return safe.contains { type.conforms(to: $0) }
    }

    static func isIgnored(_ path: String, root: String) -> Bool {
        guard path.hasPrefix(root) else { return true }
        let relative = path.dropFirst(root.count)
        for component in relative.split(separator: "/") {
            if component.hasPrefix(".") || skippedDirectories.contains(String(component)) { return true }
        }
        return false
    }

    static func scan(_ root: URL) -> [FileNode] {
        var budget = 400_000
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return scanDirectory(root, depth: 0, budget: &budget, home: home)
    }

    private static func scanDirectory(_ dir: URL, depth: Int, budget: inout Int, home: String) -> [FileNode] {
        guard depth < 32, budget > 0, !Task.isCancelled else { return [] }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        budget -= items.count

        var folders: [FileNode] = []
        var files: [FileNode] = []
        for item in items {
            let name = item.lastPathComponent
            let values = try? item.resourceValues(forKeys: Set(keys))
            // Passing isDirectory avoids a file system check per directory entry.
            let url = URL(fileURLWithPath: item.path, isDirectory: values?.isDirectory == true)
            if values?.isSymbolicLink == true {
                // Follow symlinked documents, but never symlinked folders (avoids cycles).
                var isDir: ObjCBool = false
                if isMarkdown(path: name),
                   FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir), !isDir.boolValue {
                    files.append(FileNode(url: url, name: name, children: nil))
                }
                continue
            }
            if values?.isDirectory == true {
                if values?.isPackage == true || skippedDirectories.contains(name) { continue }
                if dir.path == home, name == "Library" { continue }
                let children = scanDirectory(item, depth: depth + 1, budget: &budget, home: home)
                if !children.isEmpty {
                    folders.append(FileNode(url: url, name: name, children: children))
                }
            } else if isMarkdown(path: name) {
                files.append(FileNode(url: url, name: name, children: nil))
            }
        }
        folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        files.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return folders + files
    }

    static func searchableFiles(in nodes: [FileNode], root: String) -> [SearchableFile] {
        var files: [SearchableFile] = []
        func walk(_ list: [FileNode]) {
            for node in list {
                if let children = node.children {
                    walk(children)
                } else {
                    let dir = (node.id as NSString).deletingLastPathComponent
                    let folder = dir.hasPrefix(root) ? String(dir.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : dir
                    files.append(SearchableFile(path: node.id, name: node.name, folder: folder))
                }
            }
        }
        walk(nodes)
        return files
    }

    static func folderIDs(in nodes: [FileNode]) -> [String] {
        var ids: [String] = []
        func walk(_ list: [FileNode]) {
            for node in list {
                guard let children = node.children else { continue }
                ids.append(node.id)
                walk(children)
            }
        }
        walk(nodes)
        return ids
    }

    /// Keeps the files whose names (with merged folder names) contain `query`, and the folders
    /// holding them. With `cancellable`, a cancelled task stops early with partial results.
    static func filter(_ nodes: [FileNode], query: String, cancellable: Bool = false) -> [FileNode] {
        if cancellable, Task.isCancelled { return [] }
        return nodes.compactMap { node in
            if let children = node.children {
                let kept = filter(children, query: query, cancellable: cancellable)
                guard !kept.isEmpty else { return nil }
                var copy = node
                copy.children = kept
                return copy
            }
            let label = node.parents.isEmpty ? node.name : node.searchLabel
            return label.localizedStandardContains(query) ? node : nil
        }
    }

    /// The tree flattened into sidebar rows. A non-empty `query` filters the tree and shows
    /// every folder expanded; otherwise folders in `expanded` show their children.
    static func rows(_ nodes: [FileNode], query: String, expanded: Set<String>, cancellable: Bool = false) -> [TreeRow] {
        let filtering = !query.isEmpty
        var rows: [TreeRow] = []
        func walk(_ nodes: [FileNode], depth: Int) {
            for node in nodes {
                let open = node.children != nil && (filtering || expanded.contains(node.id))
                rows.append(TreeRow(node: node, depth: depth, isExpanded: open))
                if open, let children = node.children { walk(children, depth: depth + 1) }
            }
        }
        walk(filtering ? filter(nodes, query: query, cancellable: cancellable) : nodes, depth: 0)
        return rows
    }

    static func fileCount(in nodes: [FileNode]) -> Int {
        nodes.reduce(0) { count, node in count + (node.children.map(fileCount) ?? 1) }
    }

    /// Paths of the files and folders in a tree.
    static func paths(in nodes: [FileNode]) -> (files: Set<String>, folders: Set<String>) {
        var files: Set<String> = []
        var folders: Set<String> = []
        func walk(_ list: [FileNode]) {
            for node in list {
                if let children = node.children {
                    folders.insert(node.id)
                    walk(children)
                } else {
                    files.insert(node.id)
                }
            }
        }
        walk(nodes)
        return (files, folders)
    }

    /// Flags that may mean an item appeared, disappeared, or moved.
    static let structuralFlags = kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
        | kFSEventStreamEventFlagItemRenamed
    private static let libraryPath = FileManager.default.homeDirectoryForCurrentUser.path + "/Library"

    /// Whether `path` is in ~/Library, whose caches change constantly. Like the scan, the
    /// project skips it unless the project itself is inside it, as an iCloud Drive folder is.
    static func isInSkippedLibrary(_ path: String, root: String) -> Bool {
        let inside = { (p: String) in p == libraryPath || p.hasPrefix(libraryPath + "/") }
        return inside(path) && !inside(root)
    }

    /// A file system event's path as the tree spells it (FSEvents adds a slash to some folders),
    /// or nil for an event the project skips. Every consumer of the project's events uses this.
    static func eventPath(_ raw: String, root: String) -> String? {
        let path = raw.count > 1 && raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        guard !isIgnored(path, root: root), !isInSkippedLibrary(path, root: root) else { return nil }
        return path
    }
    /// Flags that mean the stream lost track of individual changes.
    static let rescanFlags = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged

    /// Whether a file system event can change the scanned tree. FSEvents combines the flags of
    /// changes to the same item, and atomic saves rename files over themselves, so a save can
    /// carry created or renamed flags; a Markdown file therefore counts only when its presence
    /// on disk differs from the tree. A new folder starts empty (files created in it report
    /// their own events); a folder moved in, or one in the tree that disappeared, counts.
    /// `paths` is called only for events that need it.
    static func eventChangesTree(
        path: String, flags: FSEventStreamEventFlags, root: String,
        paths: () -> (files: Set<String>, folders: Set<String>),
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        guard let path = eventPath(path, root: root) else { return false }
        let flags = Int(flags)
        if flags & rescanFlags != 0 { return true }
        guard flags & structuralFlags != 0 else { return false }
        if flags & kFSEventStreamEventFlagItemIsDir != 0 {
            if flags & kFSEventStreamEventFlagItemRenamed != 0 { return true }
            return paths().folders.contains(path) && !exists(path)
        }
        guard isMarkdown(path: path) else { return false }
        return paths().files.contains(path) != exists(path)
    }

    /// Merges folders that hold a single item into that item, so `docs/guide/README.md`
    /// alone in its folders shows as one row: `docs › guide › README`.
    static func compact(_ nodes: [FileNode]) -> [FileNode] {
        nodes.map { node in
            guard let children = node.children else { return node }
            let kept = compact(children)
            if kept.count == 1 {
                var only = kept[0]
                only.parents = [node.name] + only.parents
                return only
            }
            var copy = node
            copy.children = kept
            return copy
        }
    }
}

/// What happened to a watched project folder whose path changed.
enum ProjectFolderChange: Equatable {
    /// Still at the same path; only something around it changed.
    case unchanged
    case moved(to: String)
    case trashed(at: String)
    case removed

    /// Classifies the folder's current location, or nil when the folder no longer exists.
    init(original: String, current: String?) {
        guard let current else { self = .removed; return }
        if current == original {
            self = .unchanged
        } else if current.split(separator: "/").contains(where: { $0 == ".Trash" || $0 == ".Trashes" }) {
            self = .trashed(at: current)
        } else {
            self = .moved(to: current)
        }
    }
}

/// Thin wrapper around an FSEvents stream delivering events on the main queue. The stream
/// also reports changes to the watched folder itself (kFSEventStreamEventFlagRootChanged),
/// and `folderLocation()` follows the folder when it is renamed or moved.
final class DirectoryWatcher {
    struct Event {
        let path: String
        let flags: FSEventStreamEventFlags
    }

    private var stream: FSEventStreamRef?
    private let handler: ([Event]) -> Void
    /// An event-only descriptor for the watched folder, which follows it when it moves.
    private let folder: Int32

    init?(path: String, handler: @escaping ([Event]) -> Void) {
        self.handler = handler
        folder = open(path, O_EVTONLY)
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var events: [Event] = []
            events.reserveCapacity(count)
            for i in 0..<min(count, list.count) {
                events.append(Event(path: list[i], flags: flags[i]))
            }
            watcher.handler(events)
        }
        let createFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, createFlags
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        if folder >= 0 { close(folder) }
    }

    /// The watched folder's current path, or nil when it was deleted.
    func folderLocation() -> String? {
        guard folder >= 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var opened = stat()
        guard fcntl(folder, F_GETPATH, &buffer) != -1, fstat(folder, &opened) == 0 else { return nil }
        let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        // A deleted folder can still report its last path; make sure the path leads to this folder.
        var found = stat()
        guard stat(path, &found) == 0, found.st_ino == opened.st_ino, found.st_dev == opened.st_dev else { return nil }
        return path
    }
}
