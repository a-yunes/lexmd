import Foundation
import SwiftUI

/// How a file differs from the last commit, reduced to what LexMD shows.
enum GitChangeKind: String, Sendable, CaseIterable {
    case modified, added, untracked, deleted, renamed, conflicted

    /// One letter, as in Xcode's project navigator.
    var letter: String {
        switch self {
        case .modified: "M"
        case .added, .untracked: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .conflicted: "C"
        }
    }

    var label: String {
        switch self {
        case .modified: "Modified"
        case .added: "Added"
        case .untracked: "New, not yet tracked"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .conflicted: "Conflicted"
        }
    }

    var color: Color {
        switch self {
        case .modified: .orange
        case .added, .untracked: .green
        case .deleted, .conflicted: .red
        case .renamed: .blue
        }
    }
}

/// One changed path in a repository, relative to the repository root.
struct GitFileChange: Sendable, Hashable, Identifiable {
    let path: String
    /// The previous path of a renamed or copied file.
    var originalPath: String?
    /// Porcelain status letters for the index and the working tree ("." when unchanged).
    var index: Character
    var worktree: Character
    var kind: GitChangeKind

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var isMarkdown: Bool { FileScanner.isMarkdown(path: path) }
    /// Paths a commit of this change has to include (both sides of a rename).
    var commitPaths: [String] { originalPath.map { [path, $0] } ?? [path] }
}

struct GitStatusSnapshot: Sendable, Equatable {
    /// The checked-out branch, or nil for a detached HEAD.
    var branch: String?
    /// The HEAD commit, or nil in a repository without commits.
    var head: String?
    var changes: [GitFileChange] = []

    var hasConflicts: Bool { changes.contains { $0.kind == .conflicted } }
}

/// Parses `git status --porcelain=v2 -z --branch`.
enum GitStatusParser {
    static func parse(_ data: Data) -> GitStatusSnapshot {
        var snapshot = GitStatusSnapshot()
        let records = data.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard let type = record.first else { continue }
            switch type {
            case "#":
                let parts = record.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count == 3 else { continue }
                switch parts[1] {
                case "branch.oid": snapshot.head = parts[2] == "(initial)" ? nil : parts[2]
                case "branch.head": snapshot.branch = parts[2] == "(detached)" ? nil : parts[2]
                default: break
                }
            case "1":
                guard let (xy, path) = fields(record, count: 8) else { continue }
                snapshot.changes.append(change(path: path, xy: xy, original: nil))
            case "2":
                guard let (xy, path) = fields(record, count: 9) else { continue }
                let original = index < records.count ? records[index] : nil
                index += 1
                snapshot.changes.append(change(path: path, xy: xy, original: original))
            case "u":
                guard let (xy, path) = fields(record, count: 10) else { continue }
                snapshot.changes.append(GitFileChange(
                    path: path, index: xy.first ?? "U", worktree: xy.last ?? "U", kind: .conflicted))
            case "?":
                let path = String(record.dropFirst(2))
                // Nested repositories show up as untracked folders; they get their own status.
                guard !path.isEmpty, !path.hasSuffix("/") else { continue }
                snapshot.changes.append(GitFileChange(path: path, index: "?", worktree: "?", kind: .untracked))
            default:
                continue
            }
        }
        return snapshot
    }

    /// Splits off `count` space-separated fields; the rest of the record is the path, which may
    /// itself contain spaces.
    private static func fields(_ record: String, count: Int) -> (xy: String, path: String)? {
        let parts = record.split(separator: " ", maxSplits: count, omittingEmptySubsequences: false)
        guard parts.count == count + 1, parts[1].count == 2 else { return nil }
        return (String(parts[1]), String(parts[count]))
    }

    private static func change(path: String, xy: String, original: String?) -> GitFileChange {
        let x = xy.first ?? "."
        let y = xy.last ?? "."
        let kind: GitChangeKind
        if x == "D" || y == "D" {
            kind = .deleted
        } else if x == "A" {
            kind = .added
        } else if original != nil, x == "R" || y == "R" {
            kind = .renamed
        } else if original != nil, x == "C" {
            kind = .added
        } else {
            kind = .modified
        }
        return GitFileChange(path: path, originalPath: original, index: x, worktree: y, kind: kind)
    }
}

struct GitRepository: Sendable, Hashable, Identifiable {
    /// Absolute, symlink-resolved path of the working tree root.
    let root: String

    var id: String { root }
    var name: String { (root as NSString).lastPathComponent }

    func contains(_ path: String) -> Bool { path == root || path.hasPrefix(root + "/") }
}

enum GitDiscovery {
    static let maximumRepositories = 64

    /// Repositories relevant to a project: the one containing the project folder, plus any
    /// nested repositories among `folders` (absolute folder paths inside the project).
    static func repositories(git: Git, projectRoot: String, folders: [String]) -> [GitRepository] {
        var result: [GitRepository] = []
        if let top = toplevel(git: git, directory: projectRoot) {
            result.append(GitRepository(root: top))
        }
        let manager = FileManager.default
        for folder in folders.sorted() where folder != projectRoot {
            guard !Task.isCancelled, result.count < maximumRepositories else { break }
            guard manager.fileExists(atPath: folder + "/.git") else { continue }
            let resolved = FileScanner.canonicalPath(folder)
            guard !result.contains(where: { $0.root == resolved }),
                  toplevel(git: git, directory: folder) == resolved else { continue }
            result.append(GitRepository(root: resolved))
        }
        return result
    }

    static func toplevel(git: Git, directory: String) -> String? {
        let result = git.run(["rev-parse", "--show-toplevel"], in: directory, timeout: 10)
        let path = result.trimmed
        guard result.succeeded, !path.isEmpty else { return nil }
        return FileScanner.canonicalPath(path)
    }

    /// The status of `repository`, limited to `projectRoot` when the repository encloses it.
    static func status(git: Git, repository: GitRepository, projectRoot: String, timeout: TimeInterval = 30) -> GitStatusSnapshot? {
        var arguments = [
            "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all", "--ignore-submodules=all",
        ]
        var directory = repository.root
        if projectRoot.hasPrefix(repository.root + "/") {
            directory = projectRoot
            arguments += ["--", "."]
        }
        let result = git.run(arguments, in: directory, timeout: timeout)
        guard result.succeeded, !result.truncated else { return nil }
        return GitStatusParser.parse(result.output)
    }

    /// Sidebar decorations: a badge per changed file and the folders that contain changed
    /// Markdown files, all as absolute paths inside `projectRoot`.
    static func decorations(
        snapshots: [(GitRepository, GitStatusSnapshot)], projectRoot: String
    ) -> (badges: [String: GitChangeKind], folders: Set<String>) {
        var badges: [String: GitChangeKind] = [:]
        var folders: Set<String> = []
        // Outer repositories first, so nested repositories override what they contain.
        for (repository, snapshot) in snapshots.sorted(by: { $0.0.root.count < $1.0.root.count }) {
            for change in snapshot.changes {
                let path = repository.root + "/" + change.path
                guard path.hasPrefix(projectRoot + "/") else { continue }
                badges[path] = change.kind
                guard change.isMarkdown else { continue }
                var folder = (path as NSString).deletingLastPathComponent
                while folder.hasPrefix(projectRoot + "/"), folders.insert(folder).inserted {
                    folder = (folder as NSString).deletingLastPathComponent
                }
            }
        }
        return (badges, folders)
    }
}
