import AppKit

// Rules for choosing shortcuts in Settings: which key combinations macOS keeps for itself, and
// how the shortcut list is searched and grouped.

extension Shortcut {
    /// Key combinations macOS or the standard app, Edit, and Window menus already use, with what
    /// they do. Assigning one would break that command or never reach LexMD.
    private static let reserved: [Shortcut: String] = {
        let entries: [(String, String)] = [
            // The LexMD menu.
            ("cmd+q", "Quit LexMD"), ("cmd+h", "Hide LexMD"), ("option+cmd+h", "Hide Others"),
            ("cmd+,", "Settings"),
            // The Edit menu's text commands.
            ("cmd+z", "Undo"), ("shift+cmd+z", "Redo"), ("cmd+x", "Cut"), ("cmd+c", "Copy"),
            ("cmd+v", "Paste"), ("option+shift+cmd+v", "Paste and Match Style"), ("cmd+a", "Select All"),
            ("ctrl+cmd+space", "Emoji & Symbols"), ("ctrl+cmd+d", "Look Up"),
            // The Window and Help menus.
            ("cmd+m", "Minimize"), ("option+cmd+m", "Minimize All"), ("ctrl+cmd+f", "Full Screen"),
            ("shift+cmd+/", "Help menu search"),
            // macOS.
            ("cmd+tab", "switching apps"), ("shift+cmd+tab", "switching apps"),
            ("cmd+`", "switching windows"), ("shift+cmd+`", "switching windows"),
            ("cmd+space", "Spotlight"), ("option+cmd+space", "Spotlight"),
            ("ctrl+space", "switching input sources"), ("ctrl+option+space", "switching input sources"),
            ("option+cmd+escape", "Force Quit"), ("ctrl+cmd+q", "Lock Screen"),
            ("shift+cmd+q", "Log Out"), ("option+shift+cmd+q", "Log Out"),
            ("shift+cmd+3", "screenshots"), ("shift+cmd+4", "screenshots"), ("shift+cmd+5", "screenshots"),
            ("ctrl+shift+cmd+3", "screenshots"), ("ctrl+shift+cmd+4", "screenshots"),
            ("ctrl+upArrow", "Mission Control"), ("ctrl+downArrow", "App Exposé"),
            ("ctrl+leftArrow", "switching spaces"), ("ctrl+rightArrow", "switching spaces"),
            ("option+cmd+d", "showing and hiding the Dock"),
        ]
        return Dictionary(uniqueKeysWithValues: entries.compactMap { string, use in
            Shortcut(string: string).map { ($0, use) }
        })
    }()

    /// What macOS or a standard menu uses this key combination for, or nil when it is free.
    var reservedUse: String? { Self.reserved[self] }

    /// Why this shortcut can't be assigned, or nil when it can.
    var reservationNote: String? {
        reservedUse.map { "\(display) is reserved for \($0)." }
    }
}

// MARK: - Search

extension Shortcut {
    private static let modifierWords: [String: NSEvent.ModifierFlags] = [
        "cmd": .command, "command": .command, "⌘": .command,
        "opt": .option, "option": .option, "alt": .option, "⌥": .option,
        "shift": .shift, "⇧": .shift,
        "ctrl": .control, "control": .control, "⌃": .control,
    ]

    private static let modifierSymbols: [Character: NSEvent.ModifierFlags] = [
        "⌘": .command, "⌥": .option, "⇧": .shift, "⌃": .control,
    ]

    /// Names people type for keys that aren't a single character.
    private static let keyNames: [String: Set<String>] = [
        "leftArrow": ["left", "leftarrow", "←"], "rightArrow": ["right", "rightarrow", "→"],
        "upArrow": ["up", "uparrow", "↑"], "downArrow": ["down", "downarrow", "↓"],
        "return": ["return", "enter", "↩"], "tab": ["tab", "⇥"], "space": ["space"],
        "delete": ["delete", "backspace", "⌫"], "deleteForward": ["forwarddelete", "⌦"],
        "home": ["home", "↖"], "end": ["end", "↘"], "pageUp": ["pageup", "⇞"], "pageDown": ["pagedown", "⇟"],
        "escape": ["escape", "esc", "⎋"], "=": ["=", "+", "plus"], "-": ["-", "minus"],
    ]

    private static let allKeyNames = Set(keyNames.values.joined())

    /// Reads a search such as "⇧⌘B", "cmd shift b", or "ctrl+tab" as modifiers and at most one
    /// key. Returns nil for text that doesn't describe a shortcut, such as "b" or "bold".
    static func searchPattern(_ query: String) -> (modifiers: NSEvent.ModifierFlags, key: String?)? {
        var text = query.lowercased().trimmingCharacters(in: .whitespaces)
        var modifiers: NSEvent.ModifierFlags = []
        var key: String?
        // "⌘+" and "cmd++" mean the plus key, which the rest would read as a separator.
        if text.hasSuffix("+") {
            let before = text.dropLast()
            if before.isEmpty || before.hasSuffix("+") || before.hasSuffix(" ")
                || before.last.map({ modifierSymbols[$0] != nil }) == true {
                key = "+"
                text = String(before)
            }
        }
        let tokens = text.split(whereSeparator: { $0 == "+" || $0.isWhitespace })
        for token in tokens {
            var rest = Substring(token)
            while let first = rest.first, let flag = modifierSymbols[first] {
                modifiers.insert(flag)
                rest = rest.dropFirst()
            }
            guard !rest.isEmpty else { continue }
            if let flag = modifierWords[String(rest)] {
                modifiers.insert(flag)
            } else if key == nil {
                key = String(rest)
            } else {
                return nil
            }
        }
        if modifiers.isEmpty {
            // Without modifiers, only a key name such as "return" or "←" describes a shortcut.
            guard let key, allKeyNames.contains(key) else { return nil }
        }
        return (modifiers, key)
    }

    /// Whether this shortcut has the modifiers and key of a search pattern.
    func matches(modifiers wanted: NSEvent.ModifierFlags, key wantedKey: String?) -> Bool {
        guard modifiers.isSuperset(of: wanted) else { return false }
        guard let wantedKey else { return true }
        return wantedKey == key.lowercased() || Self.keyNames[key]?.contains(wantedKey) == true
    }
}

extension ShortcutAction {
    /// Whether the command shows for a search in Settings, by its name or by its shortcut.
    func matches(search query: String, shortcut: Shortcut?) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        // Menu titles end in an ellipsis when the command asks for more; searches need not.
        let name = query.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, title.replacingOccurrences(of: "…", with: "").localizedStandardContains(name) { return true }
        guard let shortcut, let pattern = Shortcut.searchPattern(query) else { return false }
        return shortcut.matches(modifiers: pattern.modifiers, key: pattern.key)
    }

    /// The commands Settings lists for a search, grouped by menu in menu bar order. Empty
    /// groups are left out.
    static func sections(
        matching query: String,
        includingSourceControl: Bool,
        shortcut: (ShortcutAction) -> Shortcut?
    ) -> [(category: Category, actions: [ShortcutAction])] {
        Category.allCases.compactMap { category in
            guard category != .sourceControl || includingSourceControl else { return nil }
            let actions = allCases.filter { $0.category == category && $0.matches(search: query, shortcut: shortcut($0)) }
            return actions.isEmpty ? nil : (category, actions)
        }
    }
}
