import AppKit
import Testing
@testable import LexMD

/// Replace and Replace All, the Find menu's commands, and the editor's substitution settings.
@MainActor
struct FindReplaceTests {
    private static func replaced(
        _ text: String, find: String, with template: String, options: SearchOptions = SearchOptions()
    ) throws -> String {
        let regex = try QuickSearchEngine.regex(for: find, options: options)
        let edits = FindReplace.edits(of: regex, in: text, template: template, expandsTemplate: options.regex)
        return TextEdit.apply(edits, to: text)
    }

    @Test func plainReplacementIsLiteralAndIgnoresCaseByDefault() throws {
        #expect(try Self.replaced("Cat, cat, CAT", find: "cat", with: "dog") == "dog, dog, dog")
        #expect(try Self.replaced("a.b and axb", find: ".", with: "$0\\") == "a$0\\b and axb", "plain text is neither a pattern nor a template")
        #expect(try Self.replaced("no match", find: "zzz", with: "y") == "no match")
    }

    @Test func matchCaseReplacesOnlyExactCase() throws {
        var options = SearchOptions()
        options.caseSensitive = true
        #expect(try Self.replaced("Cat, cat, CAT", find: "cat", with: "dog", options: options) == "Cat, dog, CAT")
    }

    @Test func wholeWordsSkipsPartsOfWords() throws {
        var options = SearchOptions()
        options.wholeWord = true
        #expect(try Self.replaced("cat catalog bobcat cat.", find: "cat", with: "dog", options: options) == "dog catalog bobcat dog.")
    }

