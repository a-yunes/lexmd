import AppKit
import LexMDRendering
import WebKit

// MARK: - Menu order

/// Keeps the menu bar in the standard macOS order. SwiftUI adds every `CommandMenu` after View,
/// so Format would otherwise sit after View and Go instead of between Edit and View.
@MainActor
enum MainMenuOrder {
    /// The order of the menus LexMD shows, after the app menu.
    static let titles = ["File", "Edit", "Format", "View", "Go", "Source Control", "Window", "Help"]

    private static func rank(_ item: NSMenuItem) -> Int? {
        titles.firstIndex(of: item.title) ?? item.submenu.flatMap { titles.firstIndex(of: $0.title) }
    }

    /// Moves the menus named in `titles` into that order within the places they already occupy,
    /// leaving other menus where they are. Returns whether anything moved.
    @discardableResult
    static func apply(to menu: NSMenu) -> Bool {
        let items = menu.items
        let slots = items.indices.filter { rank(items[$0]) != nil }
        let current = slots.map { items[$0] }
        let sorted = current.enumerated()
            .sorted { (rank($0.element) ?? 0, $0.offset) < (rank($1.element) ?? 0, $1.offset) }
            .map(\.element)
        guard zip(current, sorted).contains(where: { $0 !== $1 }) else { return false }
        var target = items
        for (slot, item) in zip(slots, sorted) { target[slot] = item }
        // Move only the items out of place, one at a time, so menus already in order stay put.
        for (index, item) in target.enumerated() where menu.items[index] !== item {
            menu.removeItem(item)
            menu.insertItem(item, at: index)
        }
        return true
    }
}

/// Reapplies `MainMenuOrder` whenever SwiftUI builds or changes the main menu, such as when the
/// Source Control menu appears. Changes are coalesced into one pass on the next run loop turn.
@MainActor
final class MainMenuOrganizer {
    static let shared = MainMenuOrganizer()

    private var observers: [NSObjectProtocol] = []
    private var mainMenuObservation: NSKeyValueObservation?
    private var isScheduled = false

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let menu = note.object as? NSMenu
                MainActor.assumeIsolated {
                    guard let menu, menu === NSApp.mainMenu else { return }
                    self?.schedule()
                }
            })
        }
        mainMenuObservation = NSApp.observe(\.mainMenu) { [weak self] _, _ in
            DispatchQueue.main.async { self?.schedule() }
        }
        schedule()
    }

    private func schedule() {
        guard !isScheduled else { return }
        isScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.isScheduled = false
            if let menu = NSApp.mainMenu { MainMenuOrder.apply(to: menu) }
        }
    }
}

// MARK: - Help

/// The help page bundled from `Resources/Help`, shown offline in its own window.
enum HelpPage {
    static let fileName = "LexMD Help.md"

    static var fileURL: URL? {
        for candidate in VendorAssets.bundleCandidates() {
            guard let base = candidate?.appendingPathComponent(VendorAssets.bundleName), let bundle = Bundle(url: base),
                  let resources = bundle.resourceURL else { continue }
            let url = resources.appendingPathComponent("Help", isDirectory: true).appendingPathComponent(fileName)
            if FileManager.default.isReadableFile(atPath: url.path) { return url }
        }
        return nil
    }

    /// The page rendered with the preview's styles and no scripts, as Quick Look shows documents.
    static func html() -> String? {
        fileURL.flatMap { try? QuickLookPage.make(contentsOf: $0).html }
    }
}

/// The LexMD Help window. Links within the page scroll to their section; web links open in the
/// default browser, since only the user can follow them.
@MainActor
final class HelpWindowController: NSObject, WKNavigationDelegate {
    static let shared = HelpWindowController()
    static let title = "LexMD Help"

    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let html = HelpPage.html() else { NSSound.beep(); return }
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let frame = NSRect(x: 0, y: 0, width: 760, height: 820)
        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.navigationDelegate = self
        webView.loadHTMLString(html, baseURL: nil)

        let window = NSWindow(
            contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = Self.title
        window.contentView = webView
        window.contentMinSize = NSSize(width: 420, height: 320)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        if !window.setFrameUsingName("LexMDHelp") { window.center() }
        window.setFrameAutosaveName("LexMDHelp")
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        // The page itself and its in-page links (about:blank#section).
        if url.scheme == "about" { return .allow }
        if navigationAction.navigationType == .linkActivated, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }
}

// MARK: - Commands

extension AppModel {
    static let websiteURL = URL(string: "https://github.com/a-yunes/lexmd")!
    static let newIssueURL = URL(string: "https://github.com/a-yunes/lexmd/issues/new")!

    /// Whether the file sidebar is showing, wherever it is placed.
    var isSidebarVisible: Bool {
        sidebarPosition == .right ? isInspectorPresented : columnVisibility != .detailOnly
    }

    /// Format commands and spell checking act on the editor, so they need it on screen.
    var canEditCurrentDocument: Bool { currentFile != nil && viewMode != .read }

    /// Whether closing `window` leaves another window open, so LexMD keeps running.
    static func otherWindowsRemainOpen(besides window: NSWindow, in windows: [NSWindow]) -> Bool {
        windows.contains { $0 !== window && $0.isVisible && $0.canBecomeMain && $0.sheetParent == nil }
    }

    /// Close Window: closes the key window, unless a sheet in it is waiting for an answer.
    func closeKeyWindow() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { NSSound.beep(); return }
        guard window.sheetParent == nil, window.attachedSheet == nil else { NSSound.beep(); return }
        if window === editor.scrollView.window { saveNow() }
        window.performClose(nil)
    }

    /// Opens the toolbar's customization sheet when the window's toolbar allows it.
    func customizeToolbar() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, window.toolbar?.allowsUserCustomization == true else {
            NSSound.beep()
            return
        }
        window.runToolbarCustomizationPalette(nil)
    }
}
