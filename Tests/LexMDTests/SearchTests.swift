import Foundation
import Testing
@testable import LexMD

struct SearchTests {
    @Test func cancellingTheCallerStopsDetachedWork() async {
        let started = Date()
        let task = Task {
            await runDetached { () -> Bool in
                while !Task.isCancelled, Date().timeIntervalSince(started) < 10 {}
                return Task.isCancelled
            }
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let stoppedByCancellation = await task.value
        #expect(stoppedByCancellation)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func textCacheRereadsChangedFiles() throws {
        let folder = try TestFolder()
        let file = try folder.write("a.md", "first")
        #expect(QuickSearchEngine.read(file.path) == "first")
        try "second".write(to: file, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        #expect(QuickSearchEngine.read(file.path) == "second")
    }

    @Test func searchFindsHitsAndPrefersOverrides() throws {
        let folder = try TestFolder()
        let a = try folder.write("a.md", "needle one\nhay\nneedle two\n")
        let b = try folder.write("b.md", "nothing here\n")
        let files = [a, b].map { SearchableFile(path: $0.path, name: $0.lastPathComponent, folder: "") }
        let results = QuickSearchEngine.run(
            query: "needle", options: SearchOptions(), files: files,
            overrides: [b.path: "unsaved needle\n"], currentPath: b.path
        )
        #expect(results.hits.count == 3)
        #expect(results.hits.first?.path == b.path, "the open document comes first")
        #expect(results.hitCounts[a.path] == 2)
        #expect(results.hits.map(\.line) == [1, 1, 3])
    }

    @Test func scanStopsWhenCancelled() async throws {
        let folder = try TestFolder()
        for i in 0..<50 { try folder.write("doc\(i).md", "x") }
        let task = Task.detached { () -> [FileNode] in
            withUnsafeCurrentTask { $0?.cancel() }
            return FileScanner.scan(folder.url)
        }
        #expect(await task.value.isEmpty)
        #expect(FileScanner.scan(folder.url).count == 50)
    }
}

struct OpenQuicklyNameTests {
    @Test func queriesWithTheExtensionMatchFileNames() {
        let files = [
            SearchableFile(path: "/p/README.md", name: "README.md", folder: ""),
            SearchableFile(path: "/p/docs/guide.markdown", name: "guide.markdown", folder: "docs"),
        ]
        #expect(QuickSearchEngine.fuzzyFiles(query: "readme.md", files: files).first?.path == "/p/README.md")
        #expect(QuickSearchEngine.fuzzyFiles(query: "readme", files: files).first?.path == "/p/README.md")
        #expect(QuickSearchEngine.fuzzyFiles(query: "docs/guide.markdown", files: files).first?.path == "/p/docs/guide.markdown")
    }
}

struct FuzzyMatchTests {
    @Test func scatteredAndContiguousMatchesStillScore() {
        #expect(QuickSearchEngine.fuzzy("skrev", in: "Sketches/rough-Review") != nil)
        #expect(QuickSearchEngine.fuzzy("guide", in: "User Guide")?.1 == [5, 6, 7, 8, 9])
        #expect(QuickSearchEngine.fuzzy("xyz", in: "README") == nil)
        #expect(QuickSearchEngine.fuzzy("emdaer", in: "README") == nil, "letters out of order never match")
    }

    @Test func fileMatchingStopsWhenSuperseded() async {
        let files = (0..<20_000).map { SearchableFile(path: "/p/note\($0).md", name: "note\($0).md", folder: "") }
        let task = Task.detached { () -> [FileMatch] in
            withUnsafeCurrentTask { $0?.cancel() }
            return QuickSearchEngine.fuzzyFiles(query: "note", files: files, limit: 60)
        }
        #expect(await task.value.isEmpty)
        #expect(QuickSearchEngine.fuzzyFiles(query: "note1", files: files, limit: 5).count == 5)
    }

    @Test func previewLinesMatchSplittingTheWholeText() {
        for text in ["", "one", "one\n", "a\r\nb\r\n\nc", "\n\n\n", "x\ny\nz\nw"] {
            for count in [1, 2, 3, 10] {
                #expect(AppModel.lines(of: text, count: count) == Array(text.components(separatedBy: "\n").prefix(count)))
            }
        }
    }
}
