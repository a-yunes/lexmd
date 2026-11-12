import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves files a document references (`lexmd-doc:///absolute/path`) to the preview.
/// The web content process gets no file access of its own, and only images, audio, video,
/// and fonts are served, so markup can display local media but never read other files.
@MainActor
final class DocumentSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "lexmd-doc"

    /// Open-ended byte ranges are answered in chunks of at most this size.
    private nonisolated static let maxChunk: UInt64 = 8 << 20

    /// The `lexmd-doc` URL for a local file or folder.
    static func url(for fileURL: URL) -> URL? {
        var path = fileURL.path
        if fileURL.hasDirectoryPath, !path.hasSuffix("/") { path += "/" }
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "\(scheme)://\(encoded)")
    }

    /// The local file a `lexmd-doc` URL points to.
    static func fileURL(for url: URL) -> URL? {
        guard url.scheme == scheme, !url.path.isEmpty else { return nil }
        return URL(fileURLWithPath: url.path)
    }

    /// Requests still being read. A stopped request is removed and never answered.
    private var running: Set<ObjectIdentifier> = []

    /// Files are read off the main thread: images can be large, and a file kept only in iCloud
    /// is downloaded on first read.
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let file = Self.fileURL(for: url) else {
            return task.didFailWithError(URLError(.badURL))
        }
        let range = task.request.value(forHTTPHeaderField: "Range")
        let id = ObjectIdentifier(task)
        running.insert(id)
        Task { @MainActor in
            let result = await runDetached { Self.read(file, range: range) }
            // The task is kept alive until here, so its identifier cannot be reused meanwhile.
            guard running.remove(id) != nil else { return }
            switch result {
            case .success(let payload):
                guard let response = HTTPURLResponse(url: url, statusCode: payload.status, httpVersion: "HTTP/1.1", headerFields: payload.headers) else {
                    return task.didFailWithError(URLError(.cannotParseResponse))
                }
                task.didReceive(response)
                task.didReceive(payload.data)
                task.didFinish()
            case .failure(let error):
                task.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        running.remove(ObjectIdentifier(task))
    }

    struct Payload: Sendable {
        var status: Int
        var headers: [String: String]
        var data: Data
    }

    /// Reads a servable file, or the part a `Range` header asks for.
    nonisolated static func read(_ file: URL, range rangeHeader: String?) -> Result<Payload, any Error> {
        let path = FileScanner.canonicalPath(file.path)
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, let type = values?.contentType,
              [.image, .audiovisualContent, .font].contains(where: { type.conforms(to: $0) }),
              let handle = FileHandle(forReadingAtPath: path) else {
            return .failure(URLError(.fileDoesNotExist))
        }
        defer { try? handle.close() }

        let size = UInt64(values?.fileSize ?? 0)
        var start: UInt64 = 0
        var end = size == 0 ? 0 : size - 1
        let range = rangeHeader.flatMap { byteRange($0, size: size) }
        if let range { (start, end) = range }
        let data: Data
        do {
            try handle.seek(toOffset: start)
            data = size == 0 ? Data() : try handle.read(upToCount: Int(end - start + 1)) ?? Data()
        } catch {
            return .failure(error)
        }
        var headers = [
            "Content-Type": type.preferredMIMEType ?? "application/octet-stream",
            "Content-Length": "\(data.count)",
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-store",
        ]
        if range != nil {
            headers["Content-Range"] = "bytes \(start)-\(start + UInt64(max(data.count, 1)) - 1)/\(size)"
        }
        return .success(Payload(status: range == nil ? 200 : 206, headers: headers, data: data))
    }

    /// Parses a single `bytes=` range into inclusive offsets clamped to the file.
    nonisolated static func byteRange(_ header: String, size: UInt64) -> (UInt64, UInt64)? {
        guard size > 0, header.hasPrefix("bytes="), !header.contains(",") else { return nil }
        let parts = header.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let last = size - 1
        if parts[0].isEmpty {
            guard let suffix = UInt64(parts[1]), suffix > 0 else { return nil }
            return (size - min(suffix, size), last)
        }
        guard let start = UInt64(parts[0]), start <= last else { return nil }
        if parts[1].isEmpty { return (start, min(last, start + maxChunk - 1)) }
        guard let end = UInt64(parts[1]), end >= start else { return nil }
        return (start, min(end, last))
    }
}
