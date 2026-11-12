import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings()
            }
            Tab("Shortcuts", systemImage: "command") {
                ShortcutSettings()
            }
            Tab("Updates", systemImage: "arrow.triangle.2.circlepath") {
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
            Section("Appearance") {
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
                    Text("Show the tab bar even when only one document is open.")
                }
            }
            Section("Preview") {
                Toggle(isOn: $model.loadsRemoteContent) {
                    Text("Load images from the web")
                    Text("Images and videos hosted online load from their servers, which can see when you open a document. Local images always show.")
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
            Section("Software Updates") {
                LabeledContent("LexMD version", value: Self.version)
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
            }
            Section {
                Text("Updates come from LexMD’s GitHub releases and are verified with LexMD’s signing key before installing. Automatic installs happen when you quit LexMD. No usage data is sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = updates.error {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
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

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ForEach(ShortcutAction.Category.allCases, id: \.self) { category in
                    Section(category.rawValue) {
                        ForEach(ShortcutAction.allCases.filter { $0.category == category }) { action in
                            LabeledContent(action.title) {
                                ShortcutRecorder(action: action)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack(spacing: 10) {
                if let note = model.shortcutNote {
                    Label(note, systemImage: "exclamationmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text("Click a shortcut, then press the new keys. ⌫ removes it, esc cancels.")
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

/// Click to record a new key combination for a command.
private struct ShortcutRecorder: View {
    let action: ShortcutAction
    @Environment(AppModel.self) private var model
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        let shortcut = model.shortcut(for: action)
        HStack(spacing: 6) {
            Button {
                isRecording ? stopRecording() : startRecording()
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
            .accessibilityValue(shortcut?.display ?? "None")

            Button {
                model.resetShortcut(action)
            } label: {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Restore Default (\(action.defaultShortcut?.display ?? "None"))")
            .opacity(model.isCustomized(action) ? 1 : 0)
            .disabled(!model.isCustomized(action))
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        stopRecording()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if event.keyCode == 53, modifiers.isEmpty {
                stopRecording()
            } else if (event.keyCode == 51 || event.keyCode == 117), modifiers.isEmpty {
                model.setShortcut(nil, for: action)
                stopRecording()
            } else if let shortcut = Shortcut(event: event) {
                model.setShortcut(shortcut, for: action)
                stopRecording()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
