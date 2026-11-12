import AppKit
import Foundation

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

/// Polls `condition` until it holds, failing after `seconds`.
@MainActor
func waitUntil(seconds: Double = 30, _ condition: () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if (try? await condition()) == true { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw TimedOut()
}
