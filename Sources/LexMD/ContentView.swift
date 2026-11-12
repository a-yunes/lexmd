import AppKit
import SwiftUI

/// The window's minimum content size. Sheets on the window stay within it, and the outline
/// steps aside when the window is too narrow for it (see `OutlineLayout`).
enum WindowLayout {
    static let minWidth: CGFloat = 800
    static let minHeight: CGFloat = 540
}

extension EnvironmentValues {
    /// The tallest a sheet on the window can be and still fit inside it.
    @Entry var sheetHeightLimit: CGFloat = .infinity
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sheetHeightLimit: CGFloat = .infinity

    var body: some View {
        @Bindable var model = model
        Group {
            if model.sidebarPosition == .right {
                // macOS split views keep the sidebar leading, so a trailing tree uses the inspector column.
                DetailColumn(trailingSidebar: true)
                    .inspector(isPresented: $model.isInspectorPresented) {
                        SidebarView(inInspector: true)
                            .inspectorColumnWidth(min: 210, ideal: 270, max: 440)
                    }
            } else {
                NavigationSplitView(columnVisibility: $model.columnVisibility) {
                    SidebarView(inInspector: false)
                        .navigationSplitViewColumnWidth(min: 210, ideal: 270, max: 440)
                } detail: {
                    DetailColumn(trailingSidebar: false)
                }
            }
        }
        .toolbar(removing: .title)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            model.windowWidth = size.width
            // Whole steps, so resizing the window does not resize sheets on every frame.
            let limit = max(320, ((size.height - 24) / 20).rounded(.down) * 20)
            if limit != sheetHeightLimit { sheetHeightLimit = limit }
        }
        .overlay {
            if model.isQuickSearchVisible {
                QuickSearchOverlay()
                    .transition(.asymmetric(
                        insertion: .motion(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)), reduced: reduceMotion),
                        removal: .opacity
                    ))
            }
        }
        .animation(.easeOut(duration: 0.16), value: model.isQuickSearchVisible)
        .sheet(isPresented: $model.isOnboardingPresented) {
            OnboardingView()
                .environment(model)
                .environment(\.sheetHeightLimit, sheetHeightLimit)
                .interactiveDismissDisabled()
        }
        .task {
            // Let the window finish appearing before presenting the sheet on it.
            try? await Task.sleep(nanoseconds: 600_000_000)
            model.presentOnboardingIfNeeded()
        }
        .dropDestination(for: URL.self) { urls, _ in
            // A tab dropped outside the tab bar ends its reordering drag.
            model.tabStore.draggingID = nil
            guard let url = urls.first(where: \.isFileURL) else { return false }
            model.open(url)
            return true
        }
        .modifier(CommitSheetPresenter())
        // Outside the sheet modifiers, so the sheets they present read it.
        .environment(\.sheetHeightLimit, sheetHeightLimit)
    }
}

/// The document column with its toolbar and the window title. Everything that changes with the
/// open document is read here, so switching documents does not re-evaluate the whole window.
private struct DetailColumn: View {
    let trailingSidebar: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        DetailView()
            .outlinePanel(trailingSidebar ? .leading : .trailing)
            .toolbar(id: ToolbarID.main) { detailToolbar(trailingSidebar: trailingSidebar) }
            .navigationTitle(model.title)
            .background { WindowDocumentBridge(url: model.currentFile) }
    }

    @ToolbarContentBuilder
    func detailToolbar(trailingSidebar: Bool) -> some CustomizableToolbarContent {
        ToolbarItem(id: ToolbarID.title, placement: .navigation) {
            DocumentTitle()
        }
        .customizationBehavior(.disabled)
        .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible)
        if model.showsCommitButton {
            ToolbarItem(id: ToolbarID.commit, placement: .primaryAction) {
                CommitToolbarButton()
            }
        }
        ToolbarItem(id: ToolbarID.viewMode, placement: .primaryAction) {
            ViewModePicker()
        }
        if model.canShowOutline {
            ToolbarItem(id: ToolbarID.outline, placement: .primaryAction) {
                OutlineToolbarButton()
            }
        }
        if trailingSidebar {
            ToolbarItem(id: ToolbarID.trailingSidebar, placement: .primaryAction) {
                let title = model.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar"
                Button { model.toggleSidebar() } label: {
                    Label(title, systemImage: "sidebar.trailing")
                }
                .help(model.helpText(title, .toggleSidebar))
            }
        }
    }
}

