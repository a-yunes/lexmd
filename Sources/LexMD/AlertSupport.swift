import AppKit

// Alert buttons and sheet presentation shared by every alert and file panel in the app.
//
// Conventions: the first button added is the rightmost one and takes Return, unless it is
// destructive; AppKit never gives Return to a destructive button, so neither do these helpers.
// Every alert with a choice has a button that Escape triggers, usually Cancel.

extension NSAlert {
    /// The Escape key equivalent.
    static let escapeKey = "\u{1b}"

    /// Adds a button that Escape triggers: Cancel, or a refusal such as Don’t Update.
    @discardableResult
    func addCancelButton(_ title: String = "Cancel") -> NSButton {
        let button = addButton(withTitle: title)
        button.keyEquivalent = Self.escapeKey
        return button
    }

    /// Adds a button for an action that loses data or can’t be easily undone. It is never the
    /// default, so Return can’t trigger it by accident.
    @discardableResult
    func addDestructiveButton(_ title: String) -> NSButton {
        let button = addButton(withTitle: title)
        button.hasDestructiveAction = true
        if button.keyEquivalent == "\r" { button.keyEquivalent = "" }
        return button
    }

    /// Makes `button` the default, taking Return from any other button.
    func makeDefault(_ button: NSButton) {
        for other in buttons where other !== button && other.keyEquivalent == "\r" { other.keyEquivalent = "" }
        button.keyEquivalent = "\r"
    }
}

extension AppModel {
    /// The window that alerts and file panels attach to as sheets.
    var sheetWindow: NSWindow? { NSApp?.keyWindow ?? NSApp?.mainWindow }

    /// Shows an alert as a sheet on the window, or modally when no window is open.
    func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        presentSheet { alert.beginSheetModal(for: $0, completionHandler: completion) } modal: {
            completion(alert.runModal())
        }
    }

    /// Shows an Open or Save panel as a sheet on the window, or modally when no window is open.
    func present(_ panel: NSSavePanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        presentSheet { panel.beginSheetModal(for: $0, completionHandler: completion) } modal: {
            completion(panel.runModal())
        }
    }

    /// Begins a sheet. Called from another sheet’s completion handler, that sheet may still be on
    /// screen, so the new one starts on the next turn of the run loop, once the first has ended.
    private func presentSheet(_ begin: @escaping (NSWindow) -> Void, modal: @escaping () -> Void) {
        if let key = NSApp?.keyWindow, key.isSheet || key.attachedSheet != nil {
            Task { @MainActor [weak self] in self?.beginSheet(begin, modal: modal) }
        } else {
            beginSheet(begin, modal: modal)
        }
    }

    private func beginSheet(_ begin: (NSWindow) -> Void, modal: () -> Void) {
        if let window = sheetWindow { begin(window) } else { modal() }
    }
}
