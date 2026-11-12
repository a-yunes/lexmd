import Foundation
import LexMDRendering
import QuickLookUI
import UniformTypeIdentifiers

/// Quick Look previews for Markdown files: LexMD's rendering as an HTML page with local images
/// attached. The class name is the extension's `NSExtensionPrincipalClass`.
@objc(LexMDPreviewProvider)
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let fileURL = request.fileURL
        let page = try QuickLookPage.make(contentsOf: fileURL)
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 820, height: 1000)) { reply in
            reply.stringEncoding = .utf8
            reply.title = fileURL.lastPathComponent
            var attachments: [String: QLPreviewReplyAttachment] = [:]
            for image in page.images {
                attachments[image.identifier] = QLPreviewReplyAttachment(data: image.data, contentType: image.contentType)
            }
            reply.attachments = attachments
            return Data(page.html.utf8)
        }
    }
}
