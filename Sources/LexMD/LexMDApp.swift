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
        AppModel.shared.open(urls)
    }

    /// Finder service: "Open in LexMD" for folders and Markdown files.
    @objc func openInLexMD(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        AppModel.shared.open(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Text that can't be saved is never dropped silently: quitting asks about it first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        model.saveAllTabs()
        guard !model.unsavedDocuments().isEmpty else { return .terminateNow }
        model.settleUnsavedText(before: "quit") { proceed in
            DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: proceed) }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.saveAllTabs()
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
            item(.installCommandLineTool) { model.installCommandLineTool() }
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
            item(.copyRichText, disabled: !model.canExport) { model.copyRichText() }
            Divider()
            Menu("Spelling and Grammar") {
                Button("Show Spelling and Grammar") { NSApp.sendAction(#selector(NSText.showGuessPanel(_:)), to: nil, from: nil) }
                Button("Check Document Now") { NSApp.sendAction(#selector(NSText.checkSpelling(_:)), to: nil, from: nil) }
                Divider()
                Toggle("Check Spelling While Typing", isOn: Binding(get: { model.checksSpelling }, set: { model.checksSpelling = $0 }))
                Toggle("Check Grammar With Spelling", isOn: Binding(get: { model.checksGrammar }, set: { model.checksGrammar = $0 }))
            }
            Menu("Find") {
                item(.find) { model.showFind() }
                item(.findNext) { model.findNext(true) }
                item(.findPrevious) { model.findNext(false) }
                Divider()
                item(.findInFiles, disabled: model.rootURL == nil) { model.toggleQuickSearch(mode: .everything) }
            }
        }
        CommandGroup(replacing: .saveItem) {
            item(.newTab) { model.newTab() }
            item(.closeTab) { model.performCloseCommand() }
            item(.reopenClosedTab, disabled: !model.canReopenClosedTab) { model.reopenClosedTab() }
            Divider()
            item(.save) { model.saveNow() }
            Divider()
            item(.revealInFinder) { model.revealCurrentInFinder() }
            item(.renameItem, disabled: model.currentFile == nil) { model.currentFile.map(model.beginRename) }
            item(.duplicateItem, disabled: model.currentFile == nil) { model.currentFile.map(model.duplicateItem) }
            item(.moveToTrash, disabled: model.currentFile == nil) { model.currentFile.map(model.confirmMoveToTrash) }
            Divider()
            item(.exportPDF, disabled: !model.canExport) { model.exportPDF() }
            item(.exportHTML, disabled: !model.canExport) { model.exportHTML() }
        }
        CommandGroup(replacing: .printItem) {
            item(.printDocument, disabled: !model.canExport) { model.printDocument() }
        }
        CommandGroup(before: .windowArrangement) {
            item(.showPreviousTab, disabled: model.tabStore.list.count < 2) { model.showPreviousTab() }
            item(.showNextTab, disabled: model.tabStore.list.count < 2) { model.showNextTab() }
            Divider()
        }
        CommandGroup(before: .sidebar) {
            item(.toggleSidebar) { model.toggleSidebar() }
            item(.toggleOutline, disabled: !model.canShowOutline) { model.toggleOutline() }
            Divider()
            item(.previewOnly) { model.setViewMode(.read) }
            item(.split) { model.setViewMode(.split) }
            item(.editorOnly) { model.setViewMode(.edit) }
            Divider()
            Toggle(ShortcutAction.focusMode.title, isOn: Binding(get: { model.focusMode }, set: { model.focusMode = $0 }))
                .keyboardShortcut(model.keyboardShortcut(.focusMode))
            Toggle(ShortcutAction.typewriterScrolling.title, isOn: Binding(
                get: { model.typewriterScrolling }, set: { model.typewriterScrolling = $0 }
            ))
            .keyboardShortcut(model.keyboardShortcut(.typewriterScrolling))
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
            Divider()
            item(.formatTable) { model.editor.formatTable() }
        }
        if model.showsGitCommands {
            CommandMenu("Source Control") {
                item(.commit, disabled: !model.canCommitCurrentDocument) { model.showCommitSheet() }
            }
        }
    }
}
