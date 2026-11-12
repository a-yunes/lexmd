import AppIntents
import Foundation

// Actions for the Shortcuts app. `scripts/build-app.sh` extracts their metadata into
// Contents/Resources/Metadata.appintents, which is how Shortcuts finds them.

enum LexMDIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notOnDisk
    case noProject
    case notAFolder(String)
    case noDocument

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notOnDisk: "LexMD can only open files and folders on this Mac."
        case .noProject: "Open a project in LexMD, or choose a folder for the note."
        case .notAFolder(let path): "\(path) is not a folder."
        case .noDocument: "No document is open in LexMD."
        }
    }
}

struct OpenInLexMDIntent: AppIntent {
    static let title: LocalizedStringResource = "Open in LexMD"
    static let description = IntentDescription("Opens Markdown files in tabs, or a folder as the project.")
    static let openAppWhenRun = true

    @Parameter(title: "Files or Folder", supportedContentTypes: [.folder, .text])
    var items: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$items) in LexMD")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let urls = items.compactMap(\.fileURL)
        guard !urls.isEmpty else { throw LexMDIntentError.notOnDisk }
        AppModel.shared.open(urls)
        return .result()
    }
}

struct CreateNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Note"
    static let description = IntentDescription(
        "Creates a Markdown note in a folder or the open project and opens it. Existing files are never replaced; a number is added to the name instead."
    )
    static let openAppWhenRun = true

    @Parameter(title: "Name")
    var name: String

    @Parameter(title: "Text", default: "", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    @Parameter(title: "Folder", description: "Without a folder, the note goes in the project open in LexMD.", supportedContentTypes: [.folder])
    var folder: IntentFile?

    static var parameterSummary: some ParameterSummary {
        Summary("Create note \(\.$name) with \(\.$text)") {
            \.$folder
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let target: URL
        if let folder {
            guard let url = folder.fileURL else { throw LexMDIntentError.notOnDisk }
            target = url
        } else if let root = AppModel.shared.rootURL {
            target = root
        } else {
            throw LexMDIntentError.noProject
        }
        let scoped = target.startAccessingSecurityScopedResource()
        defer { if scoped { target.stopAccessingSecurityScopedResource() } }
        let note = try NoteCreator.create(name: name, text: text, in: target)
        AppModel.shared.open([note])
        return .result(value: IntentFile(fileURL: note, filename: note.lastPathComponent))
    }
}

struct GetCurrentDocumentIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Current Document"
    static let description = IntentDescription("Returns the document open in LexMD: its file, name, path, and text, including unsaved edits.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<CurrentDocumentEntity> {
        let model = AppModel.shared
        guard let file = model.currentFile else { throw LexMDIntentError.noDocument }
        return .result(value: CurrentDocumentEntity(file: file, text: model.text))
    }
}

/// The document open in LexMD, as Shortcuts sees it.
struct CurrentDocumentEntity: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "LexMD Document"

    @Property(title: "File")
    var file: IntentFile

    @Property(title: "Name")
    var name: String

    @Property(title: "Path")
    var path: String

    @Property(title: "Text")
    var text: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(path)")
    }

    init() {
        file = IntentFile(data: Data(), filename: "Untitled.md")
        name = ""
        path = ""
        text = ""
    }

    init(file url: URL, text: String) {
        self.init()
        file = IntentFile(fileURL: url, filename: url.lastPathComponent)
        name = url.lastPathComponent
        path = url.path
        self.text = text
    }
}

struct LexMDShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateNoteIntent(),
            phrases: ["Create a note in \(.applicationName)", "New \(.applicationName) note"],
            shortTitle: "Create Note",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: GetCurrentDocumentIntent(),
            phrases: ["Get the current \(.applicationName) document"],
            shortTitle: "Current Document",
            systemImageName: "doc.text"
        )
    }
}

/// Creates Markdown notes for the Create Note action.
enum NoteCreator {
    /// A safe file name: no folder separators, not hidden, with a Markdown extension.
    static func fileName(for rawName: String) -> (base: String, extension: String) {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "Untitled" }
        if FileScanner.isMarkdown(path: name) {
            return ((name as NSString).deletingPathExtension, (name as NSString).pathExtension)
        }
        return (name, "md")
    }

    /// Writes a new note in `folder`, numbering the name when it is taken. Never replaces a file.
    static func create(name rawName: String, text: String, in folder: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LexMDIntentError.notAFolder(folder.path)
        }
        let (base, ext) = fileName(for: rawName)
        let data = Data(text.utf8)
        for _ in 0..<100 {
            let url = FileOperations.uniqueURL(in: folder, base: base, extension: ext)
            do {
                try data.write(to: url, options: .withoutOverwriting)
                return url
            } catch CocoaError.fileWriteFileExists {
                continue // created by someone else in the meantime
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}
