import Darwin
import Foundation

/// The outcome of one git invocation.
struct GitResult: Sendable {
    var status: Int32
    var output: Data
    var errorOutput: String
    var timedOut = false
    var cancelled = false
    var truncated = false

    var succeeded: Bool { status == 0 && !timedOut && !cancelled }
    var text: String { String(decoding: output, as: UTF8.self) }
    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The output without its final newline, for paths, which may end in spaces.
    var line: String {
        let text = text
        return text.hasSuffix("\n") ? String(text.dropLast()) : text
    }

    /// What to show the user when the command failed: git's stderr, else its stdout.
    var message: String {
        if timedOut { return "Git took too long and was stopped." }
        let error = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !error.isEmpty { return error }
        let out = trimmed
        return out.isEmpty ? "Git failed with exit code \(status)." : out
    }
}

/// Runs the system git with a fixed, local-only configuration. Every call uses an argument
/// array (never a shell), a timeout, and stops when the calling task is cancelled.
struct Git: Sendable {
    let executable: String
    /// Extra environment entries, mainly for tests.
    var environment: [String: String] = [:]

    /// Options placed before every subcommand.
    static let globalArguments = [
        "--no-optional-locks", "--literal-pathspecs",
        "-c", "core.quotepath=off",
        // Refuse every transport, so nothing (including lazy fetches) reaches a remote.
        "-c", "protocol.allow=never",
        "-c", "credential.helper=",
    ]

    /// Subcommands that talk to other repositories. They are never run.
    static let remoteSubcommands: Set<String> = [
        "fetch", "pull", "push", "clone", "remote", "ls-remote", "submodule", "send-pack",
        "fetch-pack", "archive", "request-pull", "send-email", "svn", "p4", "daemon",
        "http-fetch", "http-push", "upload-pack", "receive-pack", "bundle", "maintenance", "gc",
    ]

    /// The subcommand in a full argument list, skipping global options and their values.
    static func subcommand(of arguments: [String]) -> String? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-c" || argument == "-C" {
                index += 2
            } else if argument.hasPrefix("-") {
                index += 1
            } else {
                return argument
            }
        }
        return nil
    }

    /// The located git, or nil when none is usable. Resolving runs processes, so call it off
    /// the main thread. The result is cached.
    static let system: Git? = locate()

    /// Finds git without triggering the Command Line Tools install dialog: /usr/bin/git is only
    /// used through xcrun after `xcode-select -p` confirms a developer directory exists.
    static func locate(fallbacks: [String] = ["/opt/homebrew/bin/git", "/usr/local/bin/git"]) -> Git? {
        let manager = FileManager.default
        let select = ProcessRunner.run("/usr/bin/xcode-select", ["-p"], timeout: 5)
        let developer = select.trimmed
        if select.succeeded, !developer.isEmpty, manager.fileExists(atPath: developer) {
            let found = ProcessRunner.run("/usr/bin/xcrun", ["--find", "git"], timeout: 10)
            let path = found.trimmed
            if found.succeeded, manager.isExecutableFile(atPath: path), works(path) {
                return Git(executable: path)
            }
        }
        for path in fallbacks where manager.isExecutableFile(atPath: path) && works(path) {
            return Git(executable: path)
        }
        return nil
    }

    private static func works(_ path: String) -> Bool {
        ProcessRunner.run(path, ["--version"], timeout: 10).succeeded
    }

    /// The environment git runs with: no prompts, no optional locks, no lazy fetches.
    var processEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR", "GIT_PREFIX"] {
            env.removeValue(forKey: key)
        }
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_NO_LAZY_FETCH"] = "1"
        env["GCM_INTERACTIVE"] = "never"
        env["GIT_PAGER"] = "cat"
        env["GIT_EDITOR"] = "true"
        // Apps start with a short PATH; hooks and signing tools often live in Homebrew.
        var path = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for extra in ["/opt/homebrew/bin", "/usr/local/bin"] where !path.contains(extra) { path.append(extra) }
        env["PATH"] = path.joined(separator: ":")
        env.merge(environment) { _, new in new }
        return env
    }

    /// Runs `git <global options> <arguments>` in `directory`.
    func run(
        _ arguments: [String], in directory: String, input: Data? = nil,
        timeout: TimeInterval = 30, outputLimit: Int = 64 << 20
    ) -> GitResult {
        let full = Self.globalArguments + arguments
        if let command = Self.subcommand(of: full), Self.remoteSubcommands.contains(command) {
            return GitResult(status: -1, output: Data(), errorOutput: "LexMD does not run “git \(command)”.")
        }
        GitLog.record(full)
        return ProcessRunner.run(
            executable, full, directory: directory, environment: processEnvironment,
            input: input, timeout: timeout, outputLimit: outputLimit
        )
    }
}

/// Every argument list git ran with in this process, so tests can check what ran.
enum GitLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [[String]] = []

    static func record(_ arguments: [String]) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(arguments)
        if entries.count > 5000 { entries.removeFirst(2500) }
    }

    static var recorded: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

/// Runs a process with pipes, a timeout, and cooperative cancellation.
enum ProcessRunner {
    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private(set) var truncated = false
        let limit: Int

        init(limit: Int) { self.limit = limit }

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            let room = limit - data.count
            if room >= chunk.count {
                data.append(chunk)
            } else {
                if room > 0 { data.append(chunk.prefix(room)) }
                truncated = true
            }
        }

        var value: Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    static func run(
        _ executable: String, _ arguments: [String], directory: String? = nil,
        environment: [String: String]? = nil, input: Data? = nil,
        timeout: TimeInterval, outputLimit: Int = 4 << 20
    ) -> GitResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true) }
        if let environment { process.environment = environment }
        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = input == nil ? nil : Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe ?? FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return GitResult(status: -1, output: Data(), errorOutput: error.localizedDescription)
        }

        let readers = DispatchGroup()
        let out = Buffer(limit: outputLimit)
        let err = Buffer(limit: 1 << 20)
        drain(outPipe.fileHandleForReading, into: out, group: readers)
        drain(errPipe.fileHandleForReading, into: err, group: readers)
        if let inPipe, let input {
            let handle = inPipe.fileHandleForWriting
            // A process that exits early must not raise SIGPIPE in LexMD.
            _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global(qos: .userInitiated).async {
                try? handle.write(contentsOf: input)
                try? handle.close()
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        var cancelled = false
        while finished.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            let isCancelled = Task.isCancelled
            guard isCancelled || Date() > deadline else { continue }
            cancelled = isCancelled
            timedOut = !isCancelled
            process.terminate()
            if finished.wait(timeout: .now() + .seconds(2)) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
            break
        }
        // A hook may leave a background child holding the pipes open; do not wait on it forever.
        _ = readers.wait(timeout: .now() + .seconds(3))
        return GitResult(
            status: process.terminationStatus,
            output: out.value,
            errorOutput: String(decoding: err.value, as: UTF8.self),
            timedOut: timedOut,
            cancelled: cancelled,
            truncated: out.truncated
        )
    }

    private static func drain(_ handle: FileHandle, into buffer: Buffer, group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            while let chunk = try? handle.read(upToCount: 1 << 16), !chunk.isEmpty {
                buffer.append(chunk)
            }
            group.leave()
        }
    }
}
