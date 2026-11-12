import AppKit

/// Plain-text view that keeps lines at a comfortable reading measure by centering the text column.
final class LexMDTextView: NSTextView {
    var maxLineWidth: CGFloat = 700 { didSet { updateInsets() } }
    /// Extra space below the text so the last line can scroll to the middle (typewriter scrolling).
    var bottomOverscroll: CGFloat = 0 { didSet { if bottomOverscroll != oldValue { updateInsets() } } }
    weak var editor: EditorController?

    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        // Always match the visible width; autoresizing from a zero-sized start can overshoot.
        if let width = enclosingScrollView?.contentSize.width, width > 0 { size.width = width }
        super.setFrameSize(size)
        updateInsets()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        setFrameSize(frame.size)
    }

    func updateInsets() {
        let horizontal = max(28, ((bounds.width - maxLineWidth) / 2).rounded())
        let inset = NSSize(width: horizontal, height: 30 + bottomOverscroll / 2)
        if textContainerInset != inset { textContainerInset = inset }
    }

    /// Keeps the top inset fixed; the overscroll only adds space below the text.
    override var textContainerOrigin: NSPoint {
        let origin = super.textContainerOrigin
        return NSPoint(x: origin.x, y: origin.y - bottomOverscroll / 2)
    }
}

@MainActor
final class EditorController: NSObject, NSTextViewDelegate {
    let scrollView: NSScrollView
    let textView: LexMDTextView

    var onTextChange: ((String) -> Void)?
    var onScroll: ((CGFloat) -> Void)?
    /// Set while code scrolls to a place the preview reveals by itself, so `onScroll` stays quiet.
    var isScrollingQuietly = false
    /// Returns true when it handled Escape.
    var onCancel: (() -> Bool)?
    /// Runs first for every key command; returns true when it handled it (link completion).
    var onCommand: ((Selector) -> Bool)?
    private var hasFindHighlights = false
    /// The text's own undo history, separate from the window's, which holds file operations
    /// (rename, move, trash) that must outlive document switches and reloads.
    let undoManager = UndoManager()
    /// Changes with every edit of the text, including loads and reloads.
    private(set) var textVersion = 0
    /// Multi-line constructs from the last full highlight, kept in step with edits.
    private(set) var blocks: MarkdownBlocks?
    /// The text edited since the last highlight, when only that part needs restyling.
    private var pendingEdit: NSRange?
    private var needsFullHighlight = true

    // Paste, tables, spelling, focus, and typewriter state (EditorPaste.swift, TableEditing.swift, EditorFocus.swift).
    /// The open document and image folder for pasted and dropped images.
    var imageContext: (() -> ImageContext?)?
    /// Called when spelling or grammar checking is toggled from the Edit menu.
    var onCheckingChange: ((_ spelling: Bool, _ grammar: Bool) -> Void)?
    /// Called when a substitution is toggled from the editor's context menu (FindReplace.swift).
    var onSubstitutionsChange: ((TextSubstitutions) -> Void)?
    var isFocusModeEnabled = false { didSet { if isFocusModeEnabled != oldValue { updateFocusDimming() } } }
    var isTypewriterScrollingEnabled = false {
        didSet { if isTypewriterScrollingEnabled != oldValue { typewriterSettingDidChange() } }
    }
    var focusState = EditorFocusState()

    var fontSize: CGFloat = 14 {
        didSet {
            guard fontSize != oldValue else { return }
            textView.maxLineWidth = fontSize * 0.6 * 84
            textView.font = MarkdownHighlighter.font(size: fontSize)
            highlight(full: true)
        }
    }

