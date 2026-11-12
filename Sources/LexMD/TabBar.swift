import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A slim strip of open documents above the editor and preview. Hidden with a single document
/// unless "Always show tab bar" is on.
struct DocumentTabBar: View {
    @Environment(AppModel.self) private var model
    @State private var barWidth: CGFloat = 0

    var body: some View {
        if model.showsTabBar {
            // Whether the tabs overflow is decided without the overflow button, so showing it
            // never flips the answer.
            let overflows = TabStripLayout(available: barWidth - TabStripLayout.newTabButtonWidth, count: model.tabStore.list.count).overflows
            HStack(spacing: 0) {
                TabStrip()
                if overflows {
                    TabOverflowMenu()
                }
                Button { model.newTab() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(model.helpText("New Tab", .newTab))
                .accessibilityLabel("New Tab")
                .padding(.trailing, 4)
            }
            .frame(height: 30)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
        }
    }
}

/// How wide each tab is, and whether the tabs need more room than the strip has.
struct TabStripLayout: Equatable {
    static let minTabWidth: CGFloat = 120
    static let maxTabWidth: CGFloat = 240
    static let spacing: CGFloat = 2
    static let padding: CGFloat = 6
    /// The New Tab button and its trailing padding.
    static let newTabButtonWidth: CGFloat = 32

    let tabWidth: CGFloat
    let overflows: Bool

    init(available: CGFloat, count: Int) {
        let room = available - 2 * Self.padding - CGFloat(max(count - 1, 0)) * Self.spacing
        let share = room / CGFloat(max(count, 1))
        tabWidth = min(Self.maxTabWidth, max(Self.minTabWidth, share))
        overflows = count > 1 && share < Self.minTabWidth
    }
}

/// Lists every tab when there are more than the strip can show.
private struct TabOverflowMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let list = model.tabStore.list
        let titles = list.titles()
        Menu {
            Picker("Tabs", selection: Binding(
                get: { list.activeID },
                set: { if let id = $0 { model.selectTab(id) } }
            )) {
                ForEach(list.tabs) { tab in
                    Text(titles[tab.id] ?? tab.title).tag(Optional(tab.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .foregroundStyle(.secondary)
        .fixedSize()
        .help("Show All Tabs")
        .accessibilityLabel("All Tabs")
    }
}

private struct TabStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let list = model.tabStore.list
        let titles = list.titles()
        GeometryReader { geometry in
            let width = TabStripLayout(available: geometry.size.width, count: list.count).tabWidth
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: TabStripLayout.spacing) {
                        ForEach(list.tabs) { tab in
                            TabItem(tab: tab, title: titles[tab.id] ?? tab.title, isActive: tab.id == list.activeID)
                                .frame(width: width)
                                .id(tab.id)
                        }
                    }
                    .padding(.horizontal, TabStripLayout.padding)
                    .frame(height: geometry.size.height)
                }
                .onChange(of: list.activeID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) }
                }
            }
        }
    }
}

private struct TabItem: View {
    let tab: DocumentTab
    let title: String
    let isActive: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovering = false

