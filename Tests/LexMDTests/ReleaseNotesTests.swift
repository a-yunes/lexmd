import Foundation
import Testing

/// `scripts/release-notes.sh`, which turns a version's section of the changelog into the HTML
/// the update window shows.
struct ReleaseNotesTests {
    private func notes(_ version: String, changelog: String) throws -> (status: Int32, output: String) {
        let folder = try TestFolder()
        let file = try folder.write("CHANGELOG.md", changelog)
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/release-notes.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, version, file.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private let changelog = """
        # Changelog

        ## 2.0.0

        Rebuilt from scratch.

        - Use `$x$` for math, and <b> stays text
          on a second line & more.
        - A lone ` backtick is left alone.

        ## 1.9.0

        - Older item.
        """

    @Test func turnsAVersionsSectionIntoHTML() throws {
        let result = try notes("2.0.0", changelog: changelog)
        #expect(result.status == 0)
        #expect(result.output == """
            <p>Rebuilt from scratch.</p>
            <ul>
            <li>Use <code>$x$</code> for math, and &lt;b&gt; stays text on a second line &amp; more.</li>
            <li>A lone ` backtick is left alone.</li>
            </ul>

            """)
        #expect(try notes("1.9.0", changelog: changelog).output == "<ul>\n<li>Older item.</li>\n</ul>\n")
    }

    /// Packaging stops when a version has nothing to show in the update window.
    @Test func failsWithoutNotesForTheVersion() throws {
        #expect(try notes("3.0.0", changelog: changelog).status != 0)
        #expect(try notes("2.0", changelog: changelog).status != 0, "a version matches its whole heading")
        #expect(try notes("2.0.0", changelog: "## 2.0.0\n\n## 1.9.0\n\n- Older item.\n").status != 0)
    }
}
