import Foundation
import WebKit

/// Serves bundled vendor stylesheets and fonts (`lexmd-vendor:///katex/fonts/…`) to the preview.
/// It is read-only, answers only GET requests for a few file types, and never leaves the
/// vendor folder. Scripts are not served; LexMD injects them into its own content world.
@MainActor
final class VendorSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "lexmd-vendor"

    private nonisolated static let types = ["css": "text/css", "woff2": "font/woff2", "woff": "font/woff", "ttf": "font/ttf"]

    /// The vendor file a `lexmd-vendor` URL names, or nil if it is not a servable file.
    nonisolated static func file(for url: URL, in root: URL? = VendorAssets.directory) -> URL? {
        guard url.scheme == scheme, url.host(percentEncoded: false)?.isEmpty ?? true,
              url.query == nil, url.fragment == nil else { return nil }
        let path = url.path(percentEncoded: false)
        guard path.hasPrefix("/"), types[(path as NSString).pathExtension.lowercased()] != nil else { return nil }
        return VendorAssets.file(at: String(path.dropFirst()), in: root)
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, (task.request.httpMethod ?? "GET") == "GET",
              let file = Self.file(for: url), let data = try? Data(contentsOf: file) else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        let headers = [
            "Content-Type": Self.types[file.pathExtension.lowercased()] ?? "application/octet-stream",
            "Content-Length": "\(data.count)",
            // Fonts load across schemes, so the page origin needs CORS permission.
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "max-age=86400",
        ]
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else {
            return task.didFailWithError(URLError(.cannotParseResponse))
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        // Responses are delivered synchronously in `start`, so there is nothing to cancel.
    }
}
