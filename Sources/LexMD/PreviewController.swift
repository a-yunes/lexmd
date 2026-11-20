import AppKit
import OSLog
import WebKit

@MainActor
final class PreviewController: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var onOpenURL: ((URL) -> Void)?
    /// The page scrolled, and not because it was told to. The argument says the reader used the
    /// wheel, keys or mouse on it; see `ScrollSync`.
    var onReaderScroll: ((_ input: Bool) -> Void)?
    /// The reader double-clicked a block: its source lines (counted from 1), and the word the
    /// double-click selected.
    var onEditRequest: ((_ lines: ClosedRange<Int>, _ word: String) -> Void)?
    /// The number of matches the page marked, and the document the page showed then.
    var onHighlightCount: ((Int, String?) -> Void)?
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
    private var loadWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var isLoadingTemplate = false
    /// The latest template load; callbacks for loads it superseded are ignored.
    private var templateNavigation: WKNavigation?
    private var templateRetries = 0
    /// When the page's web process ended recently; too many in a row stop the reloads.
    private var recentCrashes: [Date] = []
    private var lastHTML = ""
    /// The document and render that the next flush sends, and the ones the page shows.
    private var lastDocument: String?
    private var lastGeneration = 0
    /// The rendered text's number of lines, which ends the page's map of source positions.
    private var lastLineCount = 0
    /// The page's layout and scroll offset, as it last reported them while `reportsScrolling`.
    private var pageLayout: PageLayout?
    private var reportsScrolling = false
    /// A scroll sent to the page that it hasn't run yet, and the latest one waiting after it.
    private var isScrollInFlight = false
    private var pendingScroll: CGFloat?
    private(set) var shownDocument: String?
    private(set) var shownGeneration = -1
    /// How far the page was last scrolled, as it reported; restored after the page reloads.
    private var lastScrollFraction: Double = 0
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
        content.addUserScript(WKUserScript(
            source: PreviewTemplate.scrollSyncScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world
        ))
        content.addUserScript(WKUserScript(
            source: PreviewTemplate.lightboxScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world
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
        startTemplateLoad()
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

    /// Starts a fresh load with a full retry budget.
    private func startTemplateLoad() {
        templateRetries = 0
        loadTemplate()
    }

    private func loadTemplate() {
        setLightboxOpen(false)
        isScrollInFlight = false
        pendingScroll = nil
        pageLayout = nil
        // The page that comes back shows nothing until the next flush.
        if shownDocument != nil, pendingScrollFraction == nil, pendingHeading == nil {
            // Keep the reader's place across the reload; the flush after it reapplies it.
            pendingScrollFraction = lastScrollFraction
            hasNewRender = true
        }
        shownDocument = nil
        shownGeneration = -1
        isLoaded = false
        isLoadingTemplate = true
        pageLibraries = injectedLibraries
        templateNavigation = webView.loadHTMLString(PreviewTemplate.html(allowsRemoteContent: allowsRemoteContent), baseURL: Self.pageURL)
    }

    /// Lets documents load images and media from the web. The page reloads to apply it.
    func setAllowsRemoteContent(_ value: Bool) {
        guard value != allowsRemoteContent else { return }
        allowsRemoteContent = value
        startTemplateLoad()
    }

    /// `document` and `generation` identify the render, so callers can tell whether the page
    /// shows it yet (see `shows(_:generation:)`).
    func render(html: String, baseURL: URL?, resetScroll: Bool, document: String? = nil, generation: Int = 0, lineCount: Int = 0) {
        let baseChanged = baseURL != lastBase
        lastHTML = html
        lastLineCount = lineCount
        lastBase = baseURL
        lastDocument = document
        lastGeneration = generation
        hasNewRender = true
        pendingReset = pendingReset || resetScroll || baseChanged
        guard isLoaded else {
            // A page that gave up loading, or stopped after repeated crashes, gets another try
            // with new content.
            if !isLoadingTemplate { startTemplateLoad() }
            return
        }
        flush()
    }

    /// Whether the loaded page shows `document`, and with `generation` the render it was given.
    func shows(_ document: String?, generation: Int? = nil) -> Bool {
        guard isLoaded, document != nil, shownDocument == document else { return false }
        return generation.map { $0 == shownGeneration } ?? true
    }

    private func flush() {
        let base = lastBase.flatMap { DocumentSchemeHandler.url(for: $0)?.absoluteString } ?? ""
        let reset = pendingReset
        pendingReset = false
        // A page load re-sends the last markup; scrolling meant for the next document waits for it.
        let isNewRender = hasNewRender
        hasNewRender = false
        loadLibraries(for: lastHTML)
        // An image opened from another document doesn't stay over this one.
        if isLightboxOpen, lastDocument != shownDocument { closeLightbox() }
        call("lexmdRender(html, base, reset)", ["html": lastHTML, "base": base, "reset": reset])
        shownDocument = lastDocument
        shownGeneration = lastGeneration
        var revealed = false
        if let heading = pendingHeading, isNewRender || !heading.afterRender {
            pendingHeading = nil
            revealed = true
            call("lexmdReveal(id, false)", ["id": heading.id])
        }
        if highlight != nil || highlightApplied {
            applyHighlight(scroll: Date() < highlightScrollUntil)
            highlightScrollUntil = .distantPast
        }
        if isNewRender, let fraction = pendingScrollFraction {
            pendingScrollFraction = nil
            // A heading the reader asked for wins over the position the tab remembered.
            if !revealed { call("lexmdScroll(f)", ["f": fraction]) }
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
        let document = shownDocument
        call("return lexmdFind(q, cs, word, regex, current, scroll)", args) { [weak self] result in
            self?.onHighlightCount?((result as? NSNumber)?.intValue ?? 0, document)
        }
    }

    /// Reports how far the page is scrolled, from 0 to 1, when it shows `document`.
    func readScrollFraction(of document: String, _ completion: @escaping (Double) -> Void) {
        guard shows(document) else { return }
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

    // MARK: Image viewer

    /// An image or diagram is open in the page's viewer (see PreviewTemplate+Lightbox.swift).
    private(set) var isLightboxOpen = false

    private func setLightboxOpen(_ open: Bool) {
        isLightboxOpen = open
        (webView as? PreviewWebView)?.onLightboxPinch = open ? { [weak self] magnification, point in
            self?.call("window.lexmdLightbox.pinch(m, x, y)", ["m": Double(magnification), "x": Double(point.x), "y": Double(point.y)])
        } : nil
    }

    /// Zooms the open viewer by `steps` (0 fits it to the window), as Make Text Bigger and
    /// Smaller do for the page. Returns false, doing nothing, when the viewer isn't open.
    @discardableResult
    func zoomLightbox(by steps: Int) -> Bool {
        guard isLightboxOpen else { return false }
        call("window.lexmdLightbox.zoom(s)", ["s": steps])
        return true
    }

    func closeLightbox() {
        guard isLightboxOpen else { return }
        call("window.lexmdLightbox.close()", [:])
        setLightboxOpen(false)
    }

    /// True once the page has loaded; renders requested before that have been sent to it.
    var isPageLoaded: Bool { isLoaded }

    /// Returns true once the page template has loaded (at once if it has), or false after
    /// `seconds`.
    func pageLoaded(within seconds: Double) async -> Bool {
        if isLoaded { return true }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            loadWaiters[id] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                self?.loadWaiters.removeValue(forKey: id)?.resume(returning: false)
            }
        }
    }

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
        } else if type == "lightbox", let open = body["open"] as? Bool {
            setLightboxOpen(open)
            // Keys (Escape, zoom, arrows) go to the viewer, even when the editor had focus.
            if open, let window = webView.window, window.firstResponder !== webView { window.makeFirstResponder(webView) }
        } else if type == "heading", let id = body["id"] as? String {
            onHeadingChange?(id)
        } else if type == "scroll", let fraction = body["f"] as? Double {
            lastScrollFraction = fraction
        } else if type == "layout", reportsScrolling, let layout = PageLayout(body, lineCount: lastLineCount) {
            // A report already on its way when reporting was turned off is dropped.
            pageLayout = layout
        } else if type == "scrolled", reportsScrolling, let scroll = (body["scroll"] as? NSNumber)?.doubleValue {
            pageLayout?.scroll = scroll
            if body["reader"] as? Bool == true { onReaderScroll?(body["input"] as? Bool == true) }
        } else if type == "edit", let line = (body["line"] as? NSNumber)?.intValue {
            let end = (body["end"] as? NSNumber)?.intValue ?? line
            onEditRequest?(line...max(line, end), body["word"] as? String ?? "")
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard isLoadingTemplate, templateNavigation == nil || navigation === templateNavigation else { return }
        templateNavigation = nil
        isLoadingTemplate = false
        templateRetries = 0
        isLoaded = true
        let waiters = loadWaiters.values
        loadWaiters = [:]
        waiters.forEach { $0.resume(returning: true) }
        call("lexmdZoom(s)", ["s": scale])
        applyPageOptions()
        applyScrollReporting()
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

    /// Reloads after the page's process ends. Content that keeps ending it (a huge image, for
    /// example) would reload forever, so after three crashes within a minute the page waits for
    /// the next render to try again.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let now = Date()
        recentCrashes = recentCrashes.filter { now.timeIntervalSince($0) < 60 } + [now]
        guard recentCrashes.count <= 3 else {
            Self.log.error("Preview stopped reloading after repeated crashes")
            shownDocument = nil
            isLoaded = false
            isLoadingTemplate = false
            templateNavigation = nil
            return
        }
        startTemplateLoad()
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

    /// While an image is open in the viewer, a pinch zooms it at the fingers instead of
    /// changing the text size.
    var onLightboxPinch: ((CGFloat, CGPoint) -> Void)?

    override func magnify(with event: NSEvent) {
        if let onLightboxPinch {
            let point = convert(event.locationInWindow, from: nil)
            onLightboxPinch(event.magnification, CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y))
            return
        }
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

// MARK: - Scroll sync

/// Where the page's blocks are and how far it is scrolled, as its script reports them.
private struct PageLayout {
    /// Source positions from the very top of the page (0) to its very end (`lineCount + 2`),
    /// with each block's lines at its top and bottom edges in between.
    var map: PositionMap
    var scroll: CGFloat
    var view: CGFloat
    var height: CGFloat

    /// `lineCount` is the number of lines in the rendered source.
    init?(_ message: [String: Any], lineCount: Int) {
        guard let flat = message["anchors"] as? [NSNumber], let scroll = message["scroll"] as? NSNumber,
              let view = message["view"] as? NSNumber, let height = message["height"] as? NSNumber else { return nil }
        self.scroll = CGFloat(scroll.doubleValue)
        self.view = CGFloat(view.doubleValue)
        self.height = CGFloat(height.doubleValue)
        var pairs: [(position: Double, offset: CGFloat)] = [(0, 0)]
        for index in stride(from: 0, to: flat.count - 1, by: 2) {
            pairs.append((flat[index].doubleValue, CGFloat(flat[index + 1].doubleValue)))
        }
        pairs.append((Double(lineCount + 2), self.height))
        map = PositionMap(pairs)
    }
}

extension PreviewController: ScrollSyncPane {
    var syncMetrics: ScrollMetrics? {
        pageLayout.map { ScrollMetrics(scroll: $0.scroll, view: $0.view, max: max(0, $0.height - $0.view)) }
    }

    func sourcePosition(at offset: CGFloat) -> Double? {
        pageLayout?.map.position(at: offset)
    }

    func offset(ofSourcePosition position: Double) -> CGFloat? {
        pageLayout?.map.offset(of: position)
    }

    func followScroll(to scroll: CGFloat) {
        guard isLoaded, let current = pageLayout?.scroll, abs(scroll - current) >= 0.5 else { return }
        pageLayout?.scroll = scroll
        // The editor reports every frame of a scroll. Calls the page hasn't run yet would queue up
        // and make it trail behind, so only the latest scroll waits for the one in flight.
        if isScrollInFlight { pendingScroll = scroll } else { send(scroll) }
    }

    private func send(_ scroll: CGFloat) {
        isScrollInFlight = true
        webView.callAsyncJavaScript("lexmdScrollTo(y)", arguments: ["y": Double(scroll)], in: nil, in: Self.world) { [weak self] _ in
            guard let self else { return }
            self.isScrollInFlight = false
            guard let pending = self.pendingScroll else { return }
            self.pendingScroll = nil
            self.send(pending)
        }
    }

    func setReportsScrolling(_ reports: Bool) {
        reportsScrolling = reports
        if !reports { pageLayout = nil }
        applyScrollReporting()
    }

    /// Tells the page whether to report its layout and scrolls; a page that has just loaded
    /// reports nothing until told.
    private func applyScrollReporting() {
        guard isLoaded else { return }
        call("lexmdSync(on)", ["on": reportsScrolling])
    }
}
