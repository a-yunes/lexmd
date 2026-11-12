import AppKit
import SwiftUI

@main
struct LexMDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    init() {
        // Overlay scroll bars that appear only while scrolling, for LexMD only.
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
    }

    var body: some Scene {
        Window("LexMD", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 1380, height: 880)
        .windowToolbarStyle(.unified)
        .commands { LexMDCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.applyAppearance()
        AppModel.shared.updates.start()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        AppModel.shared.open(url)
    }

    /// Finder service: "Open in LexMD" for folders and Markdown files.
    @objc func openInLexMD(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard let url = urls.first else { return }
        NSApp.activate(ignoringOtherApps: true)
        AppModel.shared.open(url)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.saveNow()
    }

    func applicationWillResignActive(_ notification: Notification) {
        AppModel.shared.saveNow()
    }
}

struct LexMDCommands: Commands {
    let model: AppModel

    /// A menu button for a command, using the user's (or default) shortcut.
    private func item(_ action: ShortcutAction, disabled: Bool = false, perform: @escaping () -> Void) -> some View {
        Button(action.title, action: perform)
            .keyboardShortcut(model.keyboardShortcut(action))
            .disabled(disabled)
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { model.updates.checkForUpdates() }
                .disabled(!model.updates.canCheck)
        }
        CommandGroup(replacing: .help) {
            Button("Welcome to LexMD") { model.showOnboarding() }
            Button("LexMD on GitHub") {
                if let url = URL(string: "https://github.com/a-yunes/lexmd") { NSWorkspace.shared.open(url) }
            }
        }
        CommandGroup(replacing: .newItem) {
            item(.newDocument, disabled: model.rootURL == nil) { model.newDocument() }
            item(.newFolder, disabled: model.rootURL == nil) { model.newFolder(near: model.currentFile) }
            item(.open) { model.showOpenPanel() }
            item(.quickOpen, disabled: model.rootURL == nil) { model.toggleQuickSearch(mode: .files) }
            Menu("Open Recent") {
                ForEach(model.recentFolders, id: \.self) { path in
                    Button((path as NSString).abbreviatingWithTildeInPath) {
                        model.open(URL(fileURLWithPath: path, isDirectory: true))
                    }
                }
                if !model.recentFolders.isEmpty {
                    Divider()
                    Button("Clear Menu") { model.clearRecentFolders() }
                }
            }
            .disabled(model.recentFolders.isEmpty)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Menu("Find") {
                item(.find) { model.showFind() }
                item(.findNext) { model.findNext(true) }
                item(.findPrevious) { model.findNext(false) }
                Divider()
                item(.findInFiles, disabled: model.rootURL == nil) { model.toggleQuickSearch(mode: .everything) }
            }
        }
        CommandGroup(replacing: .saveItem) {
            item(.closeTab) { model.performCloseCommand() }
            item(.reopenClosedTab, disabled: !model.canReopenClosedTab) { model.reopenClosedTab() }
            Divider()
            item(.save) { model.saveNow() }
            Divider()
            item(.revealInFinder) { model.revealCurrentInFinder() }
            item(.renameItem, disabled: model.currentFile == nil) { model.currentFile.map(model.beginRename) }
            item(.duplicateItem, disabled: model.currentFile == nil) { model.currentFile.map(model.duplicateItem) }
            item(.moveToTrash, disabled: model.currentFile == nil) { model.currentFile.map(model.confirmMoveToTrash) }
        }
        CommandGroup(before: .windowArrangement) {
            item(.showPreviousTab, disabled: model.tabStore.list.count < 2) { model.showPreviousTab() }
            item(.showNextTab, disabled: model.tabStore.list.count < 2) { model.showNextTab() }
            Divider()
        }
        CommandGroup(before: .sidebar) {
            item(.toggleSidebar) { model.toggleSidebar() }
            Divider()
            item(.previewOnly) { model.setViewMode(.read) }
            item(.split) { model.setViewMode(.split) }
            item(.editorOnly) { model.setViewMode(.edit) }
            Divider()
            Toggle("Compact Single-Item Folders", isOn: Binding(
                get: { model.compactFolders },
                set: { model.compactFolders = $0 }
            ))
            item(.expandAll, disabled: !model.canToggleAllFolders) { model.setAllFoldersExpanded(true) }
            item(.collapseAll, disabled: !model.canToggleAllFolders) { model.setAllFoldersExpanded(false) }
            Divider()
            item(.zoomIn) { model.zoom(by: 1) }
            item(.zoomOut) { model.zoom(by: -1) }
            item(.zoomReset) { model.zoom(by: 0) }
            Divider()
        }
        CommandMenu("Go") {
            item(.goBack, disabled: !model.canGoBack) { model.goBack() }
            item(.goForward, disabled: !model.canGoForward) { model.goForward() }
        }
        CommandMenu("Format") {
            item(.bold) { model.editor.wrapSelection("**", "**") }
            item(.italic) { model.editor.wrapSelection("*", "*") }
            item(.strikethrough) { model.editor.wrapSelection("~~", "~~") }
            item(.inlineCode) { model.editor.wrapSelection("`", "`") }
            item(.link) { model.editor.insertLink() }
        }
    }
}
