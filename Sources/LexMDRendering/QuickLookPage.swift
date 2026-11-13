import Foundation
import UniformTypeIdentifiers

/// A standalone page for the Quick Look extension: the document rendered as in the app, with the
/// preview's styles and no scripts. Diagrams and math stay readable source. Local images become
/// attachments referenced as `cid:` URLs; remote images are never loaded.
package struct QuickLookPage {
    /// A local image the page shows as `cid:<identifier>`.
    package struct Image: Equatable {
        package var identifier: String
        package var fileURL: URL
        package var data: Data
        package var contentType: UTType
    }

    package var html: String
    package var images: [Image]
    /// Whether only the start of the file is shown.
    package var isTruncated: Bool

    /// Larger files show their first part.
    package static let maxInputBytes = 5 << 20
    /// Images are attached until their total size would pass this.
    package static let maxImageBytes = 20 << 20

    package static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "svg", "webp", "avif", "heic", "heif", "bmp", "tif", "tiff", "ico",
    ]

    /// Reads a local image if it is a regular file no larger than `limit` bytes.
    package typealias ImageLoader = (_ url: URL, _ limit: Int) -> Data?

    package static func make(contentsOf fileURL: URL, loadImage: ImageLoader = QuickLookPage.readImage) throws -> QuickLookPage {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxInputBytes + 1) ?? Data()
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? data.count
        return make(data: data, fileSize: size, fileURL: fileURL, loadImage: loadImage)
    }

    /// Builds the page for a file's contents. `fileSize` is the whole file's size, for the note
    /// shown when `data` is cut at `maxInputBytes`.
    package static func make(data: Data, fileSize: Int? = nil, fileURL: URL, loadImage: ImageLoader = QuickLookPage.readImage) -> QuickLookPage {
        let truncated = data.count > maxInputBytes
        var bytes = truncated ? data.prefix(maxInputBytes) : data
        if truncated, let newline = bytes.lastIndex(of: 0x0A) { bytes = bytes[..<newline] }
        let text = String(decoding: bytes, as: UTF8.self)

        var body = MarkdownHTML.render(text)
        var images: [Image] = []
        body = rewriteImages(in: body, folder: fileURL.deletingLastPathComponent(), images: &images, loadImage: loadImage)

        var note = ""
        if truncated {
            let total = ByteCountFormatter.string(fromByteCount: Int64(max(fileSize ?? data.count, data.count)), countStyle: .file)
            let shown = ByteCountFormatter.string(fromByteCount: Int64(maxInputBytes), countStyle: .file)
            note = "<p class=\"lexmd-ql-note\">This file is \(total). Quick Look shows the first \(shown); open it in LexMD to read the rest.</p>\n"
        }
        let html = StandalonePage.html(
            title: fileURL.lastPathComponent, policy: contentSecurityPolicy,
            styles: [PreviewStyle.page, PreviewStyle.rendering, PreviewStyle.standalone, style], body: note + body
        )
        return QuickLookPage(html: html, images: images, isTruncated: truncated)
    }

    /// No scripts, no network, and images only from attachments or inline data.
    package static let contentSecurityPolicy = "default-src 'none'; style-src 'unsafe-inline'; img-src cid: data:; font-src data:; form-action 'none'"

    /// Quick Look's own spacing and notes, on top of `PreviewStyle.standalone`.
    static let style = """
    #content { padding: 2.2rem 2.4rem 3rem; }
    .lexmd-ql-note { font-size: 0.86rem; color: var(--secondary); padding: 0.6em 0.9em; border-radius: 10px; background: var(--fill-strong); }
    .lexmd-image-omitted {
      display: inline-block;
      padding: 0.1em 0.55em;
      border: 1px dashed var(--hair-strong);
      border-radius: 6px;
      color: var(--secondary);
      font-size: 0.86em;
    }
    """

    // MARK: Images

    private static let imageTag = try! NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive])

    /// Points each `<img>` at an attachment or inline data, or replaces it with its description.
    static func rewriteImages(in html: String, folder: URL, images: inout [Image], loadImage: ImageLoader) -> String {
        let ns = html as NSString
        let matches = imageTag.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return html }
        var byPath: [String: String] = [:]
        var budget = maxImageBytes
        var out = ""
        var last = 0
        for match in matches {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            last = NSMaxRange(match.range)
            let tag = ns.substring(with: match.range)
            guard let src = attribute("src", in: tag) else {
                out += tag
                continue
            }
            var replacement: String?
            switch ImageSource(src.value, folder: folder) {
            case .inline:
                replacement = src.value
            case .local(let url):
                let key = url.path
                if let identifier = byPath[key] {
                    replacement = "cid:" + identifier
                } else if budget > 0, let data = loadImage(url, budget), data.count <= budget {
                    let identifier = "image-\(images.count + 1)"
                    let type = UTType(filenameExtension: url.pathExtension) ?? .image
                    images.append(Image(identifier: identifier, fileURL: url, data: data, contentType: type))
                    byPath[key] = identifier
                    budget -= data.count
                    replacement = "cid:" + identifier
                }
            case .remote, .unsupported:
                break
            }
            if let replacement {
                var rewritten = tag as NSString
                rewritten = rewritten.replacingCharacters(in: src.range, with: "src=\"\(MarkdownHTML.escape(replacement))\"") as NSString
                out += removingAttribute("srcset", from: rewritten as String)
            } else {
                out += omitted(tag: tag, source: src.value)
            }
        }
        out += ns.substring(from: last)
        return out
    }

    /// Text in place of an image that is not shown.
    private static func omitted(tag: String, source: String) -> String {
        var label = attribute("alt", in: tag)?.value.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if label.isEmpty {
            let name = (source.split(separator: "?").first.map(String.init) ?? source) as NSString
            label = (name.lastPathComponent.removingPercentEncoding ?? name.lastPathComponent)
        }
        if label.isEmpty { label = "Image" }
        return "<span class=\"lexmd-image-omitted\">\(MarkdownHTML.escape(label))</span>"
    }

    /// Where an image source points.
    enum ImageSource: Equatable {
        case inline
        case local(URL)
        case remote
        case unsupported

        init(_ raw: String, folder: URL) {
            let source = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = source.lowercased()
            if lower.hasPrefix("data:image/") { self = .inline; return }
            if source.isEmpty { self = .unsupported; return }
            if source.hasPrefix("//") { self = .remote; return }
            if let colon = source.firstIndex(of: ":"),
               source[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || "+.-".contains($0) }),
               source[..<colon].first?.isLetter == true {
                let scheme = source[..<colon].lowercased()
                if scheme == "file", let url = URL(string: source), url.isFileURL {
                    self = Self.file(url.standardizedFileURL)
                } else {
                    self = scheme == "data" ? .unsupported : .remote
                }
                return
            }
            var path = source
            if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<cut]) }
            path = path.removingPercentEncoding ?? path
            guard !path.isEmpty else { self = .unsupported; return }
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
            self = Self.file(url.standardizedFileURL)
        }

        private static func file(_ url: URL) -> ImageSource {
            QuickLookPage.imageExtensions.contains(url.pathExtension.lowercased()) ? .local(url) : .unsupported
        }
    }

    /// The default image loader: a regular file within the size limit. Symlinks are followed,
    /// as in the app's preview.
    package static func readImage(_ url: URL, limit: Int) -> Data? {
        let url = url.resolvingSymlinksInPath()
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= limit else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    // MARK: Attributes

    /// An attribute's decoded value and the range of the whole `name=value` in `tag`.
    static func attribute(_ name: String, in tag: String) -> (value: String, range: NSRange)? {
        let pattern = #"\s"# + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
        let ns = tag as NSString
        for group in 1...3 where match.range(at: group).location != NSNotFound {
            let whole = NSRange(location: match.range.location + 1, length: match.range.length - 1)
            return (unescape(ns.substring(with: match.range(at: group))), whole)
        }
        return nil
    }

    private static func removingAttribute(_ name: String, from tag: String) -> String {
        guard let found = attribute(name, in: tag) else { return tag }
        let ns = tag as NSString
        // Drop the whitespace before the attribute too.
        let range = NSRange(location: found.range.location - 1, length: found.range.length + 1)
        return removingAttribute(name, from: ns.replacingCharacters(in: range, with: ""))
    }

    /// Decodes the character references `MarkdownHTML.escape` and common raw HTML use.
    static func unescape(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = text
        for (entity, value) in [("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            out = out.replacingOccurrences(of: entity, with: value)
        }
        return out
    }
}
