import AppKit
import UniformTypeIdentifiers
import WebKit

/// A document snapshot to export, print, or copy.
struct ExportDocument {
    var markdown: String
    /// The folder relative links and images resolve against.
    var baseURL: URL?
    var title: String
    var allowsRemoteContent = false
    /// Resolves wiki links to the documents they name; without it they stay text.
    var links: LinkContext?
}

enum ExportError: LocalizedError {
    case renderTimedOut
    case renderFailed
    case printFailed

    var errorDescription: String? {
        switch self {
        case .renderTimedOut: "The document took too long to render."
        case .renderFailed: "The document couldn’t be rendered."
        case .printFailed: "The PDF couldn’t be created."
        }
    }
}

/// Renders a document in a window that is never shown, using the live preview's configuration:
/// the same Content-Security-Policy, disabled document JavaScript, document scheme handler, and
/// isolated script world. Exports therefore work in any view mode and leave the visible preview alone.
@MainActor
final class OffscreenRenderer {
    let preview: PreviewController
    let window: NSWindow

    init(allowsRemoteContent: Bool, size: NSSize = NSSize(width: 612, height: 792)) {
        preview = PreviewController(allowsRemoteContent: allowsRemoteContent)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Exports and printouts always use the light appearance.
        window.appearance = NSAppearance(named: .aqua)
        preview.webView.appearance = NSAppearance(named: .aqua)
        preview.webView.frame = NSRect(origin: .zero, size: size)
        window.contentView = preview.webView
    }

    var webView: WKWebView { preview.webView }

    /// Renders Markdown and waits until LexMD's script, images (for print), and fonts have settled.
    func load(_ document: ExportDocument, forPrint: Bool, timeout: Double = 20) async throws {
        let markdown = document.markdown
        let links = document.links
        let html = await runDetached { MarkdownHTML.render(markdown, links: links) }
        preview.render(html: html, baseURL: document.baseURL, resetScroll: true)
        let deadline = Date().addingTimeInterval(timeout)
        while !preview.isPageLoaded {
            guard Date() < deadline else { throw ExportError.renderTimedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
        let limit = max(1000, Int(deadline.timeIntervalSinceNow * 1000))
        _ = try await preview.evaluate(ExportScripts.settle, ["eager": forPrint, "limit": limit])
    }
}

/// Export as PDF and HTML, printing, and rich text copy.
@MainActor
enum Exporter {
    // MARK: PDF and printing

    /// The user's paper size and orientation with document margins of three quarters of an inch.
    static func printInfo() -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.topMargin = 54
        info.bottomMargin = 54
        info.leftMargin = 54
        info.rightMargin = 54
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] = false
        return info
    }

    private static func renderer(for document: ExportDocument, info: NSPrintInfo) -> OffscreenRenderer {
        let width = max(200, info.paperSize.width - info.leftMargin - info.rightMargin)
        let height = max(200, info.paperSize.height - info.topMargin - info.bottomMargin)
        return OffscreenRenderer(allowsRemoteContent: document.allowsRemoteContent, size: NSSize(width: width, height: height))
    }

    private static func printOperation(_ renderer: OffscreenRenderer, info: NSPrintInfo, title: String) -> NSPrintOperation {
        let operation = renderer.webView.printOperation(with: info)
        operation.view?.frame = renderer.webView.bounds
        operation.jobTitle = title
        return operation
    }

    /// Writes a paginated PDF of the rendered document. The file is written to a temporary
    /// location first, then moved into place, so a failed export never leaves a partial file.
    static func exportPDF(_ document: ExportDocument, to destination: URL) async throws {
        let info = printInfo()
        let renderer = renderer(for: document, info: info)
        try await renderer.load(document, forPrint: true)

        let folder = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        let temporary = folder.appendingPathComponent("export.pdf")
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = temporary

        let operation = printOperation(renderer, info: info, title: document.title)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        let success = await run(operation, for: renderer.window)
        guard success, FileManager.default.fileExists(atPath: temporary.path) else { throw ExportError.printFailed }
        try place(temporary, at: destination)
    }