    @Test func regularExpressionsExpandCaptureTemplates() throws {
        var options = SearchOptions()
        options.regex = true
        #expect(try Self.replaced("Due 2026-11-12, then 2027-01-05.", find: #"(\d{4})-(\d\d)-(\d\d)"#, with: "$3.$2.$1", options: options)
            == "Due 12.11.2026, then 05.01.2027.")
        #expect(try Self.replaced("costs 5", find: #"(\d)"#, with: #"\$$1.00"#, options: options) == "costs $5.00")
        #expect(try Self.replaced("[a](x.md) [b](y.md)", find: #"\]\((\w+)\.md\)"#, with: "]($1.markdown)", options: options)
            == "[a](x.markdown) [b](y.markdown)")
        options.wholeWord = true
        options.caseSensitive = true
        #expect(try Self.replaced("Foo foo food", find: "f(o+)", with: "b$1", options: options) == "Foo boo food")
        #expect(throws: (any Error).self) { try Self.replaced("x", find: "(", with: "", options: options) }
    }

    @Test func emptyMatchesAreNeverReplaced() throws {
        var options = SearchOptions()
        options.regex = true
        #expect(try Self.replaced("ab\ncd", find: "^", with: "> ", options: options) == "ab\ncd", "the find bar does not count empty matches either")
    }

    // MARK: Editor

    @Test func replaceAllIsOneUndoStepThatTheModelAndHighlighterSee() async throws {
        let editor = EditorController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.scrollView
        let original = "# The cat\n\nA cat, **cat** and `cat`.\n\n```\ncat\n```\n\n- cat\n"
        editor.load(original)
        var reported = ""
        var changes = 0
        editor.onTextChange = { reported = $0; changes += 1 }
        let undo = try #require(editor.textView.undoManager)

        let regex = try QuickSearchEngine.regex(for: "cat", options: SearchOptions())
        let edits = FindReplace.edits(of: regex, in: original, template: "lynx", expandsTemplate: false)
        #expect(edits.count == 6)
        #expect(editor.replaceMatches(edits, actionName: "Replace All"))
        let expected = original.replacingOccurrences(of: "cat", with: "lynx")
        #expect(editor.textView.string == expected)
        #expect(reported == expected, "the model hears about the change, so it autosaves")
        #expect(changes == 1, "one change notification for every match")
        #expect(undo.undoActionName == "Replace All")
        #expect(Self.matchesFullHighlight(editor))

        undo.undo()
        #expect(editor.textView.string == original)
        #expect(!undo.canUndo, "a single undo step restores every match")
        try await waitUntil { reported == original }
        #expect(Self.matchesFullHighlight(editor))
        undo.redo()
        #expect(editor.textView.string == expected)
        try await waitUntil { reported == expected }
    }

    @Test func overlappingOrOutOfRangeEditsAreRefused() {
        let editor = EditorController()
        editor.load("abcdef")
        #expect(!editor.replaceMatches([TextEdit(range: NSRange(location: 0, length: 3), replacement: "x"),
                                        TextEdit(range: NSRange(location: 2, length: 2), replacement: "y")], actionName: "Replace All"))
        #expect(!editor.replaceMatches([TextEdit(range: NSRange(location: 5, length: 3), replacement: "x")], actionName: "Replace"))
        #expect(!editor.replaceMatches([], actionName: "Replace"))
        #expect(editor.textView.string == "abcdef")
    }

    private static func matchesFullHighlight(_ editor: EditorController) -> Bool {
        let storage = editor.textView.textStorage!
        let reference = NSTextStorage(string: storage.string)
        MarkdownHighlighter.highlight(reference, size: editor.fontSize)
        for key in [NSAttributedString.Key.foregroundColor, .font, .strikethroughStyle] {
            var index = 0
            while index < storage.length {
                var a = NSRange(), b = NSRange()
                let left = storage.attribute(key, at: index, effectiveRange: &a) as? NSObject
                let right = reference.attribute(key, at: index, effectiveRange: &b) as? NSObject
                if left != right { return false }
                index = min(NSMaxRange(a), NSMaxRange(b))
            }
        }
        return true
    }

    // MARK: Substitutions

    @Test func substitutionsStartOffAndRoundTripThroughStorage() {
        #expect(EditorController().substitutions == TextSubstitutions(), "Markdown needs straight quotes and plain hyphens")
        var value = TextSubstitutions()
        value.smartQuotes = true
        value.correctsSpelling = true
        #expect(TextSubstitutions(dictionary: value.dictionary) == value)
        #expect(TextSubstitutions(dictionary: ["smartDashes": "yes", "unknown": true]) == TextSubstitutions())
        #expect(TextSubstitutions(dictionary: nil) == TextSubstitutions())
    }

    // MARK: Commands

    @Test func findCommandsLeaveExistingShortcutsAlone() {
        #expect(ShortcutAction.findAndReplace.defaultShortcut == nil, "⌥⌘F is Focus Mode")
        #expect(ShortcutAction.useSelectionForFind.defaultShortcut == nil, "⌘E is Inline Code")
        #expect(ShortcutAction.jumpToSelection.defaultShortcut?.string == "cmd+j")
        #expect(ShortcutAction.focusMode.defaultShortcut?.string == "option+cmd+f")
        #expect(ShortcutAction.inlineCode.defaultShortcut?.string == "cmd+e")
        for action in [ShortcutAction.findAndReplace, .useSelectionForFind, .jumpToSelection] {
            #expect(action.category == .edit)
        }
        #expect(ShortcutAction.findAndReplace.title == "Find and Replace…")
    }
}

/// Find and replace through the app model. Part of the serialized app model suite, since both
/// drive `AppModel.shared`.
extension TabCommandTests {
    @Test func replaceInPreviewOnlyEditsAndSavesTheDocumentText() async throws {
        let folder = try TestFolder()
        try folder.write("doc.md", "Hello cat. A cat sat on the cat mat.\n")
        let model = AppModel.shared
        model.open(folder.url)
        let path = FileScanner.canonicalPath(folder.url.appendingPathComponent("doc.md").path)
        model.open(URL(fileURLWithPath: path))
        #expect(model.currentFile?.path == path)
        let mode = model.viewMode
        model.setViewMode(.read)
        defer {
            model.closeFindBar()
            model.findQuery = ""
            model.replaceQuery = ""
            model.findUsesRegex = false
            model.findWholeWord = false
            model.setViewMode(mode)
            model.closeTabsForProjectChange()
        }

        model.showFind(replacing: true)
        #expect(model.isFindBarVisible && model.isReplaceVisible)
        model.findQuery = "cat"
        model.replaceQuery = "dog"
        model.replaceCurrent()
        #expect(model.text == "Hello dog. A cat sat on the cat mat.\n")
        #expect(model.editor.textView.string == model.text)
        #expect(model.findIndex == 0, "the next match is the first one after the replacement")

        model.replaceAll()
        #expect(model.text == "Hello dog. A dog sat on the dog mat.\n")
        #expect(model.findStatus == "2 replaced")
        model.saveNow()
        #expect(try String(contentsOfFile: path, encoding: .utf8) == model.text)

        model.findUsesRegex = true
        model.findQuery = #"(\w+) (dog)"#
        #expect(model.findStatus == nil)
        model.replaceQuery = "$2 $1"
        model.replaceAll()
        #expect(model.text == "dog Hello. dog A sat on dog the mat.\n")

        model.findQuery = "("
        #expect(model.isFindPatternInvalid)
        model.replaceAll()
        #expect(model.text == "dog Hello. dog A sat on dog the mat.\n", "an invalid pattern replaces nothing")

        // Find… shows the search field alone again.
        model.showFind()
        #expect(!model.isReplaceVisible)
    }

