import CoreServices
import Foundation
import Testing
@testable import LexMD

/// Git isolated from the user's global and system configuration.
private let isolatedGit: Git? = Git.system.map {
    Git(executable: $0.executable, environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
}

/// A temporary repository with a repo-local identity.
private final class TestRepo {
    let folder: TestFolder
    let git: Git
    let root: String

    init(identity: Bool = true, path: String? = nil) throws {
        folder = try TestFolder()
        git = try #require(isolatedGit)
        var dir = FileScanner.canonicalPath(folder.url.path)
        if let path {
            dir += "/" + path
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        root = dir
        try run("init", "-q", "-b", "main")
        try run("config", "commit.gpgsign", "false")
        if identity {
            try run("config", "user.name", "Test Writer")
            try run("config", "user.email", "writer@example.com")
        } else {
            try run("config", "user.useConfigOnly", "true")
        }
    }

    @discardableResult
    func run(_ arguments: String..., input: String? = nil) throws -> GitResult {
        let result = git.run(arguments, in: root, input: input.map { Data($0.utf8) })
        guard result.succeeded else {
            Issue.record("git \(arguments.joined(separator: " ")) failed: \(result.message)")
            throw TimedOut()
        }
        return result
    }

    func lines(_ arguments: String...) -> [String] {
        git.run(arguments, in: root).text.split(separator: "\n").map(String.init)
    }

    @discardableResult
    func write(_ path: String, _ text: String) throws -> String {
        let full = root + "/" + path
        try FileManager.default.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: full, atomically: false, encoding: .utf8)
        return full
    }

    func status() throws -> GitStatusSnapshot {
        try #require(GitDiscovery.status(git: git, repository: GitRepository(root: root), projectRoot: root))
    }

    func change(_ path: String) throws -> GitFileChange {
        try #require(status().changes.first { $0.path == path })
    }
}

// MARK: - Parsing without git

struct GitParsingTests {
    private func porcelain(_ records: [String]) -> Data {
        Data(records.map { $0 + "\0" }.joined().utf8)
    }

    @Test func parsesEveryEntryKind() {
        let hash = String(repeating: "a", count: 40)
        let data = porcelain([
            "# branch.oid \(hash)",
            "# branch.head feature/notes",
            "1 .M N... 100644 100644 100644 \(hash) \(hash) docs/with space.md",
            "1 A. N... 000000 100644 100644 \(hash) \(hash) added.md",
            "1 D. N... 100644 000000 000000 \(hash) \(hash) staged-delete.md",
            "1 .D N... 100644 100644 000000 \(hash) \(hash) -leading dash.md",
            "1 AM N... 000000 100644 100644 \(hash) \(hash) añadido.md",
            "2 R. N... 100644 100644 100644 \(hash) \(hash) R100 new name.md",
            "old name.md",
            "u UU N... 100644 100644 100644 100644 \(hash) \(hash) \(hash) conflict.md",
            "? line\nbreak.md",
            "? ünïcødé \"quoted\".md",
            "? nested-repo/",
            "! ignored.md",
        ])
        let snapshot = GitStatusParser.parse(data)
        #expect(snapshot.branch == "feature/notes")
        #expect(snapshot.head == hash)
        let kinds = Dictionary(uniqueKeysWithValues: snapshot.changes.map { ($0.path, $0.kind) })
        #expect(kinds == [
            "docs/with space.md": .modified,
            "added.md": .added,
            "staged-delete.md": .deleted,
            "-leading dash.md": .deleted,
            "añadido.md": .added,
            "new name.md": .renamed,
            "conflict.md": .conflicted,
            "line\nbreak.md": .untracked,
            "ünïcødé \"quoted\".md": .untracked,
        ])
        let renamed = snapshot.changes.first { $0.kind == .renamed }
        #expect(renamed?.originalPath == "old name.md")
        #expect(renamed?.commitPaths == ["new name.md", "old name.md"])
        #expect(snapshot.hasConflicts)
    }

    @Test func parsesInitialAndDetachedHeads() {
        let snapshot = GitStatusParser.parse(porcelain(["# branch.oid (initial)", "# branch.head (detached)"]))
        #expect(snapshot.head == nil)
        #expect(snapshot.branch == nil)
        #expect(snapshot.changes.isEmpty)
        #expect(GitStatusParser.parse(Data()).changes.isEmpty)
    }

    @Test func commitsBothSidesOfRenamesButNotCopySources() {
        let hash = String(repeating: "a", count: 40)
        let snapshot = GitStatusParser.parse(porcelain([
            "2 C. N... 100644 100644 100644 \(hash) \(hash) C100 copy.md",
            "source.md",
            "2 RD N... 100644 100644 000000 \(hash) \(hash) R100 moved.md",
            "before.md",
        ]))
        let byPath = Dictionary(uniqueKeysWithValues: snapshot.changes.map { ($0.path, $0) })
        #expect(byPath["copy.md"]?.commitPaths == ["copy.md"], "a copy leaves its source alone")
        #expect(byPath["moved.md"]?.kind == .deleted)
        #expect(byPath["moved.md"]?.commitPaths == ["moved.md", "before.md"])
    }

    @Test func documentChangesAreComputedOncePerSnapshot() {
        var snapshot = GitStatusSnapshot(changes: [
            GitFileChange(path: "a.md", index: ".", worktree: "M", kind: .modified),
            GitFileChange(path: "Shot.PNG", index: "?", worktree: "?", kind: .untracked),
            GitFileChange(path: "main.swift", index: ".", worktree: "M", kind: .modified),
        ])
        #expect(snapshot.documentChanges.map(\.path) == ["a.md", "Shot.PNG"])
        snapshot.changes.append(GitFileChange(path: "b.jpeg", index: "?", worktree: "?", kind: .untracked))
        #expect(snapshot.documentChanges.map(\.path) == ["a.md", "Shot.PNG", "b.jpeg"])
        #expect(snapshot.documentChanges == snapshot.changes.filter(\.isDocumentChange))
    }

    @Test func ignoresMalformedRecords() {
        let snapshot = GitStatusParser.parse(porcelain(["1 M", "2 R. N...", "u", "? ", "zzz"]))
        #expect(snapshot.changes.isEmpty)
    }

    @Test func parsesIdentities() {
        let parsed = GitIdentity.parse("Ada Q. Lovelace <ada@example.com> 1700000000 +0100\n")
        #expect(parsed?.name == "Ada Q. Lovelace")
        #expect(parsed?.email == "ada@example.com")
        #expect(GitIdentity.parse("<only@example.com> 1 +0000")?.name == "")
        #expect(GitIdentity.parse("no email here") == nil)
    }

    @Test func buildsMessages() {
        #expect(GitOperations.message(summary: "  Fix typo \n", description: "") == "Fix typo\n")
        #expect(GitOperations.message(summary: "Title", description: "\n\nBody line\n  indented\n\n") == "Title\n\nBody line\n  indented\n")
        #expect(GitOperations.message(summary: "Title", description: "a\r\nb") == "Title\n\na\nb\n")
    }

    @Test func preparesDiffs() {
        let binary = GitOperations.prepare(Data("diff --git a/x b/x\nBinary files a/x and b/x differ\n".utf8), truncated: false)
        #expect(binary.isBinary)
        #expect(binary.note == "Binary file")

        let long = (0..<(GitOperations.diffLineLimit + 10)).map { "+line \($0)" }.joined(separator: "\n")
        let truncated = GitOperations.prepare(Data(long.utf8), truncated: false)
        #expect(truncated.lines.count == GitOperations.diffLineLimit)
        #expect(truncated.note?.hasPrefix("Diff truncated") == true)

        let cut = GitOperations.prepare(Data("+one\n+two\n+thr".utf8), truncated: true)
        #expect(cut.lines == ["+one", "+two"], "a partial last line is dropped")
        #expect(cut.note != nil)
    }

    @Test func decorationsStayInsideTheProject() {
        let outer = GitRepository(root: "/p")
        let inner = GitRepository(root: "/p/project/nested")
        let outerSnapshot = GitStatusSnapshot(branch: "main", head: "x", changes: [
            GitFileChange(path: "outside.md", index: ".", worktree: "M", kind: .modified),
            GitFileChange(path: "project/docs/a.md", index: ".", worktree: "M", kind: .modified),
            GitFileChange(path: "project/code/main.swift", index: ".", worktree: "M", kind: .modified),
        ])
        let innerSnapshot = GitStatusSnapshot(branch: "main", head: "y", changes: [
            GitFileChange(path: "guide/new.md", index: "?", worktree: "?", kind: .untracked),
        ])
        let result = GitDiscovery.decorations(snapshots: [(inner, innerSnapshot), (outer, outerSnapshot)], projectRoot: "/p/project")
        #expect(result.badges == [
            "/p/project/docs/a.md": .modified,
            "/p/project/code/main.swift": .modified,
            "/p/project/nested/guide/new.md": .untracked,
        ])
        #expect(result.folders == ["/p/project/docs", "/p/project/nested", "/p/project/nested/guide"],
                "only folders with changed Markdown get a dot")
    }

    @Test func refusesRemoteSubcommands() throws {
        let git = Git(executable: "/usr/bin/false")
        for command in ["fetch", "pull", "push", "clone", "remote", "ls-remote", "submodule"] {
            let result = git.run([command, "origin"], in: "/")
            #expect(!result.succeeded)
            #expect(result.message.contains("does not run"))
        }
        #expect(Git.subcommand(of: Git.globalArguments + ["status", "--porcelain=v2"]) == "status")
        #expect(Git.subcommand(of: ["-C", "/x", "-c", "a=b", "--no-pager", "push"]) == "push")
    }
}

