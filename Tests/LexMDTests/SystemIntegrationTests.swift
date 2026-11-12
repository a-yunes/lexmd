import Foundation
import Testing
@testable import LexMD

/// Opening several paths at once, the Create Note action, and the command line tool installer.
struct OpenPlanTests {
    private let home = "/Users/me"

    private func plan(_ paths: [String], root: String? = nil, folders: Set<String>, missing: Set<String> = []) -> OpenPlan {
        OpenPlan.make(paths: paths, currentRoot: root, home: home) { path in
            missing.contains(path) ? nil : folders.contains(path)
        }
    }

    @Test func firstFolderBecomesTheProjectAndFilesInsideItOpen() {
        let result = plan(
            ["/p/a.md", "/p", "/q", "/p/sub/b.md", "/elsewhere/c.md", "/p/a.md"],
            root: "/old", folders: ["/p", "/q"]
        )
        #expect(result == OpenPlan(folder: "/p", files: ["/p/a.md", "/p/sub/b.md"]))
    }

    @Test func filesStayInTheCurrentProject() {
        let result = plan(["/p/a.md", "/p/x/b.md"], root: "/p", folders: [])
        #expect(result == OpenPlan(folder: nil, files: ["/p/a.md", "/p/x/b.md"]))
    }

    @Test func filesElsewhereOpenTheFolderHoldingThem() {
        #expect(plan(["/w/docs/a.md", "/w/docs/x/b.md"], root: "/p", folders: []) == OpenPlan(folder: "/w/docs", files: ["/w/docs/a.md", "/w/docs/x/b.md"]))
        #expect(plan(["/w/one/a.md", "/w/two/b.md"], folders: []) == OpenPlan(folder: "/w", files: ["/w/one/a.md", "/w/two/b.md"]))
        // Never the whole disk or the home folder: the first file's folder wins.
        #expect(plan(["/a/x.md", "/b/y.md"], folders: []) == OpenPlan(folder: "/a", files: ["/a/x.md"]))
        #expect(plan(["\(home)/Notes/x.md", "\(home)/Work/y.md"], folders: []) == OpenPlan(folder: "\(home)/Notes", files: ["\(home)/Notes/x.md"]))
    }

    @Test func missingPathsAreSkipped() {
        #expect(plan(["/p/gone.md", "/p/a.md"], root: "/p", folders: [], missing: ["/p/gone.md"]) == OpenPlan(folder: nil, files: ["/p/a.md"]))
        #expect(plan(["/gone"], folders: [], missing: ["/gone"]) == OpenPlan(folder: nil, files: []))
    }

    @Test func commonFolder() {
        #expect(OpenPlan.commonFolder(["/a/b/c", "/a/b", "/a/b/d/e"]) == "/a/b")
        #expect(OpenPlan.commonFolder(["/a/bc", "/a/b"]) == "/a")
        #expect(OpenPlan.commonFolder([]) == "/")
    }
}

struct NoteCreatorTests {
    @Test func createsNotesWithoutReplacingFiles() throws {
        let folder = try TestFolder()
        let first = try NoteCreator.create(name: "Ideas", text: "# Ideas\n", in: folder.url)
        #expect(first.lastPathComponent == "Ideas.md")
        #expect(try String(contentsOf: first, encoding: .utf8) == "# Ideas\n")
        let second = try NoteCreator.create(name: "Ideas.md", text: "Other", in: folder.url)
        #expect(second.lastPathComponent == "Ideas 2.md")
        #expect(try String(contentsOf: first, encoding: .utf8) == "# Ideas\n")
        let markdown = try NoteCreator.create(name: "Plan.markdown", text: "", in: folder.url)
        #expect(markdown.lastPathComponent == "Plan.markdown")
        #expect(try Data(contentsOf: markdown).isEmpty)
    }

    @Test func keepsNotesInsideTheFolder() throws {
        let folder = try TestFolder()
        #expect(NoteCreator.fileName(for: "../../etc/passwd") == ("-..-etc-passwd", "md"))
        #expect(NoteCreator.fileName(for: " .hidden ") == ("hidden", "md"))
        #expect(NoteCreator.fileName(for: "a:b") == ("a-b", "md"))
        #expect(NoteCreator.fileName(for: "  ") == ("Untitled", "md"))
        let note = try NoteCreator.create(name: "../escape", text: "", in: folder.url)
        #expect(note.deletingLastPathComponent().standardizedFileURL == folder.url.standardizedFileURL)
        #expect(throws: LexMDIntentError.self) {
            try NoteCreator.create(name: "x", text: "", in: folder.url.appendingPathComponent("missing"))
        }
    }
}

