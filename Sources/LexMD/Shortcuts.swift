import AppKit
import SwiftUI

/// A key combination, stored as a compact string such as "cmd+shift+b" or "cmd+option+leftArrow".
struct Shortcut: Hashable {
    var key: String
    var modifiers: NSEvent.ModifierFlags

    private static let order: [(NSEvent.ModifierFlags, String, String)] = [
        (.control, "ctrl", "⌃"), (.option, "option", "⌥"), (.shift, "shift", "⇧"), (.command, "cmd", "⌘"),
    ]

    private static let specialKeys: [UInt16: String] = [
        123: "leftArrow", 124: "rightArrow", 125: "downArrow", 126: "upArrow",
        36: "return", 76: "return", 48: "tab", 49: "space", 51: "delete", 117: "deleteForward",
        115: "home", 119: "end", 116: "pageUp", 121: "pageDown", 53: "escape",
    ]

    private static let symbols: [String: String] = [
        "leftArrow": "←", "rightArrow": "→", "downArrow": "↓", "upArrow": "↑",
        "return": "↩", "tab": "⇥", "space": "Space", "delete": "⌫", "deleteForward": "⌦",
        "home": "↖", "end": "↘", "pageUp": "⇞", "pageDown": "⇟", "escape": "⎋",
    ]

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key
        self.modifiers = modifiers.intersection([.command, .shift, .option, .control])
    }

    /// Parses "cmd+shift+b"; returns nil for malformed input.
    init?(string: String) {
        var parts = string.split(separator: "+").map(String.init)
        guard let key = parts.popLast(), !key.isEmpty else { return nil }
        var flags: NSEvent.ModifierFlags = []
        for part in parts {
            guard let entry = Self.order.first(where: { $0.1 == part }) else { return nil }
            flags.insert(entry.0)
        }
        self.init(key: key, modifiers: flags)
    }

    /// Keys that `allowingPlainKeys` accepts without ⌘, ⌃ or ⌥.
    private static let plainKeys: Set<String> = ["return", "space"]

    /// Builds a shortcut from a key press. Requires ⌘, ⌃ or ⌥ so plain typing never becomes a
    /// shortcut; with `allowingPlainKeys`, Return and Space work alone too.
    init?(event: NSEvent, allowingPlainKeys: Bool = false) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard !flags.intersection([.command, .control, .option]).isEmpty
            || allowingPlainKeys && Self.specialKeys[event.keyCode].map(Self.plainKeys.contains) == true else { return nil }
        if let special = Self.specialKeys[event.keyCode] {
            self.init(key: special, modifiers: flags)
            return
        }
        guard let base = event.characters(byApplyingModifiers: [])?.lowercased(),
              let character = base.first, base.count == 1,
              !character.isWhitespace, !character.isNewline else { return nil }
        self.init(key: String(character), modifiers: flags)
    }

    var string: String {
        (Self.order.filter { modifiers.contains($0.0) }.map(\.1) + [key]).joined(separator: "+")
    }

    var display: String {
        let mods = Self.order.filter { modifiers.contains($0.0) }.map(\.2).joined()
        let keyText = Self.symbols[key] ?? (key == "=" ? "+" : key.uppercased())
        return mods + keyText
    }

    var keyboardShortcut: KeyboardShortcut? {
        let equivalent: KeyEquivalent
        switch key {
        case "leftArrow": equivalent = .leftArrow
        case "rightArrow": equivalent = .rightArrow
        case "upArrow": equivalent = .upArrow
        case "downArrow": equivalent = .downArrow
        case "return": equivalent = .return
        case "tab": equivalent = .tab
        case "space": equivalent = .space
        case "delete": equivalent = .delete
        case "deleteForward": equivalent = .deleteForward
        case "home": equivalent = .home
        case "escape": equivalent = .escape
        case "end": equivalent = .end
        case "pageUp": equivalent = .pageUp
        case "pageDown": equivalent = .pageDown
        default:
            guard key.count == 1, let character = key.first else { return nil }
            equivalent = KeyEquivalent(character)
        }
        var eventModifiers: EventModifiers = []
        if modifiers.contains(.command) { eventModifiers.insert(.command) }
        if modifiers.contains(.shift) { eventModifiers.insert(.shift) }
        if modifiers.contains(.option) { eventModifiers.insert(.option) }
        if modifiers.contains(.control) { eventModifiers.insert(.control) }
        return KeyboardShortcut(equivalent, modifiers: eventModifiers)
    }

    /// Whether a key press in a SwiftUI view is this shortcut.
    func matches(_ key: KeyEquivalent, modifiers: EventModifiers) -> Bool {
        guard let shortcut = keyboardShortcut else { return false }
        let pressed = modifiers.intersection([.command, .shift, .option, .control])
        return shortcut.modifiers == pressed && shortcut.key.character.lowercased() == key.character.lowercased()
    }

    static func == (lhs: Shortcut, rhs: Shortcut) -> Bool { lhs.string == rhs.string }
    func hash(into hasher: inout Hasher) { hasher.combine(string) }
}

