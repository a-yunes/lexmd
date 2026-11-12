import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// First-run setup, shown as a sheet on the main window. Every step is optional.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step = Step.welcome
    @State private var isDefaultApp = MarkdownDefaultApp.isLexMD
    @State private var defaultError: String?

    enum Step: Int, CaseIterable {
        case welcome, folder, finish
    }

    @Environment(\.sheetHeightLimit) private var heightLimit

    var body: some View {
        VStack(spacing: 24) {
            // In a short window the step scrolls and the buttons stay in view.
            ViewThatFits(in: .vertical) {
                stepContent
                ScrollView { stepContent }
                    .scrollBounceBehavior(.basedOnSize)
            }

            Spacer(minLength: 0)

            HStack {
                if step != .welcome {
                    Button("Back") { withMotion(.snappy) { step = Step(rawValue: step.rawValue - 1) ?? .welcome } }
                } else {
                    Button("Skip") { model.completeOnboarding() }
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                Button(step == .finish ? "Start Reading" : "Continue") {
                    if let next = Step(rawValue: step.rawValue + 1) {
                        withMotion(.snappy) { step = next }
                    } else {
                        model.completeOnboarding()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(40)
        .frame(width: 540, height: min(600, heightLimit))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isDefaultApp = MarkdownDefaultApp.isLexMD
        }
    }

    private var stepContent: some View {
        VStack(spacing: 24) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { item in
                    Capsule()
                        .fill(item == step ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                        .frame(width: 28, height: 4)
                }
            }
            .accessibilityLabel("Setup step \(step.rawValue + 1) of \(Step.allCases.count)")

            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 32, weight: .semibold))
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            content
                .frame(maxWidth: .infinity, minHeight: 150)
        }
    }

    private var title: String {
        switch step {
        case .welcome: "Every doc, at a glance."
        case .folder: "Open a project."
        case .finish: "Make it yours."
        }
    }

    private var subtitle: String {
        switch step {
        case .welcome: "Welcome to LexMD. See all of a project’s Markdown documents in one place, then read and update them."
        case .folder: "Pick a project folder. LexMD shows only its Markdown documents."
        case .finish: "A few choices to start with. Change any of them later in Settings."
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:
            VStack(alignment: .leading, spacing: 16) {
                Label("Every README, doc, and agent guide in one tree.", systemImage: "list.bullet.rectangle")
                Label("Clean previews, with edits a keystroke away.", systemImage: "doc.richtext")
                Label("Find any file or phrase across the project.", systemImage: "magnifyingglass")
                Label("No account. No analytics. Works offline.", systemImage: "lock.shield")
            }
            .font(.callout)

        case .folder:
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: model.rootURL == nil ? "folder.badge.questionmark" : "folder.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(model.rootURL == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.rootURL?.lastPathComponent ?? "No project yet")
                            .font(.headline)
                        Text(model.rootURL.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? model.shortcut(for: .open).map { "Pick one now, or later with \($0.display)." } ?? "Pick one now, or later from the File menu.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Button(model.rootURL == nil ? "Choose Project…" : "Change…") { chooseFolder() }
                }
                .padding(16)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text("Optional. LexMD never moves or copies your files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .finish:
            @Bindable var model = model
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open Markdown documents with LexMD")
                        Text("Double-click any .md file in Finder.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isDefaultApp {
                        Label("Default", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Make Default") {
                            MarkdownDefaultApp.makeLexMDDefault { error in
                                defaultError = error
                                isDefaultApp = MarkdownDefaultApp.isLexMD
                            }
                        }
                    }
                }
                if let defaultError {
                    Text(defaultError).font(.caption).foregroundStyle(.red)
                }
                Divider()
                Picker("Appearance", selection: $model.appearanceMode) {
                    Text("System").tag(AppearanceMode.system)
                    Text("Light").tag(AppearanceMode.light)
                    Text("Dark").tag(AppearanceMode.dark)
                }
                .pickerStyle(.segmented)
                if model.updates.isConfigured {
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Check for updates automatically")
                            Text("Signed updates from LexMD’s GitHub releases.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("Check for updates automatically", isOn: Binding(
                            get: { model.updates.automaticChecks },
                            set: { model.updates.setAutomaticChecks($0) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }
            }
            .padding(20)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a project folder to read its Markdown documents."
        model.present(panel) { response in
            if response == .OK, let url = panel.url { model.open(url) }
        }
    }
}

/// Reads and sets the system default app for Markdown documents.
enum MarkdownDefaultApp {
    static let extensions = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn"]

    static var types: [UTType] {
        var seen = Set<String>()
        return extensions.compactMap { UTType(filenameExtension: $0) }.filter { seen.insert($0.identifier).inserted }
    }

    static var isLexMD: Bool {
        guard let type = UTType(filenameExtension: "md"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: type) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    static func makeLexMDDefault(completion: @escaping @MainActor (String?) -> Void) {
        let app = Bundle.main.bundleURL
        let group = DispatchGroup()
        var failure: String?
        for type in types {
            group.enter()
            NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { error in
                if let error { failure = error.localizedDescription }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { completion(failure.map { "Couldn’t change the default app. \($0)" }) }
        }
    }
}