struct CommandLineInstallTests {
    @Test func quotesPathsForTheShellAndAppleScript() {
        #expect(CommandLineTool.shellQuote("/A B/it's") == #"'/A B/it'\''s'"#)
        #expect(CommandLineTool.appleScriptString(#"say "hi" \ there"#) == #""say \"hi\" \\ there""#)
        let tool = "/Apps/Lex \"MD\"/it's.app/Contents/Resources/bin/lexmd"
        #expect(CommandLineTool.linkCommand(tool: tool, link: "/usr/local/bin/lexmd", replace: false)
            == #"/bin/mkdir -p '/usr/local/bin' && /bin/ln -s '/Apps/Lex "MD"/it'\''s.app/Contents/Resources/bin/lexmd' '/usr/local/bin/lexmd'"#)
        #expect(CommandLineTool.linkCommand(tool: "/t", link: "/l/x", replace: true) == "/bin/mkdir -p '/l' && /bin/ln -sfn '/t' '/l/x'")
        #expect(CommandLineTool.installScript(tool: tool, link: "/usr/local/bin/lexmd", replace: false)
            == #"do shell script "/bin/mkdir -p '/usr/local/bin' && /bin/ln -s '/Apps/Lex \"MD\"/it'\\''s.app/Contents/Resources/bin/lexmd' '/usr/local/bin/lexmd'" with administrator privileges"#)
        #expect(CommandLineTool.userCommand(tool: "/Applications/LexMD.app/Contents/Resources/bin/lexmd")
            == "mkdir -p ~/bin && ln -s '/Applications/LexMD.app/Contents/Resources/bin/lexmd' ~/bin/lexmd")
    }

    @Test func compiledScriptRunsTheQuotedCommand() throws {
        // The AppleScript, without the administrator part, must run the exact shell command.
        let folder = try TestFolder()
        let tool = try folder.write("it's \"tool\"", "#!/bin/sh\n", executable: true)
        let link = folder.url.appendingPathComponent("bin dir/lexmd").path
        let script = CommandLineTool.installScript(tool: tool.path, link: link, replace: false)
            .replacingOccurrences(of: " with administrator privileges", with: "")
        // osascript runs it in its own process, away from this process's run loop.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(CommandLineTool.state(of: link, tool: tool.path) == .installed)
    }

    @Test func detectsWhatIsAlreadyThere() throws {
        let folder = try TestFolder()
        let tool = try folder.write("lexmd-tool", "#!/bin/sh\n", executable: true)
        let other = try folder.write("other", "#!/bin/sh\n", executable: true)
        let link = folder.url.appendingPathComponent("lexmd").path
        #expect(CommandLineTool.state(of: link, tool: tool.path) == .missing)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "lexmd-tool")
        #expect(CommandLineTool.state(of: link, tool: tool.path) == .installed)
        try FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: other.path)
        #expect(CommandLineTool.state(of: link, tool: tool.path) == .otherLink(other.path))
        try FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/nonexistent/lexmd")
        #expect(CommandLineTool.state(of: link, tool: tool.path) == .otherLink("/nonexistent/lexmd"))
        try FileManager.default.removeItem(atPath: link)
        try folder.write("lexmd", "real file")
        #expect(CommandLineTool.state(of: link, tool: tool.path) == .otherItem)
        #expect(CommandLineTool.isTranslocated("/private/var/folders/x/AppTranslocation/ABC/d/LexMD.app/Contents/Resources/bin/lexmd"))
        #expect(!CommandLineTool.isTranslocated("/Applications/LexMD.app/Contents/Resources/bin/lexmd"))
    }

    @Test func installMenuItemHasNoDefaultShortcut() {
        #expect(ShortcutAction.installCommandLineTool.defaultShortcut == nil)
        #expect(ShortcutAction.installCommandLineTool.title == "Install Command Line Tool…")
    }
}