    /// Shows the standard print panel for the rendered document.
    static func print(_ document: ExportDocument, window: NSWindow?) async throws {
        let info = printInfo()
        let renderer = renderer(for: document, info: info)
        try await renderer.load(document, forPrint: true)
        let operation = printOperation(renderer, info: info, title: document.title)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.printPanel.options.formUnion([.showsCopies, .showsPageRange, .showsPaperSize, .showsOrientation, .showsScaling, .showsPreview])
        // Cancelling the panel is not an error; the print system reports its own failures.
        _ = await run(operation, for: window ?? renderer.window)
    }

    private static func run(_ operation: NSPrintOperation, for window: NSWindow) async -> Bool {
        await withCheckedContinuation { continuation in
            let delegate = PrintCompletion { continuation.resume(returning: $0) }
            operation.runModal(
                for: window, delegate: delegate,
                didRun: #selector(PrintCompletion.printOperationDidRun(_:success:contextInfo:)), contextInfo: nil
            )
        }
    }

    /// Moves a finished file over the destination, replacing any file the user chose to overwrite.
    private static func place(_ file: URL, at destination: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: file)
        } else {
            try manager.moveItem(at: file, to: destination)
        }
    }

    // MARK: HTML

    struct ImageLimits {
        var perImage = 10 << 20
        var total = 50 << 20
    }

    struct HTMLExport {
        var html: String
        /// Local images that were linked rather than embedded, by file name.
        var linkedImages: [String]
    }

    /// Writes a standalone HTML file: the rendered body with the preview's CSS inlined, no scripts,
    /// a restrictive policy, and local images embedded as data URIs within the size limits.
    @discardableResult
    static func exportHTML(_ document: ExportDocument, to destination: URL, limits: ImageLimits = ImageLimits()) async throws -> HTMLExport {
        let renderer = OffscreenRenderer(allowsRemoteContent: document.allowsRemoteContent)
        try await renderer.load(document, forPrint: false)
        let export = try await standaloneHTML(from: renderer.preview, title: document.title, folder: destination.deletingLastPathComponent(), limits: limits)
        let data = Data(export.html.utf8)
        try await runDetached { () -> Result<Void, Error> in
            Result { try data.write(to: destination, options: .atomic) }
        }.get()
        return export
    }

    static func standaloneHTML(from preview: PreviewController, title: String, folder: URL, limits: ImageLimits = ImageLimits()) async throws -> HTMLExport {
        let nonce = "lexmd-res-\(UUID().uuidString)-"
        guard let result = try await preview.evaluate(ExportScripts.common + ExportScripts.exportHTML, ["nonce": nonce]) as? [String: Any],
              let body = result["html"] as? String else { throw ExportError.renderFailed }
        let css = result["css"] as? String ?? ""
        let resources = (result["resources"] as? [[String: Any]] ?? []).map {
            Resource(url: $0["url"] as? String ?? "", isImage: $0["image"] as? Bool ?? false)
        }
        let (replacements, linked) = await runDetached { resolve(resources, folder: folder, limits: limits) }
        let katex = result["katex"] as? String ?? ""
        let families = Set(result["fonts"] as? [String] ?? [])
        let math = katex.isEmpty ? "" : await runDetached { embedKaTeXFonts(katex, families: families) }
        var html = body
        for (index, value) in replacements.enumerated() {
            html = html.replacingOccurrences(of: "\(nonce)\(index);", with: MarkdownHTML.escape(value))
        }
        let style = withoutAppURLs([css, math, exportCSS].joined(separator: "\n")).replacingOccurrences(of: "</", with: "<\\/")
        let page = """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(htmlPolicy)">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <meta name="generator" content="LexMD">
        <title>\(MarkdownHTML.escape(title))</title>
        <style>
        \(style)
        </style>
        </head>
        <body>
        <article id="content">
        \(html)
        </article>
        </body>
        </html>

        """
        return HTMLExport(html: page, linkedImages: linked)
    }

    static let htmlPolicy = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; "
        + "img-src 'self' data: file: https: http:; media-src 'self' data: file: https: http:; font-src data:; "
        + "base-uri 'none'; form-action 'none'; frame-src 'none'; object-src 'none'"

    /// Page background and small adjustments for a page without LexMD's script.
    private static let exportCSS = """
    html { background: #fff; }
    @media (prefers-color-scheme: dark) { html { background: #1e1e1e; } }
    @media print { html { background: #fff; } }
    #content { padding-bottom: 4rem; }
    .codeblock:hover .lang { opacity: 1; }
    """

    /// KaTeX's stylesheet with the font faces of `families` embedded as WOFF2 data URIs and
    /// every other font face removed.
    nonisolated static func embedKaTeXFonts(_ css: String, families: Set<String>) -> String {
        guard let fontFace = try? NSRegularExpression(pattern: #"@font-face\s*\{[^}]*\}"#) else { return css }
        var output = ""
        var last = css.startIndex
        for match in fontFace.matches(in: css, range: NSRange(css.startIndex..., in: css)) {
            guard let range = Range(match.range, in: css) else { continue }
            output += css[last..<range.lowerBound]
            last = range.upperBound
            let rule = String(css[range])
            guard let family = capture(#"font-family:\s*["']?([^;"'}]+)"#, in: rule),
                  families.contains(family.trimmingCharacters(in: .whitespaces)),
                  let path = capture(#"url\(\s*["']?lexmd-vendor:///([^)"'\s]+\.woff2)"#, in: rule),
                  let file = VendorAssets.file(at: path), let data = try? Data(contentsOf: file),
                  let source = rule.range(of: #"src:[^;}]*"#, options: .regularExpression) else { continue }
            output += rule.replacingCharacters(
                in: source, with: "src:url(data:font/woff2;base64,\(data.base64EncodedString())) format(\"woff2\")"
            )
        }
        output += css[last...]
        return output
    }

    private nonisolated static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// Replaces any remaining reference to LexMD's own URL schemes, which only work inside the app.
    nonisolated static func withoutAppURLs(_ css: String) -> String {
        css.replacingOccurrences(of: #"url\(\s*["']?lexmd-(vendor|doc):[^)]*\)"#, with: "url(data:,)", options: .regularExpression)
    }

    struct Resource: Sendable {
        var url: String
        var isImage: Bool
    }

    /// Maps each local reference to a data URI (images within the limits) or a path relative to `folder`.
    nonisolated static func resolve(_ resources: [Resource], folder: URL, limits: ImageLimits) -> ([String], [String]) {
        var total = 0
        var linked: [String] = []
        var cache: [String: String] = [:]
        let replacements = resources.map { resource -> String in
            guard let url = URL(string: resource.url), url.scheme == "lexmd-doc", !url.path.isEmpty else { return resource.url }
            let file = URL(fileURLWithPath: url.path)
            let fragment = url.fragment.map { "#\($0)" } ?? ""
            let relative = relativePath(from: folder, to: file) + fragment
            guard resource.isImage else { return relative }
            if let cached = cache[file.path] { return cached }
            let values = try? file.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, let type = values?.contentType, type.conforms(to: .image) else { return relative }
            let size = values?.fileSize ?? 0
            guard size <= limits.perImage, total + size <= limits.total, let data = try? Data(contentsOf: file) else {
                if !linked.contains(file.lastPathComponent) { linked.append(file.lastPathComponent) }
                cache[file.path] = relative
                return relative
            }
            total += data.count
            let uri = "data:\(type.preferredMIMEType ?? "application/octet-stream");base64,\(data.base64EncodedString())"
            cache[file.path] = uri
            return uri
        }
        return (replacements, linked)
    }

    /// A percent-encoded relative URL path from a folder to a file.
    nonisolated static func relativePath(from folder: URL, to file: URL) -> String {
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let target = file.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        var common = 0
        while common < base.count, common < target.count, base[common] == target[common] { common += 1 }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/;")
        let parts = Array(repeating: "..", count: base.count - common)
            + target[common...].map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }
        let path = parts.joined(separator: "/")
        // A colon in the first segment would read as a URL scheme.
        return parts.first?.contains(":") == true ? "./" + path : path
    }

    // MARK: Rich text

    struct RichText {
        /// Styled HTML, kept with images and diagrams.
        var html: String
        /// The same content prepared for RTF, without images or remote references.
        var rtfHTML: String
        var text: String
    }

    /// Captures the preview's selection, or the whole document when there is none (or `selection` is false).
    static func richText(from preview: PreviewController, selection: Bool) async throws -> RichText {
        guard let result = try await preview.evaluate(ExportScripts.common + ExportScripts.copy, ["useSelection": selection]) as? [String: Any],
              let html = result["html"] as? String, let rtf = result["rtf"] as? String else { throw ExportError.renderFailed }
        return RichText(html: wrap(html), rtfHTML: wrap(rtf), text: result["text"] as? String ?? "")
    }

    /// Renders Markdown offscreen and captures it as rich text.
    static func richText(_ document: ExportDocument) async throws -> RichText {
        let renderer = OffscreenRenderer(allowsRemoteContent: document.allowsRemoteContent)
        try await renderer.load(document, forPrint: false)
        return try await richText(from: renderer.preview, selection: false)
    }

    private static func wrap(_ body: String) -> String {
        """
        <html><head><meta charset="utf-8"></head>\
        <body style="font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; font-size: 12pt; color: #1d1d1f;">\
        \(body)</body></html>
        """
    }

    /// Puts HTML, RTF, and plain text on the pasteboard as one item.
    static func write(_ rich: RichText, to pasteboard: NSPasteboard) {
        let item = NSPasteboardItem()
        item.setString(rich.html, forType: .html)
        if let rtf = rtfData(fromHTML: rich.rtfHTML) { item.setData(rtf, forType: .rtf) }
        item.setString(rich.text, forType: .string)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    /// Converts HTML without external references to RTF.
    static func rtfData(fromHTML html: String) -> Data? {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let string = try? NSMutableAttributedString(data: Data(html.utf8), options: options, documentAttributes: nil) else { return nil }
        // The HTML importer ends block elements with a newline; drop the trailing one.
        while string.string.hasSuffix("\n") { string.deleteCharacters(in: NSRange(location: string.length - 1, length: 1)) }
        return try? string.data(
            from: NSRange(location: 0, length: string.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }
}

/// Receives the print operation's completion and resumes the waiting task.
private final class PrintCompletion: NSObject {
    private let completion: (Bool) -> Void
    private var keepAlive: PrintCompletion?

    init(_ completion: @escaping (Bool) -> Void) {
        self.completion = completion
        super.init()
        keepAlive = self
    }

    @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        completion(success)
        keepAlive = nil
    }
}

/// A short note shown over the bottom of a window that fades away by itself.
@MainActor
enum ExportNote {
    private static var panel: NSPanel?

    static func show(_ message: String, in window: NSWindow?) {
        NSAccessibility.post(
            element: window ?? NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
        guard let window else { return }
        panel?.parent?.removeChildWindow(panel!)
        panel?.orderOut(nil)

        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1)
        label.preferredMaxLayoutWidth = 380
        let size = label.fittingSize
        let padding = NSSize(width: 16, height: 11)
        let frame = NSRect(x: 0, y: 0, width: size.width + padding.width * 2, height: size.height + padding.height * 2)

        let effect = NSVisualEffectView(frame: frame)
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        label.frame = NSRect(origin: NSPoint(x: padding.width, y: padding.height), size: size)
        effect.addSubview(label)
        effect.addGestureRecognizer(NSClickGestureRecognizer(target: NoteDismisser.shared, action: #selector(NoteDismisser.dismiss)))

        let note = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        note.isReleasedWhenClosed = false
        note.isOpaque = false
        note.backgroundColor = .clear
        note.hasShadow = true
        note.contentView = effect
        let parent = window.frame
        note.setFrameOrigin(NSPoint(x: parent.midX - frame.width / 2, y: parent.minY + 28))
        window.addChildWindow(note, ordered: .above)
        panel = note

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            if panel === note { dismiss() }
        }
    }

    static func dismiss() {
        guard let note = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; note.animator().alphaValue = 0 }, completionHandler: {
            MainActor.assumeIsolated {
                note.parent?.removeChildWindow(note)
                note.orderOut(nil)
            }
        })
    }
}

@MainActor
private final class NoteDismisser: NSObject {
    static let shared = NoteDismisser()
    @objc func dismiss() { ExportNote.dismiss() }
}