// MARK: - Real repositories

@Suite(.enabled(if: isolatedGit != nil, "git is not installed"))
struct GitRepositoryTests {
    @Test func statusHandlesTrickyNames() throws {
        let repo = try TestRepo()
        let names = ["plain.md", "with space.md", "-leading dash.md", "quote \"double\" 'single'.md", "ünïcødé ✓.md", "line\nbreak.md"]
        for name in names { try repo.write(name, "first\n") }
        try repo.write("folder/renamed source.md", "rename me\n")
        try repo.write("gone.md", "bye\n")
        try repo.run("add", "-A")
        try repo.run("commit", "-q", "-m", "initial")

        for name in names { try repo.write(name, "second\n") }
        try repo.run("mv", "folder/renamed source.md", "folder/renamed target.md")
        try FileManager.default.removeItem(atPath: repo.root + "/gone.md")
        try repo.write("brand new ✓.md", "hello\n")

        let snapshot = try repo.status()
        #expect(snapshot.branch == "main")
        #expect(snapshot.head != nil)
        let kinds = Dictionary(uniqueKeysWithValues: snapshot.changes.map { ($0.path, $0.kind) })
        for name in names { #expect(kinds[name] == .modified, "\(name)") }
        #expect(kinds["folder/renamed target.md"] == .renamed)
        #expect(snapshot.changes.first { $0.kind == .renamed }?.originalPath == "folder/renamed source.md")
        #expect(kinds["gone.md"] == .deleted)
        #expect(kinds["brand new ✓.md"] == .untracked)
        #expect(snapshot.changes.count == names.count + 3)
    }

    @Test func detectsConflictsAndMerges() throws {
        let repo = try TestRepo()
        try repo.write("c.md", "base\n")
        try repo.run("add", "c.md")
        try repo.run("commit", "-q", "-m", "base")
        try repo.run("checkout", "-q", "-b", "side")
        try repo.write("c.md", "side\n")
        try repo.run("commit", "-q", "-am", "side")
        try repo.run("checkout", "-q", "main")
        try repo.write("c.md", "main\n")
        try repo.run("commit", "-q", "-am", "main")
        #expect(!repo.git.run(["merge", "side"], in: repo.root).succeeded)

        #expect(try repo.change("c.md").kind == .conflicted)
        #expect(try repo.status().hasConflicts)
        #expect(GitOperations.operationInProgress(git: repo.git, repository: repo.root) == "A merge")
    }

    @Test func discoversEnclosingAndNestedRepositories() throws {
        let repo = try TestRepo()
        try repo.write("docs/guide.md", "# Guide\n")
        // The project is a folder inside the repository.
        let docs = repo.root + "/docs"
        let enclosing = GitDiscovery.repositories(git: repo.git, projectRoot: docs, folders: [])
        #expect(enclosing == [GitRepository(root: repo.root)])

        // A folder holding several repositories and a plain folder.
        let folder = try TestFolder()
        let project = FileScanner.canonicalPath(folder.url.path)
        for name in ["alpha", "beta/inner"] {
            let dir = project + "/" + name
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            #expect(repo.git.run(["init", "-q"], in: dir).succeeded)
            try "# \(name)\n".write(toFile: dir + "/README.md", atomically: false, encoding: .utf8)
        }
        try FileManager.default.createDirectory(atPath: project + "/plain", withIntermediateDirectories: true)
        try "x\n".write(toFile: project + "/plain/notes.md", atomically: false, encoding: .utf8)

        let folders = FileScanner.folderIDs(in: FileScanner.scan(URL(fileURLWithPath: project)))
        let found = GitDiscovery.repositories(git: repo.git, projectRoot: project, folders: folders)
        #expect(found.map(\.root) == [project + "/alpha", project + "/beta/inner"])
        #expect(found.first?.contains(project + "/alpha/README.md") == true)
        #expect(found.first?.contains(project + "/alphabet/README.md") == false)
    }

    @Test func resolvesConfiguredIdentity() throws {
        let repo = try TestRepo()
        let identity = try #require(GitOperations.identity(git: repo.git, repository: repo.root))
        #expect(identity == GitIdentity(name: "Test Writer", email: "writer@example.com", isConfigured: true))
    }

    @Test func reportsMissingIdentityAndSetsItLocally() throws {
        let repo = try TestRepo(identity: false)
        #expect(GitOperations.identity(git: repo.git, repository: repo.root) == nil)
        #expect(GitOperations.setIdentity(git: repo.git, repository: repo.root, name: "Local Name", email: "local@example.com") == nil)
        #expect(repo.lines("config", "--local", "user.email") == ["local@example.com"])
        let identity = try #require(GitOperations.identity(git: repo.git, repository: repo.root))
        #expect(identity.name == "Local Name")
        #expect(identity.isConfigured)
    }

    @Test func commitsOnlySelectedFilesAndKeepsOtherStagedChanges() throws {
        let repo = try TestRepo()
        try repo.write("a.md", "a1\n")
        try repo.write("b.md", "b1\n")
        try repo.run("add", "-A")
        try repo.run("commit", "-q", "-m", "initial")

        try repo.write("a.md", "a2\n")
        try repo.write("b.md", "b2\n")
        try repo.run("add", "b.md") // staged by the user, not selected
        try repo.write("-new file ✓.md", "new\n")
        try repo.write("other.txt", "untracked, not selected\n")

        let selected = [try repo.change("a.md"), try repo.change("-new file ✓.md")]
        let result = GitOperations.commit(git: repo.git, repository: repo.root, changes: selected, message: "Update a\n")
        guard case .success(let hash) = result else {
            Issue.record("commit failed: \(result)")
            return
        }
        #expect(!hash.isEmpty)
        #expect(Set(repo.lines("show", "--name-only", "--format=", "HEAD")) == ["a.md", "-new file ✓.md"])
        #expect(repo.lines("diff", "--cached", "--name-only") == ["b.md"], "b.md stays staged")
        #expect(repo.lines("show", "HEAD:b.md") == ["b1"], "b.md was not committed")
        let after = try repo.status()
        #expect(after.changes.map(\.path).sorted() == ["b.md", "other.txt"])
        #expect(try repo.change("b.md").index == "M")
    }

    @Test func commitsDeletionsAndBothSidesOfRenames() throws {
        let repo = try TestRepo()
        try repo.write("old.md", "move me\n")
        try repo.write("delete me.md", "x\n")
        try repo.run("add", "-A")
        try repo.run("commit", "-q", "-m", "initial")
        try repo.run("mv", "old.md", "new.md")
        try FileManager.default.removeItem(atPath: repo.root + "/delete me.md")

        let changes = try repo.status().changes
        #expect(Set(changes.map(\.kind)) == [.renamed, .deleted])
        let result = GitOperations.commit(git: repo.git, repository: repo.root, changes: changes, message: "Tidy\n")
        #expect((try? result.get()) != nil)
        #expect(try repo.status().changes.isEmpty)
        #expect(repo.lines("ls-files") == ["new.md"])
    }

    @Test func storesMultilineMessagesExactly() throws {
        let repo = try TestRepo()
        try repo.write("a.md", "a\n")
        let message = GitOperations.message(
            summary: "Fix “quotes”, 'single', and \"double\" ✓",
            description: "# Not a comment\n\n  Indented line with ünïcødé\n$HOME `ls` ; rm -rf nothing\n"
        )
        let result = GitOperations.commit(git: repo.git, repository: repo.root, changes: [try repo.change("a.md")], message: message)
        #expect((try? result.get()) != nil)
        let raw = try repo.run("cat-file", "commit", "HEAD").text
        let stored = raw.components(separatedBy: "\n\n").dropFirst().joined(separator: "\n\n")
        #expect(stored == message)
    }

    @Test func commitsInAnEmptyRepository() throws {
        let repo = try TestRepo()
        try repo.write("first.md", "# First\n")
        try repo.write("staged.md", "staged\n")
        try repo.run("add", "staged.md")
        let snapshot = try repo.status()
        #expect(snapshot.head == nil)

        let diff = GitOperations.diff(git: repo.git, repository: repo.root, change: try repo.change("first.md"), hasHead: false)
        #expect(diff.lines.contains("+# First"))

        let result = GitOperations.commit(git: repo.git, repository: repo.root, changes: [try repo.change("first.md")], message: "Start\n")
        #expect((try? result.get()) != nil)
        #expect(repo.lines("log", "--format=%s") == ["Start"])
        #expect(repo.lines("show", "--name-only", "--format=", "HEAD") == ["first.md"])
        #expect(repo.lines("diff", "--cached", "--name-only") == ["staged.md"])
    }

    @Test func failingHookShowsStderrAndCreatesNoCommit() throws {
        let repo = try TestRepo()
        try repo.write("a.md", "a\n")
        try repo.run("add", "a.md")
        try repo.run("commit", "-q", "-m", "initial")
        let head = try repo.run("rev-parse", "HEAD").trimmed
        let hook = try repo.write(".git/hooks/pre-commit", "#!/bin/sh\necho 'hook refused this commit' >&2\nexit 1\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)

        try repo.write("a.md", "changed\n")
        try repo.write("new.md", "new\n")
        let changes = [try repo.change("a.md"), try repo.change("new.md")]
        let result = GitOperations.commit(git: repo.git, repository: repo.root, changes: changes, message: "Blocked\n")
        guard case .failure(let error) = result else {
            Issue.record("the hook should have stopped the commit")
            return
        }
        #expect(error.message.contains("hook refused this commit"))
        #expect(try repo.run("rev-parse", "HEAD").trimmed == head)
        #expect(try repo.change("new.md").kind == .untracked, "the untracked file is unstaged again")
    }

    @Test func diffsShowChangesAndBinaryFiles() throws {
        let repo = try TestRepo()
        try repo.write("a.md", "one\ntwo\n")
        try Data([0, 1, 2, 0, 255]).write(to: URL(fileURLWithPath: repo.root + "/image.bin"))
        try repo.run("add", "-A")
        try repo.run("commit", "-q", "-m", "initial")
        try repo.write("a.md", "one\nthree\n")
        try Data([0, 9, 9, 0, 255]).write(to: URL(fileURLWithPath: repo.root + "/image.bin"))
        try repo.write("-new.md", "fresh\n")

        let modified = GitOperations.diff(git: repo.git, repository: repo.root, change: try repo.change("a.md"), hasHead: true)
        #expect(modified.lines.contains("-two"))
        #expect(modified.lines.contains("+three"))
        let binary = GitOperations.diff(git: repo.git, repository: repo.root, change: try repo.change("image.bin"), hasHead: true)
        #expect(binary.isBinary)
        let untracked = GitOperations.diff(git: repo.git, repository: repo.root, change: try repo.change("-new.md"), hasHead: true)
        #expect(untracked.lines.contains("+fresh"))
    }

    @Test func noCommandContactsARemote() throws {
        let repo = try TestRepo()
        try repo.write("a.md", "a\n")
        _ = try repo.status()
        _ = GitOperations.identity(git: repo.git, repository: repo.root)
        _ = GitOperations.diff(git: repo.git, repository: repo.root, change: try repo.change("a.md"), hasHead: false)
        _ = GitOperations.commit(git: repo.git, repository: repo.root, changes: [try repo.change("a.md")], message: "x\n")
        _ = GitOperations.operationInProgress(git: repo.git, repository: repo.root)

        let recorded = GitLog.recorded
        #expect(!recorded.isEmpty)
        for arguments in recorded {
            #expect(Array(arguments.prefix(Git.globalArguments.count)) == Git.globalArguments)
            #expect(arguments.contains("protocol.allow=never"))
            let command = try #require(Git.subcommand(of: arguments))
            #expect(!Git.remoteSubcommands.contains(command), "git \(command) must not run")
            #expect(!arguments.contains("--recurse-submodules"))
        }
        let env = repo.git.processEnvironment
        #expect(env["GIT_TERMINAL_PROMPT"] == "0")
        #expect(env["GIT_OPTIONAL_LOCKS"] == "0")
        #expect(env["GIT_NO_LAZY_FETCH"] == "1")
    }
}

// MARK: - Edge cases in real repositories

@Suite(.enabled(if: isolatedGit != nil, "git is not installed"))
struct GitEdgeCaseTests {
    @Test func statusSkipsAheadBehindCounts() throws {
        let repo = try TestRepo()
        try repo.write("a.md", "a\n")
        _ = try repo.status()
        let statuses = GitLog.recorded.filter { Git.subcommand(of: $0) == "status" }
        #expect(!statuses.isEmpty)
        #expect(statuses.allSatisfy { $0.contains("--no-ahead-behind") })
    }

    @Test func committingACopyLeavesItsSourceUncommitted() throws {
        let repo = try TestRepo()
        try repo.run("config", "diff.renames", "copies")
        try repo.write("source.md", "one\ntwo\nthree\nfour\nfive\n")
        try repo.run("add", "source.md")
        try repo.run("commit", "-q", "-m", "initial")
        try FileManager.default.copyItem(atPath: repo.root + "/source.md", toPath: repo.root + "/copy.md")
        try repo.write("source.md", "one\ntwo\nthree\nfour\nfive\nsix\n")
        try repo.run("add", "-A")
        try repo.write("source.md", "unrelated edit\n")

        let copy = try repo.change("copy.md")
        #expect(copy.originalPath == "source.md", "git reports the new file as a copy")
        let result = GitOperations.commit(git: repo.git, repository: repo.root, changes: [copy], message: "Copy\n")
        #expect((try? result.get()) != nil)
        #expect(repo.lines("show", "--name-only", "--format=", "HEAD") == ["copy.md"])
        #expect(repo.lines("show", "HEAD:source.md").count == 5, "the source was not committed")
    }

    @Test func findsRepositoriesWhosePathEndsInASpace() throws {
        let repo = try TestRepo(path: "space at end ")
        #expect(GitDiscovery.toplevel(git: repo.git, directory: repo.root) == repo.root)
        #expect(GitOperations.operationInProgress(git: repo.git, repository: repo.root) == nil)
        try repo.write("a.md", "a\n")
        try repo.run("add", "a.md")
        try repo.run("commit", "-q", "-m", "initial")
        try repo.write("a.md", "b\n")
        #expect(GitOperations.commit(git: repo.git, repository: repo.root, changes: [try repo.change("a.md")], message: "x\n")
            .map { !$0.isEmpty } == .success(true))
    }

    @Test func commitStoppedByASlowPostCommitHookKeepsNewFilesTracked() throws {
        let repo = try TestRepo()
        try repo.write("a.md", "a\n")
        try repo.run("add", "a.md")
        try repo.run("commit", "-q", "-m", "initial")
        // Closes git's pipes, then outlives the timeout below.
        let hook = try repo.write(".git/hooks/post-commit", "#!/bin/sh\nexec >/dev/null 2>&1\nsleep 8\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
        try repo.write("new.md", "new\n")

        let result = GitOperations.commit(
            git: repo.git, repository: repo.root, changes: [try repo.change("new.md")], message: "Add\n", timeout: 2)
        #expect((try? result.get()) != nil, "the commit was made before git was stopped")
        #expect(repo.lines("show", "--name-only", "--format=", "HEAD") == ["new.md"])
        #expect(repo.lines("diff", "--cached", "--name-only").isEmpty, "no deletion of new.md is staged")
        #expect(try repo.status().changes.isEmpty)
    }

    @Test func failedAddLeavesNoFilesStaged() throws {
        let repo = try TestRepo()
        try repo.write("a.md", "a\n")
        try repo.run("add", "a.md")
        try repo.run("commit", "-q", "-m", "initial")
        // With add.ignoreErrors, git add stages what it can and still fails.
        try repo.run("config", "add.ignoreErrors", "true")
        try repo.write("readable.md", "ok\n")
        let locked = try repo.write("unreadable.md", "secret\n")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked) }

        let changes = [try repo.change("readable.md"), try repo.change("unreadable.md")]
        let result = GitOperations.commit(git: repo.git, repository: repo.root, changes: changes, message: "x\n")
        guard case .failure = result else {
            Issue.record("the unreadable file should stop the commit")
            return
        }
        #expect(repo.lines("diff", "--cached", "--name-only").isEmpty)
        #expect(try repo.change("readable.md").kind == .untracked)
    }
}

