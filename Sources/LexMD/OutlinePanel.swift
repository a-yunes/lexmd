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

/// Places the outline panel beside the document: trailing when the file tree is on the left,
/// leading when it is on the right.
private struct OutlinePlacement: ViewModifier {
    let edge: HorizontalEdge
    @Environment(AppModel.self) private var model
    @State private var width: CGFloat = 260
    @State private var dragStart: CGFloat?

    func body(content: Content) -> some View {
        HStack(spacing: 0) {
            if edge == .leading, model.showsOutlinePanel {
                panel
                divider
            }
            content
            if edge == .trailing, model.showsOutlinePanel {
                divider
                panel
            }
        }
    }

    private var panel: some View {
        OutlinePanel()
            .frame(width: width)
            .transition(.move(edge: edge == .leading ? .leading : .trailing).combined(with: .opacity))
    }

    /// A divider that resizes the panel when dragged.
    private var divider: some View {
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
                                let delta = value.translation.width * (edge == .leading ? 1 : -1)
                                width = min(max(start + delta, 190), 440)
                            }
                            .onEnded { _ in dragStart = nil }
                    )
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
        Button { model.toggleOutline() } label: {
            Label(model.isOutlineVisible ? "Hide Outline" : "Show Outline", systemImage: "list.bullet.indent")
        }
        .help("Show or hide the outline and links \(model.shortcut(for: .toggleOutline).map { "(\($0.display))" } ?? "")")
    }
}
