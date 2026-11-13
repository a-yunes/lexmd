import AppKit

extension AppModel {
    // MARK: - Replace

    /// Whether the editor is on screen, for the editor's text commands.
    var isEditorVisible: Bool { currentFile != nil && viewMode != .read }

    /// Replacing edits the Markdown source, so it happens where the source shows. In Preview
    /// Only the page's matches leave out link targets, comments and other text that isn't
    /// rendered, so its count and current match can't say which source match to replace.
    /// Returns true when it switched the view, so the caller stops and lets the user see the
    /// match in the editor first.
    private func showSourceForReplace() -> Bool {
        guard viewMode == .read else { return false }
        setViewMode(.split, focusesEditor: false)
        refreshFind(scroll: true)
        return true
    }

    func toggleReplace() {
        if isReplaceVisible {
            isReplaceVisible = false
            findFocusToken += 1
        } else {
            showFind(replacing: true)
        }
    }

    /// The find bar's pattern, or nil when there is nothing to find or the pattern is invalid.
    var findPattern: NSRegularExpression? {
        guard !findQuery.isEmpty else { return nil }
        return try? QuickSearchEngine.regex(for: findQuery, options: findOptions)
    }

    var isFindPatternInvalid: Bool { !findQuery.isEmpty && findPattern == nil }

    /// Replaces the current match and moves on to the next one. While the editor shows a
    /// selection that is itself a match, that match is the one replaced.
    func replaceCurrent() {
        guard currentFile != nil, let regex = findPattern else { NSSound.beep(); return }
        guard !showSourceForReplace() else { return }
        let matches = FindReplace.matches(of: regex, in: text)
        guard !matches.isEmpty else { NSSound.beep(); return }
        let selection = editor.textView.selectedRange()
        let index = matches.firstIndex { $0.range == selection }
        let match = matches[index ?? min(findIndex, matches.count - 1)]
        let replacement = FindReplace.replacement(
            for: match, of: regex, in: text, template: replaceQuery, expandsTemplate: findUsesRegex
        )
        guard editor.replace([TextEdit(range: match.range, replacement: replacement)], actionName: "Replace") else {
            NSSound.beep()
            return
        }
        // Continue after the inserted text, so a replacement that matches again is not revisited.
        let end = match.range.location + (replacement as NSString).length
        let remaining = QuickSearchEngine.matches(of: regex, in: text)
        findIndex = remaining.firstIndex { $0.location >= end } ?? 0
        refreshFind(scroll: true)
    }

    /// Replaces every match in the document as one undoable change.
    func replaceAll() {
        guard currentFile != nil, let regex = findPattern else { NSSound.beep(); return }
        guard !showSourceForReplace() else { return }
        let edits = FindReplace.edits(of: regex, in: text, template: replaceQuery, expandsTemplate: findUsesRegex)
        guard !edits.isEmpty, editor.replace(edits, actionName: "Replace All") else {
            NSSound.beep()
            return
        }
        findIndex = 0
        refreshFind(scroll: false)
        let status = edits.count == 1 ? "1 replaced" : "\(edits.count) replaced"
        findStatus = status
        if let window = editor.textView.window ?? NSApp.keyWindow {
            NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
                .announcement: status, .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        }
    }

    // MARK: - Selection commands

    /// The find field's text for `selection`: escaped when the find bar uses regular expressions,
    /// so the selection is found as typed.
    func findQueryText(for selection: String) -> String {
        findUsesRegex ? NSRegularExpression.escapedPattern(for: selection) : selection
    }

    /// Use Selection for Find: the editor's selection becomes the search, here and in other
    /// apps' find fields.
    func useSelectionForFind() {
        guard isEditorVisible, let selection = editor.selectedSingleLineText() else { NSSound.beep(); return }
        let pasteboard = NSPasteboard(name: .find)
        pasteboard.clearContents()
        pasteboard.setString(selection, forType: .string)
        findQuery = findQueryText(for: selection)
    }

    /// Jump to Selection: scrolls the editor so the selection or caret is in view.
    func jumpToSelection() {
        guard isEditorVisible else { NSSound.beep(); return }
        editor.reveal(editor.textView.selectedRange(), indicator: false, select: false)
    }

    /// Keeps `canUseSelectionForFind` current as the editor's selection changes.
    func observeEditorSelectionForFind() {
        NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification, object: editor.textView, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCanUseSelectionForFind() }
        }
    }

    /// Matches `EditorController.selectedSingleLineText()` without copying the document's text,
    /// since this runs on every selection change.
    func updateCanUseSelectionForFind() {
        let range = editor.textView.selectedRange()
        var value = false
        if range.length > 0, range.length <= 200, let text = editor.textView.textStorage?.mutableString,
           NSMaxRange(range) <= text.length {
            value = text.range(of: "\n", options: .literal, range: range).location == NSNotFound
        }
        if canUseSelectionForFind != value { canUseSelectionForFind = value }
    }

    // MARK: - Text commands

    /// Sends a standard text command (Transformations, Speech, Substitutions panel) to the
    /// focused text view, or to the editor when focus is elsewhere.
    func performTextCommand(_ action: Selector) {
        let target = (NSApp.keyWindow?.firstResponder as? NSTextView) ?? editor.textView
        if !NSApp.sendAction(action, to: target, from: nil) { NSSound.beep() }
    }
}
