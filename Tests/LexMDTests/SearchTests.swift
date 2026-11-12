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
