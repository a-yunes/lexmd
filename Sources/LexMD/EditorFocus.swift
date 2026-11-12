import AppKit

/// Bookkeeping for focus mode and typewriter scrolling.
struct EditorFocusState {
    /// The paragraph left undimmed, or nil when nothing is dimmed.
    var paragraph: NSRange?
    /// Set when the text changes, since rendering attributes may not follow edits.
    var isStale = false
    var isCenteringScheduled = false
}

extension EditorController {
    static let focusDimColor = NSColor.tertiaryLabelColor

    func setUpEditorFeatures() {
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(featureSelectionDidChange(_:)),
            name: NSTextView.didChangeSelectionNotification, object: textView
        )
        center.addObserver(
            self, selector: #selector(featureTextDidChange(_:)),
            name: NSText.didChangeNotification, object: textView
        )
        center.addObserver(
            self, selector: #selector(featureStorageDidEdit(_:)),
            name: NSTextStorage.didProcessEditingNotification, object: textView.textStorage
        )
        scrollView.contentView.postsFrameChangedNotifications = true
        center.addObserver(
            self, selector: #selector(featureClipFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification, object: scrollView.contentView
        )
        setSpellChecking(spelling: true, grammar: false)
    }

    @objc private func featureSelectionDidChange(_ notification: Notification) {
        updateFocusDimming()
        // Follow the caret when it moves with the keyboard, never after a click or scroll.
        if isTypewriterScrollingEnabled, NSApp?.currentEvent?.type == .keyDown { scheduleCentering() }
    }

    @objc private func featureTextDidChange(_ notification: Notification) {
        updateFocusDimming(force: true)
        if isTypewriterScrollingEnabled { scheduleCentering() }
    }

    @objc private func featureStorageDidEdit(_ notification: Notification) {
        if textView.textStorage?.editedMask.contains(.editedCharacters) == true { focusState.isStale = true }
    }

    @objc private func featureClipFrameDidChange(_ notification: Notification) {
        if isTypewriterScrollingEnabled { updateOverscroll() }
    }

    // MARK: Focus mode

    /// The Markdown paragraph (run of non-blank lines) around `location`.
    static func focusParagraph(in string: NSString, at location: Int) -> NSRange {
        let location = min(location, string.length)
        func isBlank(_ line: NSRange) -> Bool {
            string.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let caretLine = string.lineRange(for: NSRange(location: location, length: 0))
        if isBlank(caretLine) { return caretLine }
        var start = caretLine.location
        while start > 0 {
            let previous = string.lineRange(for: NSRange(location: start - 1, length: 0))
            if isBlank(previous) { break }
            start = previous.location
        }
        var end = NSMaxRange(caretLine)
        while end < string.length {
            let next = string.lineRange(for: NSRange(location: end, length: 0))
            if isBlank(next) { break }
            end = NSMaxRange(next)
        }
        return NSRange(location: start, length: end - start)
    }

    /// Dims everything outside the caret's paragraph with rendering attributes, which are
    /// never stored in the text or saved.
    func updateFocusDimming(force: Bool = false) {
        let length = (textView.string as NSString).length
        guard isFocusModeEnabled, length > 0 else {
            if focusState.paragraph != nil {
                removeDimming()
                focusState.paragraph = nil
            }
            return
        }
        let paragraph = Self.focusParagraph(in: textView.string as NSString, at: textView.selectedRange().location)
        guard force || focusState.isStale || paragraph != focusState.paragraph else { return }
        removeDimming()
        focusState.paragraph = paragraph
        focusState.isStale = false
        let before = NSRange(location: 0, length: paragraph.location)
        let after = NSRange(location: NSMaxRange(paragraph), length: length - NSMaxRange(paragraph))
        for range in [before, after] where range.length > 0 {
            addRenderingColor(Self.focusDimColor, range)
        }
    }

    private func removeDimming() {
        if let layoutManager = textView.textLayoutManager, let content = layoutManager.textContentManager {
            layoutManager.removeRenderingAttribute(.foregroundColor, for: content.documentRange)
        } else if let layoutManager = textView.layoutManager {
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        }
    }

    private func addRenderingColor(_ color: NSColor, _ range: NSRange) {
        if let layoutManager = textView.textLayoutManager, let content = layoutManager.textContentManager {
            guard let start = content.location(content.documentRange.location, offsetBy: range.location),
                  let end = content.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end) else { return }
            layoutManager.addRenderingAttribute(.foregroundColor, value: color, for: textRange)
        } else {
            textView.layoutManager?.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: range)
        }
    }

    // MARK: Typewriter scrolling

    func typewriterSettingDidChange() {
        if isTypewriterScrollingEnabled {
            updateOverscroll()
            scheduleCentering()
        } else {
            textView.bottomOverscroll = 0
        }
    }

    /// Enough space below the text for its last line to reach the middle of the view.
    private func updateOverscroll() {
        let height = scrollView.contentView.bounds.height
        let line = (textView.font?.pointSize ?? fontSize) * 1.6
        textView.bottomOverscroll = max(0, (height / 2 - line).rounded())
    }

    private func scheduleCentering() {
        guard !focusState.isCenteringScheduled else { return }
        focusState.isCenteringScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.focusState.isCenteringScheduled = false
                self.centerCaret()
            }
        }
    }

    /// Scrolls so the caret line sits in the middle of the view.
    func centerCaret() {
        guard isTypewriterScrollingEnabled, let window = textView.window else { return }
        let caret = NSRange(location: textView.selectedRange().location, length: 0)
        let screenRect = textView.firstRect(forCharacterRange: caret, actualRange: nil)
        guard screenRect != .zero else { return }
        let rect = textView.convert(window.convertFromScreen(screenRect), from: nil)
        let clip = scrollView.contentView
        let y = Self.centeredOffset(
            caretMidY: rect.midY, visibleHeight: clip.bounds.height,
            documentHeight: textView.frame.height, topInset: scrollView.contentInsets.top
        )
        guard abs(clip.bounds.origin.y - y) > 0.5 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    /// The scroll offset that centers `caretMidY`, clamped to the scrollable range.
    static func centeredOffset(caretMidY: CGFloat, visibleHeight: CGFloat, documentHeight: CGFloat, topInset: CGFloat) -> CGFloat {
        let minY = -topInset
        let maxY = max(minY, documentHeight - visibleHeight)
        return min(max((caretMidY - visibleHeight / 2).rounded(), minY), maxY)
    }

    // MARK: Spelling and grammar

    func setSpellChecking(spelling: Bool, grammar: Bool) {
        if textView.isContinuousSpellCheckingEnabled != spelling { textView.isContinuousSpellCheckingEnabled = spelling }
        if textView.isGrammarCheckingEnabled != grammar { textView.isGrammarCheckingEnabled = grammar }
    }

    /// Keeps spelling and grammar marks off code, URLs, and front matter.
    func textView(_ textView: NSTextView, shouldSetSpellingState value: Int, range affectedCharRange: NSRange) -> Int {
        guard value != 0 else { return value }
        return Self.isExcludedFromSpelling(affectedCharRange, in: textView.string as NSString, blocks: blocks) ? 0 : value
    }

    private static let spellingExclusions = try! NSRegularExpression(pattern: [
        #"(`+)(?!`)[^\n]+?(?<!`)\1(?!`)"#,          // inline code
        #"\]\([^)\n]*\)"#,                          // link destinations
        #"<[^>\s]+>"#,                              // autolinks and HTML tags
        #"\b[A-Za-z][A-Za-z0-9+.-]*://[^\s<>]+"#,   // bare URLs
        #"^[ ]{0,3}\[[^\]\n]+\]:[ \t]+\S+"#,        // reference definitions
        #"\b[\w.+-]+@[\w-]+\.[\w.-]+"#,             // email addresses
    ].joined(separator: "|"), options: [.anchorsMatchLines])

    /// Whether `range` lies in front matter, fenced code, inline code, or a URL.
    static func isExcludedFromSpelling(_ range: NSRange, in string: NSString, blocks: MarkdownBlocks?) -> Bool {
        guard range.location != NSNotFound, NSMaxRange(range) <= string.length else { return false }
        let blocks = blocks ?? MarkdownHighlighter.blocks(in: string as String)
        if blocks.items.contains(where: { $0.kind != .comment && NSIntersectionRange($0.range, range).length > 0 }) {
            return true
        }
        let lines = string.lineRange(for: range)
        var excluded = false
        spellingExclusions.enumerateMatches(in: string as String, range: lines) { match, _, stop in
            guard let match, NSIntersectionRange(match.range, range).length > 0 else { return }
            excluded = true
            stop.pointee = true
        }
        return excluded
    }
}