@MainActor
@Suite(.enabled(if: isolatedGit != nil, "git is not installed"))
struct CommitSessionTests {
    @Test func refreshPicksUpNewFilesWithoutBlockingTheSheet() async throws {
        let repo = try TestRepo()
        try repo.write("a.md", "a\n")
        let repository = GitRepository(root: repo.root)
        let session = CommitSession(git: repo.git, projectRoot: repo.root, repositories: [repository], repository: repository)
        try await waitUntil(seconds: 60) { !session.isLoading }
        #expect(session.changes.map(\.path) == ["a.md"])
        session.setChecked(try #require(session.changes.first), false)

        try repo.write("b.md", "b\n")
        session.refresh()
        #expect(!session.isLoading, "a background refresh keeps the sheet usable")
        try await waitUntil(seconds: 60) { session.changes.count == 2 }
        #expect(session.checked == ["b.md"], "the user's choice for a.md is kept")
    }
}

// MARK: - Visibility

@MainActor
@Suite(.enabled(if: isolatedGit != nil, "git is not installed"))
struct GitVisibilityTests {
    private func scanned(_ model: GitModel, _ root: String) async throws {
        model.projectScanned(root: root, tree: FileScanner.scan(URL(fileURLWithPath: root)), statusEnabled: true)
        try await waitUntil(seconds: 60) { !model.isDiscovering && model.isAvailable }
    }

