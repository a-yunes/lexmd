import AppKit
import CoreServices
import Observation
import SwiftUI

struct OutlineHeading: Identifiable, Hashable, Sendable {
    let id: Int
    var level: Int
    var title: String
    var slug: String
    var line: Int
    var range: NSRange
}

/// A place in another document that links to the current one.
struct Backlink: Identifiable, Hashable, Sendable {
    var id: String { "\(path):\(range.location)" }
    var path: String
    var name: String
    var folder: String
    var line: Int
    var range: NSRange
    /// The linking line, trimmed.
    var context: String
}

/// A link in the current document whose file or heading does not exist.
struct LinkProblem: Identifiable, Hashable, Sendable {
    let id: Int
    var message: String
    var target: String
    var line: Int
    var range: NSRange
}

/// The current document's outline, backlinks, and link problems, analyzed off the main thread.
struct OutlineAnalysis: Sendable {
    var headings: [OutlineHeading] = []
    var problems: [LinkProblem] = []

    static func make(source: String, context: LinkContext) -> OutlineAnalysis {
        let structure = DocumentStructure.analyze(source)
        var context = LinkContext(
            documentPath: context.documentPath, source: source, snapshot: context.snapshot, anchors: structure.anchors
        )
        var result = OutlineAnalysis()
        result.headings = structure.headings.enumerated().map { index, heading in
            OutlineHeading(id: index, level: heading.level, title: heading.title, slug: heading.slug, line: heading.line, range: heading.range)
        }
        for link in structure.links {
            let message: String?
            switch link.kind {
            case .link, .image: message = context.problem(forDestination: link.destination)
            case .wiki: message = link.wiki.flatMap { context.problem(for: $0) }
            }
            guard let message else { continue }
            let target = link.kind == .wiki ? (source as NSString).substring(with: link.range) : link.destination
            result.problems.append(LinkProblem(id: result.problems.count, message: message, target: target, line: link.line, range: link.range))
        }
        return result
    }
}

extension Backlink {
    static let limit = 200