/// Every command that can carry a keyboard shortcut, with its default.
enum ShortcutAction: String, CaseIterable, Identifiable {
    // Declared in menu order, which is the order Settings lists them in. The raw values are the
    // keys of saved shortcuts, so a case is never renamed.
    case installCommandLineTool
    case newDocument, newFolder, newTab, open, quickOpen, closeWindow, closeTab, reopenClosedTab, save
    case revealInFinder, renameItem, duplicateItem, moveTo, moveToTrash, exportPDF, exportHTML, printDocument
    case copyRichText, find, findAndReplace, findNext, findPrevious, useSelectionForFind, jumpToSelection, findInFiles
    case bold, italic, strikethrough, inlineCode, link, formatTable
    case toggleSidebar, toggleOutline, previewOnly, split, editorOnly, focusMode, typewriterScrolling
    case expandAll, collapseAll, zoomIn, zoomOut, zoomReset
    case goBack, goForward
    case commit
    case showPreviousTab, showNextTab
    case renameInSidebar, trashInSidebar, quickLookInSidebar

    var id: String { rawValue }

    /// The menu a command appears in, in menu bar order. The raw value is the menu's name.
    enum Category: String, CaseIterable {
        case app = "LexMD", file = "File", edit = "Edit", format = "Format", view = "View", go = "Go"
        case sourceControl = "Source Control", window = "Window"
        /// Commands for the file list, which work while it has focus.
        case sidebar = "Sidebar"
    }

    var category: Category {
        switch self {
        case .installCommandLineTool: .app
        case .newDocument, .newFolder, .newTab, .open, .quickOpen, .closeWindow, .closeTab, .reopenClosedTab, .save,
             .revealInFinder, .renameItem, .duplicateItem, .moveTo, .moveToTrash, .exportPDF, .exportHTML, .printDocument: .file
        case .copyRichText, .find, .findAndReplace, .findNext, .findPrevious, .useSelectionForFind, .jumpToSelection,
             .findInFiles: .edit
        case .bold, .italic, .strikethrough, .inlineCode, .link, .formatTable: .format
        case .toggleSidebar, .toggleOutline, .previewOnly, .split, .editorOnly, .focusMode, .typewriterScrolling,
             .expandAll, .collapseAll, .zoomIn, .zoomOut, .zoomReset: .view
        case .goBack, .goForward: .go
        case .commit: .sourceControl
        case .showPreviousTab, .showNextTab: .window
        case .renameInSidebar, .trashInSidebar, .quickLookInSidebar: .sidebar
        }
    }

