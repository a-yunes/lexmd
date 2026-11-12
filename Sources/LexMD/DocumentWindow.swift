import AppKit
import Quartz
import SwiftUI

// MARK: - Document path

/// The folders that contain a document, as the title's path menu lists them.
enum DocumentPath {
    /// The item itself first, then each enclosing folder up to the root of the file system.
    static func components(of url: URL) -> [URL] {
        var result: [URL] = []
        var current = url.standardizedFileURL
        while true {
            result.append(current)
            guard current.path != "/" else { break }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path || parent.path.isEmpty { break }
            current = parent
        }
        return result
    }

    /// What Finder calls the item, such as the volume name for "/".
    static func displayName(of url: URL) -> String {
        FileManager.default.displayName(atPath: url.path)
    }

    /// Shows a path menu choice in Finder: the document itself, or a folder with the item
    /// inside it selected.
    static func reveal(_ index: Int, of components: [URL]) {
        guard components.indices.contains(index) else { return }
        let target = index == 0 ? components[0] : components[index - 1]
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
}

// MARK: - Proxy icon

/// The document's icon beside the window title. Drag it to copy or link the file elsewhere,
/// and Command-click or Control-click it for the folders that contain it.
struct DocumentProxyIcon: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> DocumentProxyView { DocumentProxyView() }

    func updateNSView(_ view: DocumentProxyView, context: Context) {
        view.url = url
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DocumentProxyView, context: Context) -> CGSize? {
        CGSize(width: 16, height: 16)
    }
}

final class DocumentProxyView: NSView, NSDraggingSource {
    var url: URL? {
        didSet {
            guard url != oldValue else { return }
            icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            let name = url.map(DocumentPath.displayName(of:)) ?? ""
            setAccessibilityLabel(name.isEmpty ? "Document" : "Document \(name)")
            toolTip = url.map { ($0.path as NSString).abbreviatingWithTildeInPath }
            needsDisplay = true
        }
    }
    private var icon: NSImage?
    private var mouseDownEvent: NSEvent?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityHelp("Drag to copy the document. Show the menu for the folders that contain it.")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        icon?.draw(in: bounds)
    }

    override func mouseDown(with event: NSEvent) {
        if !event.modifierFlags.intersection([.command, .control]).isEmpty {
            showPathMenu()
        } else {
            mouseDownEvent = event
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let url, let down = mouseDownEvent else { return }
        let start = down.locationInWindow
        let now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) >= 3 else { return }
        mouseDownEvent = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: icon)
        beginDraggingSession(with: [item], event: down, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? { pathMenu() }

    override func accessibilityPerformShowMenu() -> Bool {
        showPathMenu()
        return true
    }

    /// Other apps may copy or link the document but never move it out of the project.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link] : [.copy, .move, .generic]
    }

    private func showPathMenu() {
        guard let menu = pathMenu() else { return }
        menu.popUp(positioning: menu.items.first, at: NSPoint(x: 0, y: bounds.maxY), in: self)
    }

    private func pathMenu() -> NSMenu? {
        guard let url else { return nil }
        let components = DocumentPath.components(of: url)
        let menu = NSMenu()
        for (index, component) in components.enumerated() {
            let item = NSMenuItem(title: DocumentPath.displayName(of: component), action: #selector(revealComponent(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.representedObject = components
            let image = NSWorkspace.shared.icon(forFile: component.path)
            image.size = NSSize(width: 16, height: 16)
            item.image = image
            menu.addItem(item)
        }
        return menu
    }

    @objc private func revealComponent(_ sender: NSMenuItem) {
        guard let components = sender.representedObject as? [URL] else { return }
        DocumentPath.reveal(sender.tag, of: components)
    }
}

// MARK: - Window

/// Connects the window to the open document: its represented file (for the Window menu and
/// assistive apps) and the sidebar's Quick Look panel.
struct WindowDocumentBridge: NSViewRepresentable {
    let url: URL?

    func makeNSView(context: Context) -> WindowDocumentView { WindowDocumentView() }

    func updateNSView(_ view: WindowDocumentView, context: Context) {
        view.url = url
    }
}

final class WindowDocumentView: NSView {
    var url: URL? {
        didSet { if url != oldValue { apply() } }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func apply() {
        guard let window else { return }
        if window.representedURL != url { window.representedURL = url }
        SidebarQuickLook.shared.attach(to: window)
    }
}

// MARK: - Quick Look

/// The Quick Look panel for files in the sidebar, as Space shows it in Finder. It sits in the
/// window's responder chain so the shared panel can find it.
final class SidebarQuickLook: NSResponder, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    @MainActor static let shared = SidebarQuickLook()

    private var url: URL?
    /// The sidebar list, which keeps handling arrow keys while the panel is in front.
    private weak var source: NSResponder?

    @MainActor var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    /// Shows the panel for the file, or closes it if it is open.
    @MainActor func toggle(_ url: URL) {
        if isVisible {
            QLPreviewPanel.shared().orderOut(nil)
            return
        }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        attach(to: window)
        self.url = url
        source = window.firstResponder
        QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
    }

    /// Follows the sidebar selection while the panel is open.
    @MainActor func selectionChanged(to path: String?) {
        guard isVisible, let path, url?.path != path, QLPreviewPanel.shared().dataSource === self else { return }
        url = URL(fileURLWithPath: path)
        QLPreviewPanel.shared().reloadData()
    }

    /// Inserts this object after the window in its responder chain, once.
    @MainActor func attach(to window: NSWindow) {
        var responder = window.nextResponder
        while let next = responder {
            if next === self { return }
            responder = next.nextResponder
        }
        nextResponder = window.nextResponder
        window.nextResponder = self
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { url != nil }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        url.map { $0 as NSURL }
    }

    /// Arrow keys move the sidebar selection, and the Quick Look shortcut closes the panel.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        return MainActor.assumeIsolated {
            if let shortcut = AppModel.shared.shortcut(for: .quickLookInSidebar),
               Shortcut(event: event, allowingPlainKeys: true) == shortcut {
                panel.orderOut(nil)
                return true
            }
            if [125, 126].contains(event.keyCode), let source {
                source.keyDown(with: event)
                return true
            }
            return false
        }
    }
}

extension AppModel {
    /// The file Quick Look shows: the sidebar selection, or else the open document.
    var quickLookTarget: URL? {
        (selectedPath ?? currentFile?.path).map { URL(fileURLWithPath: $0) }
    }

    /// File > Quick Look: shows or closes the panel for the sidebar selection.
    func quickLookSelection() {
        guard let url = quickLookTarget else { NSSound.beep(); return }
        SidebarQuickLook.shared.toggle(url)
    }
}
