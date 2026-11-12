import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A slim strip of open documents above the editor and preview. Hidden with a single document
/// unless "Always show tab bar" is on.
struct DocumentTabBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.showsTabBar {
            TabStrip()
                .frame(height: 30)
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
        }
    }
}

private struct TabStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let list = model.tabStore.list
        let titles = list.titles()
        GeometryReader { geometry in
            let available = geometry.size.width - 12 - CGFloat(max(list.count - 1, 0)) * 2
            let width = min(240, max(120, available / CGFloat(max(list.count, 1))))
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(list.tabs) { tab in
                            TabItem(tab: tab, title: titles[tab.id] ?? tab.title, isActive: tab.id == list.activeID)
                                .frame(width: width)
                                .id(tab.id)
                        }
                    }
                    .padding(.horizontal, 6)
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
    @State private var isHovering = false

    var body: some View {
        let unsaved = model.tabHasUnsavedChanges(tab.id)
        let showsDot = unsaved && !isHovering
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
            .help(unsaved ? "Unsaved changes. Close Tab" : "Close Tab")
            Text(title)
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
            Color.clear.frame(width: 16, height: 1)
        }
        .padding(.horizontal, 5)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(isActive ? 0.1 : (isHovering ? 0.05 : 0)))
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture { model.selectTab(tab.id) }
        .onHover { isHovering = $0 }
        .overlay(MiddleClickArea { model.closeTab(tab.id) })
        .onDrag {
            model.tabStore.draggingID = tab.id
            return NSItemProvider(object: tab.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: TabDropDelegate(target: tab.id, model: model))
        .help(relativePath)
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
        .accessibilityValue(unsaved ? "Unsaved changes" : "")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.selectTab(tab.id) }
        .accessibilityAction(named: "Close Tab") { model.closeTab(tab.id) }
    }

    private var relativePath: String {
        guard let root = model.rootURL?.path, tab.path.hasPrefix(root + "/") else { return tab.path }
        return String(tab.path.dropFirst(root.count + 1))
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
        model.tabStore.draggingID != nil && !info.hasItemsConforming(to: [.fileURL, .url])
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