    var body: some View {
        let unsaved = model.tabHasUnsavedChanges(tab.id)
        let missing = model.tabStore.missing.contains(tab.id)
        let showsDot = unsaved && !isHovering
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        // ⌘W closes the active tab, so only its button names that shortcut.
        let close = isActive ? model.helpText("Close Tab", .closeTab) : "Close Tab"
        HStack(spacing: 4) {
            Button { model.closeTab(tab.id) } label: {
                Image(systemName: showsDot ? "circle.fill" : "xmark")
                    .font(.system(size: showsDot ? 6 : 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovering || unsaved ? 1 : 0)
            .help(unsaved ? "Unsaved changes. \(close)" : close)
            Text(title)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .italic(missing)
                .strikethrough(missing)
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
            Color.clear.frame(width: 16, height: 1)
        }
        .padding(.horizontal, 5)
        .frame(height: 24)
        .background {
            // The active tab gets the system fill, a hairline edge and a heavier title, so it
            // reads as selected without relying on a faint tint alone.
            if isActive {
                shape.fill(.fill)
            } else if isHovering {
                shape.fill(.fill.tertiary)
            }
        }
        .overlay {
            if isActive {
                shape.strokeBorder(
                    Color.primary.opacity(contrast == .increased ? 0.55 : 0.16),
                    lineWidth: contrast == .increased ? 1 : 0.5
                )
            }
        }
        .contentShape(shape)
        .onTapGesture { model.selectTab(tab.id) }
        .onHover { isHovering = $0 }
        .overlay(MiddleClickArea { model.closeTab(tab.id) })
        .onDrag {
            model.tabStore.draggingID = tab.id
            return TabDrag.provider(for: tab)
        }
        .onDrop(of: [TabDrag.type], delegate: TabDropDelegate(target: tab.id, model: model))
        .help(missing ? "\(relativePath) is no longer on disk. Saving puts it back." : relativePath)
        .contextMenu {
            Button("Close Tab") { model.closeTab(tab.id) }
            Button("Close Other Tabs") { model.closeOtherTabs(tab.id) }
                .disabled(model.tabStore.list.count < 2)
            Divider()
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tab.path)]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tab.path, forType: .string)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue([unsaved ? "Unsaved changes" : nil, missing ? "No longer on disk" : nil].compactMap(\.self).joined(separator: ", "))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.selectTab(tab.id) }
        .accessibilityAction(named: "Close Tab") { model.closeTab(tab.id) }
    }

    private var relativePath: String {
        guard let root = model.rootURL?.path, tab.path.hasPrefix(root + "/") else { return tab.path }
        return String(tab.path.dropFirst(root.count + 1))
    }
}

/// What a tab drag carries: the tab's identity for reordering, and its file, so dropping the
/// tab in Finder or another app hands over the document.
enum TabDrag {
    /// The tab's identity, private to LexMD (declared in Info.plist). Files dragged from
    /// Finder or other apps never carry it.
    static let type = UTType(exportedAs: "io.github.a-yunes.lexmd.document-tab", conformingTo: .data)

    static func provider(for tab: DocumentTab) -> NSItemProvider {
        let provider = NSItemProvider()
        let identity = Data(tab.id.uuidString.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
            completion(identity, nil)
            return nil
        }
        provider.registerObject(URL(fileURLWithPath: tab.path) as NSURL, visibility: .all)
        provider.suggestedName = (tab.path as NSString).lastPathComponent
        return provider
    }
}

/// Reorders tabs live while one is dragged over another.
private struct TabDropDelegate: DropDelegate {
    let target: UUID
    let model: AppModel

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info), let dragging = model.tabStore.draggingID, dragging != target,
              let index = model.tabStore.list.index(of: target) else { return }
        withAnimation(.snappy(duration: 0.2)) { model.moveTab(dragging, to: index) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    /// Only tabs reorder here; files dragged from the sidebar or Finder do not.
    func validateDrop(info: DropInfo) -> Bool {
        model.tabStore.draggingID != nil && info.hasItemsConforming(to: [TabDrag.type])
    }

    func performDrop(info: DropInfo) -> Bool {
        model.tabStore.draggingID = nil
        return true
    }
}

/// Closes a tab on a middle click. Other clicks pass through to the tab.
private struct MiddleClickArea: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> MiddleClickView {
        let view = MiddleClickView()
        view.action = action
        return view
    }

    func updateNSView(_ view: MiddleClickView, context: Context) {
        view.action = action
    }
}

final class MiddleClickView: NSView {
    var action: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let type = NSApp.currentEvent?.type, type == .otherMouseDown || type == .otherMouseUp else { return nil }
        return super.hitTest(point)
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber != 2 { super.otherMouseDown(with: event) }
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { action?() } else { super.otherMouseUp(with: event) }
    }
}
