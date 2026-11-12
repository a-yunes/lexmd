import AppKit
import Observation
import SwiftUI

/// What the text before the caret is completing.
struct CompletionContext: Equatable {
    enum Kind: Equatable {
        /// `](query`: a file path; `image` for `![...](`.
        case path(image: Bool)
        /// `](file#query`, or `](#query` (empty file) for this document.
        case heading(file: String)
        /// `[[query`
        case wiki
        /// `[[Name#query`, or `[[#query` (empty name) for this document.
        case wikiHeading(name: String)
    }

    var kind: Kind
    var query: String
    /// The text an accepted suggestion replaces.
    var range: NSRange
    /// Where `](` or `[[` starts; a new trigger is a new context.
    var trigger: Int
}

struct CompletionItem: Identifiable, Equatable {
    enum Kind { case document, image, heading }
    var id: String
    var kind: Kind
    var title: String
    var detail: String = ""
    var insertion: String
}

/// Suggests project files and headings while typing link targets in the editor: after `](`,
/// after `#` in a link target, and after `[[`. The list only takes arrows, Return, Tab, and
/// Escape while it is showing; otherwise every key goes to the editor as usual.
@MainActor
final class EditorCompletion: NSObject {
    let textView: NSTextView
    /// Suggestions for a context, best first.
    var provider: ((CompletionContext) -> [CompletionItem])?
    var isEnabled: () -> Bool = { true }

    let list = CompletionListState()
    private(set) var context: CompletionContext?
    var isVisible: Bool { context != nil && !list.items.isEmpty }

    /// Escape hides the list until a new `](` or `[[` is typed.
    private var suppressedTrigger: Int?
    /// After accepting, the list stays hidden until the link text changes again.
    private var acceptedContext: CompletionContext?
    private var isAccepting = false
    private var panel: CompletionPanel?
    private var observers: [NSObjectProtocol] = []

