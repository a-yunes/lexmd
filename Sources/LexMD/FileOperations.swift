import AppKit
import Foundation

/// File system work behind the sidebar's file commands. Nothing here deletes permanently.
enum FileOperations {
    enum RenameCheck: Equatable {
        case unchanged
        /// `leavesSidebar` is true when a Markdown file gets a non-Markdown extension.
        case valid(name: String, leavesSidebar: Bool)
        case invalid(String)
    }

    /// Why a name can't be used, or nil when it is fine.
    static func problem(with name: String) -> String? {
        if name.isEmpty { return "Enter a name." }
        if name == "." || name == ".." { return "“\(name)” is reserved. Choose another name." }
        if name.contains("/") || name.contains(":") { return "Names can’t contain “/” or “:”." }
        if name.hasPrefix(".") { return "Names that begin with a dot are hidden. Choose another name." }
        if name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) {
            return "Names can’t contain line breaks or control characters."
        }
        if name.utf8.count > 255 { return "The name is too long." }
        return nil
    }

    /// The name to use: a file keeps its extension unless the new name has one of its own.
    static func finalName(_ proposed: String, original: String, isDirectory: Bool) -> String {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isDirectory else { return trimmed }
        let originalExtension = (original as NSString).pathExtension
        guard !originalExtension.isEmpty, !hasExtension(trimmed) else { return trimmed }
        return trimmed + "." + originalExtension
    }

    /// A short run of letters and digits after the last dot counts as an extension; "v1.2 notes" has none.
    static func hasExtension(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, ext.count <= 12, (name as NSString).deletingPathExtension.count > 0 else { return false }
        return ext.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }

    static func checkRename(_ item: URL, isDirectory: Bool, to proposed: String) -> RenameCheck {
        let original = item.lastPathComponent
        let name = finalName(proposed, original: original, isDirectory: isDirectory)
        if let problem = problem(with: name) { return .invalid(problem) }
        if name == original { return .unchanged }
        let destination = item.deletingLastPathComponent().appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path), !isSameItem(item, destination) {
            return .invalid("An item named “\(name)” already exists in “\(item.deletingLastPathComponent().lastPathComponent)”.")
        }
        let leaves = !isDirectory && FileScanner.isMarkdown(path: original) && !FileScanner.isMarkdown(path: name)
        return .valid(name: name, leavesSidebar: leaves)
    }

    /// True when both URLs name the same file, as with a case-only rename on a case-insensitive volume.
    static func isSameItem(_ a: URL, _ b: URL) -> Bool {
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let first = try? URL(fileURLWithPath: a.path).resourceValues(forKeys: key).fileResourceIdentifier,
              let second = try? URL(fileURLWithPath: b.path).resourceValues(forKeys: key).fileResourceIdentifier
        else { return false }
        return first.isEqual(second)
    }

    /// Why `source` can't move into `folder`, or nil when it can.
    static func moveProblem(_ source: String, into folder: String) -> String? {
        if folder == source || folder.hasPrefix(source + "/") { return "A folder can’t be moved into itself." }
        let name = (source as NSString).lastPathComponent
        let destination = (folder as NSString).appendingPathComponent(name)
        if (source as NSString).deletingLastPathComponent == folder { return nil }
        if FileManager.default.fileExists(atPath: destination) {
            return "An item named “\(name)” already exists in “\((folder as NSString).lastPathComponent)”."
        }
        return nil
    }

    /// Renames or moves without ever replacing an existing item. Case-only renames work on
    /// case-insensitive volumes.
    static func move(_ source: URL, to destination: URL) throws {
        let result = source.path.withCString { from in
            destination.path.withCString { to in renamex_np(from, to, UInt32(RENAME_EXCL)) }
        }
        guard result != 0 else { return }
        let code = errno
        if code == EEXIST, isSameItem(source, destination) {
            // Same file under a differently cased name: go through a temporary name.
            let temporary = source.deletingLastPathComponent().appendingPathComponent(".lexmd-rename-\(UUID().uuidString)")
            try posix { renamex_np(source.path, temporary.path, UInt32(RENAME_EXCL)) }
            do {
                try posix { renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) }
            } catch {
                _ = rename(temporary.path, source.path)
                throw error
            }
            return
        }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    private static func posix(_ call: () -> Int32) throws {
        if call() != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// "Untitled.md", then "Untitled 2.md", and so on.
    static func uniqueURL(in folder: URL, base: String, extension ext: String) -> URL {
        let suffix = ext.isEmpty ? "" : "." + ext
        var url = folder.appendingPathComponent(base + suffix)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(counter)\(suffix)")
            counter += 1
        }
        return url
    }

    static func createFile(in folder: URL) throws -> URL {
        let url = uniqueURL(in: folder, base: "Untitled", extension: "md")
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return url
    }

    static func createFolder(in folder: URL) throws -> URL {
        let url = uniqueURL(in: folder, base: "untitled folder", extension: "")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// Finder-style copy names: "Notes copy.md", "Notes copy 2.md", ...
    static func duplicateName(for name: String, isDirectory: Bool, exists: (String) -> Bool) -> String {
        var base = name
        var suffix = ""
        if !isDirectory, hasExtension(name) {
            base = (name as NSString).deletingPathExtension
            suffix = "." + (name as NSString).pathExtension
        }
        // Copying a copy continues its numbering instead of adding another " copy".
        if let range = base.range(of: #" copy( \d+)?$"#, options: .regularExpression) {
            base = String(base[..<range.lowerBound])
        }
        var candidate = "\(base) copy\(suffix)"
        var counter = 2
        while exists(candidate) {
            candidate = "\(base) copy \(counter)\(suffix)"
            counter += 1
        }
        return candidate
    }

    static func duplicate(_ url: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let folder = url.deletingLastPathComponent()
        let name = duplicateName(for: url.lastPathComponent, isDirectory: isDirectory.boolValue) {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        let destination = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    /// Moves items to the Trash and returns their new locations. Injected so tests never touch the Trash.
    typealias Recycler = @Sendable ([URL]) async throws -> [URL: URL]

    static let systemRecycler: Recycler = { urls in
        try await NSWorkspace.shared.recycle(urls)
    }

    /// Moves one item to the Trash. Returns where it went, when the system reports it.
    static func moveToTrash(_ url: URL, using recycler: Recycler) async throws -> URL? {
        let result = try await recycler([url])
        return result[url] ?? result.values.first
    }
}

/// In-place edits of the sidebar tree, so it updates at once after a file operation.
enum FileTreeEdit {
    static func node(at path: String, in nodes: [FileNode]) -> FileNode? {
        for node in nodes {
            if node.id == path { return node }
            if let children = node.children, path.hasPrefix(node.id + "/"), let found = Self.node(at: path, in: children) {
                return found
            }
        }
        return nil
    }

    /// Removes an item; folders left without documents go too, unless listed in `keep`.
    static func removing(_ path: String, from nodes: [FileNode], keep: Set<String> = []) -> [FileNode] {
        nodes.compactMap { node in
            if node.id == path { return nil }
            guard let children = node.children, path.hasPrefix(node.id + "/") else { return node }
            var copy = node
            copy.children = removing(path, from: children, keep: keep)
            if copy.children?.isEmpty == true, !keep.contains(node.id) { return nil }
            return copy
        }
    }

    /// Inserts a node into `parent`, creating folder nodes on the way when needed.
    static func inserting(_ node: FileNode, into nodes: [FileNode], parent: String, root: String) -> [FileNode] {
        if parent == root {
            return sorted(nodes.filter { $0.id != node.id } + [node])
        }
        guard parent.hasPrefix(root + "/") else { return nodes }
        let relative = parent.dropFirst(root.count + 1)
        guard let first = relative.split(separator: "/").first else { return nodes }
        let childPath = root + "/" + first
        var result = nodes
        if let index = result.firstIndex(where: { $0.id == childPath && $0.children != nil }) {
            var folder = result[index]
            folder.children = inserting(node, into: folder.children ?? [], parent: parent, root: childPath)
            result[index] = folder
            return result
        }
        let folder = FileNode(
            url: URL(fileURLWithPath: childPath, isDirectory: true), name: String(first),
            children: inserting(node, into: [], parent: parent, root: childPath)
        )
        return sorted(result + [folder])
    }

    /// The same node at a new path, with its children moved along.
    static func rebased(_ node: FileNode, to path: String) -> FileNode {
        let isFolder = node.children != nil
        return FileNode(
            url: URL(fileURLWithPath: path, isDirectory: isFolder),
            name: (path as NSString).lastPathComponent,
            children: node.children?.map { rebased($0, to: path + "/" + $0.name) }
        )
    }

    static func moving(_ nodes: [FileNode], move: PathMove, root: String, keep: Set<String> = []) -> [FileNode] {
        guard let node = node(at: move.from, in: nodes) else { return nodes }
        let removed = removing(move.from, from: nodes, keep: keep)
        let parent = (move.to as NSString).deletingLastPathComponent
        return inserting(rebased(node, to: move.to), into: removed, parent: parent, root: root)
    }

    /// Adds empty folders the user just created, which the scanner leaves out.
    static func addingFolders(_ folders: Set<String>, to nodes: [FileNode], root: String) -> [FileNode] {
        var result = nodes
        for folder in folders.sorted() where node(at: folder, in: result) == nil {
            let empty = FileNode(url: URL(fileURLWithPath: folder, isDirectory: true), name: (folder as NSString).lastPathComponent, children: [])
            result = inserting(empty, into: result, parent: (folder as NSString).deletingLastPathComponent, root: root)
        }
        return result
    }

    static func sorted(_ nodes: [FileNode]) -> [FileNode] {
        let folders = nodes.filter { $0.children != nil }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let files = nodes.filter { $0.children == nil }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return folders + files
    }

    static func containsMarkdown(_ node: FileNode) -> Bool {
        guard let children = node.children else { return FileScanner.isMarkdown(path: node.name) }
        return children.contains(where: containsMarkdown)
    }
}
