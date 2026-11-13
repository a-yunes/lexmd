import AppKit
import OSLog
import WebKit

@MainActor
final class PreviewController: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var onOpenURL: ((URL) -> Void)?
    var onHighlightCount: ((Int) -> Void)?
    /// The id of the heading in view as the preview scrolls (empty above the first heading).
    var onHeadingChange: ((String) -> Void)?
    /// Pinch gestures, in text size steps (positive is bigger).
    var onPinch: ((Int) -> Void)? {
        get { (webView as? PreviewWebView)?.onPinch }
        set { (webView as? PreviewWebView)?.onPinch = newValue }
    }

    struct Highlight: Equatable {
        var query: String
        var options: SearchOptions
        var current: Int
    }

    /// LexMD's preview script runs here, apart from the page world that holds document markup.
    private static let world = WKContentWorld.world(name: "LexMD")
    private static let log = Logger(subsystem: "io.github.a-yunes.lexmd", category: "preview")
    private static let pageURL = URL(string: "\(DocumentSchemeHandler.scheme):///")!
    /// Pele draws diagrams and KaTeX typesets math; each is loaded when markup first needs it.
    private static let libraries = [("class=\"lexmd-diagram\"", VendorAssets.peleScript), ("class=\"lexmd-math", VendorAssets.katexScript)]

    private var highlight: Highlight?
    private var highlightApplied = false
    private var highlightScrollUntil = Date.distantPast

    private var isLoaded = false
    private var isLoadingTemplate = false
    /// The latest template load; callbacks for loads it superseded are ignored.
    private var templateNavigation: WKNavigation?
    private var templateRetries = 0
    private var lastHTML = ""
    private var lastBase: URL?
    private var pendingReset = false
    /// True from `render` until the markup reaches the page.
    private var hasNewRender = false
    private var pendingHeading: (id: String, afterRender: Bool)?
    private var scale: Double = 1
    /// Scroll position (0...1) to apply after the next render, used when switching tabs.
    var pendingScrollFraction: Double?
    /// Modifier keys held for the last clicked link; Command opens it in a new tab.
    private(set) var linkModifiers: NSEvent.ModifierFlags = []
    private(set) var allowsRemoteContent: Bool
    private let userContent: WKUserContentController
    private var injectedLibraries: Set<Int> = []
    private var pageLibraries: Set<Int> = []
    /// The document's name, announced by VoiceOver as the page title.
    private var documentTitle = ""
    /// Underlines links and marks the current find match with more than color.
    private(set) var differentiatesWithoutColor = NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor

    init(allowsRemoteContent: Bool) {
        self.allowsRemoteContent = allowsRemoteContent
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(DocumentSchemeHandler(), forURLScheme: DocumentSchemeHandler.scheme)
        configuration.setURLSchemeHandler(VendorSchemeHandler(), forURLScheme: VendorSchemeHandler.scheme)
        // Scripts in documents never run; LexMD's own script below is unaffected.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let content = WKUserContentController()
        content.addUserScript(WKUserScript(
            source: PreviewTemplate.renderingScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world
        ))
        content.addUserScript(WKUserScript(
            source: PreviewTemplate.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world
        ))
        configuration.userContentController = content
        // Tab moves through links and buttons, such as a code block's Copy button.
        configuration.preferences.tabFocusesLinks = true
        userContent = content
        webView = PreviewWebView(frame: .zero, configuration: configuration)
        webView.setAccessibilityLabel("Preview")
        webView.setAccessibilityIdentifier("preview")

        super.init()
        // The content controller keeps its handlers alive, so it gets a proxy that holds this controller weakly.
        content.add(ScriptMessageProxy(self), contentWorld: Self.world, name: "lexmd")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
        loadTemplate()
    }

    @objc private func displayOptionsDidChange(_ notification: Notification) {
        setDifferentiatesWithoutColor(NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor)
    }

    /// Follows the system's Differentiate Without Color setting.
    func setDifferentiatesWithoutColor(_ value: Bool) {
        guard value != differentiatesWithoutColor else { return }
        differentiatesWithoutColor = value
        applyPageOptions()
    }

    /// Names the page after the document, so VoiceOver announces which document it shows.
    func setDocumentTitle(_ title: String) {
        guard title != documentTitle else { return }
        documentTitle = title
        applyPageOptions()
    }

    private func applyPageOptions() {
        guard isLoaded else { return }
        call(
            "document.documentElement.classList.toggle('lexmd-differentiate', differentiate); document.title = title",
            ["differentiate": differentiatesWithoutColor, "title": documentTitle]
        )
    }

    private func loadTemplate() {
        isLoaded = false
        isLoadingTemplate = true
        pageLibraries = injectedLibraries
        templateNavigation = webView.loadHTMLString(PreviewTemplate.html(allowsRemoteContent: allowsRemoteContent), baseURL: Self.pageURL)
    }

    /// Lets documents load images and media from the web. The page reloads to apply it.
    func setAllowsRemoteContent(_ value: Bool) {
        guard value != allowsRemoteContent else { return }
        allowsRemoteContent = value
        loadTemplate()
    }

    func render(html: String, baseURL: URL?, resetScroll: Bool) {
        let baseChanged = baseURL != lastBase
        lastHTML = html
        lastBase = baseURL
        hasNewRender = true
        pendingReset = pendingReset || resetScroll || baseChanged
        guard isLoaded else { return }
        flush()
    }

    private func flush() {
        let base = lastBase.flatMap { DocumentSchemeHandler.url(for: $0)?.absoluteString } ?? ""
        let reset = pendingReset
        pendingReset = false
        // A page load re-sends the last markup; scrolling meant for the next document waits for it.
        let isNewRender = hasNewRender
        hasNewRender = false
        loadLibraries(for: lastHTML)
        call("lexmdRender(html, base, reset)", ["html": lastHTML, "base": base, "reset": reset])
        if let heading = pendingHeading, isNewRender || !heading.afterRender {
            pendingHeading = nil
            call("lexmdReveal(id, false)", ["id": heading.id])
        }
        if highlight != nil || highlightApplied {
            applyHighlight(scroll: Date() < highlightScrollUntil)
            highlightScrollUntil = .distantPast
        }
        if isNewRender, let fraction = pendingScrollFraction {
            pendingScrollFraction = nil
            call("lexmdScroll(f)", ["f": fraction])
        }
    }

    /// Pele and KaTeX take tens of milliseconds to evaluate, so they are injected into LexMD's
    /// world (never loaded by the page) when a document first needs them, then kept as user
    /// scripts for later page loads. Calls into the page run in order, so rendering sees them.
    private func loadLibraries(for html: String) {
        for (index, library) in Self.libraries.enumerated() where !pageLibraries.contains(index) && Self.contains(html, library.0) {
            guard let source = library.1 else { continue }
            pageLibraries.insert(index)
            if injectedLibraries.insert(index).inserted {
                userContent.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world))
            }
            webView.evaluateJavaScript(source, in: nil, in: Self.world, completionHandler: nil)
        }
    }

    /// A byte search, much cheaper on a large page than `String.contains`, which compares characters.
    nonisolated static func contains(_ text: String, _ marker: String) -> Bool {
        var text = text, marker = marker
        return text.withUTF8 { haystack in
            marker.withUTF8 { needle in
                guard let base = haystack.baseAddress, let pattern = needle.baseAddress else { return needle.isEmpty }
                return memmem(base, haystack.count, pattern, needle.count) != nil
            }
        }
    }

    /// Highlights matches in the rendered document; `current` marks (and optionally scrolls to) one of them.
    func setHighlight(_ newValue: Highlight?, scroll: Bool) {
        guard newValue != highlight || scroll else { return }
        highlight = newValue
        if scroll { highlightScrollUntil = Date().addingTimeInterval(1.5) }
        guard isLoaded else { return }
        applyHighlight(scroll: scroll)
    }

    private func applyHighlight(scroll: Bool) {
        let h = highlight
        highlightApplied = h != nil
        let args: [String: Any] = [
            "q": h?.query ?? "", "cs": h?.options.caseSensitive ?? false, "word": h?.options.wholeWord ?? false,
            "regex": h?.options.regex ?? false, "current": h?.current ?? -1, "scroll": scroll,
        ]
        call("return lexmdFind(q, cs, word, regex, current, scroll)", args) { [weak self] result in
            self?.onHighlightCount?((result as? NSNumber)?.intValue ?? 0)
        }
    }

    func scroll(to fraction: CGFloat) {
        guard isLoaded else { return }
        call("lexmdScroll(f)", ["f": Double(fraction)])
    }

    /// Reports how far the page is scrolled, from 0 to 1.
    func readScrollFraction(_ completion: @escaping (Double) -> Void) {
        guard isLoaded else { return }
        let body = "var max = document.documentElement.scrollHeight - window.innerHeight; return max > 0 ? window.scrollY / max : 0"
        call(body, [:]) { completion(($0 as? NSNumber)?.doubleValue ?? 0) }
    }

    /// Scrolls a heading to the top, now or (`afterRender`) once the next document has rendered.
    func revealHeading(_ id: String, smooth: Bool, afterRender: Bool = false) {
        guard !afterRender, isLoaded else { pendingHeading = (id, afterRender); return }
        call("lexmdReveal(id, smooth)", ["id": id, "smooth": smooth && !Motion.isReduced])
    }

    func setScale(_ value: Double) {
        scale = value
        guard isLoaded else { return }
        call("lexmdZoom(s)", ["s": value])
    }

    /// True once the page has loaded; renders requested before that have been sent to it.
    var isPageLoaded: Bool { isLoaded }

    /// Runs a script body in LexMD's content world after any pending render, and returns its result.
    func evaluate(_ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: Self.world)
    }

    /// Runs a call into the preview script in LexMD's content world.
    private func call(_ body: String, _ arguments: [String: Any], completion: ((Any?) -> Void)? = nil) {
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: Self.world) { result in
            switch result {
            case .success(let value): completion?(value)
            case .failure(let error):
                Self.log.error("Preview call failed: \(body.prefix(40), privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "copy", let text = body["text"] as? String {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } else if type == "heading", let id = body["id"] as? String {
            onHeadingChange?(id)
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard isLoadingTemplate, templateNavigation == nil || navigation === templateNavigation else { return }
        templateNavigation = nil
        isLoadingTemplate = false
        templateRetries = 0
        isLoaded = true
        call("lexmdZoom(s)", ["s": scale])
        applyPageOptions()
        pendingReset = true
        flush()
    }

    /// A file URL with the `#fragment` of the link that led to it, so links can open at a heading.
    private static func keepingFragment(of link: URL, _ file: URL?) -> URL? {
        guard let file, let fragment = link.fragment, !fragment.isEmpty,
              var components = URLComponents(url: file, resolvingAgainstBaseURL: false) else { return file }
        components.percentEncodedFragment = link.fragment(percentEncoded: true)
        return components.url ?? file
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadTemplate()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        templateLoadFailed(navigation, error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        templateLoadFailed(navigation, error)
    }

    /// Loads the template again when its latest load fails, so the preview never stays blank.
    private func templateLoadFailed(_ navigation: WKNavigation?, _ error: any Error) {
        guard isLoadingTemplate, let templateNavigation, navigation === templateNavigation else { return }
        Self.log.error("Preview page failed to load: \(error.localizedDescription, privacy: .public)")
        self.templateNavigation = nil
        guard templateRetries < 3 else { isLoadingTemplate = false; return }
        templateRetries += 1
        loadTemplate()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        let frame = navigationAction.targetFrame
        // The template, until its latest load finishes. Loads it supersedes ask here too.
        if isLoadingTemplate, navigationAction.navigationType == .other, frame?.isMainFrame == true, url == Self.pageURL {
            return .allow
        }
        if navigationAction.navigationType == .linkActivated {
            // A click on a link, including one that asks for a new window.
            linkModifiers = navigationAction.modifierFlags
            defer { linkModifiers = [] }
            if frame?.isMainFrame != false { onOpenURL?(Self.keepingFragment(of: url, DocumentSchemeHandler.fileURL(for: url)) ?? url) }
        } else if frame?.isMainFrame == true, url.isFileURL, FileScanner.isMarkdown(path: url.path) {
            // A Markdown file dropped onto the preview. Nothing else may navigate without a click.
            onOpenURL?(url)
        }
        return .cancel
    }
}

/// The preview's web view. Pinching changes LexMD's text size, the same setting as Make Text
/// Bigger and Make Text Smaller, instead of magnifying the page: a second, separate zoom would
/// leave Actual Size unable to reset it and the scroll indicator and scroll sync out of step.
final class PreviewWebView: WKWebView {
    var onPinch: ((Int) -> Void)?
    private var pinch = PinchSteps()

    /// Shorter than the preview ever really is; the window's minimum height keeps it far taller.
    static let placeholderHeight: CGFloat = 120

    /// On each step of a live window resize, the enclosing navigation columns are first laid out
    /// at a placeholder height (their toolbar inset) and then at their real size. AppKit views
    /// only draw the final size, but a web view hands every size to its renderer at once, so
    /// following the placeholder would shrink the page to a strip and back on every step and the
    /// preview would blink. While the reader drags, the web view keeps its size through that pass.
    override func setFrameSize(_ newSize: NSSize) {
        if inLiveResize, Self.isPlaceholder(newSize, current: frame.size) { return }
        super.setFrameSize(newSize)
    }

    static func isPlaceholder(_ size: NSSize, current: NSSize) -> Bool {
        size.height < placeholderHeight && current.height >= placeholderHeight
    }

    override func magnify(with event: NSEvent) {
        guard let onPinch else { return super.magnify(with: event) }
        let steps = pinch.steps(adding: event.magnification, phase: event.phase)
        if steps != 0 { onPinch(steps) }
    }
}

/// Turns a pinch gesture's running magnification into whole text size steps.
struct PinchSteps {
    /// How far fingers spread or close for one step.
    static let threshold: CGFloat = 0.12
    private var pending: CGFloat = 0

    mutating func steps(adding magnification: CGFloat, phase: NSEvent.Phase) -> Int {
        if phase.contains(.began) { pending = 0 }
        pending += magnification
        let steps = Int((pending / Self.threshold).rounded(.towardZero))
        pending -= CGFloat(steps) * Self.threshold
        if phase.contains(.ended) || phase.contains(.cancelled) { pending = 0 }
        return steps
    }
}

/// Forwards script messages to the preview without the content controller retaining it.
@MainActor
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    private weak var target: PreviewController?

    init(_ target: PreviewController) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.receive(message)
    }
}