    var title: String {
        switch self {
        case .open: "Open…"
        case .quickOpen: "Open Quickly…"
        case .newDocument: "New Document"
        case .save: "Save"
        case .revealInFinder: "Show in Finder"
        case .toggleSidebar: "Show or Hide Sidebar"
        case .previewOnly: "Preview Only"
        case .split: "Preview and Editor"
        case .editorOnly: "Editor Only"
        case .expandAll: "Expand All Folders"
        case .collapseAll: "Collapse All Folders"
        case .zoomIn: "Make Text Bigger"
        case .zoomOut: "Make Text Smaller"
        case .zoomReset: "Actual Size"
        case .find: "Find…"
        case .findNext: "Find Next"
        case .findPrevious: "Find Previous"
        case .findInFiles: "Find in Files…"
        case .findAndReplace: "Find and Replace…"
        case .useSelectionForFind: "Use Selection for Find"
        case .jumpToSelection: "Jump to Selection"
        case .goBack: "Back"
        case .goForward: "Forward"
        case .bold: "Bold"
        case .italic: "Italic"
        case .strikethrough: "Strikethrough"
        case .inlineCode: "Inline Code"
        case .link: "Link"
        case .newFolder: "New Folder"
        case .renameItem: "Rename"
        case .duplicateItem: "Duplicate"
        case .moveTo: "Move To…"
        case .moveToTrash: "Move to Trash"
        case .closeTab: "Close Tab"
        case .closeWindow: "Close Window"
        case .newTab: "New Tab…"
        case .reopenClosedTab: "Reopen Closed Tab"
        case .showNextTab: "Show Next Tab"
        case .showPreviousTab: "Show Previous Tab"
        case .formatTable: "Format Table"
        case .focusMode: "Focus Mode"
        case .typewriterScrolling: "Typewriter Scrolling"
        case .commit: "Commit…"
        case .exportPDF: "Export as PDF…"
        case .exportHTML: "Export as HTML…"
        case .printDocument: "Print…"
        case .copyRichText: "Copy as Rich Text"
        case .toggleOutline: "Show or Hide Outline"
        case .installCommandLineTool: "Install Command Line Tool…"
        case .renameInSidebar: "Rename in Sidebar"
        case .trashInSidebar: "Move to Trash in Sidebar"
        case .quickLookInSidebar: "Quick Look in Sidebar"
        }
    }

    /// Sidebar commands act only while the file list has focus, so they may use a key
    /// without modifiers, such as Return.
    var allowsPlainKeys: Bool { category == .sidebar }

    var defaultShortcut: Shortcut? {
        let value: String = switch self {
        case .open: "cmd+o"
        case .quickOpen: "cmd+p"
        case .newDocument: "cmd+n"
        case .save: "cmd+s"
        case .revealInFinder: "cmd+shift+r"
        case .toggleSidebar: "cmd+b"
        case .previewOnly: "cmd+1"
        case .split: "cmd+2"
        case .editorOnly: "cmd+3"
        case .expandAll: "option+cmd+rightArrow"
        case .collapseAll: "option+cmd+leftArrow"
        case .zoomIn: "cmd+="
        case .zoomOut: "cmd+-"
        case .zoomReset: "cmd+0"
        case .find: "cmd+f"
        case .findNext: "cmd+g"
        case .findPrevious: "shift+cmd+g"
        case .findInFiles: "shift+cmd+f"
        // The standard ⌥⌘F and ⌘E belong to Focus Mode and Inline Code.
        case .findAndReplace: ""
        case .useSelectionForFind: ""
        case .jumpToSelection: "cmd+j"
        case .goBack: "cmd+["
        case .goForward: "cmd+]"
        case .bold: "shift+cmd+b"
        case .italic: "cmd+i"
        case .strikethrough: "shift+cmd+x"
        case .inlineCode: "cmd+e"
        case .link: "cmd+k"
        case .newFolder: "shift+cmd+n"
        case .renameItem: ""
        case .duplicateItem: ""
        case .moveTo: ""
        case .moveToTrash: ""
        case .closeTab: "cmd+w"
        case .closeWindow: "shift+cmd+w"
        case .newTab: "cmd+t"
        case .reopenClosedTab: "shift+cmd+t"
        case .showNextTab: "ctrl+tab"
        case .showPreviousTab: "ctrl+shift+tab"
        case .formatTable: "option+cmd+t"
        case .focusMode: "option+cmd+f"
        case .typewriterScrolling: ""
        case .commit: "option+cmd+k"
        case .exportPDF: "shift+cmd+e"
        case .exportHTML: ""
        case .printDocument: "option+cmd+p"
        case .copyRichText: "option+cmd+c"
        case .toggleOutline: "option+cmd+o"
        case .installCommandLineTool: ""
        case .renameInSidebar: "return"
        case .trashInSidebar: "cmd+delete"
        case .quickLookInSidebar: "space"
        }
        return Shortcut(string: value)
    }
}

extension AppModel {
    private static let noShortcut = "none"

    func shortcut(for action: ShortcutAction) -> Shortcut? {
        guard let stored = shortcutOverrides[action.rawValue] else { return action.defaultShortcut }
        return stored == Self.noShortcut ? nil : Shortcut(string: stored)
    }

    func keyboardShortcut(_ action: ShortcutAction) -> KeyboardShortcut? {
        shortcut(for: action)?.keyboardShortcut
    }