/// Stable identifiers, so Customize Toolbar can save where the reader puts each item.
enum ToolbarID {
    static let main = "lexmd.toolbar"
    static let title = "lexmd.title"
    static let commit = "lexmd.commit"
    static let viewMode = "lexmd.viewMode"
    static let outline = "lexmd.outline"
    static let trailingSidebar = "lexmd.trailingSidebar"
    static let expandAll = "lexmd.expandAll"
    static let findInFiles = "lexmd.findInFiles"
    static let open = "lexmd.open"
}

/// Window title and subtitle drawn by SwiftUI so the subtitle always gets its full width
/// as the word count changes.
/// The system title is hidden, so this view also carries the document's proxy icon and the
/// path menu on its title.
struct DocumentTitle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            if let url = model.currentFile {
                DocumentProxyIcon(url: url)
                    .frame(width: 16, height: 16)
            }
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
            .accessibilityElement(children: .combine)
            .contextMenu {
                if let url = model.currentFile {
                    DocumentPathMenuItems(url: url)
                }
            }
        }
        .fixedSize()
        .padding(.horizontal, 6)
    }
}

/// The document and the folders that contain it; choosing one shows it in Finder.
private struct DocumentPathMenuItems: View {
    let url: URL

    var body: some View {
        let components = DocumentPath.components(of: url)
        ForEach(Array(components.enumerated()), id: \.offset) { index, component in
            Button {
                DocumentPath.reveal(index, of: components)
            } label: {
                Label {
                    Text(DocumentPath.displayName(of: component))
                } icon: {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: component.path))
                }
            }
        }
    }
}

struct ViewModePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Picker("View Mode", selection: Binding(get: { model.viewMode }, set: { model.setViewMode($0) })) {
            ForEach(ViewMode.pickerOrder, id: \.self) { mode in
                Label(mode.command.title, systemImage: mode.symbol).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .help(ViewMode.pickerOrder.map { model.helpText($0.command.title, $0.command) }.joined(separator: ", "))
        .disabled(model.currentFile == nil)
    }
}

extension ViewMode {
    /// The order of the view mode control, as in the View menu.
    static let pickerOrder: [ViewMode] = [.read, .split, .edit]

    /// The menu command that switches to this mode; its title names the mode everywhere.
    var command: ShortcutAction {
        switch self {
        case .read: .previewOnly
        case .split: .split
        case .edit: .editorOnly
        }
    }