    /// Reads the line of each reference, opening each linking file once.
    static func load(_ references: [LinkReference], root: String?) -> [Backlink] {
        var lines: [String: SourceLines] = [:]
        var result: [Backlink] = []
        for reference in references.prefix(limit) {
            guard !Task.isCancelled else { break }
            if lines[reference.source] == nil {
                let text = (try? String(contentsOfFile: reference.source, encoding: .utf8)) ?? ""
                lines[reference.source] = SourceLines(text)
            }
            var context = lines[reference.source]?.string(ofLine: reference.line).trimmingCharacters(in: .whitespaces) ?? ""
            if context.count > 240 { context = String(context.prefix(240)) + "…" }
            let folder = (reference.source as NSString).deletingLastPathComponent
            var relative = folder
            if let root, folder.hasPrefix(root) { relative = String(folder.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            result.append(Backlink(
                path: reference.source, name: ((reference.source as NSString).lastPathComponent as NSString).deletingPathExtension,
                folder: relative, line: reference.line, range: reference.range, context: context
            ))
        }
        return result
    }
}

@MainActor
@Observable
final class OutlineModel {
    private(set) var headings: [OutlineHeading] = []
    /// The heading whose section is in view.
    private(set) var currentHeading: Int?
    private(set) var backlinks: [Backlink] = []
    /// All links to the document; `backlinks` lists at most `Backlink.limit` of them.
    private(set) var backlinkCount = 0
    private(set) var problems: [LinkProblem] = []
    let index = LinkIndex()

    @ObservationIgnored private(set) var documentPath: String?
    @ObservationIgnored private(set) var backlinksPath: String?
    @ObservationIgnored private var backlinkReferences: [LinkReference] = []
    @ObservationIgnored var analysisTask: Task<Void, Never>?
    @ObservationIgnored var backlinkTask: Task<Void, Never>?
    @ObservationIgnored var completion: EditorCompletion?
    @ObservationIgnored var observers: [NSObjectProtocol] = []
    @ObservationIgnored var lastEditorScroll = Date.distantPast
    /// The heading id the preview last reported.
    @ObservationIgnored var previewSlug: String?
    @ObservationIgnored private var headingCache: (source: String, headings: [HeadingInfo])?

    func apply(_ analysis: OutlineAnalysis, path: String) {
        if documentPath != path { currentHeading = nil }
        documentPath = path
        if headings != analysis.headings { headings = analysis.headings }
        if problems != analysis.problems { problems = analysis.problems }
        if let current = currentHeading, current >= headings.count { currentHeading = nil }
    }

    func setBacklinks(_ links: [Backlink], references: [LinkReference], path: String?) {
        backlinksPath = path
        backlinkReferences = references
        if backlinks != links { backlinks = links }
        if backlinkCount != references.count { backlinkCount = references.count }
    }

    func needsBacklinks(_ references: [LinkReference], path: String) -> Bool {
        backlinksPath != path || backlinkReferences != references
    }

    func clear() {
        documentPath = nil
        headings = []
        problems = []
        currentHeading = nil
        previewSlug = nil
        setBacklinks([], references: [], path: nil)
    }

    func setCurrentHeading(_ id: Int?) {
        if currentHeading != id { currentHeading = id }
    }

    /// The last heading at or before a text location.
    func heading(atLocation location: Int) -> Int? {
        headings.last { $0.range.location <= location }?.id
    }

    func heading(forSlug slug: String) -> Int? {
        headings.first { $0.slug == slug }?.id
    }

    /// Headings of a text, parsed once per version of the text.
    func headings(of source: String) -> [HeadingInfo] {
        if let headingCache, headingCache.source == source { return headingCache.headings }
        let headings = DocumentStructure.analyze(source).headings
        headingCache = (source, headings)
        return headings
    }
}

extension AppModel {
    func setUpLinks() {
        preview.onHeadingChange = { [weak self] id in self?.previewHeadingChanged(id) }
        outline.index.onUpdate = { [weak self] previous in self?.linkIndexDidUpdate(from: previous) }
        outline.observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: editor.scrollView.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.editorDidScroll() }
        })
        let completion = EditorCompletion(textView: editor.textView)
        completion.isEnabled = { [weak self] in self?.suggestsLinks ?? false }
        completion.provider = { [weak self] context in self?.linkSuggestions(for: context) ?? [] }
        editor.onCommand = { [weak completion] selector in completion?.handle(selector) ?? false }
        outline.completion = completion
    }

    func toggleOutline() {
        withAnimation(.snappy(duration: 0.25)) { isOutlineVisible.toggle() }
    }

    func outlineVisibilityChanged() {
        guard isOutlineVisible else { return }
        if outline.documentPath != currentFile?.path { outline.clear() }
        scheduleOutlineUpdate(debounce: false)
        updateBacklinks()
    }

    func linkSettingsChanged() {
        if currentFile != nil { render(debounce: false) }
    }

    // MARK: Index upkeep

    func linksTreeDidChange() {
        outline.index.setRoot(rootURL?.path)
    }

    /// Re-reads changed documents and images; folder changes rescan the whole project.
    func linksHandleFileEvents(_ events: [DirectoryWatcher.Event], root: String) {
        var paths: [String] = []
        var rescan = false
        for event in events where !FileScanner.isIgnored(event.path, root: root) {
            let flags = Int(event.flags)
            if flags & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0 {
                rescan = true
            } else if flags & kFSEventStreamEventFlagItemIsDir != 0 {
                let moved = kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed
                if flags & moved != 0 { rescan = true }
            } else if FileScanner.isMarkdown(path: event.path) || LinkIndexBuilder.isImage(path: event.path) {
                paths.append(event.path)
            }
        }
        if rescan { outline.index.refresh() } else if !paths.isEmpty { outline.index.update(paths: paths) }
    }

    private func linkIndexDidUpdate(from previous: LinkIndexSnapshot) {
        let snapshot = outline.index.snapshot
        if currentFile != nil, snapshot.structureVersion != previous.structureVersion {
            // Wiki links and anchors in the preview may resolve differently now.
            render(debounce: false)
        }
        updateBacklinks()
    }

    /// The link checker for the current document, used while rendering and analyzing.
    func linkContext(for source: String) -> LinkContext {
        LinkContext(documentPath: currentFile?.path, source: source, snapshot: outline.index.snapshot, marksBrokenLinks: marksBrokenLinks)
    }

    // MARK: Analysis

    func scheduleOutlineUpdate(debounce: Bool) {
        outline.analysisTask?.cancel()
        guard let path = currentFile?.path else { outline.clear(); return }
        guard isOutlineVisible else { return }
        if outline.backlinksPath != path { updateBacklinks() }
        let source = text
        let context = linkContext(for: source)
        outline.analysisTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            let analysis = await runDetached { OutlineAnalysis.make(source: source, context: context) }
            guard let self, !Task.isCancelled, self.currentFile?.path == path else { return }
            self.outline.apply(analysis, path: path)
            self.refreshCurrentHeading()
        }
    }

    func updateBacklinks() {
        guard isOutlineVisible, let path = currentFile?.path else { return }
        let references = outline.index.snapshot.incoming[path] ?? []
        guard outline.needsBacklinks(references, path: path) else { return }
        outline.backlinkTask?.cancel()
        let root = rootURL?.path
        outline.backlinkTask = Task { [weak self] in
            let links = await runDetached { Backlink.load(references, root: root) }
            guard let self, !Task.isCancelled, self.currentFile?.path == path else { return }
            self.outline.setBacklinks(links, references: references, path: path)
        }
    }

    // MARK: Following the reader

    private func previewHeadingChanged(_ slug: String) {
        outline.previewSlug = slug
        guard isOutlineVisible, viewMode != .edit else { return }
        // In split view the editor leads; the preview follows it.
        if viewMode == .split, Date().timeIntervalSince(outline.lastEditorScroll) < 0.5 { return }
        outline.setCurrentHeading(slug.isEmpty ? nil : outline.heading(forSlug: slug))
    }

    private func editorDidScroll() {
        guard isOutlineVisible, viewMode != .read, currentFile != nil else { return }
        outline.lastEditorScroll = Date()
        outline.setCurrentHeading(outline.heading(atLocation: editor.topVisibleLocation()))
    }

    private func refreshCurrentHeading() {
        if viewMode == .read, let slug = outline.previewSlug {
            outline.setCurrentHeading(slug.isEmpty ? nil : outline.heading(forSlug: slug))
        } else if viewMode != .read {
            outline.setCurrentHeading(outline.heading(atLocation: editor.topVisibleLocation()))
        }
    }

    // MARK: Navigation

    /// Scrolls the preview and the editor to a heading from the outline.
    func revealHeading(_ heading: OutlineHeading) {
        outline.setCurrentHeading(heading.id)
        if viewMode != .read {
            editor.revealAtTop(heading.range.location)
            outline.lastEditorScroll = Date()
        }
        if viewMode != .edit { preview.revealHeading(heading.slug, smooth: true) }
    }

    /// Opens a Markdown document, then scrolls to the heading a link's `#fragment` names.
    /// A document already open in another tab shows that tab.
    func openDocument(_ file: URL, fragment: String?, inNewTab: Bool = false) {
        let wasOpen = currentFile?.path == file.path
        openPath(file.path, inNewTab: inNewTab)
        guard let fragment, !fragment.isEmpty, currentFile?.path == file.path else { return }
        revealAnchor(fragment, afterRender: !wasOpen)
    }

    private func revealAnchor(_ slug: String, afterRender: Bool) {
        if viewMode != .read, let heading = outline.headings(of: text).first(where: { $0.slug == slug }) {
            editor.revealAtTop(heading.range.location)
        }
        if viewMode != .edit { preview.revealHeading(slug, smooth: !afterRender, afterRender: afterRender) }
    }

    /// Opens a linking document at the link; Command-click opens it in a new tab.
    func openBacklink(_ link: Backlink, inNewTab: Bool = NSEvent.modifierFlags.contains(.command)) {
        let wasOpen = currentFile?.path == link.path
        openPath(link.path, inNewTab: inNewTab)
        guard currentFile?.path == link.path else { return }
        if viewMode != .read { editor.reveal(link.range, indicator: true, select: true) }
        if viewMode != .edit, let heading = outline.headings(of: text).last(where: { $0.line <= link.line }) {
            preview.revealHeading(heading.slug, smooth: wasOpen, afterRender: !wasOpen)
        }
    }

    /// Selects a broken link in the editor, showing the editor if needed.
    func selectProblem(_ problem: LinkProblem) {
        guard viewMode == .read else {
            editor.reveal(problem.range, indicator: true, select: true)
            editor.focus()
            return
        }
        setViewMode(.split)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            self?.editor.reveal(problem.range, indicator: true, select: true)
            self?.editor.focus()
        }
    }

    // MARK: Completion

    /// Suggestions for the link target being typed in the editor.
    func linkSuggestions(for context: CompletionContext) -> [CompletionItem] {
        let snapshot = outline.index.snapshot
        let current = currentFile?.path
        guard let folder = current.map({ ($0 as NSString).deletingLastPathComponent }) ?? rootURL?.path else { return [] }
        let root = rootURL?.path ?? folder
        switch context.kind {
        case .path(let image):
            var candidates: [EditorCompletion.Candidate] = []
            for path in snapshot.markdownPaths where path != current {
                candidates.append(fileCandidate(path, kind: .document, folder: folder, root: root, group: image ? 1 : 0))
            }
            for path in snapshot.imagePaths {
                candidates.append(fileCandidate(path, kind: .image, folder: folder, root: root, group: image ? 0 : 1))
            }
            var query = context.query.removingPercentEncoding ?? context.query
            while query.hasPrefix("./") { query.removeFirst(2) }
            return EditorCompletion.rank(query, candidates)

        case .heading(let file):
            var path = current
            if !file.isEmpty {
                guard case .file(let target, _) = LinkDestination(file, folder: folder) else { return [] }
                path = target
            }
            return headingSuggestions(in: path, snapshot: snapshot, query: context.query, insertTitle: false)

        case .wiki:
            let candidates = snapshot.markdownPaths.filter { $0 != current }.map { path -> EditorCompletion.Candidate in
                let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                let relative = WikiLinkResolver.stem(LinkPaths.relative(path, from: root))
                let insertion = snapshot.resolver.isAmbiguous(path) ? relative : name
                let parent = (relative as NSString).deletingLastPathComponent
                return EditorCompletion.Candidate(
                    item: CompletionItem(id: path, kind: .document, title: name, detail: parent, insertion: insertion),
                    keys: [name, relative], weight: -LinkPaths.relative(path, from: folder).count
                )
            }
            return EditorCompletion.rank(context.query, candidates)

        case .wikiHeading(let name):
            let path = name.isEmpty ? current : snapshot.resolve(name, from: current)
            return headingSuggestions(in: path, snapshot: snapshot, query: context.query, insertTitle: true)
        }
    }

    private func fileCandidate(_ path: String, kind: CompletionItem.Kind, folder: String, root: String, group: Int) -> EditorCompletion.Candidate {
        let relative = LinkPaths.relative(path, from: folder)
        let fromRoot = LinkPaths.relative(path, from: root)
        let name = (path as NSString).lastPathComponent
        return EditorCompletion.Candidate(
            item: CompletionItem(id: path, kind: kind, title: name, detail: (fromRoot as NSString).deletingLastPathComponent, insertion: LinkPaths.encode(relative)),
            keys: [name, relative, fromRoot], group: group, weight: -relative.count
        )
    }

    private func headingSuggestions(in path: String?, snapshot: LinkIndexSnapshot, query: String, insertTitle: Bool) -> [CompletionItem] {
        guard let path else { return [] }
        let headings: [(title: String, slug: String, level: Int)]
        if path == currentFile?.path {
            headings = outline.headings(of: text).map { ($0.title, $0.slug, $0.level) }
        } else {
            headings = snapshot.documents[path]?.headings.map { ($0.title, $0.slug, $0.level) } ?? []
        }
        let candidates = headings.enumerated().map { index, heading in
            EditorCompletion.Candidate(
                item: CompletionItem(
                    id: "\(index):\(heading.slug)", kind: .heading, title: heading.title,
                    detail: String(repeating: "#", count: heading.level), insertion: insertTitle ? heading.title : heading.slug
                ),
                keys: [heading.title, heading.slug], weight: -index
            )
        }
        return EditorCompletion.rank(query, candidates)
    }
}

extension EditorController {
    /// Moves the caret to a location and scrolls its line to the top of the editor.
    func revealAtTop(_ location: Int) {
        let length = (textView.string as NSString).length
        let range = NSRange(location: min(max(location, 0), length), length: 0)
        textView.setSelectedRange(range)
        guard let window = textView.window else { textView.scrollRangeToVisible(range); return }
        let screenRect = textView.firstRect(forCharacterRange: range, actualRange: nil)
        guard screenRect != .zero else { textView.scrollRangeToVisible(range); return }
        let rect = textView.convert(window.convertFromScreen(screenRect), from: nil)
        let clip = scrollView.contentView
        let top = scrollView.contentInsets.top
        let maxY = max(-top, textView.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(max(rect.minY - top - 12, -top), maxY)))
        scrollView.reflectScrolledClipView(clip)
    }

    /// The text location at the top of the visible editor area.
    func topVisibleLocation() -> Int {
        let bounds = scrollView.contentView.bounds
        let point = NSPoint(x: textView.textContainerInset.width + 4, y: bounds.minY + scrollView.contentInsets.top + 24)
        return textView.characterIndexForInsertion(at: point)
    }
}
