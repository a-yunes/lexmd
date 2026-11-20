import AppKit
import Foundation
import Testing
@testable import LexMD
@testable import LexMDRendering

/// Opening images and diagrams in the preview's viewer, zooming them, and closing it.
@MainActor
@Suite(.serialized)
struct LightboxTests {
    private func makePreview() -> (PreviewController, NSWindow) {
        let preview = PreviewController(allowsRemoteContent: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = preview.webView
        return (preview, window)
    }

    /// A PNG of the given size, as a data URL.
    private func png(width: Int, height: Int) -> String {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        return "data:image/png;base64," + rep.representation(using: .png, properties: [:])!.base64EncodedString()
    }

    private func click(_ preview: PreviewController, _ selector: String, detail: Int = 1) async throws {
        _ = try await page(preview, """
            var el = document.querySelector(s);
            el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, detail: d, button: 0 }));
            if (d > 1) el.dispatchEvent(new MouseEvent('dblclick', { bubbles: true, cancelable: true, detail: d }));
            return true
            """, ["s": selector, "d": detail])
    }

    private func isOpen(_ preview: PreviewController) async throws -> Bool {
        try await world(preview, "return window.lexmdLightbox.isOpen()") as? Bool == true
    }

    @Test func clickingAnImageOpensItToZoom() async throws {
        let (preview, window) = makePreview()
        defer { window.contentView = nil; window.close() }
        let source = png(width: 300, height: 200)
        let html = MarkdownHTML.renderWithSourceLines("![A chart](\(source))\n\n[![Linked](\(source))](https://example.com)\n").html
        preview.render(html: html, baseURL: nil, resetScroll: true, document: "/doc.md", generation: 1)
        try await waitUntil(seconds: 10) {
            guard preview.isPageLoaded else { return false }
            return try await page(preview, "return Array.from(document.querySelectorAll('#content img')).every(i => i.complete && i.naturalWidth > 0)") as? Bool == true
        }

        // A click opens the viewer at once. The second click of a double-click lands on it: the
        // viewer closes and the block opens for editing, as a double-click does on the page.
        var edited: ClosedRange<Int>?
        preview.onEditRequest = { lines, _ in edited = lines }
        try await click(preview, "#content p img", detail: 1)
        #expect(try await isOpen(preview), "the viewer opens on the click, without waiting")
        _ = try await page(preview, "document.querySelector('.lexmd-lightbox-item').dispatchEvent(new MouseEvent('dblclick', { bubbles: true, cancelable: true, detail: 2 })); return true")
        try await waitUntil(seconds: 5) { edited != nil && !preview.isLightboxOpen }
        #expect(try await !isOpen(preview))
        #expect(try await page(preview, "return document.querySelector('#content p img').style.visibility") as? String == "", "the page's image is back")

        // An image inside a link follows the link instead.
        try await click(preview, "#content a img")
        try await Task.sleep(for: .milliseconds(450))
        #expect(try await !isOpen(preview))

        try await click(preview, "#content p img")
        try await waitUntil(seconds: 5) { preview.isLightboxOpen }
        #expect(try await isOpen(preview))
        #expect(try await page(preview, "return document.querySelector('.lexmd-lightbox-item').tagName") as? String == "IMG")
        #expect(try await page(preview, "return document.querySelector('.lexmd-lightbox-caption').textContent") as? String == "A chart")
        let label = { try await page(preview, "return document.querySelector('.lexmd-lightbox-zoom').textContent") as? String ?? "" }
        let itemSize = {
            try await page(preview, "var r = document.querySelector('.lexmd-lightbox-item').getBoundingClientRect(); return [r.width, r.height]") as? [Double] ?? []
        }
        // Even a small image opens filling the window (900 wide, less 40 on each side), and the
        // zoom reads relative to its size in the document (300 wide there).
        let fitted = try await itemSize()
        #expect(abs((fitted.first ?? 0) - 820) < 1, "opened at \(fitted)")
        #expect(try await label() == "\(Int((fitted.first ?? 0) / 300 * 100))%")

        preview.zoomLightbox(by: 1)
        try await waitUntil(seconds: 5) { abs((try await itemSize().first ?? 0) - (fitted.first ?? 0) * 1.25) < 1 }
        // 1:1 is the image's own pixels, which is also its size in the document here.
        _ = try await page(preview, "document.querySelector('.lexmd-lightbox-bar button[aria-label=\"Actual Size\"]').click(); return true")
        try await waitUntil(seconds: 5) { try await label() == "100%" }
        #expect(abs((try await itemSize().first ?? 0) - 300) < 1)
        preview.zoomLightbox(by: 0)
        try await waitUntil(seconds: 5) { abs((try await itemSize().first ?? 0) - 820) < 1 }

        // Dragging the image and letting go beside it arrives as a click on the backdrop; only a
        // plain click there closes the viewer.
        _ = try await page(preview, """
            var item = document.querySelector('.lexmd-lightbox-item'), stage = document.querySelector('.lexmd-lightbox-stage');
            item.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, button: 0, clientX: 300, clientY: 300 }));
            window.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, clientX: 20, clientY: 20 }));
            window.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, clientX: 20, clientY: 20 }));
            stage.dispatchEvent(new MouseEvent('click', { bubbles: true, button: 0 }));
            return true
            """)
        #expect(try await isOpen(preview), "a drag that ends beside the image doesn't close the viewer")

        _ = try await page(preview, "document.getElementById('lexmd-lightbox').dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); return true")
        try await waitUntil(seconds: 5) { !preview.isLightboxOpen }
        #expect(try await !isOpen(preview))
    }

    @Test func diagramsOpenAtTheirFullSize() async throws {
        let (preview, window) = makePreview()
        defer { window.contentView = nil; window.close() }
        preview.render(html: MarkdownHTML.render("```mermaid\nflowchart LR\n  A[Start] --> B[Finish]\n```\n"), baseURL: nil, resetScroll: true, document: "/doc.md", generation: 1)
        try await waitUntil(seconds: 20) {
            guard preview.isPageLoaded else { return false }
            return try await page(preview, "return document.querySelectorAll('.lexmd-diagram-view svg').length") as? Int == 1
        }
        try await click(preview, ".lexmd-diagram-view svg")
        try await waitUntil(seconds: 5) { preview.isLightboxOpen }
        #expect(try await page(preview, "return document.querySelectorAll('.lexmd-lightbox-item svg').length") as? Int == 1)
        // A drawing fills the window, scaled up past the size it has on the page.
        let label = try await page(preview, "return document.querySelector('.lexmd-lightbox-zoom').textContent") as? String ?? ""
        #expect((Int(label.dropLast()) ?? 0) > 100, "opened at \(label)")

        // Opening another document closes the viewer.
        preview.render(html: "<p>Other</p>", baseURL: nil, resetScroll: true, document: "/other.md", generation: 2)
        try await waitUntil(seconds: 5) { !preview.isLightboxOpen }
        #expect(try await !isOpen(preview))
    }

    /// A PNG of thin colored outlines and hairlines on white, the kind of image whose lines
    /// show any difference in how it is drawn.
    private func thinLinePNG(width: Int, height: Int) -> String {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor.systemBlue.setStroke()
        let outline = NSBezierPath(roundedRect: NSRect(x: 40.5, y: 40.5, width: Double(width) / 2 - 60, height: Double(height) - 81), xRadius: 18, yRadius: 18)
        outline.lineWidth = 3
        outline.stroke()
        NSColor.black.setStroke()
        for index in 0..<24 {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: Double(width) / 2 + 20, y: 60.5 + Double(index) * 13))
            line.line(to: NSPoint(x: Double(width) - 40, y: 60.5 + Double(index) * 13 + Double(index % 3)))
            line.lineWidth = 1
            line.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        return "data:image/png;base64," + rep.representation(using: .png, properties: [:])!.base64EncodedString()
    }

