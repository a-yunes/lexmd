import AppKit
import Testing
@testable import LexMD

struct ShortcutGroupingTests {
    @Test func groupsFollowTheMenuBar() {
        #expect(ShortcutAction.Category.allCases.map(\.rawValue) == [
            "LexMD", "File", "Edit", "Format", "View", "Go", "Source Control", "Window", "Sidebar",
        ])
        #expect(ShortcutAction.installCommandLineTool.category == .app)
        #expect(ShortcutAction.printDocument.category == .file)
        #expect(ShortcutAction.copyRichText.category == .edit)
        #expect(ShortcutAction.findInFiles.category == .edit)
        #expect(ShortcutAction.goBack.category == .go)
        #expect(ShortcutAction.showNextTab.category == .window)
        #expect(ShortcutAction.showPreviousTab.category == .window)
    }

    @Test func commandsAreListedInMenuOrder() {
        func listed(_ category: ShortcutAction.Category) -> [ShortcutAction] {
            ShortcutAction.allCases.filter { $0.category == category }
        }
        #expect(listed(.file) == [
            .newDocument, .newFolder, .open, .quickOpen, .newTab, .closeTab, .reopenClosedTab, .save,
            .revealInFinder, .renameItem, .duplicateItem, .moveToTrash, .exportPDF, .exportHTML, .printDocument,
        ])
        #expect(listed(.edit) == [
            .copyRichText, .find, .findAndReplace, .findNext, .findPrevious, .useSelectionForFind, .jumpToSelection,
            .findInFiles,
        ])
        #expect(listed(.view) == [
            .toggleSidebar, .toggleOutline, .previewOnly, .split, .editorOnly, .focusMode, .typewriterScrolling,
            .expandAll, .collapseAll, .zoomIn, .zoomOut, .zoomReset,
        ])
        #expect(listed(.window) == [.showPreviousTab, .showNextTab])
    }

    /// Saved shortcuts are keyed by these names, so they must never change.
    @Test func savedShortcutKeysAreStable() {
        #expect(Set(ShortcutAction.allCases.map(\.rawValue)) == [
            "open", "quickOpen", "newDocument", "save", "revealInFinder",
            "toggleSidebar", "previewOnly", "split", "editorOnly", "expandAll", "collapseAll", "zoomIn", "zoomOut", "zoomReset",
            "find", "findNext", "findPrevious", "findInFiles", "goBack", "goForward",
            "bold", "italic", "strikethrough", "inlineCode", "link",
            "newFolder", "renameItem", "duplicateItem", "moveToTrash",
            "closeTab", "reopenClosedTab", "showNextTab", "showPreviousTab", "newTab",
            "formatTable", "focusMode", "typewriterScrolling", "commit",
            "exportPDF", "exportHTML", "printDocument", "copyRichText", "toggleOutline",
            "installCommandLineTool", "renameInSidebar", "trashInSidebar",
            "findAndReplace", "useSelectionForFind", "jumpToSelection",
        ])
    }

    @Test func sourceControlGroupAppearsOnlyWithARepository() {
        let without = ShortcutAction.sections(matching: "", includingSourceControl: false, shortcut: \.defaultShortcut)
        let with = ShortcutAction.sections(matching: "", includingSourceControl: true, shortcut: \.defaultShortcut)
        #expect(!without.contains { $0.category == .sourceControl })
        #expect(with.map(\.category) == ShortcutAction.Category.allCases)
        #expect(with.flatMap(\.actions).count == ShortcutAction.allCases.count)
    }
}

struct ShortcutSearchTests {
    private func results(_ query: String) -> Set<ShortcutAction> {
        Set(ShortcutAction.sections(matching: query, includingSourceControl: true, shortcut: \.defaultShortcut)
            .flatMap(\.actions))
    }

    @Test func findsCommandsByName() {
        #expect(results("bold") == [.bold])
        #expect(results("open").isSuperset(of: [.open, .quickOpen, .reopenClosedTab]))
        #expect(results("export as") == [.exportPDF, .exportHTML])
        #expect(results("Open…").isEmpty == false, "the ellipsis in menu titles is ignored")
        #expect(results("  ").count == ShortcutAction.allCases.count)
    }

    @Test func findsCommandsByShortcutSymbols() {
        #expect(results("⌘B") == [.toggleSidebar, .bold])
        #expect(results("⇧⌘B") == [.bold])
        #expect(results("⌘⇧b") == [.bold], "modifier order and case do not matter")
        #expect(results("⌥⌘←") == [.collapseAll])
        #expect(results("⌘+") == [.zoomIn])
        #expect(results("⌘K").contains(.link))
        #expect(results("⌘K").contains(.commit), "⌥⌘K has ⌘ and K too")
    }

    @Test func findsCommandsBySpelledOutShortcuts() {
        #expect(results("cmd shift b") == [.bold])
        #expect(results("command+shift+b") == [.bold])
        #expect(results("ctrl tab") == [.showNextTab, .showPreviousTab])
        #expect(results("cmd+=") == [.zoomIn])
        #expect(results("cmd++") == [.zoomIn])
        #expect(results("return") == [.renameInSidebar])
        #expect(results("option cmd left") == [.collapseAll])
    }

    @Test func plainLettersSearchNamesOnly() {
        #expect(!results("k").contains(.commit), "Commit is ⌥⌘K, but its name has no k")
        #expect(Shortcut.searchPattern("b") == nil)
        #expect(Shortcut.searchPattern("bold") == nil)
        #expect(Shortcut.searchPattern("cmd b c") == nil, "two keys are not a shortcut")
    }
}

struct ReservedShortcutTests {
    @Test func refusesSystemShortcuts() throws {
        let reserved = [
            "cmd+q", "cmd+h", "option+cmd+h", "cmd+m", "cmd+,", "cmd+tab", "cmd+space", "ctrl+space", "cmd+`",
            "shift+cmd+3", "shift+cmd+4", "shift+cmd+5", "option+cmd+escape", "ctrl+cmd+f", "cmd+c", "cmd+v",
        ]
        for string in reserved {
            let shortcut = try #require(Shortcut(string: string))
            #expect(shortcut.reservedUse != nil, "\(string)")
        }
        #expect(Shortcut(string: "cmd+q")?.reservationNote == "⌘Q is reserved for Quit LexMD.")
        #expect(Shortcut(string: "cmd+space")?.reservationNote == "⌘Space is reserved for Spotlight.")
    }

    @Test func noDefaultShortcutIsReserved() {
        for action in ShortcutAction.allCases {
            #expect(action.defaultShortcut?.reservedUse == nil, "\(action.rawValue)")
        }
        #expect(Shortcut(string: "cmd+b")?.reservedUse == nil)
        #expect(Shortcut(string: "shift+cmd+m")?.reservedUse == nil)
    }

    @Test func recordsEscapeWithModifiers() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53
        ))
        let shortcut = try #require(Shortcut(event: event))
        #expect(shortcut.string == "option+cmd+escape")
        #expect(shortcut.display == "⌥⌘⎋")
        #expect(shortcut.reservedUse == "Force Quit")
    }
}

struct SettingsTabTests {
    @Test func sourceControlFallsBackToGeneralWithoutARepository() {
        #expect(SettingsTab.sourceControl.resolved(showsSourceControl: false) == .general)
        #expect(SettingsTab.sourceControl.resolved(showsSourceControl: true) == .sourceControl)
        #expect(SettingsTab.shortcuts.resolved(showsSourceControl: false) == .shortcuts)
        #expect(SettingsTab(rawValue: "shortcuts") == .shortcuts)
    }
}
