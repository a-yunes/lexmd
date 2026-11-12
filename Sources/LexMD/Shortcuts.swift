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
        115: "home", 119: "end", 116: "pageUp", 121: "pageDown",
    ]

    private static let symbols: [String: String] = [
        "leftArrow": "←", "rightArrow": "→", "downArrow": "↓", "upArrow": "↑",
        "return": "↩", "tab": "⇥", "space": "Space", "delete": "⌫", "deleteForward": "⌦",
        "home": "↖", "end": "↘", "pageUp": "⇞", "pageDown": "⇟",
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

    /// Builds a shortcut from a key press. Requires ⌘, ⌃ or ⌥ so plain typing never becomes a shortcut.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
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

    static func == (lhs: Shortcut, rhs: Shortcut) -> Bool { lhs.string == rhs.string }
    func hash(into hasher: inout Hasher) { hasher.combine(string) }
}

/// Every command that can carry a keyboard shortcut, with its default.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case open, quickOpen, newDocument, save, revealInFinder
    case toggleSidebar, previewOnly, split, editorOnly, expandAll, collapseAll, zoomIn, zoomOut, zoomReset
    case find, findNext, findPrevious, findInFiles
    case goBack, goForward
    case bold, italic, strikethrough, inlineCode, link
    case newFolder, renameItem, duplicateItem, moveToTrash
    case closeTab, reopenClosedTab, showNextTab, showPreviousTab
    case newTab
    case formatTable
    case focusMode, typewriterScrolling
    case commit
    case exportPDF, exportHTML, printDocument, copyRichText
    case toggleOutline
    case installCommandLineTool

    var id: String { rawValue }

    enum Category: String, CaseIterable {
        case file = "File", navigate = "Navigate", find = "Find", view = "View", format = "Format"
        case sourceControl = "Source Control"
    }

    var category: Category {
        switch self {
        case .open, .quickOpen, .newDocument, .save, .revealInFinder: .file
        case .goBack, .goForward: .navigate
        case .find, .findNext, .findPrevious, .findInFiles: .find
        case .toggleSidebar, .editorOnly, .split, .previewOnly, .expandAll, .collapseAll, .zoomIn, .zoomOut, .zoomReset: .view
        case .toggleOutline: .view
        case .bold, .italic, .strikethrough, .inlineCode, .link: .format
        case .newFolder, .renameItem, .duplicateItem, .moveToTrash, .closeTab, .reopenClosedTab, .newTab: .file
        case .showNextTab, .showPreviousTab: .navigate
        case .formatTable: .format
        case .focusMode, .typewriterScrolling: .view
        case .commit: .sourceControl
        case .exportPDF, .exportHTML, .printDocument, .copyRichText: .file
        case .installCommandLineTool: .file
        }
    }

    var title: String {
        switch self {
        case .open: "Open…"
        case .quickOpen: "Open Quickly…"
        case .newDocument: "New Document…"
        case .save: "Save"
        case .revealInFinder: "Reveal in Finder"
        case .toggleSidebar: "Show/Hide Sidebar"
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
        case .moveToTrash: "Move to Trash"
        case .closeTab: "Close Tab"
        case .newTab: "New Tab"
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
        case .toggleOutline: "Show/Hide Outline"
        case .installCommandLineTool: "Install Command Line Tool…"
        }
    }

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
        case .moveToTrash: ""
        case .closeTab: "cmd+w"
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

    func isCustomized(_ action: ShortcutAction) -> Bool {
        shortcutOverrides[action.rawValue] != nil
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