    override init() {
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        textView = LexMDTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        super.init()

        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 0

        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .controlAccentColor
        textView.textColor = .labelColor
        textView.font = MarkdownHighlighter.font(size: fontSize)
        textView.maxLineWidth = fontSize * 0.6 * 84
        textView.typingAttributes = MarkdownHighlighter.baseAttributes(size: fontSize)
        textView.delegate = self
        textView.editor = self
        textView.setAccessibilityLabel("Editor")
        textView.setAccessibilityIdentifier("editor")

        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(storageDidProcessEditing(_:)),
            name: NSTextStorage.didProcessEditingNotification, object: textView.textStorage
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollerStyleDidChange(_:)),
            name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil
        )
        setUpEditorFeatures()
    }

    @objc private func scrollerStyleDidChange(_ notification: Notification) {
        scrollView.scrollerStyle = .overlay
    }

    // MARK: Content

    func load(_ text: String) {
        // The whole text is restyled below; skip tracking the replacement as an edit.
        needsFullHighlight = true
        textView.string = text
        highlight(full: true)
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let top = NSPoint(x: 0, y: -scrollView.contentInsets.top)
        scrollView.contentView.scroll(to: top)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Shows new text (reloaded from disk or restored) in place, keeping the caret and scroll position.
    func replaceText(_ text: String) {
        let selection = textView.selectedRange()
        let origin = scrollView.contentView.bounds.origin
        needsFullHighlight = true
        textView.string = text
        highlight(full: true)
        // Undo steps recorded against the old text would apply to the wrong ranges of the new one.
        textView.undoManager?.removeAllActions()
        let length = (text as NSString).length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func moveCursorToEnd() {
        let length = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: length, length: 0))
        textView.scrollRangeToVisible(NSRange(location: length, length: 0))
    }

    func focus() {
        textView.window?.makeFirstResponder(textView)
    }

    private var isFocused: Bool { textView.window?.firstResponder === textView }

    // MARK: Find

    private static let matchColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.systemYellow.withAlphaComponent(0.28)
            : NSColor.systemYellow.withAlphaComponent(0.38)
    }
    private static let currentMatchColor = NSColor.systemYellow.withAlphaComponent(0.85)

    /// Paints every match with a temporary background (not part of the document's attributes).
    func setFindHighlights(_ ranges: [NSRange], current: Int?) {
        clearFindHighlights()
        guard !ranges.isEmpty else { return }
        for (index, range) in ranges.enumerated() {
            let color = index == current ? Self.currentMatchColor : Self.matchColor
            addHighlight(.backgroundColor, color, range)
        }
        // With Differentiate Without Color, the current match is also underlined.
        if let current, ranges.indices.contains(current),
           NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor {
            addHighlight(.underlineStyle, NSUnderlineStyle.thick.rawValue, ranges[current])
        }
        hasFindHighlights = true
    }

    func clearFindHighlights() {
        guard hasFindHighlights else { return }
        hasFindHighlights = false
        if let layoutManager = textView.textLayoutManager, let content = layoutManager.textContentManager {
            layoutManager.removeRenderingAttribute(.backgroundColor, for: content.documentRange)
            layoutManager.removeRenderingAttribute(.underlineStyle, for: content.documentRange)
        } else if let layoutManager = textView.layoutManager {
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
        }
    }

    private func addHighlight(_ key: NSAttributedString.Key, _ value: Any, _ range: NSRange) {
        if let layoutManager = textView.textLayoutManager, let content = layoutManager.textContentManager {
            guard let start = content.location(content.documentRange.location, offsetBy: range.location),
                  let end = content.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end) else { return }
            layoutManager.addRenderingAttribute(key, value: value, for: textRange)
        } else {
            textView.layoutManager?.addTemporaryAttribute(key, value: value, forCharacterRange: range)
        }
    }

    /// The selection when it is a short single line, for seeding search fields.
    func selectedSingleLineText() -> String? {
        let range = textView.selectedRange()
        guard range.length > 0, range.length <= 200 else { return nil }
        let text = (textView.string as NSString).substring(with: range)
        return text.contains("\n") ? nil : text
    }

    /// Centers a range in the editor, optionally selecting it and flashing the find indicator.
    func reveal(_ range: NSRange, indicator: Bool, select: Bool) {
        let length = (textView.string as NSString).length
        guard range.location <= length else { return }
        let clamped = NSRange(location: range.location, length: min(range.length, length - range.location))
        if select { textView.setSelectedRange(clamped) }
        textView.scrollRangeToVisible(clamped)
        if let window = textView.window {
            let screenRect = textView.firstRect(forCharacterRange: clamped, actualRange: nil)
            if screenRect != .zero {
                let rect = textView.convert(window.convertFromScreen(screenRect), from: nil)
                let clip = scrollView.contentView
                let minY = -scrollView.contentInsets.top
                let maxY = max(minY, textView.frame.height - clip.bounds.height)
                let targetY = rect.midY - clip.bounds.height / 2
                clip.scroll(to: NSPoint(x: 0, y: min(max(targetY, minY), maxY)))
                scrollView.reflectScrolledClipView(clip)
            }
        }
        if indicator, !scrollView.isHiddenOrHasHiddenAncestor {
            textView.showFindIndicator(for: clamped)
        }
    }

    func wrapSelection(_ prefix: String, _ suffix: String) {
        guard isFocused else { return }
        let range = textView.selectedRange()
        let ns = textView.string as NSString
        let selected = ns.substring(with: range)
        let p = (prefix as NSString).length, s = (suffix as NSString).length
        // Toggle off when the selection is already wrapped.
        if range.location >= p, range.location + range.length + s <= ns.length,
           ns.substring(with: NSRange(location: range.location - p, length: p)) == prefix,
           ns.substring(with: NSRange(location: range.location + range.length, length: s)) == suffix {
            let outer = NSRange(location: range.location - p, length: range.length + p + s)
            textView.insertText(selected, replacementRange: outer)
            textView.setSelectedRange(NSRange(location: outer.location, length: range.length))
            return
        }
        textView.insertText(prefix + selected + suffix, replacementRange: range)
        textView.setSelectedRange(NSRange(location: range.location + p, length: range.length))
    }

    func insertLink() {
        guard isFocused else { return }
        let range = textView.selectedRange()
        let selected = (textView.string as NSString).substring(with: range)
        let label = selected.isEmpty ? "link" : selected
        textView.insertText("[\(label)](url)", replacementRange: range)
        let urlStart = range.location + (label as NSString).length + 3
        textView.setSelectedRange(NSRange(location: urlStart, length: 3))
    }

    // MARK: Delegate

    func undoManager(for view: NSTextView) -> UndoManager? {
        undoManager
    }

    func textDidChange(_ notification: Notification) {
        highlight(full: false)
        onTextChange?(textView.string)
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if onCommand?(selector) == true { return true }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            return continueList()
        }
        if selector == #selector(NSResponder.cancelOperation(_:)), onCancel?() == true {
            return true
        }
        if selector == #selector(NSResponder.insertTab(_:)) || selector == #selector(NSResponder.insertBacktab(_:)) {
            return moveTableCell(backward: selector == #selector(NSResponder.insertBacktab(_:)))
        }
        return false
    }

    private static let listPrefix = try! NSRegularExpression(
        pattern: #"^([ \t]*)(?:([-*+])|(\d+)([.)]))([ \t]+)(\[[ xX]\][ \t]+)?"#
    )
    private static let quotePrefix = try! NSRegularExpression(pattern: #"^([ \t]*>[ \t]?)+"#)

    /// Continues Markdown lists and quotes when pressing Return; an empty item ends the list.
    private func continueList() -> Bool {
        let selection = textView.selectedRange()
        guard selection.length == 0, !textView.hasMarkedText() else { return false }
        let ns = textView.string as NSString
        let line = ns.lineRange(for: NSRange(location: selection.location, length: 0))
        let headRange = NSRange(location: line.location, length: selection.location - line.location)
        let head = ns.substring(with: headRange)
        let headNS = head as NSString
        let all = NSRange(location: 0, length: headNS.length)

        var continuation: String?
        var markerLength = 0
        if let m = Self.listPrefix.firstMatch(in: head, range: all) {
            markerLength = m.range.length
            let indent = headNS.substring(with: m.range(at: 1))
            let spacing = headNS.substring(with: m.range(at: 5))
            let task = m.range(at: 6).location != NSNotFound ? "[ ] " : ""
            if m.range(at: 2).location != NSNotFound {
                continuation = indent + headNS.substring(with: m.range(at: 2)) + spacing + task
            } else {
                let number = Int(headNS.substring(with: m.range(at: 3))) ?? 0
                continuation = indent + "\(number + 1)" + headNS.substring(with: m.range(at: 4)) + spacing + task
            }
        } else if let m = Self.quotePrefix.firstMatch(in: head, range: all) {
            markerLength = m.range.length
            continuation = headNS.substring(with: m.range)
        }
        guard let continuation else { return false }

        let restOfLine = ns.substring(with: NSRange(location: selection.location, length: NSMaxRange(line) - selection.location))
        if markerLength == headNS.length, restOfLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Empty item: remove the marker instead of continuing.
            textView.insertText("", replacementRange: headRange)
            return true
        }
        textView.insertText("\n" + continuation, replacementRange: selection)
        return true
    }

    @objc private func boundsDidChange(_ notification: Notification) {
        guard !isScrollingQuietly, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView.bounds
        let insets = scrollView.contentInsets
        let maxY = document.frame.height + insets.top + insets.bottom - clip.height
        let fraction = maxY > 1 ? (clip.origin.y + insets.top) / maxY : 0
        onScroll?(min(max(fraction, 0), 1))
    }

    /// Records each text edit so the next highlight restyles only the edited paragraphs.
    /// Edits that can open, close, or move a multi-line block fall back to a full pass.
    @objc private func storageDidProcessEditing(_ notification: Notification) {
        guard let storage = textView.textStorage, storage.editedMask.contains(.editedCharacters) else { return }
        textVersion &+= 1
        guard !needsFullHighlight else { return }
        let edited = storage.editedRange
        let delta = storage.changeInLength
        let old = NSRange(location: edited.location, length: max(0, edited.length - delta))
        // The storage's own string: bridging `storage.string` would copy the whole document.
        let text = storage.mutableString
        let lines = text.lineRange(for: Self.withNextLine(edited, length: text.length))
        guard var blocks, !blocks.touchesBoundary(old),
              !MarkdownBlocks.linesHaveDelimiter(text.substring(with: lines)) else {
            needsFullHighlight = true
            pendingEdit = nil
            return
        }
        blocks.shift(replacing: old, delta: delta)
        self.blocks = blocks
        // Several edits before one highlight (input method composition, multi-range edits)
        // restyle the span that covers them all.
        pendingEdit = pendingEdit.map { Self.union($0, movedBy: old, edited: edited) } ?? edited
    }

    /// The range covering `pending` (an earlier edit, adjusted for the later one) and `edited`,
    /// where the later edit replaced `old` with the text now at `edited`.
    static func union(_ pending: NSRange, movedBy old: NSRange, edited: NSRange) -> NSRange {
        let delta = edited.length - old.length
        func moved(_ location: Int) -> Int {
            if location <= old.location { return location }
            if location >= NSMaxRange(old) { return location + delta }
            return NSMaxRange(edited)
        }
        let start = min(moved(pending.location), edited.location)
        let end = max(moved(NSMaxRange(pending)), NSMaxRange(edited))
        return NSRange(location: start, length: end - start)
    }

    /// Front matter, fenced code, and comments in the current text: the highlighter's blocks
    /// while they are in step with the text, otherwise a fresh scan.
    var currentBlocks: MarkdownBlocks {
        if let blocks, !needsFullHighlight { return blocks }
        return MarkdownHighlighter.blocks(in: textView.string)
    }

    /// Extends an edited range by one character so a line split by an inserted newline
    /// includes the new line after it.
    private static func withNextLine(_ range: NSRange, length: Int) -> NSRange {
        let location = min(range.location, length)
        return NSRange(location: location, length: min(range.length + 1, length - location))
    }

    private func highlight(full: Bool) {
        guard let storage = textView.textStorage, !textView.hasMarkedText() else { return }
        if !full, !needsFullHighlight {
            // Without a pending edit, nothing changed since the last pass.
            if let edit = pendingEdit {
                let ns = storage.mutableString
                let range = ns.paragraphRange(for: Self.withNextLine(edit, length: ns.length))
                MarkdownHighlighter.highlight(storage, size: fontSize, in: range, blocks: blocks)
            }
        } else {
            blocks = MarkdownHighlighter.highlight(storage, size: fontSize)
        }
        pendingEdit = nil
        needsFullHighlight = false
        textView.typingAttributes = MarkdownHighlighter.baseAttributes(size: fontSize)
    }
}
