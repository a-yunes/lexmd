import AppKit
import SwiftUI

/// The tabs of the Settings window. The raw value is saved to reopen Settings where it was left.
enum SettingsTab: String, CaseIterable {
    case general, editor, preview, sourceControl, shortcuts, updates

    static let defaultsKey = "settingsTab"

    /// The tab Settings shows: Source Control appears only while a project is in a Git
    /// repository, and General stands in for it otherwise.
    func resolved(showsSourceControl: Bool) -> SettingsTab {
        self == .sourceControl && !showsSourceControl ? .general : self
    }
}

extension AppModel {
    /// Opens Settings on `tab`. Views get `openSettings` from `@Environment(\.openSettings)`.
    func showSettings(_ tab: SettingsTab, using openSettings: OpenSettingsAction) {
        settingsTab = tab
        openSettings()
    }
}

/// A button that opens Settings on a given tab, for menus and views alike.
struct SettingsTabButton: View {
    let title: String
    let tab: SettingsTab
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    init(_ title: String, tab: SettingsTab, model: AppModel) {
        self.title = title
        self.tab = tab
        self.model = model
    }

    var body: some View {
        Button(title) { model.showSettings(tab, using: openSettings) }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let selection = Binding(
            get: { model.settingsTab.resolved(showsSourceControl: model.git.isActive) },
            set: { model.settingsTab = $0 }
        )
        TabView(selection: selection) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) {
                GeneralSettings()
            }
            Tab("Editor", systemImage: "square.and.pencil", value: SettingsTab.editor) {
                EditorSettings()
            }
            Tab("Preview", systemImage: "doc.richtext", value: SettingsTab.preview) {
                PreviewSettings()
            }
            if model.git.isActive {
                Tab("Source Control", systemImage: "arrow.triangle.branch", value: SettingsTab.sourceControl) {
                    SourceControlSettings()
                }
            }
            Tab("Shortcuts", systemImage: "command", value: SettingsTab.shortcuts) {
                ShortcutSettings()
            }
            Tab("Updates", systemImage: "arrow.triangle.2.circlepath", value: SettingsTab.updates) {
                UpdateSettings()
            }
        }
        .frame(width: 540)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Appearance", selection: $model.appearanceMode) {
                    Text("System").tag(AppearanceMode.system)
                    Text("Light").tag(AppearanceMode.light)
                    Text("Dark").tag(AppearanceMode.dark)
                }
                .pickerStyle(.segmented)
            }
            Section("Sidebar") {
                Picker("Position", selection: $model.sidebarPosition) {
                    Label("Left", systemImage: "sidebar.leading").tag(SidebarPosition.left)
                    Label("Right", systemImage: "sidebar.trailing").tag(SidebarPosition.right)
                }
                .pickerStyle(.segmented)
                Toggle(isOn: $model.compactFolders) {
                    Text("Compact single-item folders")
                    Text("A folder that holds just one item is merged into it, so a lone README.md inside “guides” shows as one row: guides › README.")
                }
            }
            Section("Tabs") {
                Toggle(isOn: Binding(get: { model.tabStore.alwaysShowTabBar }, set: { model.tabStore.alwaysShowTabBar = $0 })) {
                    Text("Always show tab bar")
                    Text("Shows the tab bar even when only one document is open.")
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PreviewSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle(isOn: $model.loadsRemoteContent) {
                    Text("Load images from the web")
                    Text("Images and videos hosted online load from their servers, which can see when you open a document. Local images always show.")
                }
                Toggle(isOn: $model.marksBrokenLinks) {
                    Text("Mark broken links")
                    Text("Links to documents or headings that don’t exist are underlined in red. Web links are never checked.")
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SourceControlSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle(isOn: $model.showGitStatus) {
                    Text("Show changes in the sidebar")
                    Text("Marks documents with uncommitted changes. LexMD runs Git only on this Mac and never contacts remotes.")
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct UpdateSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let updates = model.updates
        Form {
            Section {
                LabeledContent("Version", value: Self.version)
            }
            Section {
                if updates.isConfigured {
                    Toggle("Automatically check for updates", isOn: Binding(
                        get: { updates.automaticChecks }, set: { updates.setAutomaticChecks($0) }))
                    Toggle("Automatically download and install updates", isOn: Binding(
                        get: { updates.automaticDownloads }, set: { updates.setAutomaticDownloads($0) }))
                        .disabled(!updates.automaticChecks)
                    HStack {
                        Button("Check for Updates…") { updates.checkForUpdates() }
                            .disabled(!updates.canCheck)
                        Spacer()
                        if let lastChecked = updates.lastChecked {
                            Text("Last checked \(lastChecked.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Updates are unavailable in this build.")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Updates come from LexMD’s GitHub releases and are verified with LexMD’s signing key before installing. Automatic installs happen when you quit LexMD. No usage data is sent.")
                    if let error = updates.error {
                        Text(error)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}

private struct ShortcutSettings: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        let sections = ShortcutAction.sections(
            matching: query, includingSourceControl: model.git.isActive, shortcut: model.shortcut(for:)
        )
        VStack(spacing: 0) {
            SettingsSearchField(text: $query, prompt: "Search commands and shortcuts")
                .padding(.horizontal, 20)
                .padding(.top, 14)

            if sections.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxHeight: .infinity)
            } else {
                Form {
                    ForEach(sections, id: \.category) { section in
                        Section {
                            ForEach(section.actions) { action in
                                LabeledContent(action.title) {
                                    ShortcutRecorder(action: action)
                                }
                            }
                        } header: {
                            Text(section.category.rawValue)
                        } footer: {
                            if section.category == .sidebar {
                                Text("These work while the file list has focus.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }

            HStack(spacing: 10) {
                if let note = model.shortcutNote {
                    Label(note, systemImage: "exclamationmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text("Click a shortcut, then press the new keys. Delete removes it; Escape cancels.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Restore Defaults") { model.resetAllShortcuts() }
                    .disabled(model.shortcutOverrides.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(height: 560)
    }
}

/// A standard search field with a clear button; Escape clears it.
private struct SettingsSearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.setAccessibilityLabel(prompt)
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

/// Click to record a new key combination for a command.
private struct ShortcutRecorder: View {
    let action: ShortcutAction
    @Environment(AppModel.self) private var model

    /// One recorder at a time: starting this one stops any other.
    private var isRecording: Bool { model.recordingShortcut == action }

    var body: some View {
        let shortcut = model.shortcut(for: action)
        let isCustomized = model.isCustomized(action)
        HStack(spacing: 6) {
            Button {
                isRecording ? model.stopRecordingShortcut() : model.startRecordingShortcut(action, in: NSApp.keyWindow)
            } label: {
                Text(isRecording ? "Type Shortcut…" : (shortcut?.display ?? "None"))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(isRecording ? Color.accentColor : (shortcut == nil ? Color.secondary : Color.primary))
                    .frame(minWidth: 104)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isRecording ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(isRecording ? Color.accentColor : Color.clear, lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(action.title) shortcut")
            .accessibilityValue(isRecording ? "Recording" : (shortcut?.display ?? "None"))
            .accessibilityHint(isRecording ? "Press the new keys, or Escape to cancel." : "Records a new shortcut.")

            // Always laid out so rows line up; hidden from the pointer and VoiceOver until the
            // shortcut differs from its default.
            Button {
                model.resetShortcut(action)
            } label: {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Restore Default (\(action.defaultShortcut?.display ?? "None"))")
            .accessibilityLabel("Restore Default")
            .accessibilityValue(action.defaultShortcut?.display ?? "None")
            .opacity(isCustomized ? 1 : 0)
            .disabled(!isCustomized)
            .allowsHitTesting(isCustomized)
            .accessibilityHidden(!isCustomized)
        }
        .onDisappear { if isRecording { model.stopRecordingShortcut() } }
    }
}
