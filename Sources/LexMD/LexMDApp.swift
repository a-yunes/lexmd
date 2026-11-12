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
        MainMenuOrganizer.shared.start()
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
    private func item(_ action: ShortcutAction, title: String? = nil, disabled: Bool = false, perform: @escaping () -> Void) -> some View {
        Button(title ?? action.title, action: perform)
            .keyboardShortcut(model.keyboardShortcut(action))
            .disabled(disabled)
    }

    /// A checkmarked Edit menu item for one of the editor's automatic substitutions.
    private func substitutionToggle(_ title: String, _ setting: WritableKeyPath<TextSubstitutions, Bool>) -> some View {
        Toggle(title, isOn: Binding(
            get: { model.substitutions[keyPath: setting] },
            set: { model.substitutions[keyPath: setting] = $0 }
        ))
    }

    /// A checked menu item for a setting, using the user's (or default) shortcut.
    private func toggle(_ action: ShortcutAction, isOn: Binding<Bool>, disabled: Bool = false) -> some View {
        Toggle(action.title, isOn: isOn)
            .keyboardShortcut(model.keyboardShortcut(action))
            .disabled(disabled)
    }

    /// One of the three view modes. Together they read as a radio group: the current mode is
    /// checked, and choosing it again keeps it.
    private func viewMode(_ action: ShortcutAction, _ mode: ViewMode) -> some View {
        toggle(action, isOn: Binding(
            get: { model.viewMode == mode },
            set: { if $0 { model.setViewMode(mode) } }
        ), disabled: model.currentFile == nil)
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { model.updates.checkForUpdates() }
                .disabled(!model.updates.canCheck)
            if CommandLineTool.isBundled {
                item(.installCommandLineTool) { model.installCommandLineTool() }
            }
        }
        CommandGroup(replacing: .help) {
            Button(HelpWindowController.title) { HelpWindowController.shared.show() }
            SettingsTabButton("Keyboard Shortcuts", tab: .shortcuts, model: model)
            Divider()
            Button("Welcome to LexMD") { model.showOnboarding() }
            Divider()
            Button("LexMD Website") { NSWorkspace.shared.open(AppModel.websiteURL) }
            Button("Report an Issue…") { NSWorkspace.shared.open(AppModel.newIssueURL) }
        }
        CommandGroup(replacing: .newItem) {
            item(.newDocument, disabled: model.rootURL == nil) { model.newDocument() }
            item(.newFolder, disabled: model.rootURL == nil) { model.newFolder(near: model.currentFile) }
            item(.newTab) { model.newTab() }
            Divider()
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
            // The system's pasteboard group ends with Select All, so Copy as Rich Text follows it
            // directly; replacing that group would lose its responder-chain validation.
            item(.copyRichText, disabled: !model.canExport) { model.copyRichText() }
            Divider()
            Menu("Find") {
                item(.find, disabled: model.currentFile == nil) { model.showFind() }
                item(.findAndReplace, disabled: model.currentFile == nil) { model.showFind(replacing: true) }
                item(.findNext, disabled: model.currentFile == nil) { model.findNext(true) }
                item(.findPrevious, disabled: model.currentFile == nil) { model.findNext(false) }
                item(.useSelectionForFind, disabled: !model.isEditorVisible || !model.canUseSelectionForFind) {
                    model.useSelectionForFind()
                }
                item(.jumpToSelection, disabled: !model.isEditorVisible) { model.jumpToSelection() }
                Divider()
                item(.findInFiles, disabled: model.rootURL == nil) { model.toggleQuickSearch(mode: .everything) }
            }
            Menu("Spelling and Grammar") {
                Button("Show Spelling and Grammar") { NSApp.sendAction(#selector(NSText.showGuessPanel(_:)), to: nil, from: nil) }
                    .disabled(!model.canEditCurrentDocument)
                Button("Check Document Now") { NSApp.sendAction(#selector(NSText.checkSpelling(_:)), to: nil, from: nil) }
                    .disabled(!model.canEditCurrentDocument)
                Divider()
                Toggle("Check Spelling While Typing", isOn: Binding(get: { model.checksSpelling }, set: { model.checksSpelling = $0 }))
                Toggle("Check Grammar With Spelling", isOn: Binding(get: { model.checksGrammar }, set: { model.checksGrammar = $0 }))
                substitutionToggle("Correct Spelling Automatically", \.correctsSpelling)
            }
            Menu("Substitutions") {
                Button("Show Substitutions") { model.performTextCommand(#selector(NSTextView.orderFrontSubstitutionsPanel(_:))) }
                Divider()
                substitutionToggle("Smart Copy/Paste", \.smartCopyPaste)
                substitutionToggle("Smart Quotes", \.smartQuotes)
                substitutionToggle("Smart Dashes", \.smartDashes)
                substitutionToggle("Smart Links", \.smartLinks)
                substitutionToggle("Text Replacement", \.textReplacement)
            }
            .disabled(!model.isEditorVisible)
            Menu("Transformations") {
                Button("Make Upper Case") { model.performTextCommand(#selector(NSResponder.uppercaseWord(_:))) }
                Button("Make Lower Case") { model.performTextCommand(#selector(NSResponder.lowercaseWord(_:))) }
                Button("Capitalize") { model.performTextCommand(#selector(NSResponder.capitalizeWord(_:))) }
            }
            .disabled(!model.isEditorVisible)
            Menu("Speech") {
                Button("Start Speaking") { model.performTextCommand(#selector(NSTextView.startSpeaking(_:))) }
                Button("Stop Speaking") { model.performTextCommand(#selector(NSTextView.stopSpeaking(_:))) }
            }
            .disabled(!model.isEditorVisible)
        }
        CommandGroup(replacing: .saveItem) {
            item(.closeWindow) { model.closeKeyWindow() }
            item(.closeTab) { model.performCloseCommand() }
            item(.reopenClosedTab, disabled: !model.canReopenClosedTab) { model.reopenClosedTab() }
            item(.save, disabled: model.currentFile == nil) { model.saveNow() }
            Divider()
            item(.revealInFinder, disabled: model.currentFile == nil && model.rootURL == nil) { model.revealCurrentInFinder() }
            item(.renameItem, disabled: model.currentFile == nil) { model.currentFile.map(model.beginRename) }
            item(.duplicateItem, disabled: model.currentFile == nil) { model.currentFile.map(model.duplicateItem) }
            item(.moveTo, disabled: model.currentFile == nil) { model.currentFile.map(model.chooseMoveDestination) }
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
        // SidebarCommands and ToolbarCommands are left out: the first adds a second Show Sidebar
        // (⌃⌘S) that misses the trailing sidebar, and the second takes ⌥⌘T, which is Format Table.
        CommandGroup(replacing: .toolbar) {
            Button("Customize Toolbar…") { model.customizeToolbar() }
        }
        CommandGroup(before: .sidebar) {
            item(.toggleSidebar, title: model.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar") { model.toggleSidebar() }
            item(.toggleOutline, title: model.showsOutlinePanel ? "Hide Outline" : "Show Outline", disabled: !model.canShowOutline) {
                model.toggleOutline()
            }
            Divider()
            viewMode(.previewOnly, .read)
            viewMode(.split, .split)
            viewMode(.editorOnly, .edit)
            Divider()
            toggle(.focusMode, isOn: Binding(get: { model.focusMode }, set: { model.focusMode = $0 }))
            toggle(.typewriterScrolling, isOn: Binding(get: { model.typewriterScrolling }, set: { model.typewriterScrolling = $0 }))
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
        // Placed between Edit and View by MainMenuOrder.
        CommandMenu("Format") {
            let disabled = !model.canEditCurrentDocument
            item(.bold, disabled: disabled) { model.editor.wrapSelection("**", "**") }
            item(.italic, disabled: disabled) { model.editor.wrapSelection("*", "*") }
            item(.strikethrough, disabled: disabled) { model.editor.wrapSelection("~~", "~~") }
            item(.inlineCode, disabled: disabled) { model.editor.wrapSelection("`", "`") }
            item(.link, disabled: disabled) { model.editor.insertLink() }
            Divider()
            item(.formatTable, disabled: disabled) { model.editor.formatTable() }
        }
        if model.showsGitCommands {
            CommandMenu("Source Control") {
                item(.commit, disabled: !model.canCommitCurrentDocument) { model.showCommitSheet() }
            }
        }
    }
}
