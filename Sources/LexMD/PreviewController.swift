import AppKit
import WebKit

@MainActor
final class PreviewController: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var onOpenURL: ((URL) -> Void)?
    var onHighlightCount: ((Int) -> Void)?
    /// The id of the heading in view as the preview scrolls (empty above the first heading).
    var onHeadingChange: ((String) -> Void)?

    struct Highlight: Equatable {
        var query: String
        var options: SearchOptions
        var current: Int
    }

    /// LexMD's preview script runs here, apart from the page world that holds document markup.
    private static let world = WKContentWorld.world(name: "LexMD")
    private static let pageURL = URL(string: "\(DocumentSchemeHandler.scheme):///")!

    private var highlight: Highlight?
    private var highlightApplied = false
    private var highlightScrollUntil = Date.distantPast

    private var isLoaded = false
    private var isLoadingTemplate = false
    private var lastHTML = ""
    private var lastBase: URL?
    private var pendingReset = false
    private var pendingHeading: String?
    private var scale: Double = 1
    private(set) var allowsRemoteContent: Bool

    init(allowsRemoteContent: Bool) {
        self.allowsRemoteContent = allowsRemoteContent
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(DocumentSchemeHandler(), forURLScheme: DocumentSchemeHandler.scheme)
        // Scripts in documents never run; LexMD's own script below is unaffected.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let content = WKUserContentController()
        content.addUserScript(WKUserScript(
            source: PreviewTemplate.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world
        ))
        configuration.userContentController = content
        webView = WKWebView(frame: .zero, configuration: configuration)

        super.init()
        // The content controller keeps its handlers alive, so it gets a proxy that holds this controller weakly.
        content.add(ScriptMessageProxy(self), contentWorld: Self.world, name: "lexmd")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        loadTemplate()
    }

    private func loadTemplate() {
        isLoaded = false
        isLoadingTemplate = true
        webView.loadHTMLString(PreviewTemplate.html(allowsRemoteContent: allowsRemoteContent), baseURL: Self.pageURL)
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
        pendingReset = pendingReset || resetScroll || baseChanged
        guard isLoaded else { return }
        flush()
    }

    private func flush() {
        let base = lastBase.flatMap { DocumentSchemeHandler.url(for: $0)?.absoluteString } ?? ""
        let reset = pendingReset
        pendingReset = false
        call("lexmdRender(html, base, reset)", ["html": lastHTML, "base": base, "reset": reset])
        if let id = pendingHeading {
            pendingHeading = nil
            call("lexmdReveal(id, false)", ["id": id])
        }
        if highlight != nil || highlightApplied {
            applyHighlight(scroll: Date() < highlightScrollUntil)
            highlightScrollUntil = .distantPast
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

    /// Scrolls a heading to the top, now or (`afterRender`) once the next document has rendered.
    func revealHeading(_ id: String, smooth: Bool, afterRender: Bool = false) {
        guard !afterRender, isLoaded else { pendingHeading = id; return }
        call("lexmdReveal(id, smooth)", ["id": id, "smooth": smooth])
    }

    func setScale(_ value: Double) {
        scale = value
        guard isLoaded else { return }
        call("lexmdZoom(s)", ["s": value])
    }

    /// Runs a call into the preview script in LexMD's content world.
    private func call(_ body: String, _ arguments: [String: Any], completion: ((Any?) -> Void)? = nil) {
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: Self.world) { result in
            if let completion, case .success(let value) = result { completion(value) }
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
        isLoaded = true
        call("lexmdZoom(s)", ["s": scale])
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

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        let frame = navigationAction.targetFrame
        if isLoadingTemplate, frame?.isMainFrame == true, url == Self.pageURL {
            isLoadingTemplate = false
            return .allow
        }
        if navigationAction.navigationType == .linkActivated {
            // A click on a link, including one that asks for a new window.
            if frame?.isMainFrame != false { onOpenURL?(Self.keepingFragment(of: url, DocumentSchemeHandler.fileURL(for: url)) ?? url) }
        } else if frame?.isMainFrame == true, url.isFileURL, FileScanner.isMarkdown(path: url.path) {
            // A Markdown file dropped onto the preview. Nothing else may navigate without a click.
            onOpenURL?(url)
        }
        return .cancel
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
