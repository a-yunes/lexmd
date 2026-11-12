import AppKit
import UniformTypeIdentifiers

/// Export as PDF and HTML, printing, and Copy as Rich Text for the open document.
extension AppModel {
    var canExport: Bool { currentFile != nil }

    /// A snapshot of the open document, including unsaved edits.
    var exportDocument: ExportDocument? {
        guard let currentFile else { return nil }
        return ExportDocument(
            markdown: text, baseURL: currentFile.deletingLastPathComponent(), title: title,
            allowsRemoteContent: loadsRemoteContent, links: exportLinkContext(for: text)
        )
    }

    private var exportWindow: NSWindow? { NSApp.keyWindow ?? NSApp.mainWindow }

    func exportPDF() {
        guard let document = exportDocument else { NSSound.beep(); return }
        chooseExportDestination(for: document, type: .pdf) { [weak self] url in
            Task { @MainActor in
                do {
                    try await Exporter.exportPDF(document, to: url)
                } catch {
                    self?.showExportError(error, file: url)
                }
            }
        }
    }

    func exportHTML() {
        guard let document = exportDocument else { NSSound.beep(); return }
        chooseExportDestination(for: document, type: .html) { [weak self] url in
            Task { @MainActor in
                do {
                    let result = try await Exporter.exportHTML(document, to: url)
                    guard !result.linkedImages.isEmpty else { return }
                    let names = result.linkedImages.prefix(3).joined(separator: ", ")
                    let more = result.linkedImages.count > 3 ? " and \(result.linkedImages.count - 3) more" : ""
                    ExportNote.show(
                        "Some images were too large to embed and are linked instead: \(names)\(more).",
                        in: self?.exportWindow
                    )
                } catch {
                    self?.showExportError(error, file: url)
                }
            }
        }
    }

    func printDocument() {
        guard let document = exportDocument else { NSSound.beep(); return }
        let window = exportWindow
        Task { @MainActor [weak self] in
            do {
                try await Exporter.print(document, window: window)
            } catch {
                self?.showExportError(error, file: nil)
            }
        }
    }

    /// Copies the editor's selected Markdown as rich text when the editor has focus and a selection;
    /// otherwise the preview's selection, or the whole rendered document.
    func copyRichText(to pasteboard: NSPasteboard = .general) {
        guard let document = exportDocument else { NSSound.beep(); return }
        let textView = editor.textView
        let range = textView.selectedRange()
        let editorSelection = textView.window?.firstResponder === textView && range.length > 0
            ? (textView.string as NSString).substring(with: range) : nil
        let useLivePreview = editorSelection == nil && preview.isPageLoaded
        let previewSelection = viewMode != .edit
        Task { @MainActor [weak self] in
            do {
                let rich: Exporter.RichText
                if let editorSelection {
                    var selected = document
                    selected.markdown = editorSelection
                    rich = try await Exporter.richText(selected)
                } else if useLivePreview, let self {
                    rich = try await Exporter.richText(from: self.preview, selection: previewSelection)
                } else {
                    rich = try await Exporter.richText(document)
                }
                Exporter.write(rich, to: pasteboard)
            } catch {
                self?.showExportError(error, file: nil)
            }
        }
    }

    private func chooseExportDestination(for document: ExportDocument, type: UTType, completion: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(document.title).\(type.preferredFilenameExtension ?? "")"
        panel.directoryURL = document.baseURL
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url { completion(url) }
        }
        if let window = exportWindow {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(panel.runModal())
        }
    }

    private func showExportError(_ error: Error, file: URL?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        if let file {
            alert.messageText = "Couldn’t export “\(file.lastPathComponent)”."
        } else {
            alert.messageText = "Couldn’t complete the command."
        }
        alert.informativeText = error.localizedDescription
        present(alert) { _ in }
    }
}
