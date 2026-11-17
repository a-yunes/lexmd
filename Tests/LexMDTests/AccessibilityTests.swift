import AppKit
import Foundation
import Testing
import WebKit
@testable import LexMD
@testable import LexMDRendering

/// Reduce Motion, contrast, names for assistive technologies, and pinch zoom.
struct AccessibilitySettingsTests {
    @Test func pinchTurnsIntoTextSizeSteps() {
        var pinch = PinchSteps()
        #expect(pinch.steps(adding: 0.05, phase: .began) == 0)
        #expect(pinch.steps(adding: 0.05, phase: .changed) == 0)
        #expect(pinch.steps(adding: 0.05, phase: .changed) == 1, "0.15 passes one step and keeps the rest")
        #expect(pinch.steps(adding: 0.10, phase: .changed) == 1)
        #expect(pinch.steps(adding: -0.30, phase: .changed) == -2)
        #expect(pinch.steps(adding: 0.05, phase: .ended) == 0)
        // A new gesture starts from nothing, whatever the last one left over.
        #expect(pinch.steps(adding: 0.11, phase: .began) == 0)
        #expect(pinch.steps(adding: 0.5, phase: .changed) == 5)
    }

    @Test func pageLanguage() {
        #expect(MarkdownHTML.languageTag(preferred: ["de-CH", "en"]) == "de-CH")
        #expect(MarkdownHTML.languageTag(preferred: ["zh-Hans-CN"]) == "zh-Hans-CN")
        #expect(MarkdownHTML.languageTag(preferred: []) == "en")
        #expect(MarkdownHTML.languageTag(preferred: ["en\"><script>"]) == "en")
        #expect(MarkdownHTML.languageTag(preferred: ["fr_FR"]) == "en")
        let html = PreviewTemplate.html(allowsRemoteContent: false)
        #expect(html.contains("<html lang=\"\(MarkdownHTML.languageTag())\">"))
        #expect(html.contains("<title></title>"))
    }

    @Test func reducedMotionAnimatesNothing() {
        #expect(Motion.animation(.snappy, reduced: true) == nil)
        #expect(Motion.animation(.snappy, reduced: false) != nil)
        #expect(PreviewTemplate.script.contains("matchMedia('(prefers-reduced-motion: reduce)')"))
        #expect(!PreviewTemplate.script.contains("behavior: 'smooth'"), "smooth scrolling goes through the Reduce Motion check")
    }

    /// Text in the preview's tertiary color stays readable: 4.5:1 on the window background and on code blocks.
    @Test func tertiaryTextContrast() throws {
        let values = PreviewStyle.page.components(separatedBy: "--tertiary: ").dropFirst().map { String($0.prefix(7)) }
        #expect(values.count == 5, "light, dark, Increase Contrast (light and dark), and print")
        let light = try #require(values.first), dark = values[1]
        #expect(contrast(light, "#ffffff") >= 4.5)
        #expect(contrast(light, "#f8f8f8") >= 4.5)
        #expect(contrast(dark, "#1e1e1e") >= 4.5)
        #expect(contrast(dark, "#262626") >= 4.5)
        #expect(contrast(values[2], "#ffffff") >= 7)
        #expect(contrast(values[3], "#1e1e1e") >= 7)
    }

