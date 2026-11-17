import AppKit
import Foundation
import WebKit
@testable import LexMD

/// A temporary folder removed when the value is released.
final class TestFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("LexMDTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func write(_ name: String, _ text: String, executable: Bool = false) throws -> URL {
        let file = url.appendingPathComponent(name)
        try text.write(to: file, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return file
    }

    func writePNG(_ name: String) throws {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        try rep.representation(using: .png, properties: [:])!.write(to: url.appendingPathComponent(name))
    }
}

struct TimedOut: Error {}

/// Polls `condition` until it holds, failing after `seconds`. The default is generous because
/// other main-actor tests in the parallel run can hold the main thread for seconds at a time.
@MainActor
func waitUntil(seconds: Double = 30, _ condition: () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if (try? await condition()) == true { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw TimedOut()
}

/// Evaluates JavaScript in the preview's page world, where document markup lives.
@MainActor
func page(_ preview: PreviewController, _ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
    try await preview.webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
}

/// Evaluates JavaScript in LexMD's own content world, where the preview's scripts run.
@MainActor
func world(_ preview: PreviewController, _ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
    try await preview.webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .world(name: "LexMD"))
}

/// Puts the shared model's editor in a window of its own for a test (for a responder chain,
/// an undo manager, or a size), and puts it back where it was with `restore()`.
@MainActor
final class EditorHost {
    let window: NSWindow
    private let editor: NSView
    private let previousSuperview: NSView?

    init(_ model: AppModel, width: CGFloat = 600, height: CGFloat = 400) {
        editor = model.editor.scrollView
        previousSuperview = editor.superview
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
    }

    func restore() {
        window.contentView = nil
        previousSuperview?.addSubview(editor)
    }
}
