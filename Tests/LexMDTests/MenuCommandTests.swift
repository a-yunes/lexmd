import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LexMD

/// The menu bar: its order, command titles and shortcuts, the help page, and the bundle's
/// document types.
@MainActor
struct MenuCommandTests {
    private func menu(_ titles: [String]) -> NSMenu {
        let menu = NSMenu(title: "Main")
        for title in titles {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: title)
            menu.addItem(item)
        }
        return menu
    }

    @Test func formatSitsBetweenEditAndView() {
        // The order SwiftUI produces: command menus follow View.
        let bar = menu(["LexMD", "File", "Edit", "View", "Go", "Format", "Source Control", "Window", "Help"])
        let formatItem = bar.items[5]
        #expect(MainMenuOrder.apply(to: bar))
        #expect(bar.items.map(\.title) == ["LexMD", "File", "Edit", "Format", "View", "Go", "Source Control", "Window", "Help"])
        #expect(bar.items[3] === formatItem, "the same item moves, so SwiftUI keeps updating it")
        #expect(!MainMenuOrder.apply(to: bar), "an ordered menu bar is left alone")
    }

    @Test func menusAddedLaterFindTheirPlace() {
        // Source Control appearing after Format was moved.
        let bar = menu(["LexMD", "File", "Edit", "Format", "Source Control", "View", "Go", "Window", "Help"])
        #expect(MainMenuOrder.apply(to: bar))
        #expect(bar.items.map(\.title) == ["LexMD", "File", "Edit", "Format", "View", "Go", "Source Control", "Window", "Help"])

        // Without Source Control, and with a menu LexMD does not know, which keeps its position.
        let other = menu(["LexMD", "File", "Edit", "View", "Debug", "Go", "Format", "Window", "Help"])
        MainMenuOrder.apply(to: other)
        #expect(other.items.map(\.title) == ["LexMD", "File", "Edit", "Format", "Debug", "View", "Go", "Window", "Help"])
    }

    @Test func menuItemsMatchedBySubmenuTitle() {
        let bar = menu(["File", "Edit", "View", "Format"])
        bar.items[3].title = ""
        MainMenuOrder.apply(to: bar)
        #expect(bar.items.map { $0.submenu?.title } == ["File", "Edit", "Format", "View"])
    }

    @Test func commandShortcutsAndTitles() {
        // Defaults the menus depend on stay as they are.
        let defaults: [ShortcutAction: String] = [
            .toggleSidebar: "cmd+b", .quickOpen: "cmd+p", .inlineCode: "cmd+e", .focusMode: "option+cmd+f",
            .formatTable: "option+cmd+t", .copyRichText: "option+cmd+c", .showNextTab: "ctrl+tab",
            .showPreviousTab: "ctrl+shift+tab", .printDocument: "option+cmd+p", .closeTab: "cmd+w",
            .closeWindow: "shift+cmd+w", .previewOnly: "cmd+1", .split: "cmd+2", .editorOnly: "cmd+3",
        ]
        for (action, shortcut) in defaults {
            #expect(action.defaultShortcut?.string == shortcut, "\(action)")
        }
        #expect(ShortcutAction.moveTo.defaultShortcut == nil)

        // Saved shortcuts are keyed by raw value, which stays when a title changes.
        #expect(ShortcutAction(rawValue: "revealInFinder") == .revealInFinder)
        #expect(ShortcutAction.revealInFinder.title == "Show in Finder")
        #expect(ShortcutAction.newTab.title == "New Tab…")
        #expect(ShortcutAction.moveTo.title == "Move To…")
        #expect(ShortcutAction.toggleSidebar.title == "Show or Hide Sidebar")
        #expect(ShortcutAction.toggleOutline.title == "Show or Hide Outline")
        for action in ShortcutAction.allCases {
            #expect(!action.title.contains("/") && !action.title.contains("—"), "\(action.title)")
            #expect(!action.title.hasSuffix("..."), "\(action.title) uses an ellipsis character")
        }
    }

    @Test func sidebarStateFollowsItsPosition() {
        let model = AppModel.shared
        let position = model.sidebarPosition, columns = model.columnVisibility, inspector = model.isInspectorPresented
        defer {
            model.sidebarPosition = position
            model.columnVisibility = columns
            model.isInspectorPresented = inspector
        }
        model.sidebarPosition = .left
        model.columnVisibility = .detailOnly
        #expect(!model.isSidebarVisible)
        model.columnVisibility = .all
        #expect(model.isSidebarVisible)
        model.sidebarPosition = .right
        model.isInspectorPresented = false
        #expect(!model.isSidebarVisible)
    }

    @Test func closingWithoutADocumentKeepsTheLastWindow() {
        func window() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            return window
        }
        let main = window(), other = window()
        #expect(!AppModel.otherWindowsRemainOpen(besides: main, in: [main, other]), "the other window is not open")
        other.alphaValue = 0
        other.orderFrontRegardless()
        defer { other.orderOut(nil) }
        #expect(AppModel.otherWindowsRemainOpen(besides: main, in: [main, other]))
        #expect(!AppModel.otherWindowsRemainOpen(besides: main, in: [main]))
    }

    @Test func helpPageIsBundledAndItsContentsLinkToItsSections() throws {
        let url = try #require(HelpPage.fileURL)
        let markdown = try String(contentsOf: url, encoding: .utf8)
        #expect(!markdown.contains("—"))
        let html = try #require(HelpPage.html())
        #expect(!html.contains("<script"))
        let links = try NSRegularExpression(pattern: #"\]\(#([a-z0-9-]+)\)"#)
            .matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown))
            .compactMap { Range($0.range(at: 1), in: markdown).map { String(markdown[$0]) } }
        #expect(links.count >= 8)
        for anchor in links {
            #expect(html.contains("id=\"\(anchor)\""), "\(anchor)")
        }
        for topic in ["Open Quickly", "Export as PDF", "Commit", "Quick Look", "lexmd", "Keyboard Shortcuts", "Tabs", "Outline"] {
            #expect(markdown.contains(topic), "\(topic)")
        }
    }

    @Test func infoPlistDeclaresEveryMarkdownExtension() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let plist = try #require(NSDictionary(contentsOf: plistURL) as? [String: Any])
        #expect(plist["NSHumanReadableCopyright"] as? String == "© 2026 Aleksei Iunes")

        let imported = try #require(plist["UTImportedTypeDeclarations"] as? [[String: Any]])
        let markdown = try #require(imported.first { $0["UTTypeIdentifier"] as? String == "net.daringfireball.markdown" })
        let tags = try #require(markdown["UTTypeTagSpecification"] as? [String: Any])
        let declared = try #require(tags["public.filename-extension"] as? [String])
        #expect(Set(declared) == Set(FileScanner.markdownExtensions))

        let types = try #require(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let document = try #require(types.first { ($0["LSItemContentTypes"] as? [String])?.contains("net.daringfireball.markdown") == true })
        #expect(Set(document["CFBundleTypeExtensions"] as? [String] ?? []) == Set(FileScanner.markdownExtensions))
    }
}
