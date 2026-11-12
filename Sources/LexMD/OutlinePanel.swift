import SwiftUI

/// The document's headings, the documents that link to it, and its broken links.
struct OutlinePanel: View {
    @Environment(AppModel.self) private var model
    @State private var showsHeadings = true
    @State private var showsBacklinks = true
    @State private var showsProblems = true

    var body: some View {
        let outline = model.outline
        Group {
            if model.currentFile == nil {
                ContentUnavailableView(
                    "No Document", systemImage: "list.bullet.indent",
                    description: Text("Open a document to see its outline and links.")
                )
            } else {
                ScrollViewReader { proxy in
                    List {
                        let sections = OutlineSections(outline)
                        if sections.headings {
                            Section(isExpanded: $showsHeadings) {
                                headingRows(outline)
                            } header: {
                                SectionHeader(title: "Outline", count: nil)
                            }
                        }
                        if sections.backlinks {
                            Section(isExpanded: $showsBacklinks) {
                                backlinkRows(outline)
                            } header: {
                                SectionHeader(title: "Linked From", count: outline.backlinkCount)
                            }
                        }
                        if sections.problems {
                            Section(isExpanded: $showsProblems) {
                                problemRows(outline)
                            } header: {
                                SectionHeader(title: "Problems", count: outline.problems.count)
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .onChange(of: outline.currentHeading) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("heading-\(id)") }
                    }
                }
            }
        }
        .accessibilityLabel("Outline")
    }

    @ViewBuilder
    private func headingRows(_ outline: OutlineModel) -> some View {
        let minLevel = outline.headings.map(\.level).min() ?? 1
        ForEach(outline.headings) { heading in
            let current = outline.currentHeading == heading.id
            Button { model.revealHeading(heading) } label: {
                Text(heading.title.isEmpty ? "Untitled" : heading.title)
                    .font(.system(size: 12.5, weight: heading.level == minLevel ? .semibold : .regular))
                    .foregroundStyle(current ? Color.accentColor : (heading.level - minLevel >= 2 ? Color.secondary : Color.primary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, CGFloat(min(heading.level - minLevel, 5)) * 12)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(current ? Color.accentColor.opacity(0.14) : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .id("heading-\(heading.id)")
            .help(heading.title)
            .accessibilityLabel("\(heading.title), heading level \(heading.level)")
            .accessibilityAddTraits(current ? .isSelected : [])
        }
    }

    @ViewBuilder
    private func backlinkRows(_ outline: OutlineModel) -> some View {
        if outline.backlinks.isEmpty {
            // The index counted links that are still being read.
            Text("Finding links…").foregroundStyle(.secondary)
        } else {
            ForEach(outline.backlinks) { link in
                Button { model.openBacklink(link) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Image(systemName: "doc.text").foregroundStyle(.secondary)
                            Text(link.name)
                                .font(.system(size: 12.5, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        Text(link.context)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(link.folder.isEmpty ? "" : link.folder + "/")\(link.name), line \(link.line)")
            }
            if outline.backlinkCount > outline.backlinks.count {
                Text("\(outline.backlinkCount - outline.backlinks.count) more not shown")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func problemRows(_ outline: OutlineModel) -> some View {
        ForEach(outline.problems) { problem in
            Button { model.selectProblem(problem) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 11))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(problem.message)
                            .font(.system(size: 12))
                            .lineLimit(2)
                        Text("Line \(problem.line) · \(problem.target)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Select in the editor")
        }
    }
}

/// Which sections the panel shows: each only when it has something in it.
struct OutlineSections: Equatable {
    var headings: Bool
    var backlinks: Bool
    var problems: Bool

    init(headings: Bool, backlinks: Bool, problems: Bool) {
        self.headings = headings
        self.backlinks = backlinks
        self.problems = problems
    }

    @MainActor
    init(_ outline: OutlineModel) {
        headings = outline.headings.count > 1
        backlinks = outline.backlinkCount > 0
        problems = !outline.problems.isEmpty
    }
}

private struct SectionHeader: View {
    let title: String
    let count: Int?

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
            if let count, count > 0 {
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The outline's widths, and when the window has room for it beside the document.
enum OutlineLayout {
    static let minWidth: CGFloat = 190
    static let idealWidth: CGFloat = 260
    static let maxWidth: CGFloat = 440
    /// The narrowest the file tree gets.
    static let sidebarMinWidth: CGFloat = 210
    /// Keyboard and VoiceOver resizing steps.
    static let widthStep: CGFloat = 20

    /// The narrowest the document gets: one pane, or the editor and preview side by side.
    static func documentMinWidth(_ mode: ViewMode) -> CGFloat {
        mode == .split ? 520 : 360
    }

    static func fits(windowWidth: CGFloat, sidebarVisible: Bool, mode: ViewMode) -> Bool {
        windowWidth >= (sidebarVisible ? sidebarMinWidth : 0) + documentMinWidth(mode) + minWidth
    }

    static func clampedWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minWidth), maxWidth)
    }
}

/// Places the outline beside the document. With the file tree on the left it is the window's
/// inspector, which the system sizes, remembers and makes resizable from the keyboard. With
/// the file tree in the inspector on the right, it is a panel on the leading side.
private struct OutlinePlacement: ViewModifier {
    let edge: HorizontalEdge
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        if edge == .trailing {
            content.inspector(isPresented: Binding(
                get: { model.showsOutlinePanel },
                // Only a change the reader made, such as dragging it closed, updates the preference.
                set: { shown in if shown != model.showsOutlinePanel { model.setOutlineShown(shown) } }
            )) {
                OutlinePanel()
                    .inspectorColumnWidth(min: OutlineLayout.minWidth, ideal: OutlineLayout.idealWidth, max: OutlineLayout.maxWidth)
            }
        } else {
            HStack(spacing: 0) {
                if model.showsOutlinePanel {
                    LeadingOutlinePanel()
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                content
            }
        }
    }
}

/// The outline on the leading side, with a divider that resizes it and remembers its width.
private struct LeadingOutlinePanel: View {
    @AppStorage("outlinePanelWidth") private var storedWidth = Double(OutlineLayout.idealWidth)
    @State private var dragStart: CGFloat?

    var body: some View {
        let width = OutlineLayout.clampedWidth(storedWidth)
        HStack(spacing: 0) {
            OutlinePanel()
                .frame(width: width)
            divider(width: width)
        }
    }

    private func divider(width: CGFloat) -> some View {
        Divider()
            .ignoresSafeArea()
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStart ?? width
                                dragStart = start
                                storedWidth = Double(OutlineLayout.clampedWidth(start + value.translation.width))
                            }
                            .onEnded { _ in dragStart = nil }
                    )
                    .accessibilityElement()
                    .accessibilityLabel("Outline Width")
                    .accessibilityValue("\(Int(width)) points")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: storedWidth = Double(OutlineLayout.clampedWidth(width + OutlineLayout.widthStep))
                        case .decrement: storedWidth = Double(OutlineLayout.clampedWidth(width - OutlineLayout.widthStep))
                        @unknown default: break
                        }
                    }
            }
    }
}

extension View {
    /// Shows the outline panel on the given side when it is visible.
    func outlinePanel(_ edge: HorizontalEdge) -> some View {
        modifier(OutlinePlacement(edge: edge))
    }
}

struct OutlineToolbarButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let shown = model.showsOutlinePanel
        Button { model.toggleOutline() } label: {
            Label(shown ? "Hide Outline" : "Show Outline", systemImage: "list.bullet.indent")
        }
        .help(model.helpText(shown ? "Hide the outline and links" : "Show the outline and links", .toggleOutline))
    }
}
