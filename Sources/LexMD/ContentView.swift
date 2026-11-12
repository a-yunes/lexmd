import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.sidebarPosition == .right {
                // macOS split views keep the sidebar leading, so a trailing tree uses the inspector column.
                DetailView()
                    .outlinePanel(.leading)
                    .toolbar { detailToolbar(trailingSidebar: true) }
                    .inspector(isPresented: $model.isInspectorPresented) {
                        SidebarView(inInspector: true)
                            .inspectorColumnWidth(min: 210, ideal: 270, max: 440)
                    }
            } else {
                NavigationSplitView(columnVisibility: $model.columnVisibility) {
                    SidebarView(inInspector: false)
                        .navigationSplitViewColumnWidth(min: 210, ideal: 270, max: 440)
                } detail: {
                    DetailView()
                        .outlinePanel(.trailing)
                        .toolbar { detailToolbar(trailingSidebar: false) }
                }
            }
        }
        .navigationTitle(model.title)
        .toolbar(removing: .title)
        .overlay {
            if model.isQuickSearchVisible {
                QuickSearchOverlay()
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)),
                        removal: .opacity
                    ))
            }
        }
        .animation(.easeOut(duration: 0.16), value: model.isQuickSearchVisible)
        .sheet(isPresented: $model.isOnboardingPresented) {
            OnboardingView()
                .environment(model)
                .interactiveDismissDisabled()
        }
        .task {
            // Let the window finish appearing before presenting the sheet on it.
            try? await Task.sleep(nanoseconds: 600_000_000)
            model.presentOnboardingIfNeeded()
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.isFileURL) else { return false }
            model.open(url)
            return true
        }
    }
}

extension ContentView {
    @ToolbarContentBuilder
    func detailToolbar(trailingSidebar: Bool) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            DocumentTitle()
        }
        ToolbarSpacer(.flexible)
        ToolbarItem(placement: .primaryAction) {
            ViewModePicker()
        }
        ToolbarItem(placement: .primaryAction) {
            OutlineToolbarButton()
        }
        if trailingSidebar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.toggleSidebar() } label: {
                    Label(model.isInspectorPresented ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.trailing")
                }
                .help("Show or hide the sidebar \(model.shortcut(for: .toggleSidebar).map { "(\($0.display))" } ?? "")")
            }
        }
    }
}

