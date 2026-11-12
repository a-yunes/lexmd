import CoreServices
import Foundation
import Testing
@testable import LexMD

struct SidebarTreeTests {
    private func file(_ path: String) -> FileNode {
        FileNode(url: URL(fileURLWithPath: path), name: (path as NSString).lastPathComponent, children: nil)
    }

    private func folder(_ path: String, _ children: [FileNode]) -> FileNode {
        FileNode(url: URL(fileURLWithPath: path, isDirectory: true), name: (path as NSString).lastPathComponent, children: children)
    }

    private var tree: [FileNode] {
        [
            folder("/p/docs", [folder("/p/docs/guides", [file("/p/docs/guides/setup.md")]), file("/p/docs/intro.md")]),
            file("/p/README.md"),
        ]
    }

    @Test func rowsFollowExpansionAndCarryIt() {
        let collapsed = FileScanner.rows(tree, query: "", expanded: [])
        #expect(collapsed.map(\.id) == ["/p/docs", "/p/README.md"])
        #expect(collapsed.map(\.isExpanded) == [false, false])

        let open = FileScanner.rows(tree, query: "", expanded: ["/p/docs"])
        #expect(open.map(\.id) == ["/p/docs", "/p/docs/guides", "/p/docs/intro.md", "/p/README.md"])
        #expect(open.map(\.depth) == [0, 1, 1, 0])
        #expect(open.map(\.isExpanded) == [true, false, false, false])
    }

    @Test func filteredRowsShowEveryMatchExpanded() {
        let rows = FileScanner.rows(tree, query: "setup", expanded: [])
        #expect(rows.map(\.id) == ["/p/docs", "/p/docs/guides", "/p/docs/guides/setup.md"])
        #expect(rows.map(\.isExpanded) == [true, true, false])

        let compacted = FileScanner.compact(tree)
        #expect(FileScanner.rows(compacted, query: "guides/set", expanded: []).last?.id == "/p/docs/guides/setup.md",
                "merged folder names still match")
    }

    @Test func onlyEventsThatCanChangeTheTreeCount() {
        let paths = FileScanner.paths(in: tree)
        #expect(paths.files == ["/p/docs/guides/setup.md", "/p/docs/intro.md", "/p/README.md"])
        #expect(paths.folders == ["/p/docs", "/p/docs/guides"])
        let created = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemModified)
        let removed = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)
        let renamed = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)
        let modified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
        let dir = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
        let onDisk: Set<String> = ["/p/docs", "/p/docs/guides", "/p/docs/guides/setup.md", "/p/docs/intro.md", "/p/README.md",
                                   "/p/new.md", "/p/build", "/p/build/out", "/p/moved"]
        func changes(_ path: String, _ flags: FSEventStreamEventFlags) -> Bool {
            FileScanner.eventChangesTree(path: path, flags: flags, root: "/p", paths: { paths }, exists: { onDisk.contains($0) })
        }

        // A save to a recently created document repeats the created flag; the tree already has it.
        #expect(!changes("/p/README.md", created))
        #expect(!changes("/p/README.md", modified))
        #expect(!changes("/p/README.md", renamed), "an atomic save replaces the file in place")
        #expect(changes("/p/new.md", created))
        #expect(changes("/p/docs/intro.md", removed) == false, "still on disk")
        #expect(changes("/p/gone.md", removed) == false, "never in the tree")
        #expect(changes("/p/docs/guides/setup.md", renamed) == false)
        #expect(changes("/p/old.md", renamed) == false)
        #expect(!changes("/p/image.png", created), "only Markdown files appear in the tree")

        // Folders: new ones start empty, moved ones may hold documents, removed ones in the tree count.
        #expect(!changes("/p/build/out", FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) | dir))
        #expect(!changes("/p/tmp", removed | dir), "a folder without documents disappeared")
        #expect(changes("/p/moved", renamed | dir))
        #expect(changes("/p/docs/gone", removed | dir) == false)
        let missingFolder = FileScanner.eventChangesTree(
            path: "/p/docs/guides/", flags: removed | dir, root: "/p", paths: { paths }, exists: { _ in false }
        )
        #expect(missingFolder)
        let deletedDocument = FileScanner.eventChangesTree(
            path: "/p/README.md", flags: removed, root: "/p", paths: { paths }, exists: { _ in false }
        )
        #expect(deletedDocument)

        // Lost events always rescan, except inside ignored folders.
        let mustScan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        #expect(changes("/p/docs", mustScan))
        #expect(!changes("/p/.git/objects", mustScan))
        #expect(!changes("/p/node_modules/x.md", created))

        // The scan never enters ~/Library, so its constant cache churn is skipped too.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let library = FileScanner.eventChangesTree(
            path: home + "/Library/Caches/app", flags: renamed | dir, root: home, paths: { ([], []) }, exists: { _ in true }
        )
        #expect(!library)
    }

    @Test func eventsWithoutStructuralFlagsSkipTheTreeLookup() {
        var looked = false
        let changed = FileScanner.eventChangesTree(
            path: "/p/a.md", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified), root: "/p",
            paths: { looked = true; return ([], []) }, exists: { _ in true }
        )
        #expect(!changed)
        #expect(!looked)
    }
}
