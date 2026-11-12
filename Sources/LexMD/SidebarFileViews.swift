import AppKit
import SwiftUI

/// A row's name, or an inline field while the row is being renamed.
struct RenamableName: View {
    let node: FileNode
    let name: String
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.sidebarFiles.renamingPath == node.id {
            InlineRenameField(
                initial: node.name,
                selectsBaseName: node.children == nil,
                onCommit: { model.commitRename(node.id, to: $0) },
                onCancel: { model.cancelRename() }
            )
        } else {
            CompactName(parents: node.parents, name: name)
        }
    }
}

/// File commands at the top of a row's context menu.
struct FileActionMenuItems: View {
    let url: URL
    @Environment(AppModel.self) private var model

    var body: some View {
        let isFolder = url.hasDirectoryPath
        if !isFolder {
            Button("Open in New Tab") { model.openInNewTab(url.path) }
            Divider()
        }
        Button("New File") { model.newFile(near: url) }
        Button("New Folder") { model.newFolder(near: url) }
        Divider()
        Button("Rename") { model.beginRename(url) }
        Button("Duplicate") { model.duplicateItem(url) }
        Button("Move To…") { model.chooseMoveDestination(for: url) }
        Button("Move to Trash") { model.confirmMoveToTrash(url) }
        Divider()
    }
}

/// The context menu for empty space in the sidebar.
struct SidebarBackgroundMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("New File") { model.newFile(near: nil) }
        Button("New Folder") { model.newFolder(near: nil) }
        if let root = model.rootURL {
            Divider()
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([root]) }
        }
    }
}

extension View {
    /// Lets a folder row (or a file row, for its folder) take items dropped from Finder. Rows are not
    /// draggable: a drag source makes the list select on mouse-up, which slows switching documents.
    func sidebarDragAndDrop(_ node: FileNode) -> some View {
        modifier(SidebarDragAndDrop(node: node))
    }
}

private struct SidebarDragAndDrop: ViewModifier {
    let node: FileNode
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false
    @State private var springTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        let isFolder = node.children != nil
        content
            .dropDestination(for: URL.self) { urls, _ in
                model.moveItems(urls, into: isFolder ? node.url : node.url.deletingLastPathComponent())
            } isTargeted: { targeted in
                isTargeted = targeted
                springTask?.cancel()
                guard targeted, isFolder, !model.isExpanded(node) else { return }
                // Spring-loaded folders: hovering a closed folder opens it.
                springTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(700))
                    guard !Task.isCancelled, isTargeted else { return }
                    withAnimation(.snappy(duration: 0.22)) { model.setExpanded(node, true) }
                }
            }
            .background {
                if isTargeted, isFolder {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(.horizontal, -4)
                }
            }
    }
}

/// An AppKit name field: selects the name without its extension, Return commits, Escape
/// cancels, and clicking elsewhere commits, as in Finder.
struct InlineRenameField: NSViewRepresentable {
    let initial: String
    let selectsBaseName: Bool
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: initial)
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.isBezeled = true
        field.bezelStyle = .squareBezel
        field.delegate = context.coordinator
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.lineBreakMode = .byClipping
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("Name")
        context.coordinator.focus(field, attempts: 10)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineRenameField
        private var finished = false
        private var focused = false

        init(_ parent: InlineRenameField) {
            self.parent = parent
        }

        func focus(_ field: NSTextField, attempts: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self, weak field] in
                guard let self, let field, !self.finished else { return }
                guard let window = field.window, window.makeFirstResponder(field), let editor = field.currentEditor() else {
                    if attempts > 0 { self.focus(field, attempts: attempts - 1) }
                    return
                }
                self.focused = true
                let name = field.stringValue as NSString
                let length = self.parent.selectsBaseName && FileOperations.hasExtension(field.stringValue)
                    ? (name.deletingPathExtension as NSString).length : name.length
                editor.selectedRange = NSRange(location: 0, length: length)
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                finish(control.stringValue)
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                finish(nil)
                return true
            }
            return false
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            focused = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard focused, let field = notification.object as? NSTextField else { return }
            finish(field.stringValue)
        }

        private func finish(_ value: String?) {
            guard !finished else { return }
            finished = true
            if let value { parent.onCommit(value) } else { parent.onCancel() }
        }
    }
}
