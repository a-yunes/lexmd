import Foundation

/// The author a commit will be made as.
struct GitIdentity: Sendable, Equatable {
    var name: String
    var email: String
    /// False when git guessed the identity from the Mac account instead of its configuration.
    var isConfigured: Bool

    /// Parses `git var GIT_AUTHOR_IDENT` output: "Name <email> 1700000000 +0100".
    static func parse(_ ident: String) -> (name: String, email: String)? {
        let line = ident.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let close = line.range(of: ">", options: .backwards),
              let open = line.range(of: "<", options: .backwards, range: line.startIndex..<close.lowerBound)
        else { return nil }
        let name = line[..<open.lowerBound].trimmingCharacters(in: .whitespaces)
        let email = line[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
        return (name, email)
    }
}

/// A unified diff prepared for display.
struct GitDiff: Sendable, Equatable {
    var lines: [String] = []
    var isBinary = false
    var note: String?
}

/// Local repository operations used by the commit sheet. Nothing here contacts a remote.
enum GitOperations {
    static let diffLineLimit = 4000
    static let diffByteLimit = 1 << 20

    /// The identity git resolves for commits in `repository`, or nil when git cannot resolve one.
    static func identity(git: Git, repository: String) -> GitIdentity? {
        let ident = git.run(["var", "GIT_AUTHOR_IDENT"], in: repository, timeout: 10)
        guard ident.succeeded, let parsed = GitIdentity.parse(ident.text), !parsed.email.isEmpty else { return nil }
        let env = git.processEnvironment
        func configured(_ keys: [String], _ variable: String) -> Bool {
            if let value = env[variable], !value.isEmpty { return true }
            return keys.contains { git.run(["config", "--get", $0], in: repository, timeout: 10).succeeded }
        }
        let isConfigured = configured(["user.name", "author.name"], "GIT_AUTHOR_NAME")
            && configured(["user.email", "author.email"], "GIT_AUTHOR_EMAIL")
        return GitIdentity(name: parsed.name, email: parsed.email, isConfigured: isConfigured)
    }

    /// Sets the commit identity for this repository only.
    static func setIdentity(git: Git, repository: String, name: String, email: String) -> String? {
        for (key, value) in [("user.name", name), ("user.email", email)] {
            let result = git.run(["config", "--local", key, value], in: repository, timeout: 10)
            if !result.succeeded { return result.message }
        }
        return nil
    }

    /// Describes an operation that blocks a partial commit, such as an unfinished merge.
    static func operationInProgress(git: Git, repository: String) -> String? {
        let result = git.run(["rev-parse", "--absolute-git-dir"], in: repository, timeout: 10)
        guard result.succeeded else { return nil }
        let dir = result.trimmed
        let manager = FileManager.default
        let checks = [
            ("MERGE_HEAD", "A merge"), ("rebase-merge", "A rebase"), ("rebase-apply", "A rebase"),
            ("CHERRY_PICK_HEAD", "A cherry-pick"), ("REVERT_HEAD", "A revert"),
        ]
        return checks.first { manager.fileExists(atPath: dir + "/" + $0.0) }?.1
    }

    /// The working tree's changes to `change` since the last commit.
    static func diff(git: Git, repository: String, change: GitFileChange, hasHead: Bool) -> GitDiff {
        let options = ["--no-color", "--no-ext-diff", "--no-textconv"]
        var arguments: [String]
        if change.kind == .untracked || (!hasHead && change.kind != .deleted) {
            arguments = ["diff", "--no-index"] + options + ["--", "/dev/null", change.path]
        } else if hasHead {
            arguments = ["diff", "HEAD", "-M"] + options + ["--"] + change.commitPaths
        } else {
            return GitDiff(note: "Deleted")
        }
        let result = git.run(arguments, in: repository, timeout: 20, outputLimit: diffByteLimit)
        // `--no-index` exits with 1 when the files differ.
        guard result.status == 0 || result.status == 1, !result.timedOut else {
            return GitDiff(note: result.cancelled ? nil : result.message)
        }
        return prepare(result.output, truncated: result.truncated)
    }

    static func prepare(_ data: Data, truncated: Bool) -> GitDiff {
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        if lines.contains(where: { $0.hasPrefix("Binary files ") || $0 == "GIT binary patch" }) {
            return GitDiff(isBinary: true, note: "Binary file")
        }
        var diff = GitDiff(lines: lines)
        if lines.count > diffLineLimit {
            diff.lines = Array(lines.prefix(diffLineLimit))
            diff.note = "Diff truncated. Showing the first \(diffLineLimit.formatted()) lines."
        } else if truncated {
            if !diff.lines.isEmpty { diff.lines.removeLast() }
            diff.note = "Diff truncated. Showing the first \(diff.lines.count.formatted()) lines."
        }
        return diff
    }

    /// Builds a commit message from a summary line and an optional description.
    static func message(summary: String, description: String) -> String {
        let title = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = description.replacingOccurrences(of: "\r\n", with: "\n")
        while body.hasPrefix("\n") { body.removeFirst() }
        while let last = body.last, last.isWhitespace { body.removeLast() }
        return body.isEmpty ? title + "\n" : title + "\n\n" + body + "\n"
    }

    enum CommitError: Error, Equatable {
        case failed(String)

        var message: String {
            switch self { case .failed(let text): text }
        }
    }

    /// Commits exactly `changes` as they are on disk. Other staged changes stay staged and are
    /// not committed. Untracked files are added first and unstaged again if the commit fails.
    /// Returns the new commit's short hash.
    static func commit(git: Git, repository: String, changes: [GitFileChange], message: String) -> Result<String, CommitError> {
        guard !changes.isEmpty else { return .failure(.failed("Choose at least one file to commit.")) }
        let untracked = changes.filter { $0.kind == .untracked }.map(\.path)
        if !untracked.isEmpty {
            let add = git.run(["add", "--"] + untracked, in: repository, timeout: 120)
            guard add.succeeded else { return .failure(.failed(add.message)) }
        }
        var seen = Set<String>()
        let paths = changes.flatMap(\.commitPaths).filter { seen.insert($0).inserted }
        let commit = git.run(
            ["commit", "--only", "--cleanup=verbatim", "-F", "-", "--"] + paths,
            in: repository, input: Data(message.utf8), timeout: 600
        )
        guard commit.succeeded else {
            if !untracked.isEmpty {
                _ = git.run(["rm", "--cached", "--quiet", "--ignore-unmatch", "--"] + untracked, in: repository, timeout: 60)
            }
            return .failure(.failed(commit.message))
        }
        let hash = git.run(["rev-parse", "--short", "HEAD"], in: repository, timeout: 10)
        return .success(hash.succeeded ? hash.trimmed : "")
    }
}
