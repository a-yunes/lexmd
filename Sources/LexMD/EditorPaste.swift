import AppKit
import UniformTypeIdentifiers

/// Where pasted and dropped images are saved and linked from.
struct ImageContext {
    /// The open Markdown document.
    var document: URL
    /// The project folder; image files inside it are linked in place instead of copied.
    var root: URL?
    /// The image folder setting, relative to the document's folder.
    var folder: String
}

/// Saves images next to a document and builds relative Markdown links to them.
enum ImageStore {
    static let dataTypes: [NSPasteboard.PasteboardType] = [
        .png, NSPasteboard.PasteboardType(UTType.jpeg.identifier), NSPasteboard.PasteboardType(UTType.gif.identifier),
        NSPasteboard.PasteboardType(UTType.heic.identifier), .tiff,
    ]

    static func isImageFile(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    /// The image folder for a document. Leading slashes are ignored so the folder stays relative.
    static func folderURL(for context: ImageContext) -> URL {
        let base = context.document.deletingLastPathComponent()
        let trimmed = context.folder.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? base : base.appendingPathComponent(trimmed, isDirectory: true)
    }

    /// A readable name for pasted image data, such as `image-2026-11-12-0914.png`.
    static func pastedName(date: Date, ext: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "image-\(formatter.string(from: date)).\(ext)"
    }

    /// `name`, or `name-2`, `name-3` and so on before the extension, whichever is free in `folder`.
    static func candidates(for name: String) -> some Sequence<String> {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return (1...).lazy.map { index in
            let stem = index == 1 ? base : "\(base)-\(index)"
            return ext.isEmpty ? stem : "\(stem).\(ext)"
        }
    }

    /// Writes data under a free name; never replaces an existing file.
    static func write(_ data: Data, named name: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for candidate in candidates(for: name).prefix(10_000) {
            let url = folder.appendingPathComponent(candidate)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try data.write(to: url, options: .withoutOverwriting)
                return url
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Copies a file under a free name; never replaces an existing file.
    static func copy(_ file: URL, into folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for candidate in candidates(for: file.lastPathComponent).prefix(10_000) {
            let url = folder.appendingPathComponent(candidate)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.copyItem(at: file, to: url)
                return url
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    static func isInside(_ file: URL, folder: URL) -> Bool {
        let path = FileScanner.canonicalPath(file.path)
        let root = FileScanner.canonicalPath(folder.path)
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// The path of `file` relative to `directory`, using `..` where needed.
    static func relativePath(from directory: URL, to file: URL) -> String {
        let from = FileScanner.canonicalPath(directory.path).split(separator: "/")
        let to = FileScanner.canonicalPath(file.path).split(separator: "/")
        var common = 0
        while common < from.count, common < to.count - 1, from[common] == to[common] { common += 1 }
        let ups = Array(repeating: "..", count: from.count - common)
        return (ups + to[common...].map(String.init)).joined(separator: "/")
    }

    private static let pathAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/!$&'*+,;=@"
    )

    /// Percent-encodes a relative path for a Markdown link destination (spaces, parentheses,
    /// colons, and non-ASCII characters are encoded).
    static func encodePath(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? path
    }

    static func markdownImage(_ path: String) -> String {
        "![](\(encodePath(path)))"
    }

    /// Image data on a pasteboard, as PNG when it only offers TIFF.
    static func imageData(from pasteboard: NSPasteboard) -> (data: Data, ext: String)? {
        guard let type = pasteboard.availableType(from: dataTypes), let data = pasteboard.data(forType: type) else { return nil }
        if type == .tiff {
            guard let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) else { return nil }
            return (png, "png")
        }
        let ext = UTType(type.rawValue)?.preferredFilenameExtension ?? "png"
        return (data, ext == "jpeg" ? "jpg" : ext)
    }

    static func imageFiles(on pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter(isImageFile)
    }
}

/// Converts pasted URLs and tabular data into Markdown.
enum SmartPaste {
    private static let urlPattern = try! NSRegularExpression(
        pattern: #"^(?:[A-Za-z][A-Za-z0-9+.-]*://[^\s/?#]+\S*|mailto:[^\s@]+@\S+)$"#
    )

    /// The URL when the pasted text is exactly one URL.
    static func url(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(location: 0, length: (trimmed as NSString).length)
        guard urlPattern.firstMatch(in: trimmed, range: range) != nil else { return nil }
        return trimmed
    }

    /// `[text](url)`, wrapping the URL in angle brackets when its parentheses are unbalanced.
    static func link(text: String, url: String) -> String {
        var depth = 0
        var balanced = true
        for character in url {
            if character == "(" { depth += 1 } else if character == ")" { depth -= 1 }
            if depth < 0 { balanced = false }
        }
        let destination = balanced && depth == 0 ? url : "<\(url)>"
        return "[\(text)](\(destination))"
    }

    /// Escapes pipes and line breaks so the text fits in one table cell.
    static func escapeCell(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "<br>")
            .replacingOccurrences(of: "|", with: "\\|")
    }

    /// A formatted Markdown table, with the first row as the header.
    static func table(rows: [[String]]) -> String {
        let columns = rows.map(\.count).max() ?? 0
        let cells = rows.map { row in row.map(escapeCell) + Array(repeating: "", count: columns - row.count) }
        return MarkdownTable(rows: cells, alignments: Array(repeating: .none, count: columns)).formatted().text
    }

    /// Rows of tab-separated text (as copied from Numbers, Excel, or Google Sheets), or nil when the
    /// text does not look like a table: at least two rows with the same number of columns (two or more).
    static func tsvRows(_ text: String) -> [[String]]? {
        guard text.contains("\t") else { return nil }
        var rows = parseTSV(text, quotes: true) ?? parseTSV(text, quotes: false) ?? []
        while let last = rows.last, last.allSatisfy(\.isEmpty) { rows.removeLast() }
        guard rows.count >= 2, let columns = rows.first?.count, columns >= 2,
              rows.allSatisfy({ $0.count == columns }),
              !rows.allSatisfy({ $0[0].trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        return rows
    }

    /// Splits on tabs and line breaks. With `quotes`, cells wrapped in double quotes may contain
    /// tabs, line breaks, and doubled quotes; returns nil when a quote is left open.
    private static func parseTSV(_ text: String, quotes: Bool) -> [[String]]? {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var wasQuoted = false
        var characters = text.makeIterator()
        var pending: Character? = characters.next()
        while let character = pending {
            pending = characters.next()
            if inQuotes {
                if character == "\"" {
                    if pending == "\"" { field.append("\""); pending = characters.next() } else { inQuotes = false }
                } else {
                    field.append(character)
                }
                continue
            }
            if quotes, character == "\"", field.isEmpty, !wasQuoted {
                inQuotes = true
                wasQuoted = true
            } else if character == "\t" {
                row.append(field); field = ""; wasQuoted = false
            } else if character.isNewline {
                row.append(field); rows.append(row); row = []; field = ""; wasQuoted = false
            } else {
                field.append(character)
            }
        }
        if inQuotes { return nil }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    /// Rows of the HTML table on the pasteboard, when the table is all the HTML holds.
    static func htmlRows(_ html: String) -> [[String]]? {
        guard html.range(of: "<table", options: .caseInsensitive) != nil,
              let document = try? XMLDocument(xmlString: html, options: [.documentTidyHTML]) else { return nil }
        for node in (try? document.nodes(forXPath: "//style | //script | //head | //title")) ?? [] {
            node.detach()
        }
        guard let table = (try? document.nodes(forXPath: "//table"))?.first as? XMLElement else { return nil }
        func squeeze(_ text: String?) -> String {
            (text ?? "").components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined()
        }
        // Text outside the table would be lost, so only convert a table pasted on its own.
        let body = (try? document.nodes(forXPath: "//body"))?.first ?? document.rootElement()
        guard squeeze(body?.stringValue) == squeeze(table.stringValue) else { return nil }
        let rowNodes = (try? table.nodes(forXPath: "./tr | ./thead/tr | ./tbody/tr | ./tfoot/tr")) ?? []
        var rows: [[String]] = []
        for case let rowNode as XMLElement in rowNodes {
            var cells: [String] = []
            for case let cell as XMLElement in rowNode.children ?? [] where ["td", "th"].contains(cell.name?.lowercased() ?? "") {
                let text = (cell.stringValue ?? "").components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }.joined(separator: " ")
                cells.append(text)
                let span = Int(cell.attribute(forName: "colspan")?.stringValue ?? "") ?? 1
                if span > 1 { cells += Array(repeating: "", count: min(span, 100) - 1) }
            }
            if !cells.isEmpty { rows.append(cells) }
        }
        guard rows.count >= 1, (rows.map(\.count).max() ?? 0) >= 1, rows.count + (rows.first?.count ?? 0) > 2 else {
            return nil
        }
        return rows
    }

    /// The Markdown table for tabular pasteboard content, or nil.
    static func table(from pasteboard: NSPasteboard) -> String? {
        if let text = pasteboard.string(forType: .string), let rows = tsvRows(text) {
            return table(rows: rows)
        }
        if let html = pasteboard.string(forType: .html), let rows = htmlRows(html) {
            return table(rows: rows)
        }
        return nil
    }
}

extension EditorController {
    /// Inserts text over `range` and puts the caret after it.
    private func insert(_ string: String, over range: NSRange, actionName: String) {
        guard replace([TextEdit(range: range, replacement: string)], actionName: actionName) else { return }
        let end = range.location + (string as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))
        textView.scrollRangeToVisible(NSRange(location: end, length: 0))
    }

    private var isInCode: Bool {
        let location = textView.selectedRange().location
        return currentBlocks.items.contains {
            $0.kind != .comment && $0.range.location < location && location < NSMaxRange($0.range)
        }
    }

    /// Handles Paste for images, URLs over a selection, and tables. Returns false to paste normally,
    /// which includes pasting while an input method is composing text.
    func paste(from pasteboard: NSPasteboard, date: Date = Date()) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        let range = textView.selectedRange()
        let files = ImageStore.imageFiles(on: pasteboard)
        if !files.isEmpty { return insertImages(files: files, over: range) }
        if let text = pasteboard.string(forType: .string) {
            guard !isInCode else { return false }
            let selected = textView.textStorage?.mutableString.substring(with: range) ?? ""
            if !selected.isEmpty, !selected.contains("\n"), SmartPaste.url(in: selected) == nil,
               let url = SmartPaste.url(in: text) {
                insert(SmartPaste.link(text: selected, url: url), over: range, actionName: "Paste Link")
                return true
            }
            if let table = SmartPaste.table(from: pasteboard) {
                insert(table, over: range, actionName: "Paste Table")
                return true
            }
            return false
        }
        if let image = ImageStore.imageData(from: pasteboard) {
            return insertImage(data: image.data, ext: image.ext, over: range, date: date)
        }
        if let table = SmartPaste.table(from: pasteboard) {
            insert(table, over: range, actionName: "Paste Table")
            return true
        }
        return false
    }

    /// Whether a drag carries images this editor saves or links.
    func acceptsImageDrop(_ pasteboard: NSPasteboard) -> Bool {
        guard imageContext?() != nil else { return false }
        if !ImageStore.imageFiles(on: pasteboard).isEmpty { return true }
        let hasFiles = pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return !hasFiles && pasteboard.string(forType: .string) == nil && ImageStore.imageData(from: pasteboard) != nil
    }

    /// Inserts dropped images at `location`. Returns false when the drop holds no images.
    func dropImages(from pasteboard: NSPasteboard, at location: Int, date: Date = Date()) -> Bool {
        guard acceptsImageDrop(pasteboard) else { return false }
        let range = NSRange(location: min(location, (textView.string as NSString).length), length: 0)
        let files = ImageStore.imageFiles(on: pasteboard)
        if !files.isEmpty { return insertImages(files: files, over: range) }
        guard let image = ImageStore.imageData(from: pasteboard) else { return false }
        return insertImage(data: image.data, ext: image.ext, over: range, date: date)
    }

    /// Links image files: files in the project are linked in place, others are copied to the image folder.
    func insertImages(files: [URL], over range: NSRange) -> Bool {
        guard let context = imageContext?() else { return false }
        let directory = context.document.deletingLastPathComponent()
        let root = context.root ?? directory
        var links: [String] = []
        do {
            for file in files {
                let target = ImageStore.isInside(file, folder: root)
                    ? file : try ImageStore.copy(file, into: ImageStore.folderURL(for: context))
                links.append(ImageStore.markdownImage(ImageStore.relativePath(from: directory, to: target)))
            }
        } catch {
            presentImageError(error)
            return true
        }
        insert(links.joined(separator: "\n"), over: range, actionName: "Paste Image")
        return true
    }

    /// Saves image data to the image folder and links it.
    func insertImage(data: Data, ext: String, over range: NSRange, date: Date = Date()) -> Bool {
        guard let context = imageContext?() else { return false }
        do {
            let url = try ImageStore.write(data, named: ImageStore.pastedName(date: date, ext: ext), in: ImageStore.folderURL(for: context))
            let path = ImageStore.relativePath(from: context.document.deletingLastPathComponent(), to: url)
            insert(ImageStore.markdownImage(path), over: range, actionName: "Paste Image")
        } catch {
            presentImageError(error)
        }
        return true
    }

    private func presentImageError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t save the image"
        alert.informativeText = error.localizedDescription
        if let window = textView.window { alert.beginSheetModal(for: window) } else { NSSound.beep() }
    }
}

extension LexMDTextView {
    override func paste(_ sender: Any?) {
        if editor?.paste(from: .general) == true { return }
        super.paste(sender)
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        // Image data enables Paste for screenshots; `paste(_:)` saves it as a file.
        super.readablePasteboardTypes + ImageStore.dataTypes
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + ImageStore.dataTypes
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        // Image data is only inserted through `paste(_:)` and drops, never as raw content.
        if ImageStore.dataTypes.contains(type) { return false }
        return super.readSelection(from: pboard, type: type)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = super.draggingEntered(sender)
        return isImageDrop(sender) ? .copy : operation
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = super.draggingUpdated(sender)
        return isImageDrop(sender) ? .copy : operation
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isImageDrop(sender), let editor else { return super.performDragOperation(sender) }
        let point = convert(sender.draggingLocation, from: nil)
        let location = characterIndexForInsertion(at: point)
        cleanUpAfterDragOperation()
        window?.makeFirstResponder(self)
        return editor.dropImages(from: sender.draggingPasteboard, at: location)
    }

    private func isImageDrop(_ sender: NSDraggingInfo) -> Bool {
        (sender.draggingSource as? NSTextView) !== self && editor?.acceptsImageDrop(sender.draggingPasteboard) == true
    }

    override func toggleContinuousSpellChecking(_ sender: Any?) {
        super.toggleContinuousSpellChecking(sender)
        editor?.onCheckingChange?(isContinuousSpellCheckingEnabled, isGrammarCheckingEnabled)
    }

    override func toggleGrammarChecking(_ sender: Any?) {
        super.toggleGrammarChecking(sender)
        editor?.onCheckingChange?(isContinuousSpellCheckingEnabled, isGrammarCheckingEnabled)
    }
}