    private func contrast(_ a: String, _ b: String) -> Double {
        func luminance(_ hex: String) -> Double {
            let value = Int(hex.dropFirst(), radix: 16) ?? 0
            func linear(_ shift: Int) -> Double {
                let c = Double((value >> shift) & 0xff) / 255
                return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            let red = 0.2126 * linear(16), green = 0.7152 * linear(8), blue = 0.0722 * linear(0)
            return red + green + blue
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    @MainActor
    @Test func editorHasAName() {
        let editor = EditorController()
        #expect(editor.textView.accessibilityLabel() == "Editor")
        #expect(editor.textView.accessibilityIdentifier() == "editor")
    }
}

/// The preview's accessibility behavior in the real web view.
@MainActor
@Suite(.serialized)
struct PreviewAccessibilityTests {
    private func makePreview() -> (PreviewController, NSWindow) {
        let preview = PreviewController(allowsRemoteContent: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = preview.webView
        return (preview, window)
    }

    @Test func pageIsNamedAndKeyboardReachable() async throws {
        let (preview, window) = makePreview()
        defer { window.contentView = nil }
        #expect(preview.webView.accessibilityLabel() == "Preview")
        #expect(preview.webView.accessibilityIdentifier() == "preview")
        #expect(preview.webView.configuration.preferences.tabFocusesLinks)

        preview.setDocumentTitle("Release Notes")
        preview.render(html: MarkdownHTML.render("# Notes\n\n```swift\nlet x = 1\n```\n"), baseURL: nil, resetScroll: true)
        try await waitUntil { try await page(preview, "return document.querySelector('.codeblock .copy') !== null") as? Bool == true }
        #expect(try await page(preview, "return document.title") as? String == "Release Notes")
        #expect(try await page(preview, "return document.documentElement.lang") as? String == MarkdownHTML.languageTag())
        preview.setDocumentTitle("Other")
        try await waitUntil { try await page(preview, "return document.title") as? String == "Other" }

        // The Copy button shows while it or its code block has keyboard focus. (A test window is
        // never key, so the page cannot take focus; the parsed rule stands in for it.)
        #expect(try await page(preview, "return getComputedStyle(document.querySelector('.codeblock .copy')).opacity") as? String == "0")
        let focusRule = """
        for (var s of document.styleSheets) for (var r of s.cssRules) {
          var t = r.selectorText || '';
          if (t.indexOf('.codeblock:focus-within .copy') >= 0 && t.indexOf('.codeblock .copy:focus-visible') >= 0) return r.style.opacity;
        }
        return null
        """
        #expect(try await page(preview, focusRule) as? String == "1")
        #expect(try await page(preview, "return document.querySelector('.codeblock .copy').tabIndex") as? Int == 0)
    }

    @Test func linksCarryMoreThanColor() async throws {
        let (preview, window) = makePreview()
        defer { window.contentView = nil }
        preview.setDifferentiatesWithoutColor(false)
        let html = "<p><a id=\"plain\" href=\"#x\">plain</a> <a id=\"broken\" class=\"lexmd-broken\" href=\"gone.md\">gone</a></p>"
        preview.render(html: html, baseURL: nil, resetScroll: true)
        try await waitUntil { try await page(preview, "return document.getElementById('plain') !== null") as? Bool == true }
        let line = "return getComputedStyle(document.getElementById(id)).textDecorationLine"
        let style = "return getComputedStyle(document.getElementById(id)).textDecorationStyle"
        // Without Increase Contrast (the test machine's default), links rely on color alone.
        let contrast = try await page(preview, "return matchMedia('(prefers-contrast: more)').matches") as? Bool == true
        if !contrast { #expect(try await page(preview, line, ["id": "plain"]) as? String == "none") }

        preview.setDifferentiatesWithoutColor(true)
        try await waitUntil { try await page(preview, line, ["id": "plain"]) as? String == "underline" }
        #expect(try await page(preview, "return document.documentElement.classList.contains('lexmd-differentiate')") as? Bool == true)
        #expect(try await page(preview, style, ["id": "broken"]) as? String == "wavy", "broken links keep their own underline")

        preview.setDifferentiatesWithoutColor(false)
        try await waitUntil { try await page(preview, "return document.documentElement.classList.contains('lexmd-differentiate')") as? Bool == false }
    }

    /// Increase Contrast rules parse and cover links, borders, and secondary text.
    @Test func increaseContrastRules() async throws {
        let (preview, window) = makePreview()
        defer { window.contentView = nil }
        preview.render(html: "<p>x</p>", baseURL: nil, resetScroll: true)
        try await waitUntil { try await page(preview, "return document.querySelector('#content p') !== null") as? Bool == true }
        let rules = """
        var found = [];
        for (var s of document.styleSheets) for (var r of s.cssRules) {
          if (r.media && r.media.mediaText.indexOf('prefers-contrast: more') >= 0)
            for (var inner of r.cssRules) found.push(inner.selectorText || '');
        }
        return found.join('|')
        """
        let selectors = try #require(try await page(preview, rules) as? String)
        #expect(selectors.contains("a:not(.lexmd-broken)"))
        #expect(selectors.contains(".codeblock"))
        #expect(selectors.contains(":root"))
    }
}
