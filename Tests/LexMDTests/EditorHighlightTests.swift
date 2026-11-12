import AppKit
import Testing
@testable import LexMD

/// The editor restyles only edited paragraphs; the result must always match a full pass.
@MainActor
struct EditorHighlightTests {
    private static let sample = """
    ---
    title: Sample
    ---

    # Heading

    Some **bold** and *italic* text with `code` and a [link](url).

    ```swift
    let x = 1 // comment
    ```

    <!-- a
    comment -->

    > quote
    - [ ] task
    1. item

    | a | b |
    |---|---|
    """

    private static let snippets = [
        "a", " ", "\n", "\n\n", "**b**", "`c`", "_x_", "# ", "> ", "- [ ] ", "~~s~~",
        "```", "```\n", "~~~\n", "<!--", "-->", "---", "---\n", "[l](u)", "|",
    ]

    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8])
    func incrementalMatchesFullHighlight(seed: UInt64) throws {
        let editor = EditorController()
        editor.load(Self.sample)
        var random = SeededRandom(seed: seed)
        for step in 0..<600 {
            let length = (editor.textView.string as NSString).length
            let location = Int.random(in: 0...length, using: &random)
            let deleting = Int.random(in: 0...2, using: &random) == 0
            let range = NSRange(location: location, length: deleting ? min(Int.random(in: 1...6, using: &random), length - location) : 0)
            let insert = deleting ? "" : Self.snippets.randomElement(using: &random)!
            editor.textView.insertText(insert, replacementRange: range)
            try #require(Self.matchesFullHighlight(editor), "seed \(seed), step \(step): \(insert.debugDescription) at \(range)")
        }
    }

    @Test func largeDocumentsRestyleOnlyTheEditedParagraph() {
        let editor = EditorController()
        let paragraph = "Plain paragraph with **bold** text.\n\n"
        editor.load(String(repeating: paragraph, count: 4000))
        let storage = editor.textView.textStorage!
        var edited: [NSRange] = []
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                if storage.editedMask == .editedAttributes { edited.append(storage.editedRange) }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        editor.textView.insertText("x", replacementRange: NSRange(location: 10, length: 0))
        let restyled = edited.map(\.length).max() ?? 0
        #expect(restyled > 0 && restyled < 200, "restyled \(restyled) of \(storage.length) characters")
        #expect(Self.matchesFullHighlight(editor))
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
}

/// A small deterministic generator so failures reproduce.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
