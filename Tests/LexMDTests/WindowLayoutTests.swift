import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import LexMD

/// The window's layout rules: when the outline fits, how tabs share the strip, and the names
/// the toolbar shows.
struct WindowLayoutTests {
    @Test func outlineStepsAsideOnlyWhenTheWindowIsTooNarrow() {
        // The narrowest window still fits the sidebar, one pane and the outline.
        #expect(OutlineLayout.fits(windowWidth: WindowLayout.minWidth, sidebarVisible: true, mode: .read))
        #expect(OutlineLayout.fits(windowWidth: WindowLayout.minWidth, sidebarVisible: true, mode: .edit))
        // Two panes need more room; hiding the sidebar makes it.
        #expect(!OutlineLayout.fits(windowWidth: WindowLayout.minWidth, sidebarVisible: true, mode: .split))
        #expect(OutlineLayout.fits(windowWidth: WindowLayout.minWidth, sidebarVisible: false, mode: .split))
        #expect(OutlineLayout.fits(windowWidth: 920, sidebarVisible: true, mode: .split))
        #expect(!OutlineLayout.fits(windowWidth: 919, sidebarVisible: true, mode: .split))
        #expect(OutlineLayout.fits(windowWidth: .infinity, sidebarVisible: true, mode: .split), "before the window reports its width")
    }

    @Test func outlineWidthStaysInItsRange() {
        #expect(OutlineLayout.clampedWidth(10) == OutlineLayout.minWidth)
        #expect(OutlineLayout.clampedWidth(1000) == OutlineLayout.maxWidth)
        #expect(OutlineLayout.clampedWidth(300) == 300)
        #expect(OutlineLayout.minWidth <= OutlineLayout.idealWidth && OutlineLayout.idealWidth <= OutlineLayout.maxWidth)
    }

    @Test func tabsShareTheStripUntilTheyOverflow() {
        let few = TabStripLayout(available: 800, count: 2)
        #expect(few.tabWidth == TabStripLayout.maxTabWidth && !few.overflows)

        let snug = TabStripLayout(available: 12 + 4 * 120 + 3 * 2, count: 4)
        #expect(snug.tabWidth == TabStripLayout.minTabWidth && !snug.overflows)

        let many = TabStripLayout(available: 12 + 4 * 120 + 3 * 2 - 1, count: 4)
        #expect(many.tabWidth == TabStripLayout.minTabWidth && many.overflows)

        #expect(!TabStripLayout(available: 50, count: 1).overflows, "one tab never needs the tab menu")
        #expect(!TabStripLayout(available: 0, count: 0).overflows)
    }

    @Test func viewModeControlUsesTheMenuNames() {
        #expect(ViewMode.pickerOrder == [.read, .split, .edit])
        #expect(ViewMode.pickerOrder.map(\.command.title) == ["Preview Only", "Preview and Editor", "Editor Only"])
        #expect(Set(ViewMode.allCases) == Set(ViewMode.pickerOrder))
    }

    @MainActor
    @Test func tooltipsNeverEndWithASpace() {
        let model = AppModel.shared
        for action in ShortcutAction.allCases {
            let text = model.helpText(action.title, action)
            #expect(!text.hasSuffix(" ") && text.hasPrefix(action.title), "\(action)")
        }
    }

    @Test func toolbarItemsHaveDistinctIdentifiers() {
        let ids = [
            ToolbarID.title, ToolbarID.commit, ToolbarID.viewMode, ToolbarID.outline,
            ToolbarID.trailingSidebar, ToolbarID.expandAll, ToolbarID.findInFiles, ToolbarID.open,
        ]
        #expect(Set(ids).count == ids.count)
        #expect(!ids.contains(ToolbarID.main))
    }

    @Test func openButtonUsesTheMenuName() {
        #expect(ShortcutAction.open.title == "Open…")
    }
}

struct DocumentPathTests {
    @Test func listsTheDocumentThenEachEnclosingFolder() {
        let components = DocumentPath.components(of: URL(fileURLWithPath: "/Users/someone/Notes/Plan.md"))
        #expect(components.map(\.path) == ["/Users/someone/Notes/Plan.md", "/Users/someone/Notes", "/Users/someone", "/Users", "/"])
        #expect(DocumentPath.components(of: URL(fileURLWithPath: "/")).map(\.path) == ["/"])
    }

    @Test func standardizesThePath() {
        let components = DocumentPath.components(of: URL(fileURLWithPath: "/Users/someone/Notes/../Plan.md"))
        #expect(components.first?.path == "/Users/someone/Plan.md")
    }
}

struct QuickLookShortcutTests {
    @Test func spaceIsARemappableSidebarDefault() throws {
        let shortcut = try #require(ShortcutAction.quickLookInSidebar.defaultShortcut)
        #expect(shortcut.string == "space" && shortcut.display == "Space")
        #expect(shortcut.matches(.space, modifiers: []))
        #expect(!shortcut.matches(.space, modifiers: .command))
        #expect(ShortcutAction.quickLookInSidebar.allowsPlainKeys)
        #expect(ShortcutAction.quickLookInSidebar.category == .sidebar)
    }
}

struct TabDragTests {
    @Test func tabDragCarriesItsIdentityAndItsFile() async throws {
        #expect(TabDrag.type.identifier == "io.github.a-yunes.lexmd.document-tab")
        let tab = DocumentTab(path: "/tmp/Plan.md")
        let provider = TabDrag.provider(for: tab)
        #expect(provider.hasItemConformingToTypeIdentifier(TabDrag.type.identifier))
        #expect(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        #expect(!provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), "dropping a tab never inserts its identity as text")

        let url: URL? = await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                continuation.resume(returning: (object as? NSURL) as URL?)
            }
        }
        #expect(url?.path == "/tmp/Plan.md")

        let identity: String? = await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: TabDrag.type.identifier) { data, _ in
                continuation.resume(returning: data.map { String(decoding: $0, as: UTF8.self) })
            }
        }
        #expect(identity == tab.id.uuidString)
    }
}
