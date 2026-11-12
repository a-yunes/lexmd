import AppKit
import SwiftUI

// MARK: - Keyboard-aware text field

/// A borderless text field that reports arrow keys, Return (with Shift state) and Escape.
struct CommandTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var font: NSFont
    var focusToken: Int
    /// Whether the field takes focus when it first appears, not only when `focusToken` changes.
    var focusesOnAppear = true
    var onMove: (Int) -> Void = { _ in }
    var onSubmit: (_ shift: Bool) -> Void = { _ in }
    var onCancel: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.lineBreakMode = .byClipping
        field.stringValue = text
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text, field.currentEditor() == nil || context.coordinator.lastSent != text {
            field.stringValue = text
        }
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            DispatchQueue.main.async {
                guard let window = field.window else { return }
                window.makeFirstResponder(field)
                field.currentEditor()?.selectAll(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandTextField
        var focusToken: Int
        var lastSent: String?

        init(_ parent: CommandTextField) {
            self.parent = parent
            self.focusToken = parent.focusesOnAppear ? parent.focusToken - 1 : parent.focusToken
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            lastSent = field.stringValue
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            default: return false
            }
            return true
        }
    }
}

/// Small rounded toggle used for search options ("Aa", "W", ".*").
struct OptionToggle: View {
    let title: String
    let help: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .frame(minWidth: 24, minHeight: 20)
                .padding(.horizontal, 2)
                .foregroundStyle(isOn ? Color.white : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isOn ? Color.accentColor : Color.primary.opacity(0.07))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private func highlighted(_ text: String, _ range: NSRange?, matchFont: Font, matchBackground: Color?) -> AttributedString {
    let ns = text as NSString
    guard let range, range.location != NSNotFound, NSMaxRange(range) <= ns.length, range.length > 0 else {
        return AttributedString(text)
    }
    var result = AttributedString(ns.substring(to: range.location))
    var match = AttributedString(ns.substring(with: range))
    match.font = matchFont
    if let matchBackground { match.backgroundColor = matchBackground }
    result += match
    result += AttributedString(ns.substring(from: NSMaxRange(range)))
    return result
}

// MARK: - Find bar

/// Floating find bar for the open document, on the same Liquid Glass as the Find in Files
/// panel, with an optional replace row.
struct FindBar: View {
    @Environment(AppModel.self) private var model
    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
    /// The width of the disclosure button and magnifying glass, so both fields line up.
    private let leadingWidth: CGFloat = 36

    private var findRow: some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            HStack(spacing: 6) {
                Button { model.toggleReplace() } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(model.isReplaceVisible ? 90 : 0))
                        .frame(width: 12, height: 20)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.isReplaceVisible ? "Hide Replace" : model.helpText("Show Replace", .findAndReplace))
                .accessibilityLabel(model.isReplaceVisible ? "Hide Replace" : "Show Replace")
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(width: leadingWidth, alignment: .leading)
            CommandTextField(
                text: $model.findQuery,
                placeholder: "Find in Document",
                font: .systemFont(ofSize: 14),
                focusToken: model.findFocusToken,
                onMove: { model.findNext($0 > 0) },
                onSubmit: { shift in model.findNext(!shift) },
                onCancel: { model.closeFindBar() }
            )
            .frame(width: 210, height: 20)
            .accessibilityLabel("Find")
            Text(countLabel)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(model.findQuery.isEmpty ? Color.clear : Color.secondary)
                .frame(minWidth: 62, alignment: .trailing)
                .fixedSize()
            Divider().frame(height: 18)
            HStack(spacing: 4) {
                OptionToggle(title: "Aa", help: "Match Case", isOn: $model.findCaseSensitive)
                OptionToggle(title: "W", help: "Whole Words", isOn: $model.findWholeWord)
                OptionToggle(title: ".*", help: "Regular Expression", isOn: $model.findUsesRegex)
            }
            HStack(spacing: 2) {
                BarIconButton(symbol: "chevron.up", label: "Previous Match", help: model.helpText("Previous Match", .findPrevious)) { model.findNext(false) }
                BarIconButton(symbol: "chevron.down", label: "Next Match", help: model.helpText("Next Match", .findNext)) { model.findNext(true) }
            }
            .disabled(model.findCount == 0)
            BarIconButton(symbol: "xmark", label: "Close Find Bar", help: "Close (esc)") { model.closeFindBar() }
        }
        .frame(height: 44)
    }

    private var replaceRow: some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            Color.clear.frame(width: leadingWidth, height: 1)
            CommandTextField(
                text: $model.replaceQuery,
                placeholder: "Replace With",
                font: .systemFont(ofSize: 14),
                focusToken: model.replaceFocusToken,
                // Like Find and Replace…: the replace field starts out focused when there is
                // something to find, otherwise the find field keeps focus.
                focusesOnAppear: !model.findQuery.isEmpty,
                onMove: { model.findNext($0 > 0) },
                onSubmit: { _ in model.replaceCurrent() },
                onCancel: { model.closeFindBar() }
            )
            .frame(width: 210, height: 20)
            .accessibilityLabel("Replace With")
            .help(model.findUsesRegex ? "$0 inserts the match and $1, $2, and so on insert its groups." : "")
            Spacer(minLength: 8)
            Group {
                Button("Replace") { model.replaceCurrent() }
                    .help("Replace the current match and find the next one")
                Button("Replace All") { model.replaceAll() }
                    .help("Replace every match in the document")
            }
            .controlSize(.small)
            .disabled(model.findCount == 0)
        }
        .padding(.trailing, 4)
        .frame(height: 34)
        .padding(.bottom, 6)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            findRow
            if model.isReplaceVisible {
                replaceRow
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        // System glass draws its own edge and shadow.
        .glassEffect(.regular, in: shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.isReplaceVisible ? "Find and Replace" : "Find")
    }

    private var countLabel: String {
        if let status = model.findStatus { return status }
        if model.isFindPatternInvalid { return "Invalid pattern" }
        return model.findCount == 0 ? "No matches" : "\(model.findIndex + 1) of \(model.findCount)"
    }
}