/// Window title and subtitle drawn by SwiftUI so the subtitle always gets its full width
/// as the word count changes.
struct DocumentTitle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(model.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            if !model.subtitle.isEmpty {
                Text(model.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .fixedSize()
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
    }
}

struct ViewModePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Picker("View Mode", selection: Binding(get: { model.viewMode }, set: { model.setViewMode($0) })) {
            Label("Preview", systemImage: "doc.richtext").tag(ViewMode.read)
            Label("Preview and Editor", systemImage: "rectangle.split.2x1").tag(ViewMode.split)
            Label("Editor", systemImage: "square.and.pencil").tag(ViewMode.edit)
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .help([("Preview", ShortcutAction.previewOnly), ("Split", .split), ("Editor", .editorOnly)]
            .map { "\($0.0) \(model.shortcut(for: $0.1)?.display ?? "")" }
            .joined(separator: " · "))
        .disabled(model.currentFile == nil)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    var inInspector = false
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let rows = model.rootURL == nil ? [] : model.visibleRows
        Group {
            if let root = model.rootURL {
                List(selection: $model.selectedPath) {
                    Section {
                        ForEach(rows) { row in
                            FileRow(row: row)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Text(root.lastPathComponent)
                            if model.isScanning {
                                ProgressView().controlSize(.mini)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .overlay {
                    if rows.isEmpty, !model.isScanning {
                        if model.filter.isEmpty {
                            ContentUnavailableView(
                                "No Markdown Files",
                                systemImage: "doc.text.magnifyingglass",
                                description: Text("This folder doesn’t contain any Markdown documents.")
                            )
                        } else {
                            ContentUnavailableView.search(text: model.filter)
                        }
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("No Project Open", systemImage: "folder")
                } description: {
                    Text("Open a repository or folder to see all of its Markdown.")
                } actions: {
                    Button("Open Project…") { model.showOpenPanel() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
        }
        .modifier(SidebarFilter(inInspector: inInspector, text: $model.filter))
        .toolbar {
            if model.canToggleAllFolders {
                ToolbarItem {
                    ExpandAllButton()
                }
            }
            ToolbarItem {
                Button { model.toggleQuickSearch(mode: .everything) } label: {
                    Label("Find in Files", systemImage: "magnifyingglass")
                }
                .help("Find in Files \(model.shortcut(for: .findInFiles).map { "(\($0.display))" } ?? "")")
                .disabled(model.rootURL == nil)
            }
            ToolbarItem {
                Button { model.showOpenPanel() } label: {
                    Label("Open Folder", systemImage: "folder.badge.plus")
                }
                .help("Open a folder or Markdown file \(model.shortcut(for: .open).map { "(\($0.display))" } ?? "")")
            }
        }
    }
}

/// The sidebar's filter: the system search field on the left, an inline field in the inspector.
private struct SidebarFilter: ViewModifier {
    let inInspector: Bool
    @Binding var text: String

    func body(content: Content) -> some View {
        if inInspector {
            content.safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("Filter", text: $text)
                        .textFieldStyle(.plain)
                    if !text.isEmpty {
                        Button { text = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear Filter")
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)
            }
        } else {
            content.searchable(text: $text, placement: .sidebar, prompt: "Filter")
        }
    }
}

/// One row of the flattened file tree. Folders toggle on click; files are selectable.
struct FileRow: View {
    let row: TreeRow
    @Environment(AppModel.self) private var model

    var body: some View {
        let node = row.node
        if node.children != nil {
            let expanded = model.isExpanded(node)
            Button {
                withAnimation(.snappy(duration: 0.22)) { model.setExpanded(node, !expanded) }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    Label {
                        CompactName(parents: node.parents, name: node.name)
                    } icon: {
                        Image(systemName: "folder")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, indent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                if FileScanner.folderIDs(in: [node]).count >= 2 {
                    Button("Expand All Inside") { model.setExpanded(subtreeOf: [node], true) }
                    Button("Collapse All Inside") { model.setExpanded(subtreeOf: [node], false) }
                    Divider()
                }
                RowMenu(url: node.url)
            }
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        } else {
            HStack(spacing: 3) {
                Color.clear.frame(width: 12)
                Label {
                    CompactName(parents: node.parents, name: node.displayName)
                } icon: {
                    Image(systemName: "doc.text")
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, indent)
            .tag(node.id)
            .help(node.searchLabel)
            .contextMenu { RowMenu(url: node.url) }
        }
    }

    private var indent: CGFloat { CGFloat(row.depth) * 14 }
}

/// "parent › child › name", with the separators dimmed.
struct CompactName: View {
    let parents: [String]
    let name: String

    var body: some View {
        if parents.isEmpty {
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            let separator = Text(" › ").foregroundStyle(.tertiary)
            let joined = parents.reduce(Text("")) { result, parent in
                Text("\(result)\(Text(parent))\(separator)")
            }
            Text("\(joined)\(Text(name))")
                .lineLimit(1)
                .truncationMode(.head)
        }
    }
}

struct ExpandAllButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let expanded = model.allFoldersExpanded
        Button {
            withAnimation(.snappy(duration: 0.25)) { model.setAllFoldersExpanded(!expanded) }
        } label: {
            Label(expanded ? "Collapse All Folders" : "Expand All Folders",
                  systemImage: expanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
        }
        .help(expanded ? "Collapse All Folders (⌥⌘←)" : "Expand All Folders (⌥⌘→)")
    }
}

struct RowMenu: View {
    let url: URL

    var body: some View {
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }
    }
}

// MARK: - Detail

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        documentArea
            .overlay(alignment: .topTrailing) {
                if model.isFindBarVisible, model.currentFile != nil {
                    FindBar()
                        .padding(.top, 12)
                        .padding(.trailing, 18)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: -8)),
                            removal: .opacity
                        ))
                }
            }
            .animation(.easeOut(duration: 0.16), value: model.isFindBarVisible)
    }

    private var documentArea: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
                .ignoresSafeArea()
            WorkspaceView(model: model, mode: model.viewMode)
                .opacity(model.currentFile == nil ? 0 : 1)
            if model.currentFile == nil {
                ContentUnavailableView(
                    "No Document Selected",
                    systemImage: "doc.text",
                    description: Text(model.rootURL == nil
                        ? "Open a project or a Markdown file to start reading."
                        : "Choose a Markdown file from the sidebar.")
                )
            }
        }
    }
}

/// Hosts the editor and preview in one long-lived AppKit split view; modes collapse a pane
/// instead of rebuilding views, so text, undo history and scroll positions survive.
struct WorkspaceView: NSViewRepresentable {
    let model: AppModel
    let mode: ViewMode

    func makeNSView(context: Context) -> WorkspaceContainer {
        WorkspaceContainer(editor: model.editor.scrollView, preview: model.preview.webView)
    }

    func updateNSView(_ container: WorkspaceContainer, context: Context) {
        container.setMode(mode)
    }
}

final class WorkspaceContainer: NSView, NSSplitViewDelegate {
    private let split = NSSplitView()
    private let editor: NSView
    private let preview: NSView
    private var mode: ViewMode?
    private var needsEvenSplit = true

    init(editor: NSView, preview: NSView) {
        self.editor = editor
        self.preview = preview
        super.init(frame: .zero)
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.translatesAutoresizingMaskIntoConstraints = false
        editor.removeFromSuperview()
        preview.removeFromSuperview()
        split.addArrangedSubview(editor)
        split.addArrangedSubview(preview)
        addSubview(split)
        // Pin to the safe area so content never sits under the floating sidebar or toolbar.
        let guide = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            split.topAnchor.constraint(equalTo: guide.topAnchor),
            split.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setMode(_ newMode: ViewMode) {
        guard newMode != mode else { return }
        mode = newMode
        editor.isHidden = newMode == .read
        preview.isHidden = newMode == .edit
        if newMode == .split { needsEvenSplit = true }
        split.adjustSubviews()
        split.needsLayout = true
        split.needsDisplay = true
        needsLayout = true
    }

    private var isSinglePane: Bool { editor.isHidden || preview.isHidden }

    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        isSinglePane
    }

    func splitView(
        _ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
        forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int
    ) -> NSRect {
        isSinglePane ? .zero : proposedEffectiveRect
    }

    override func layout() {
        super.layout()
        if needsEvenSplit, mode == .split, split.bounds.width > 0 {
            needsEvenSplit = false
            split.setPosition((split.bounds.width / 2).rounded(), ofDividerAt: 0)
        }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, 260)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.width - 260)
    }
}
