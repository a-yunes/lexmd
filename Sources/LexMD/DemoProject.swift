import AppKit

/// The demo project bundled from `Resources/Demo`. It is copied to Application Support so it can
/// be read and edited like any other project, and onboarding opens it.
enum DemoProject {
    static let folderName = "LexMD Demo"
    static let documentName = "Showcase.md"

    /// The bundled copy, read only.
    static var bundledURL: URL? {
        for candidate in VendorAssets.bundleCandidates() {
            guard let base = candidate?.appendingPathComponent(VendorAssets.bundleName), let bundle = Bundle(url: base),
                  let resources = bundle.resourceURL else { continue }
            let url = resources.appendingPathComponent("Demo", isDirectory: true)
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(documentName).path) { return url }
        }
        return nil
    }

    /// Where the reader's copy lives.
    static var defaultLocation: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("LexMD", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// Copies the demo into `location` and returns its main document. Items already there are kept,
    /// so the reader's edits survive and anything they deleted comes back.
    static func install(from source: URL? = bundledURL, to location: URL = defaultLocation) throws -> URL {
        guard let source else { throw CocoaError(.fileNoSuchFile) }
        let manager = FileManager.default
        try manager.createDirectory(at: location, withIntermediateDirectories: true)
        for item in try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            let target = location.appendingPathComponent(item.lastPathComponent)
            if !manager.fileExists(atPath: target.path) { try manager.copyItem(at: item, to: target) }
        }
        return location.appendingPathComponent(documentName)
    }

    /// Whether `url` is the reader's copy of the demo project.
    static func isDemo(_ url: URL?) -> Bool {
        guard let url else { return false }
        return FileScanner.canonicalPath(url.path) == FileScanner.canonicalPath(defaultLocation.path)
    }
}

extension AppModel {
    /// Opens the demo project at its showcase document, restoring any missing demo files first.
    func openDemoProject() {
        do {
            open(try DemoProject.install())
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn’t open the demo project"
            present(alert) { _ in }
        }
    }
}
