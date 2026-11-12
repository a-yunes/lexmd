import AppKit
import Testing
@testable import LexMD

/// Heading suggestions for the open document come from a background parse, not one per keystroke.
/// Part of the serialized app model suite, since both drive `AppModel.shared`.
extension TabCommandTests {
    @Test func headingSuggestionsParseTheEditedTextOffTheMainThread() async throws {
        let folder = try TestFolder()
        try folder.write("doc.md", "# First\n\nText\n")
        let model = AppModel.shared
        model.open(folder.url)
        let path = FileScanner.canonicalPath(folder.url.appendingPathComponent("doc.md").path)
        model.open(URL(fileURLWithPath: path))
        #expect(model.currentFile?.path == path)
        let editor = model.editor
        let context = CompletionContext(kind: .heading(file: ""), query: "", range: NSRange(location: 0, length: 0), trigger: 0)
        func titles() -> [String] { model.linkSuggestions(for: context).map(\.title) }

        _ = titles()
        try await waitUntil { model.outline.editorHeadings?.version == editor.textVersion }
        #expect(titles() == ["First"])
        #expect(model.outline.editorHeadingTask == nil, "an unchanged text is not parsed again")

        // Typing returns the last parse at once and starts one background pass for the new text.
        let version = editor.textVersion
        editor.textView.insertText("## Second\n", replacementRange: NSRange(location: (editor.textView.string as NSString).length, length: 0))
        #expect(editor.textVersion != version)
        #expect(titles() == ["First"])
        #expect(model.outline.editorHeadingTask != nil)
        try await waitUntil { titles() == ["First", "Second"] }
        #expect(model.outline.editorHeadings?.version == editor.textVersion)

        model.closeTabsForProjectChange()
    }
}