/// Compact icon button with a soft hover background.
struct BarIconButton: View {
    let symbol: String
    /// The name VoiceOver reads; `help` may add the shortcut.
    let label: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .foregroundStyle(isEnabled ? Color.secondary : Color.secondary.opacity(0.4))
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(isHovering && isEnabled ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(label)
    }
}

// MARK: - Find in Files panel

struct QuickSearchOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.black.opacity(0.08)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { model.closeQuickSearch() }
                QuickSearchPanel()
                    .frame(
                        width: min(800, geometry.size.width - 48),
                        height: min(600, max(320, geometry.size.height - 80))
                    )
                    .padding(.top, 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct QuickSearchPanel: View {
    @Environment(AppModel.self) private var model
    private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().opacity(0.6)
            content
            if let preview = model.quickPreview {
                Divider().opacity(0.6)
                QuickPreviewPane(preview: preview)
            }
            Divider().opacity(0.6)
            footer
        }
        .clipShape(shape)
        // System glass draws its own edge and shadow.
        .glassEffect(.regular, in: shape)
    }

    private var searchField: some View {
        @Bindable var model = model
        return HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.secondary)
            CommandTextField(
                text: $model.quickQuery,
                placeholder: model.quickMode == .files
                    ? "Open Quickly"
                    : "Search in \(model.rootURL?.lastPathComponent ?? "Folder")",
                font: .systemFont(ofSize: 21, weight: .regular),
                focusToken: model.quickFocusToken,
                onMove: { model.moveQuickSelection($0) },
                onSubmit: { _ in model.activateQuickSelection() },
                onCancel: { model.closeQuickSearch() }
            )
            .frame(height: 28)
            if model.isQuickSearching {
                ProgressView().controlSize(.small)
            }
            if model.quickMode == .everything {
                HStack(spacing: 4) {
                    OptionToggle(title: "Aa", help: "Match Case", isOn: $model.quickOptions.caseSensitive)
                    OptionToggle(title: "W", help: "Whole Words", isOn: $model.quickOptions.wholeWord)
                    OptionToggle(title: ".*", help: "Regular Expression", isOn: $model.quickOptions.regex)
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
    }

    @ViewBuilder private var content: some View {
        let results = model.quickResults
        if model.quickMode == .files, model.quickItemCount == 0 {
            placeholder(
                symbol: "doc.text.magnifyingglass",
                title: model.quickQuery.trimmingCharacters(in: .whitespaces).isEmpty ? "Open Quickly" : "No Matching Files",
                message: "Type part of a file or folder name. Letters can be spread out, like “skrev”."
            )
        } else if model.quickQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            placeholder(
                symbol: "text.magnifyingglass",
                title: "Search \(model.rootURL?.lastPathComponent ?? "Files")",
                message: "Find files by name and text across every Markdown document."
            )
        } else if let error = results.error {
            placeholder(symbol: "exclamationmark.triangle", title: error, message: "Check the pattern, or turn off .* to search for plain text.")
        } else if model.quickItemCount == 0 && !model.isQuickSearching {
            placeholder(symbol: "magnifyingglass", title: "No Results", message: "Nothing matches “\(model.quickQuery)”.")
        } else {
            QuickResultsList()
        }
    }

    private func placeholder(symbol: String, title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        let results = model.quickResults
        let summary: String = {
            if model.quickMode == .files {
                let count = results.files.count
                if model.quickQuery.trimmingCharacters(in: .whitespaces).isEmpty { return count == 0 ? "" : "Recent files" }
                return "\(count) \(count == 1 ? "file" : "files")"
            }
            if model.quickQuery.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
            if model.isQuickSearching && model.quickItemCount == 0 { return "Searching…" }
            let matches = results.hits.count
            var parts: [String] = []
            if !results.files.isEmpty { parts.append("\(results.files.count) \(results.files.count == 1 ? "file" : "files") by name") }
            parts.append("\(matches)\(results.truncated ? "+" : "") \(matches == 1 ? "match" : "matches") in \(results.hitFileCount) \(results.hitFileCount == 1 ? "file" : "files")")
            return parts.joined(separator: " · ")
        }()
        return HStack(spacing: 14) {
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            KeyHint(keys: "↑↓", label: "Navigate")
            KeyHint(keys: "↩", label: "Open")
            KeyHint(keys: "⌘↩", label: "New Tab")
            KeyHint(keys: "esc", label: "Close")
        }
        .padding(.horizontal, 16)
        .frame(height: 32)
    }
}

private struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 16)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.08)))
            Text(label).font(.subheadline)
        }
        .foregroundStyle(.secondary)
    }
}

private struct QuickResultsList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let results = model.quickResults
        let fileOffset = results.files.count
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if !results.files.isEmpty {
                        SectionTitle(title: model.quickMode == .files && model.quickQuery.trimmingCharacters(in: .whitespaces).isEmpty ? "Recent" : "Files")
                        ForEach(Array(results.files.enumerated()), id: \.element.id) { index, file in
                            QuickFileRow(file: file, isSelected: model.quickSelection == index)
                                .onTapGesture { model.activateQuickItem(at: index) }
                        }
                    }
                    if !results.hits.isEmpty {
                        SectionTitle(title: "Text Matches")
                        ForEach(Array(results.hits.enumerated()), id: \.element.id) { index, hit in
                            if index == 0 || results.hits[index - 1].path != hit.path {
                                QuickFileHeader(hit: hit, count: results.hitCounts[hit.path] ?? 0)
                            }
                            QuickHitRow(hit: hit, isSelected: model.quickSelection == fileOffset + index)
                                .onTapGesture { model.activateQuickItem(at: fileOffset + index) }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            // A results refresh can keep a row further down selected.
            .onAppear { if model.quickSelection > 0 { scroll(proxy, to: model.quickSelection) } }
            // Each new set of results gets a fresh list, scrolled to the top, so no rows or
            // scroll position carry over from an earlier query.
            .id(model.quickResultsGeneration)
            .onChange(of: model.quickSelection) { _, selection in
                scroll(proxy, to: selection)
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to selection: Int) {
        switch model.quickItem(at: selection) {
        case .file(let file): proxy.scrollTo(file.id)
        case .hit(let hit): proxy.scrollTo(hit.id)
        case nil: break
        }
    }
}

private struct SectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 3)
    }
}

private struct QuickFileRow: View {
    let file: FileMatch
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "doc.text.fill")
                .font(.body)
                .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                .frame(width: 18)
            Text(name)
                .font(.body)
                .lineLimit(1)
            if !file.folder.isEmpty {
                Text(file.folder)
                    .font(.subheadline)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.75) : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(SelectionBackground(isSelected: isSelected))
        .contentShape(Rectangle())
    }

    private var name: AttributedString {
        var result = AttributedString()
        let matched = Set(file.matched)
        for (i, ch) in file.name.enumerated() {
            var piece = AttributedString(String(ch))
            if matched.contains(i) { piece.font = .body.bold() }
            result += piece
        }
        return result
    }
}

private struct QuickFileHeader: View {
    let hit: SearchHit
    let count: Int

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "doc.text")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text((hit.name as NSString).deletingPathExtension)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            if !hit.folder.isEmpty {
                Text(hit.folder)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            Text("\(count)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
        }
        .padding(.horizontal, 10)
        .padding(.top, 7)
        .padding(.bottom, 2)
    }
}

private struct QuickHitRow: View {
    let hit: SearchHit
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(highlighted(
                hit.snippet, hit.snippetMatch,
                matchFont: .body.weight(.semibold),
                matchBackground: isSelected ? nil : Color.yellow.opacity(0.35)
            ))
            .font(.body)
            .lineLimit(1)
            Spacer(minLength: 8)
            Text("\(hit.line)")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
        }
        .padding(.leading, 37)
        .padding(.trailing, 10)
        .frame(height: 26)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(SelectionBackground(isSelected: isSelected))
        .contentShape(Rectangle())
    }
}

private struct SelectionBackground: View {
    let isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isSelected ? Color.accentColor : Color.clear)
    }
}

private struct QuickPreviewPane: View {
    let preview: QuickPreviewData

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "doc.text")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(preview.name).font(.callout.weight(.semibold))
                if !preview.folder.isEmpty {
                    Text(preview.folder)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
                Text(preview.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 9)
            .padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(preview.lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(line.id)")
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                        Text(highlighted(
                            line.text, line.match,
                            matchFont: .system(.callout, design: .monospaced, weight: .bold),
                            matchBackground: Color.yellow.opacity(0.45)
                        ))
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                    .padding(.trailing, 12)
                    .background(line.match != nil ? Color.accentColor.opacity(0.1) : Color.clear)
                }
            }
            .padding(.bottom, 8)
        }
        .frame(height: 196, alignment: .top)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
        .clipped()
    }
}
