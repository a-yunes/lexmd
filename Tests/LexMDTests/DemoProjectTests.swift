import Foundation
import Testing
@testable import LexMD

struct DemoProjectTests {
    @Test func theDemoIsBundled() throws {
        let source = try #require(DemoProject.bundledURL)
        for path in ["Showcase.md", "notes/Index.md", "notes/Reading.md", "assets/icon.png", "assets/wave.svg"] {
            #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent(path).path), "\(path)")
        }
        let showcase = try String(contentsOf: source.appendingPathComponent("Showcase.md"), encoding: .utf8)
        #expect(showcase.contains("```mermaid") && showcase.contains("$$") && showcase.contains("[^1]"))
        #expect(!showcase.contains("—"), "no em dashes")
    }

    @Test func installKeepsEditsAndRestoresMissingFiles() throws {
        let folder = try TestFolder()
        let location = folder.url.appendingPathComponent("LexMD Demo", isDirectory: true)
        let document = try DemoProject.install(to: location)
        #expect(document.lastPathComponent == "Showcase.md")
        #expect(FileManager.default.fileExists(atPath: location.appendingPathComponent("notes/Reading.md").path))

        try "# Mine\n".write(to: document, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: location.appendingPathComponent("notes"))
        _ = try DemoProject.install(to: location)
        #expect(try String(contentsOf: document, encoding: .utf8) == "# Mine\n", "edits survive")
        #expect(FileManager.default.fileExists(atPath: location.appendingPathComponent("notes/Index.md").path), "deleted files return")
    }

    @Test func recognizesTheDemoFolder() {
        #expect(DemoProject.isDemo(DemoProject.defaultLocation))
        #expect(!DemoProject.isDemo(URL(fileURLWithPath: "/tmp/elsewhere")))
        #expect(!DemoProject.isDemo(nil))
    }
}
