import AppKit

/// Replacement text for find bar matches.
enum FindReplace {
    /// Non-empty matches of `regex` in `text`, in order: the same matches the find bar counts.
    static func matches(of regex: NSRegularExpression, in text: String) -> [NSTextCheckingResult] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).filter { $0.range.length > 0 }
    }

    /// The text that replaces `match`. With `expandsTemplate` (regular expressions), `$0` to `$9`
    /// in `template` take the matched and captured text and `\$` stays a dollar sign; otherwise
    /// `template` is used as typed.
    static func replacement(
        for match: NSTextCheckingResult, of regex: NSRegularExpression, in text: String,
        template: String, expandsTemplate: Bool
    ) -> String {
        guard expandsTemplate else { return template }
        return regex.replacementString(for: match, in: text, offset: 0, template: template)
    }

    /// One edit per match, for Replace All.
    static func edits(
        of regex: NSRegularExpression, in text: String, template: String, expandsTemplate: Bool
    ) -> [TextEdit] {
        matches(of: regex, in: text).map {
            TextEdit(
                range: $0.range,
                replacement: replacement(for: $0, of: regex, in: text, template: template, expandsTemplate: expandsTemplate)
            )
        }
    }
}

/// The text view's automatic substitutions. Markdown relies on straight quotes and plain
/// hyphens, so every one is off until the user turns it on.
struct TextSubstitutions: Equatable {
    var correctsSpelling = false
    var smartCopyPaste = false
    var smartQuotes = false
    var smartDashes = false
    var smartLinks = false
    var textReplacement = false

    private static let keys: [(String, WritableKeyPath<TextSubstitutions, Bool>)] = [
        ("correctsSpelling", \.correctsSpelling), ("smartCopyPaste", \.smartCopyPaste),
        ("smartQuotes", \.smartQuotes), ("smartDashes", \.smartDashes),
        ("smartLinks", \.smartLinks), ("textReplacement", \.textReplacement),
    ]

    init() {}

    /// Reads stored settings; missing or malformed values stay off.
    init(dictionary: [String: Any]?) {
        for (key, path) in Self.keys {
            if let value = dictionary?[key] as? Bool { self[keyPath: path] = value }
        }
    }

    var dictionary: [String: Bool] {
        Dictionary(uniqueKeysWithValues: Self.keys.map { ($0.0, self[keyPath: $0.1]) })
    }
}

extension EditorController {
    /// The text view's automatic substitutions and spelling correction.
    var substitutions: TextSubstitutions {
        get {
            var value = TextSubstitutions()
            value.correctsSpelling = textView.isAutomaticSpellingCorrectionEnabled
            value.smartCopyPaste = textView.smartInsertDeleteEnabled
            value.smartQuotes = textView.isAutomaticQuoteSubstitutionEnabled
            value.smartDashes = textView.isAutomaticDashSubstitutionEnabled
            value.smartLinks = textView.isAutomaticLinkDetectionEnabled
            value.textReplacement = textView.isAutomaticTextReplacementEnabled
            return value
        }
        set {
            guard newValue != substitutions else { return }
            textView.isAutomaticSpellingCorrectionEnabled = newValue.correctsSpelling
            textView.smartInsertDeleteEnabled = newValue.smartCopyPaste
            textView.isAutomaticQuoteSubstitutionEnabled = newValue.smartQuotes
            textView.isAutomaticDashSubstitutionEnabled = newValue.smartDashes
            textView.isAutomaticLinkDetectionEnabled = newValue.smartLinks
            textView.isAutomaticTextReplacementEnabled = newValue.textReplacement
        }
    }
}

/// The editor's context menu toggles substitutions directly; report each change so the
/// Edit menu's checkmarks and the stored settings follow.
extension LexMDTextView {
    override func toggleAutomaticSpellingCorrection(_ sender: Any?) {
        super.toggleAutomaticSpellingCorrection(sender)
        reportSubstitutions()
    }

    override func toggleSmartInsertDelete(_ sender: Any?) {
        super.toggleSmartInsertDelete(sender)
        reportSubstitutions()
    }

    override func toggleAutomaticQuoteSubstitution(_ sender: Any?) {
        super.toggleAutomaticQuoteSubstitution(sender)
        reportSubstitutions()
    }

    override func toggleAutomaticDashSubstitution(_ sender: Any?) {
        super.toggleAutomaticDashSubstitution(sender)
        reportSubstitutions()
    }

    override func toggleAutomaticLinkDetection(_ sender: Any?) {
        super.toggleAutomaticLinkDetection(sender)
        reportSubstitutions()
    }

    override func toggleAutomaticTextReplacement(_ sender: Any?) {
        super.toggleAutomaticTextReplacement(sender)
        reportSubstitutions()
    }

    /// Data detectors would add link attributes to plain Markdown text, so they stay off.
    override func toggleAutomaticDataDetection(_ sender: Any?) {}

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(NSTextView.toggleAutomaticDataDetection(_:)) { return false }
        return super.validateMenuItem(item)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSTextView.toggleAutomaticDataDetection(_:)) { return false }
        return super.validateUserInterfaceItem(item)
    }

    private func reportSubstitutions() {
        guard let editor else { return }
        editor.onSubstitutionsChange?(editor.substitutions)
    }
}
