import AppKit
import WebKit

@MainActor
final class PreviewController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: WKWebView
    var onOpenURL: ((URL) -> Void)?
    var onHighlightCount: ((Int) -> Void)?

    struct Highlight: Equatable {
        var query: String
        var options: SearchOptions
        var current: Int
    }

    private var highlight: Highlight?
    private var highlightApplied = false
    private var highlightScrollUntil = Date.distantPast

    private var isLoaded = false
    private var lastHTML = ""
    private var lastBase: URL?
    private var pendingReset = false
    private var scale: Double = 1
    private let templateURL: URL

    override init() {
        let configuration = WKWebViewConfiguration()
        let content = WKUserContentController()
        configuration.userContentController = content
        configuration.suppressesIncrementalRendering = false
        webView = WKWebView(frame: .zero, configuration: configuration)

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "LexMD", isDirectory: true)
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        templateURL = caches.appendingPathComponent("preview.html")
        try? PreviewTemplate.html.write(to: templateURL, atomically: true, encoding: .utf8)

        super.init()
        content.add(self, name: "lexmd")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        loadTemplate()
    }

    private func loadTemplate() {
        isLoaded = false
        webView.loadFileURL(templateURL, allowingReadAccessTo: URL(fileURLWithPath: "/"))
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
        let b64 = Data(lastHTML.utf8).base64EncodedString()
        var base = lastBase?.absoluteString ?? ""
        if !base.isEmpty, !base.hasSuffix("/") { base += "/" }
        let args: [Any] = [b64, base, pendingReset]
        pendingReset = false
        guard let data = try? JSONSerialization.data(withJSONObject: args),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("lexmdRender.apply(null, \(json))", completionHandler: nil)
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
        let args: [Any] = [
            h?.query ?? "", h?.options.caseSensitive ?? false, h?.options.wholeWord ?? false,
            h?.options.regex ?? false, h?.current ?? -1, scroll,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: args),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("lexmdFind.apply(null, \(json))") { [weak self] result, _ in
            let count = (result as? NSNumber)?.intValue ?? 0
            MainActor.assumeIsolated { self?.onHighlightCount?(count) }
        }
    }

    func scroll(to fraction: CGFloat) {
        guard isLoaded else { return }
        webView.evaluateJavaScript("lexmdScroll(\(Double(fraction)))", completionHandler: nil)
    }

    func setScale(_ value: Double) {
        scale = value
        guard isLoaded else { return }
        webView.evaluateJavaScript("lexmdZoom(\(value))", completionHandler: nil)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        webView.evaluateJavaScript("lexmdZoom(\(scale))", completionHandler: nil)
        pendingReset = true
        flush()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadTemplate()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if navigationAction.targetFrame?.isMainFrame == false { return .allow }
        if url.isFileURL, url.standardizedFileURL.path == templateURL.standardizedFileURL.path,
           navigationAction.navigationType != .linkActivated {
            return .allow
        }
        // Link clicks, new-window links, and files dropped onto the preview.
        if navigationAction.navigationType == .linkActivated || navigationAction.targetFrame == nil || url.isFileURL {
            onOpenURL?(url)
        }
        return .cancel
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "copy", let text = body["text"] as? String {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}