    private func snapshot(_ preview: PreviewController) async throws -> NSBitmapImageRep {
        let image = try await preview.webView.takeSnapshot(configuration: nil)
        let tiff = try #require(image.tiffRepresentation)
        return try #require(NSBitmapImageRep(data: tiff))
    }

    /// The largest difference in any color channel between two snapshots, and how many pixels differ.
    private func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> (worst: Int, pixels: Int) {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, a.bytesPerRow == b.bytesPerRow,
              let first = a.bitmapData, let second = b.bitmapData else { return (255, -1) }
        var worst = 0, pixels = 0
        let bytes = a.bitsPerPixel / 8
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide {
                let offset = y * a.bytesPerRow + x * bytes
                var delta = 0
                for channel in 0..<min(bytes, 3) { delta = max(delta, abs(Int(first[offset + channel]) - Int(second[offset + channel]))) }
                if delta > 0 { pixels += 1 }
                worst = max(worst, delta)
            }
        }
        return (worst, pixels)
    }

    /// The last frame of closing is the page itself: the copy that lands is drawn at the page's
    /// size and place, so handing back to the page's own image or diagram changes no pixel.
    @Test func closingLandsExactlyOnThePage() async throws {
        let (preview, window) = makePreview()
        defer { window.contentView = nil; window.close() }
        // The second diagram is wider than the page, so the page shows it scaled down, with small text.
        let wide = "```mermaid\nflowchart LR\n  A[App and server send events] --> B[PostHog millions of rows] -->|hourly daily jobs| C[Command Center jobs] --> D[Supabase small daily summary tables] -->|read-only API| E[Hub API] --> F[Hub page final arithmetic and charts]\n```\n"
        let markdown = "Text before.\n\n![Lines](\(thinLinePNG(width: 1400, height: 520)))\n\n```mermaid\nflowchart LR\n  A[Numerator] --> B[Metric]\n  C[Denominator] --> B\n```\n\n" + wide
        preview.render(html: MarkdownHTML.render(markdown), baseURL: nil, resetScroll: true, document: "/doc.md", generation: 1)
        try await waitUntil(seconds: 20) {
            guard preview.isPageLoaded else { return false }
            return try await page(preview, "var i = document.querySelector('#content img'); return !!i && i.complete && i.naturalWidth > 0 && document.querySelectorAll('.lexmd-diagram-view svg').length == 2") as? Bool == true
        }
        try await Task.sleep(for: .milliseconds(300))
        let resting = try await snapshot(preview)

        #expect(try await page(preview, "var s = document.querySelectorAll('.lexmd-diagram-view svg')[1]; return s.getBoundingClientRect().width < parseFloat(s.getAttribute('viewBox').split(' ')[2])") as? Bool == true, "the wide diagram is scaled down on the page")
        for selector in ["#content img", ".lexmd-diagram-view svg", ".lexmd-diagram:last-of-type .lexmd-diagram-view svg"] {
            #expect(try await world(preview, "return window.lexmdLightbox.showLanding(s)", ["s": selector]) as? Bool == true)
            try await Task.sleep(for: .milliseconds(300))
            #expect(try await page(preview, "return document.querySelectorAll('.lexmd-lightbox-flight').length") as? Int == 1)
            let landed = try await snapshot(preview)
            let change = difference(resting, landed)
            #expect(change.worst == 0, "\(selector): \(change.pixels) pixels differ, by up to \(change.worst)")
            // Scaled up, as at the start of closing, and back: it still lands on the page exactly.
            // A diagram's text keeps the letter spacing it was first laid out with.
            _ = try await page(preview, "document.querySelector('.lexmd-lightbox-flight').style.transform = 'translate(30px, 20px) scale(2.2)'; return true")
            try await Task.sleep(for: .milliseconds(250))
            _ = try await page(preview, "document.querySelector('.lexmd-lightbox-flight').style.transform = ''; return true")
            try await Task.sleep(for: .milliseconds(250))
            let returned = difference(resting, try await snapshot(preview))
            #expect(returned.worst == 0, "\(selector): after scaling and back, \(returned.pixels) pixels differ, by up to \(returned.worst)")
            // The harshest case for a diagram's text: laid out afresh while scaled up, then back.
            guard selector != "#content img" else {
                _ = try await world(preview, "window.lexmdLightbox.hideLanding(); return true")
                continue
            }
            _ = try await page(preview, """
                var flight = document.querySelector('.lexmd-lightbox-flight'), holder = flight.querySelector('svg').parentNode, copy = holder.firstChild;
                flight.style.transform = 'translate(30px, 20px) scale(2.2)';
                holder.removeChild(copy); flight.offsetWidth; holder.appendChild(copy); flight.offsetWidth;
                return true
                """)
            try await Task.sleep(for: .milliseconds(250))
            _ = try await page(preview, "document.querySelector('.lexmd-lightbox-flight').style.transform = ''; return true")
            try await Task.sleep(for: .milliseconds(250))
            let relaid = difference(resting, try await snapshot(preview))
            #expect(relaid.worst == 0, "\(selector): laid out while scaled, then back, \(relaid.pixels) pixels differ, by up to \(relaid.worst)")
            _ = try await world(preview, "window.lexmdLightbox.hideLanding(); return true")
            try await Task.sleep(for: .milliseconds(150))
            let after = difference(resting, try await snapshot(preview))
            #expect(after.worst == 0, "\(selector): the page differs after the hand-back")
        }
    }
}