    init(textView: NSTextView) {
        self.textView = textView
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSText.didChangeNotification, object: textView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.textDidChange() }
        })
        observers.append(center.addObserver(forName: NSTextView.didChangeSelectionNotification, object: textView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.selectionDidChange() }
        })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? NSWindow, window === self.textView.window else { return }
                self.dismiss(suppress: false)
            }
        })
        if let clip = textView.enclosingScrollView?.contentView {
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.positionPanel() }
            })
        }
    }

    // MARK: Editor events

    private func textDidChange() {
        guard !isAccepting else { return }
        update(allowOpening: true)
    }

    private func selectionDidChange() {
        guard !isAccepting, context != nil else { return }
        update(allowOpening: false)
    }

    /// Handles a key command from the editor. Returns true only while the list is showing.
    func handle(_ selector: Selector) -> Bool {
        guard isVisible, !textView.hasMarkedText() else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(by: 1)
        case #selector(NSResponder.moveUp(_:)): move(by: -1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)): accept(list.selection)
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)): dismiss(suppress: true)
        default: return false
        }
        return true
    }

    /// The storage's own string; bridging `textView.string` would copy the document on every keystroke.
    private var currentText: NSString { textView.textStorage?.mutableString ?? textView.string as NSString }

    private func update(allowOpening: Bool) {
        let selection = textView.selectedRange()
        guard isEnabled(), !textView.hasMarkedText(), selection.length == 0,
              let next = Self.context(in: currentText, caret: selection.location) else {
            close()
            return
        }
        if let suppressedTrigger {
            if suppressedTrigger == next.trigger { close(); return }
            self.suppressedTrigger = nil
        }
        if let acceptedContext {
            if acceptedContext == next { close(); return }
            self.acceptedContext = nil
        }
        guard allowOpening || context != nil else { return }
        guard next != context else { return }
        context = next
        list.items = Array((provider?(next) ?? []).prefix(60))
        list.selection = 0
        if list.items.isEmpty { hidePanel() } else { showPanel() }
    }

    /// Asks the provider again for the link target being completed, for suggestions that
    /// became available after the last keystroke.
    func refresh() {
        guard let context, !isAccepting, isEnabled() else { return }
        let items = Array((provider?(context) ?? []).prefix(60))
        guard items != list.items else { return }
        list.items = items
        list.selection = 0
        if items.isEmpty { hidePanel() } else { showPanel() }
    }

    private func move(by step: Int) {
        let count = list.items.count
        guard count > 0 else { return }
        list.selection = (list.selection + step + count) % count
    }

    /// Hides the list; with `suppress`, it stays hidden for the rest of this link.
    func dismiss(suppress: Bool) {
        if suppress, let context { suppressedTrigger = context.trigger }
        close()
    }

    private func close() {
        context = nil
        list.items = []
        hidePanel()
    }

    /// Inserts the suggestion at `index`, closing a wiki link with `]]` when needed.
    func accept(_ index: Int) {
        guard let context, list.items.indices.contains(index) else { return }
        let item = list.items[index]
        let ns = currentText
        var insertion = item.insertion
        var caretAfter = 0
        switch context.kind {
        case .wiki, .wikiHeading:
            let end = NSMaxRange(context.range)
            let rest = end < ns.length ? ns.substring(with: NSRange(location: end, length: min(2, ns.length - end))) : ""
            if rest == "]]" { caretAfter = 2 } else { insertion += "]]" }
        case .path, .heading:
            break
        }
        isAccepting = true
        textView.insertText(insertion, replacementRange: context.range)
        isAccepting = false
        if caretAfter > 0 {
            let caret = textView.selectedRange().location + caretAfter
            textView.setSelectedRange(NSRange(location: min(caret, currentText.length), length: 0))
        }
        close()
        let caret = textView.selectedRange().location
        acceptedContext = Self.context(in: currentText, caret: caret)
    }

    // MARK: Context

    /// The completion context for the caret, or nil when it is not in a link target.
    static func context(in text: NSString, caret: Int) -> CompletionContext? {
        guard caret <= text.length else { return nil }
        let lineStart = text.lineRange(for: NSRange(location: caret, length: 0)).location
        let start = max(lineStart, caret - 400)
        let prefix = text.substring(with: NSRange(location: start, length: caret - start)) as NSString
        let wiki = prefix.range(of: "[[", options: .backwards)
        let link = prefix.range(of: "](", options: .backwards)
        let useWiki: Bool
        switch (wiki.location != NSNotFound, link.location != NSNotFound) {
        case (false, false): return nil
        case (true, false): useWiki = true
        case (false, true): useWiki = false
        case (true, true): useWiki = wiki.location > link.location
        }
        let open = useWiki ? wiki : link
        let queryStart = NSMaxRange(open)
        let query = prefix.substring(from: queryStart)
        let stoppers = useWiki ? ["]", "[", "|", "\t"] : ["]", "[", ")", "(", " ", "\t", "<", ">", ":"]
        guard !stoppers.contains(where: { query.contains($0) }) else { return nil }
        // Not inside inline code or a fenced code block.
        let ticks = prefix.substring(to: open.location).filter { $0 == "`" }.count
        let lineTicks = text.substring(with: NSRange(location: lineStart, length: start - lineStart)).filter { $0 == "`" }.count
        guard (ticks + lineTicks) % 2 == 0, !isInFencedCode(text, before: lineStart) else { return nil }

        let trigger = start + open.location
        let base = start + queryStart
        let hash = (query as NSString).range(of: "#")
        if hash.location != NSNotFound {
            let before = (query as NSString).substring(to: hash.location)
            let after = (query as NSString).substring(from: hash.location + 1)
            let range = NSRange(location: base + hash.location + 1, length: (after as NSString).length)
            let kind: CompletionContext.Kind = useWiki
                ? .wikiHeading(name: before.trimmingCharacters(in: .whitespaces))
                : .heading(file: before)
            return CompletionContext(kind: kind, query: after, range: range, trigger: trigger)
        }
        let range = NSRange(location: base, length: (query as NSString).length)
        if useWiki { return CompletionContext(kind: .wiki, query: query, range: range, trigger: trigger) }
        return CompletionContext(kind: .path(image: isImageLink(prefix, closing: link.location)), query: query, range: range, trigger: trigger)
    }

    /// Whether the `]` at `closing` ends the alt text of an image (`![...]`).
    private static func isImageLink(_ text: NSString, closing: Int) -> Bool {
        var depth = 0
        var index = closing - 1
        while index >= 0 {
            let c = text.character(at: index)
            if c == 0x5D { depth += 1 }
            if c == 0x5B {
                if depth == 0 { return index > 0 && text.character(at: index - 1) == 0x21 }
                depth -= 1
            }
            index -= 1
        }
        return false
    }

    /// Whether a line starting at `location` is inside a fenced code block. Runs on keystrokes in
    /// link targets, so it visits only the lines holding three backticks or tildes, not every line.
    static func isInFencedCode(_ text: NSString, before location: Int) -> Bool {
        let length = min(location, text.length)
        var fence: (char: Character, count: Int)?
        var searchStart = 0
        // The next run of each kind at or after `searchStart` (NSNotFound when there is none).
        var next = (tick: -1, tilde: -1)
        func find(_ run: String, cached: Int) -> Int {
            guard cached != NSNotFound, cached < searchStart else { return cached }
            return text.range(of: run, range: NSRange(location: searchStart, length: length - searchStart)).location
        }
        while searchStart < length {
            next = (find("```", cached: next.tick), find("~~~", cached: next.tilde))
            let hit = min(next.tick, next.tilde)
            guard hit != NSNotFound else { break }
            let lineRange = text.lineRange(for: NSRange(location: hit, length: 0))
            searchStart = NSMaxRange(lineRange)
            let line = text.substring(with: lineRange).trimmingCharacters(in: .newlines)
            let trimmed = line.drop { $0 == " " }
            guard line.count - trimmed.count < 4, let first = trimmed.first, first == "`" || first == "~" else { continue }
            let run = trimmed.prefix { $0 == first }.count
            guard run >= 3 else { continue }
            if let open = fence {
                if first == open.char, run >= open.count, trimmed.dropFirst(run).allSatisfy(\.isWhitespace) { fence = nil }
            } else {
                fence = (first, run)
            }
        }
        return fence != nil
    }

    // MARK: Ranking

    struct Candidate {
        var item: CompletionItem
        /// Texts the query is matched against, for example the file name and its path.
        let keys: [String]
        /// Lower groups come first among equally good matches (Markdown before images).
        var group: Int
        /// Breaks ties when the query is empty; higher is better.
        var weight: Int
        /// `keys` lowercased, prepared once so ranking a cached list on each keystroke stays cheap.
        let folded: [[Character]]

        init(item: CompletionItem, keys: [String], group: Int = 0, weight: Int = 0) {
            self.item = item
            self.keys = keys
            self.group = group
            self.weight = weight
            folded = keys.map { Array($0.lowercased()) }
        }
    }

    /// Fuzzy-ranks candidates: prefix matches, then substring matches, then scattered letters.
    static func rank(_ query: String, _ candidates: [Candidate], limit: Int = 60) -> [CompletionItem] {
        let q = Array(query.lowercased())
        var scored: [(tier: Int, group: Int, score: Int, title: String, item: CompletionItem)] = []
        for candidate in candidates {
            var best: (tier: Int, score: Int)?
            for key in candidate.folded {
                guard let match = score(q, key) else { continue }
                if best == nil || (match.tier, match.score) > (best!.tier, best!.score) { best = match }
            }
            guard let best else { continue }
            let score = q.isEmpty ? candidate.weight : best.score + candidate.weight / 4
            scored.append((best.tier, candidate.group, score, candidate.item.title, candidate.item))
        }
        scored.sort { a, b in
            if a.tier != b.tier { return a.tier > b.tier }
            if a.group != b.group { return a.group < b.group }
            if a.score != b.score { return a.score > b.score }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        return scored.prefix(limit).map(\.item)
    }

    /// Match quality (3 prefix, 2 word start, 1 substring, 0 scattered) and a finer score.
    private static func score(_ query: [Character], _ key: [Character]) -> (tier: Int, score: Int)? {
        guard !query.isEmpty else { return (0, 0) }
        guard query.count <= key.count else { return nil }
        if key.starts(with: query) { return (3, 1000 - key.count) }
        // Contiguous match, preferring one at a word start.
        var substring: Int?
        if key.count >= query.count {
            for i in 0...(key.count - query.count) where key[i] == query[0] && Array(key[i..<(i + query.count)]) == query {
                if isBoundary(key, i) { return (2, 900 - key.count - i) }
                if substring == nil { substring = i }
            }
        }
        if let substring { return (1, 800 - key.count - substring) }
        // Scattered letters in order, rewarding runs and word starts.
        var score = 0, k = 0, run = 0
        for c in query {
            var found = false
            var gap = 0
            while k < key.count {
                if key[k] == c {
                    run = gap == 0 ? run + 1 : 1
                    score += 2 + run * 2 + (isBoundary(key, k) ? 10 : 0) - min(gap, 3)
                    k += 1
                    found = true
                    break
                }
                gap += 1
                k += 1
            }
            if !found { return nil }
        }
        return (0, score - key.count / 4)
    }

    private static func isBoundary(_ key: [Character], _ index: Int) -> Bool {
        index == 0 || " /-_.".contains(key[index - 1])
    }

    // MARK: Panel

    private func showPanel() {
        guard let window = textView.window else { return }
        let panel = self.panel ?? makePanel()
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        positionPanel()
        panel.orderFront(nil)
    }

    private func hidePanel() {
        guard let panel, panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func positionPanel() {
        guard let panel, panel.parent != nil, let context else { return }
        let caret = textView.firstRect(forCharacterRange: NSRange(location: context.range.location, length: 0), actualRange: nil)
        // Without a place to show the list, close it: a hidden list must not take Return or arrows.
        guard caret != .zero else { close(); return }
        let rows = CGFloat(min(list.items.count, 8))
        let size = NSSize(width: 380, height: rows * CompletionListView.rowHeight + 10)
        var origin = NSPoint(x: caret.minX - 30, y: caret.minY - size.height - 4)
        if let screen = textView.window?.screen?.visibleFrame {
            if origin.y < screen.minY { origin.y = caret.maxY + 4 }
            origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func makePanel() -> CompletionPanel {
        let panel = CompletionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.contentView = NSHostingView(rootView: CompletionListView(state: list) { [weak self] index in
            self?.accept(index)
        })
        self.panel = panel
        return panel
    }
}

/// The visible suggestions and the highlighted one.
@MainActor
@Observable
final class CompletionListState {
    var items: [CompletionItem] = []
    var selection = 0
}

/// A borderless panel that never takes focus from the editor.
private final class CompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct CompletionListView: View {
    static let rowHeight: CGFloat = 26
    let state: CompletionListState
    let onPick: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                        row(item, selected: index == state.selection)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture { onPick(index) }
                    }
                }
                .padding(5)
            }
            .scrollIndicators(.never)
            .onChange(of: state.selection) { _, selection in proxy.scrollTo(selection) }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Link Suggestions")
    }

    private func row(_ item: CompletionItem, selected: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon(item.kind))
                .font(.system(size: 11))
                .frame(width: 14)
                .foregroundStyle(selected ? Color.white : Color.secondary)
            Text(item.title)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
            if !item.detail.isEmpty {
                Text(item.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func icon(_ kind: CompletionItem.Kind) -> String {
        switch kind {
        case .document: "doc.text"
        case .image: "photo"
        case .heading: "number"
        }
    }
}
