import Foundation

/// Third-party preview assets bundled from `Resources/Vendor`: Pele draws diagrams and KaTeX
/// typesets math. Scripts are injected into LexMD's content world; stylesheets and fonts are
/// served read-only through `VendorSchemeHandler`.
enum VendorAssets {
    static let bundleName = "LexMD_LexMD.bundle"

    /// The canonical path of the vendor folder, or nil when the resource bundle is missing.
    static let directory: URL? = {
        for candidate in bundleCandidates() {
            guard let base = candidate?.appendingPathComponent(bundleName), let bundle = Bundle(url: base),
                  let resources = bundle.resourceURL else { continue }
            let vendor = resources.appendingPathComponent("Vendor", isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: vendor.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: FileScanner.canonicalPath(vendor.path), isDirectory: true)
            }
        }
        return nil
    }()

    /// Same places SwiftPM's generated accessor looks, without its crash when nothing is found:
    /// the app's Resources folder, the bundle holding this code (tests), and next to the executable.
    private static func bundleCandidates() -> [URL?] {
        [
            Bundle.main.resourceURL,
            Bundle(for: BundleMarker.self).resourceURL,
            Bundle.main.bundleURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
        ]
    }

    private final class BundleMarker {}

    /// Resolves a relative path inside the vendor folder. Rejects absolute paths, `..`, hidden
    /// names, and anything that resolves (through symlinks) outside the folder or is not a file.
    static func file(at relativePath: String, in root: URL? = directory) -> URL? {
        guard let root, !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.contains("\\"),
              !relativePath.contains("\0") else { return nil }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }) else { return nil }
        let rootPath = FileScanner.canonicalPath(root.path)
        let resolved = FileScanner.canonicalPath(root.appendingPathComponent(relativePath).path)
        guard resolved.hasPrefix(rootPath + "/") else { return nil }
        let values = try? URL(fileURLWithPath: resolved).resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else { return nil }
        return URL(fileURLWithPath: resolved)
    }

    static func text(_ relativePath: String) -> String? {
        file(at: relativePath).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    static let peleScript: String? = text("pele/pele.global.js")
    static let katexScript: String? = text("katex/katex.min.js")

    /// KaTeX's stylesheet with its relative font URLs pointed at the vendor route.
    static let katexStyle: String? = text("katex/katex.min.css").map {
        $0.replacingOccurrences(of: "url(fonts/", with: "url(\(VendorSchemeHandler.scheme):///katex/fonts/")
    }
}