    /// A tooltip that names the command's current shortcut, if it has one.
    func helpText(_ title: String, _ action: ShortcutAction) -> String {
        shortcut(for: action).map { "\(title) (\($0.display))" } ?? title
    }

    func isCustomized(_ action: ShortcutAction) -> Bool {
        shortcutOverrides[action.rawValue] != nil
    }

    /// Makes stored overrides consistent again: one command per shortcut, and none that macOS
    /// keeps for itself. Overrides saved before a default existed can collide with it; the
    /// shortcut the user chose wins, and the command whose default it was gets none.
    static func resolvingShortcutConflicts(_ stored: [String: String]) -> (overrides: [String: String], cleared: [ShortcutAction]) {
        var overrides = stored
        // A reserved combination never works; the command goes back to its default.
        for action in ShortcutAction.allCases {
            if let value = overrides[action.rawValue], value != noShortcut,
               Shortcut(string: value)?.reservationNote != nil {
                overrides[action.rawValue] = nil
            }
        }
        var claimed: Set<String> = []
        var cleared: [ShortcutAction] = []
        // Chosen shortcuts first, in menu order; a later duplicate loses its shortcut.
        for action in ShortcutAction.allCases {
            guard let value = overrides[action.rawValue], value != noShortcut else { continue }
            if !claimed.insert(value).inserted { overrides[action.rawValue] = noShortcut }
        }
        for action in ShortcutAction.allCases where overrides[action.rawValue] == nil {
            guard let value = action.defaultShortcut?.string else { continue }
            if claimed.contains(value) {
                overrides[action.rawValue] = noShortcut
                cleared.append(action)
            } else {
                claimed.insert(value)
            }
        }
        return (overrides, cleared)
    }

    // MARK: Recording

    /// Starts recording a shortcut for `action` in `window` (Settings), stopping any other recording.
    func startRecordingShortcut(_ action: ShortcutAction, in window: NSWindow?) {
        stopRecordingShortcut()
        recordingShortcut = action
        shortcutWindow = window
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.recordShortcutKey(event) ?? event
        }
    }

    func stopRecordingShortcut() {
        recordingShortcut = nil
        shortcutWindow = nil
        if let monitor = shortcutMonitor {
            NSEvent.removeMonitor(monitor)
            shortcutMonitor = nil
        }
    }

    /// Handles a key while recording. Keys for other windows stop the recording and go on to
    /// their window, so typing in a document is never taken for a shortcut.
    func recordShortcutKey(_ event: NSEvent) -> NSEvent? {
        guard let action = recordingShortcut else { return event }
        if let window = shortcutWindow, event.window !== window {
            stopRecordingShortcut()
            return event
        }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 53, modifiers.isEmpty {
            stopRecordingShortcut()
        } else if event.keyCode == 51 || event.keyCode == 117, modifiers.isEmpty {
            setShortcut(nil, for: action)
            stopRecordingShortcut()
        } else if let shortcut = Shortcut(event: event, allowingPlainKeys: action.allowsPlainKeys) {
            if let note = shortcut.reservationNote {
                // Keep recording so another combination can be tried right away.
                shortcutNote = note
                AccessibilityNotification.Announcement(note).post()
                NSSound.beep()
            } else {
                setShortcut(shortcut, for: action)
                stopRecordingShortcut()
            }
        } else {
            NSSound.beep()
        }
        return nil
    }

    /// Assigns a shortcut; any other command already using it loses its shortcut.
    func setShortcut(_ shortcut: Shortcut?, for action: ShortcutAction) {
        var overrides = shortcutOverrides
        var cleared: [ShortcutAction] = []
        if let shortcut {
            for other in ShortcutAction.allCases where other != action && self.shortcut(for: other) == shortcut {
                overrides[other.rawValue] = Self.noShortcut
                cleared.append(other)
            }
        }
        let value = shortcut?.string ?? Self.noShortcut
        overrides[action.rawValue] = value == action.defaultShortcut?.string ? nil : value
        shortcutOverrides = overrides
        shortcutNote = cleared.isEmpty ? nil
            : "\(shortcut?.display ?? "") was removed from \(cleared.map(\.title).joined(separator: ", "))."
    }

    func resetShortcut(_ action: ShortcutAction) {
        setShortcut(action.defaultShortcut, for: action)
    }

    func resetAllShortcuts() {
        shortcutOverrides = [:]
        shortcutNote = nil
    }
}
