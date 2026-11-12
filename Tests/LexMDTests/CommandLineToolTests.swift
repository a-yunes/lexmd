import Foundation
import Testing
@testable import LexMD

/// Runs the bundled `lexmd` script in a fake app bundle with a stand-in `open` that records its arguments.
struct CommandLineToolTests {
    static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/bin/lexmd")

    struct Result {
        var status: Int32
        var stdout: String
        var stderr: String
        /// Arguments `open` received, or nil when it did not run.
        var open: [String]?
    }

    /// A temporary folder with `LexMD.app` (holding the script), a fake `open`, and a work folder.
    final class Sandbox {
        let folder: TestFolder
        let app: URL
        let tool: URL
        let work: URL
        let log: URL

        init() throws {
            folder = try TestFolder()
            let root = URL(fileURLWithPath: Self.realPath(folder.url.path))
            app = root.appendingPathComponent("Apps/LexMD.app")
            let bin = app.appendingPathComponent("Contents/Resources/bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": "io.github.a-yunes.lexmd", "CFBundleShortVersionString": "9.8.7"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
            tool = bin.appendingPathComponent("lexmd")
            try FileManager.default.copyItem(at: CommandLineToolTests.script, to: tool)

            let fakeBin = root.appendingPathComponent("fakebin")
            try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
            log = root.appendingPathComponent("open.log")
            try folder.write("fakebin/open", "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done > \"$LEXMD_TEST_LOG\"\n", executable: true)

            work = root.appendingPathComponent("work dir")
            try FileManager.default.createDirectory(at: work.appendingPathComponent("sub"), withIntermediateDirectories: true)
            try "# A\n".write(to: work.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        }

        static func realPath(_ path: String) -> String {
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }

        func run(
            _ arguments: [String], shell: String = "/bin/sh", tool: URL? = nil, in directory: URL? = nil,
            environment extra: [String: String] = [:]
        ) throws -> Result {
            try? FileManager.default.removeItem(at: log)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = [(tool ?? self.tool).path] + arguments
            process.currentDirectoryURL = directory ?? work
            process.environment = [
                "PATH": folder.url.appendingPathComponent("fakebin").path + ":/usr/bin:/bin",
                "LEXMD_TEST_LOG": log.path,
            ].merging(extra) { _, new in new }
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let stdout = out.fileHandleForReading.readDataToEndOfFile()
            let stderr = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let opened = (try? String(contentsOf: log, encoding: .utf8)).map { $0.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init) }
            return Result(
                status: process.terminationStatus,
                stdout: String(decoding: stdout, as: UTF8.self),
                stderr: String(decoding: stderr, as: UTF8.self),
                open: opened
            )
        }
    }

    static let shells = ["/bin/sh", "/bin/dash"].filter { FileManager.default.isExecutableFile(atPath: $0) }

    @Test(arguments: shells)
    func helpAndVersion(shell: String) throws {
        let box = try Sandbox()
        let help = try box.run(["--help"], shell: shell)
        #expect(help.status == 0)
        #expect(help.stdout.hasPrefix("Usage: lexmd"))
        #expect(help.open == nil)

        let version = try box.run(["-v"], shell: shell)
        #expect(version.status == 0)
        #expect(version.stdout == "LexMD 9.8.7\n")

        let unknown = try box.run(["--bogus", "a.md"], shell: shell)
        #expect(unknown.status == 2)
        #expect(unknown.stderr.contains("unknown option: --bogus"))
        #expect(unknown.open == nil)
    }

    @Test(arguments: shells)
    func opensFilesAndFoldersAsAbsolutePaths(shell: String) throws {
        let box = try Sandbox()
        let work = box.work.path
        #expect(try box.run(["."], shell: shell).open == ["-a", box.app.path, work])
        #expect(try box.run(["a.md", "sub/", "./sub/../a.md"], shell: shell).open == ["-a", box.app.path, work + "/a.md", work + "/sub", work + "/a.md"])
        #expect(try box.run([work + "/sub"], shell: shell, in: box.app).open == ["-a", box.app.path, work + "/sub"])
        // No paths: just open the app.
        #expect(try box.run([], shell: shell).open == ["-a", box.app.path])
    }