    @Test func useSelectionForFindAndJumpToSelectionFollowTheEditor() async throws {
        let folder = try TestFolder()
        try folder.write("doc.md", "one a.b two\nthree\n")
        let model = AppModel.shared
        model.open(folder.url)
        let path = FileScanner.canonicalPath(folder.url.appendingPathComponent("doc.md").path)
        model.open(URL(fileURLWithPath: path))
        let mode = model.viewMode
        defer {
            model.closeFindBar()
            model.findQuery = ""
            model.findUsesRegex = false
            model.setViewMode(mode)
            model.closeTabsForProjectChange()
        }
        model.setViewMode(.split)
        #expect(model.isEditorVisible)
        let textView = model.editor.textView

        textView.setSelectedRange(NSRange(location: 4, length: 3))
        #expect(model.canUseSelectionForFind)
        model.useSelectionForFind()
        #expect(model.findQuery == "a.b")
        #expect(NSPasteboard(name: .find).string(forType: .string) == "a.b")

        model.findUsesRegex = true
        model.useSelectionForFind()
        #expect(model.findQuery == #"a\.b"#, "the selection is found as typed")

        textView.setSelectedRange(NSRange(location: 4, length: 10))
        #expect(!model.canUseSelectionForFind, "a selection across lines does not fit the find field")
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(!model.canUseSelectionForFind)

        model.jumpToSelection()
        #expect(textView.selectedRange() == NSRange(location: 0, length: 0), "jumping only scrolls")

        model.setViewMode(.read)
        #expect(!model.isEditorVisible, "editor commands are off in Preview Only")
    }

    @Test func substitutionTogglesPersistAndApplyToTheEditor() throws {
        let model = AppModel.shared
        let saved = model.substitutions
        defer { model.substitutions = saved }
        let textView = model.editor.textView
        model.substitutions = TextSubstitutions()
        #expect(!textView.isAutomaticQuoteSubstitutionEnabled && !textView.isAutomaticSpellingCorrectionEnabled)

        model.substitutions.smartQuotes = true
        model.substitutions.correctsSpelling = true
        model.substitutions.smartCopyPaste = true
        #expect(textView.isAutomaticQuoteSubstitutionEnabled)
        #expect(textView.isAutomaticSpellingCorrectionEnabled)
        #expect(textView.smartInsertDeleteEnabled)
        #expect(!textView.isAutomaticDashSubstitutionEnabled)
        let stored = model.defaults.dictionary(forKey: AppModel.Keys.substitutions)
        #expect(TextSubstitutions(dictionary: stored) == model.substitutions)

        // The editor's context menu toggles the text view directly.
        textView.toggleAutomaticDashSubstitution(nil)
        #expect(model.substitutions.smartDashes)
        textView.toggleAutomaticQuoteSubstitution(nil)
        #expect(!model.substitutions.smartQuotes)
        textView.toggleAutomaticTextReplacement(nil)
        textView.toggleAutomaticLinkDetection(nil)
        #expect(model.substitutions.textReplacement && model.substitutions.smartLinks)
        #expect(TextSubstitutions(dictionary: model.defaults.dictionary(forKey: AppModel.Keys.substitutions)) == model.substitutions)

        textView.toggleAutomaticDataDetection(nil)
        #expect(!textView.isAutomaticDataDetectionEnabled, "data detectors stay off")
        let item = NSMenuItem(title: "Data Detectors", action: #selector(NSTextView.toggleAutomaticDataDetection(_:)), keyEquivalent: "")
        #expect(!textView.validateMenuItem(item))
    }
}