    @Test func projectWithoutRepositoryShowsNoGitUI() async throws {
        let folder = try TestFolder()
        let root = FileScanner.canonicalPath(folder.url.path)
        try "# Notes\n".write(toFile: root + "/notes.md", atomically: false, encoding: .utf8)
        #expect(GitDiscovery.repositories(git: try #require(isolatedGit), projectRoot: root, folders: []).isEmpty)

        let model = GitModel()
        try await scanned(model, root)
        #expect(model.repositories.isEmpty)
        #expect(!model.isActive)
        #expect(!model.showsStatus)
        #expect(!model.canCommit(currentFile: root + "/notes.md"))
        #expect(!model.showsCommitButton(currentFile: root + "/notes.md"))
        #expect(!model.canCommit(currentFile: nil))
        #expect(model.badge(for: root + "/notes.md") == nil)
    }

    @Test func mixedProjectTargetsTheCurrentDocumentsRepository() async throws {
        let folder = try TestFolder()
        let root = FileScanner.canonicalPath(folder.url.path)
        let git = try #require(isolatedGit)
        try "loose\n".write(toFile: root + "/loose.md", atomically: false, encoding: .utf8)
        let repoDir = root + "/repo"
        try FileManager.default.createDirectory(atPath: repoDir, withIntermediateDirectories: true)
        #expect(git.run(["init", "-q"], in: repoDir).succeeded)
        try "inside\n".write(toFile: repoDir + "/inside.md", atomically: false, encoding: .utf8)

        let model = GitModel()
        try await scanned(model, root)
        #expect(model.isActive)
        #expect(model.repositories.map(\.root) == [repoDir])
        try await waitUntil(seconds: 60) { model.badge(for: repoDir + "/inside.md") == .untracked }
        #expect(model.folderHasChanges(repoDir))
        #expect(model.commitTarget(currentFile: repoDir + "/inside.md")?.root == repoDir)
        #expect(model.showsCommitButton(currentFile: repoDir + "/inside.md"))
        #expect(model.commitTarget(currentFile: root + "/loose.md") == nil)
        #expect(!model.showsCommitButton(currentFile: root + "/loose.md"))
        #expect(!model.canCommit(currentFile: root + "/loose.md"))

        model.setStatusEnabled(false)
        #expect(model.badge(for: repoDir + "/inside.md") == nil)
        #expect(!model.showsCommitButton(currentFile: repoDir + "/inside.md"))
        #expect(model.canCommit(currentFile: repoDir + "/inside.md"), "committing works without badges")
    }