    @Test(arguments: shells)
    func reportsMissingPaths(shell: String) throws {
        let box = try Sandbox()
        let mixed = try box.run(["missing.md", "a.md"], shell: shell)
        #expect(mixed.status == 1)
        #expect(mixed.stderr.contains("no such file or folder: missing.md"))
        #expect(mixed.open == ["-a", box.app.path, box.work.path + "/a.md"])
        #expect(!FileManager.default.fileExists(atPath: box.work.path + "/missing.md"))

        let onlyMissing = try box.run(["missing.md"], shell: shell)
        #expect(onlyMissing.status == 1)
        #expect(onlyMissing.open == nil)

        // After `--`, an argument that looks like an option is a path.
        let dashed = try box.run(["--", "-n"], shell: shell)
        #expect(dashed.status == 1)
        #expect(dashed.stderr.contains("no such file or folder: -n"))
    }

    @Test(arguments: shells)
    func createsMissingFilesWithNew(shell: String) throws {
        let box = try Sandbox()
        let work = box.work.path
        let result = try box.run(["--new", "todo", "Notes.markdown", "a.md", "nofolder/x.md"], shell: shell)
        #expect(result.status == 1)
        #expect(result.stderr.contains("its folder does not exist"))
        #expect(result.open == ["-a", box.app.path, work + "/todo.md", work + "/Notes.markdown", work + "/a.md"])
        #expect(try Data(contentsOf: box.work.appendingPathComponent("todo.md")).isEmpty)
        #expect(FileManager.default.fileExists(atPath: work + "/Notes.markdown"))
        // Existing files are never touched.
        #expect(try String(contentsOf: box.work.appendingPathComponent("a.md"), encoding: .utf8) == "# A\n")
    }

    @Test(arguments: shells)
    func opensNamesThatStartWithADash(shell: String) throws {
        let box = try Sandbox()
        let work = box.work.path
        try "# Dash\n".write(toFile: work + "/-dash.md", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: work + "/-folder", withIntermediateDirectories: true)
        let result = try box.run(["--", "-dash.md", "-folder"], shell: shell)
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.open == ["-a", box.app.path, work + "/-dash.md", work + "/-folder"])

        let created = try box.run(["--new", "--", "-new"], shell: shell)
        #expect(created.status == 0, "\(created.stderr)")
        #expect(created.open == ["-a", box.app.path, work + "/-new.md"])
        #expect(FileManager.default.fileExists(atPath: work + "/-new.md"))
    }

    @Test(arguments: shells)
    func ignoresAnExportedCDPATH(shell: String) throws {
        let box = try Sandbox()
        // A folder named like one in the work folder, reachable through CDPATH.
        let elsewhere = box.folder.url.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let result = try box.run(["sub"], shell: shell, environment: ["CDPATH": Sandbox.realPath(elsewhere.path)])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.open == ["-a", box.app.path, box.work.path + "/sub"])
    }

    @Test(arguments: shells)
    func neverCreatesAFileForAnEmptyArgument(shell: String) throws {
        let box = try Sandbox()
        let result = try box.run(["--new", "", "a.md"], shell: shell)
        #expect(result.status == 1)
        #expect(result.open == ["-a", box.app.path, box.work.path + "/a.md"])
        #expect(!FileManager.default.fileExists(atPath: box.work.path + "/.md"))
    }

    @Test(arguments: shells)
    func findsTheAppThroughALinkAndFallsBackToTheBundleID(shell: String) throws {
        let box = try Sandbox()
        let links = box.folder.url.appendingPathComponent("links")
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        let link = links.appendingPathComponent("lexmd")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: box.tool.path)
        let linked = try box.run(["a.md"], shell: shell, tool: link)
        #expect(linked.open == ["-a", box.app.path, box.work.path + "/a.md"])
        #expect(try box.run(["--version"], shell: shell, tool: link).stdout == "LexMD 9.8.7\n")

        let loose = links.appendingPathComponent("loose")
        try FileManager.default.copyItem(at: box.tool, to: loose)
        let fallback = try box.run(["a.md"], shell: shell, tool: loose)
        #expect(fallback.open == ["-b", "io.github.a-yunes.lexmd", box.work.path + "/a.md"])
    }
}
