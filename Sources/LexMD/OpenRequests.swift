import Foundation

/// How files and folders opened together (from Finder, `lexmd`, or Shortcuts) are shown.
///
/// The first folder becomes the project. Without a folder, files stay in the current project
/// when they are all inside it; otherwise the project becomes the folder that holds them all
/// (or the first file's folder when that would be a whole disk, the home folder, or a folder
/// above it, such as /Users). Files then open in tabs; files outside the project and paths that
/// do not exist are left out.
struct OpenPlan: Equatable {
    /// The folder to open as the project, or nil to keep the current one.
    var folder: String?
    /// Files to open, in order.
    var files: [String]

    /// `isDirectory` returns nil for paths that do not exist.
    static func make(paths: [String], currentRoot: String?, home: String, isDirectory: (String) -> Bool?) -> OpenPlan {
        var seen: Set<String> = []
        var folder: String?
        var files: [String] = []
        for path in paths where seen.insert(path).inserted {
            switch isDirectory(path) {
            case true?: if folder == nil { folder = path }
            case false?: files.append(path)
            case nil: continue
            }
        }
        if folder == nil, !files.isEmpty, !(currentRoot.map { root in files.allSatisfy { contains(root, $0) } } ?? false) {
            let common = commonFolder(files.map { ($0 as NSString).deletingLastPathComponent })
            folder = isTooBroad(common, home: home) ? (files[0] as NSString).deletingLastPathComponent : common
        }
        let root = folder ?? currentRoot
        if let root { files = files.filter { contains(root, $0) } }
        return OpenPlan(folder: folder, files: files)
    }

    /// Folders too large to scan as a project: a disk (/ or /Volumes/Name), a top-level folder
    /// such as /Users or /Volumes, and the home folder or any folder above it.
    static func isTooBroad(_ folder: String, home: String) -> Bool {
        let parts = folder.split(separator: "/")
        if parts.count < 2 || (parts.count == 2 && parts[0] == "Volumes") { return true }
        return folder == home || contains(folder, home)
    }

    static func contains(_ folder: String, _ path: String) -> Bool {
        path.hasPrefix(folder == "/" ? "/" : folder + "/")
    }

    /// The deepest folder that holds every folder in `folders`.
    static func commonFolder(_ folders: [String]) -> String {
        guard var common = folders.first.map({ $0.split(separator: "/") }) else { return "/" }
        for folder in folders.dropFirst() {
            let parts = folder.split(separator: "/")
            var count = 0
            while count < common.count, count < parts.count, common[count] == parts[count] { count += 1 }
            common = Array(common.prefix(count))
        }
        return "/" + common.joined(separator: "/")
    }
}

extension AppModel {
    /// Opens several files and folders at once; see `OpenPlan`. One URL opens as before.
    func open(_ urls: [URL]) {
        guard urls.count > 1 else {
            if let url = urls.first { open(url) }
            return
        }
        let plan = OpenPlan.make(
            paths: urls.map { FileScanner.canonicalPath($0.path) },
            currentRoot: rootURL?.path,
            home: FileScanner.canonicalPath(FileManager.default.homeDirectoryForCurrentUser.path)
        ) { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) ? isDirectory.boolValue : nil
        }
        if let folder = plan.folder { open(URL(fileURLWithPath: folder, isDirectory: true)) }
        for path in plan.files { openPath(path, inNewTab: true) }
    }
}