    @Test func redetectsRepositoriesCreatedOrRemovedInTheProject() async throws {
        let folder = try TestFolder()
        let root = FileScanner.canonicalPath(folder.url.path)
        let git = try #require(isolatedGit)
        try "# Notes\n".write(toFile: root + "/notes.md", atomically: false, encoding: .utf8)
        let model = GitModel()
        try await scanned(model, root)
        #expect(!model.isActive)

        let created = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsDir)
        #expect(git.run(["init", "-q"], in: root).succeeded)
        model.fileEvents([DirectoryWatcher.Event(path: root + "/.git", flags: created)])
        try await waitUntil(seconds: 60) { model.isActive }
        #expect(model.repositories.map(\.root) == [root])

        try FileManager.default.removeItem(atPath: root + "/.git")
        let removed = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsDir)
        model.fileEvents([DirectoryWatcher.Event(path: root + "/.git", flags: removed)])
        try await waitUntil(seconds: 60) { !model.isActive }
        #expect(model.badge(for: root + "/notes.md") == nil)
    }
}

/// LexMD offers only documents and their images for commit.
struct GitDocumentChangeTests {
    private func change(_ path: String, _ kind: GitChangeKind) -> GitFileChange {
        GitFileChange(path: path, index: ".", worktree: "M", kind: kind)
    }

    @Test func onlyMarkdownAndImagesAreOffered() {
        var snapshot = GitStatusSnapshot()
        snapshot.changes = [
            change(".DS_Store", .untracked), change("skills/.DS_Store", .untracked),
            change("Sources/App.swift", .modified), change("README.md", .modified),
            change("docs/guide.markdown", .added), change("docs/assets/shot.png", .untracked),
        ]
        #expect(snapshot.documentChanges.map(\.path) == ["README.md", "docs/guide.markdown", "docs/assets/shot.png"])

        var noise = GitStatusSnapshot()
        noise.changes = [change(".DS_Store", .untracked), change("Package.swift", .modified)]
        #expect(noise.documentChanges.isEmpty)
    }

    @Test func newImagesNearChangedDocumentsStartChecked() {
        let changes = [
            change("docs/guide.md", .modified), change("docs/assets/new.png", .untracked),
            change("art/logo.png", .untracked), change("docs/old.png", .modified),
        ]
        #expect(GitStatusSnapshot.checkedByDefault(changes) == ["docs/guide.md", "docs/assets/new.png"])
        #expect(GitStatusSnapshot.checkedByDefault([change("a.png", .untracked)]).isEmpty)
    }
}