    var symbol: String {
        switch self {
        case .read: "doc.richtext"
        case .split: "rectangle.split.2x1"
        case .edit: "square.and.pencil"
        }
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
                .contextMenu { SidebarBackgroundMenu() }
                .dropDestination(for: URL.self) { urls, _ in model.moveItems(urls, into: root) }
                .onKeyPress(phases: [.down, .repeat]) { press in
                    guard let path = model.selectedPath else { return .ignored }
                    if model.shortcut(for: .renameInSidebar)?.matches(press.key, modifiers: press.modifiers) == true,
                       model.sidebarFiles.renamingPath == nil {
                        model.beginRename(URL(fileURLWithPath: path))
                        return .handled
                    }
                    if press.phase == .down,
                       model.shortcut(for: .trashInSidebar)?.matches(press.key, modifiers: press.modifiers) == true {
                        model.confirmMoveToTrash(URL(fileURLWithPath: path))
                        return .handled
                    }
                    if press.phase == .down, model.sidebarFiles.renamingPath == nil,
                       model.shortcut(for: .quickLookInSidebar)?.matches(press.key, modifiers: press.modifiers) == true {
                        SidebarQuickLook.shared.toggle(URL(fileURLWithPath: path))
                        return .handled
                    }
                    return .ignored
                }
                .onChange(of: model.selectedPath) { _, path in
                    SidebarQuickLook.shared.selectionChanged(to: path)
                }
                .overlay {
                    if rows.isEmpty, !model.isScanning {
                        if model.filter.isEmpty {
                            ContentUnavailableView(
                                "No Markdown Documents",
                                systemImage: "doc.text.magnifyingglass",
                                description: Text("This project doesn’t contain any Markdown documents.")
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
                    Text("Open a project folder to see all of its Markdown documents.")
                } actions: {
                    Button("Open Project…") { model.showOpenPanel() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
        }
        .modifier(SidebarFilter(inInspector: inInspector, text: $model.filter))
        .toolbar(id: ToolbarID.main) {
            if model.canToggleAllFolders {
                ToolbarItem(id: ToolbarID.expandAll) {
                    ExpandAllButton()
                }
            }
            ToolbarItem(id: ToolbarID.findInFiles) {
                Button { model.toggleQuickSearch(mode: .everything) } label: {
                    Label("Find in Files", systemImage: "magnifyingglass")
                }
                .help(model.helpText("Find in Files", .findInFiles))
                .disabled(model.rootURL == nil)
            }
            ToolbarItem(id: ToolbarID.open) {
                Button { model.showOpenPanel() } label: {
                    Label(ShortcutAction.open.title, systemImage: "folder")
                }
                .help(model.helpText("Open a folder or Markdown file", .open))
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
        if let children = node.children {
            let expanded = row.isExpanded
            Button {
                withMotion(.snappy(duration: 0.22)) { model.setExpanded(node, !expanded) }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    Label {
                        RenamableName(node: node, name: node.name)
                    } icon: {
                        Image(systemName: "folder")
                    }
                    Spacer(minLength: 0)
                    GitBadgeView(path: node.id, isFolder: true)
                }
                .padding(.leading, indent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                // Menu items are built with the row, so look only one level down.
                if children.contains(where: { $0.children != nil }) {
                    Button("Expand All Inside") { model.setExpanded(subtreeOf: [node], true) }
                    Button("Collapse All Inside") { model.setExpanded(subtreeOf: [node], false) }
                    Divider()
                }
                RowMenu(url: node.url)
            }
            .sidebarDragAndDrop(node)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        } else {
            HStack(spacing: 3) {
                Color.clear.frame(width: 12)
                Label {
                    RenamableName(node: node, name: node.displayName)
                } icon: {
                    Image(systemName: "doc.text")
                }
                Spacer(minLength: 0)
                GitBadgeView(path: node.id, isFolder: false)
            }
            .padding(.leading, indent)
            .tag(node.id)
            .help(node.searchLabel)
            .contextMenu { RowMenu(url: node.url) }
            .sidebarDragAndDrop(node)
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
            withMotion(.snappy(duration: 0.25)) { model.setAllFoldersExpanded(!expanded) }
        } label: {
            Label(expanded ? "Collapse All Folders" : "Expand All Folders",
                  systemImage: expanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
        }
        .help(expanded ? model.helpText("Collapse All Folders", .collapseAll) : model.helpText("Expand All Folders", .expandAll))
    }
}

struct RowMenu: View {
    let url: URL

    var body: some View {
        FileActionMenuItems(url: url)
        if !url.hasDirectoryPath {
            Button("Quick Look") { SidebarQuickLook.shared.toggle(url) }
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }
    }
}

// MARK: - Detail

struct DetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        documentArea
            .overlay(alignment: .topTrailing) {
                if model.isFindBarVisible, model.currentFile != nil {
                    FindBar()
                        .padding(.top, 12)
                        .padding(.trailing, 18)
                        .transition(.asymmetric(
                            insertion: .motion(.opacity.combined(with: .offset(y: -8)), reduced: reduceMotion),
                            removal: .opacity
                        ))
                }
            }
            .animation(.easeOut(duration: 0.16), value: model.isFindBarVisible)
            // A system bar under the toolbar, with the scroll edge treatment instead of its own
            // background and divider.
            .safeAreaBar(edge: .top, spacing: 0) { DocumentTabBar() }
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
                        ? "Open a project or a Markdown document to start reading."
                        : "Choose a Markdown document from the sidebar.")
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
