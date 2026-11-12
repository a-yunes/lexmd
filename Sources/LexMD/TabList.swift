import Foundation
import Observation

/// Find bar state remembered per tab.
struct TabFindState: Equatable {
    var query: String
    var caseSensitive: Bool
    var index: Int
}

/// What a tab remembers while another tab is showing.
struct TabViewState: Equatable {
    var selection = NSRange(location: 0, length: 0)
    var editorOrigin: CGPoint?
    var previewFraction: Double?
    var history: [String] = []
    var historyIndex = -1
    var find: TabFindState?
    /// Text that could not be saved when the tab was left, so it is never lost.
    var unsavedText: String?
}

struct DocumentTab: Identifiable, Equatable {
    let id: UUID
    var path: String
    var state = TabViewState()

    init(path: String, id: UUID = UUID()) {
        self.id = id
        self.path = path
    }

    var title: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
}

/// The open documents of one window, in order, plus recently closed ones. Pure value logic.
struct TabList: Equatable {
    struct Closed: Equatable {
        var tab: DocumentTab
        var index: Int
    }

    static let closedLimit = 20

    private(set) var tabs: [DocumentTab] = []
    private(set) var activeID: UUID?
    private(set) var closed: [Closed] = []

    var isEmpty: Bool { tabs.isEmpty }
    var count: Int { tabs.count }
    var active: DocumentTab? { activeID.flatMap { id in tabs.first { $0.id == id } } }
    var activeIndex: Int? { activeID.flatMap(index(of:)) }

    func index(of id: UUID) -> Int? { tabs.firstIndex { $0.id == id } }
    func tab(_ id: UUID) -> DocumentTab? { tabs.first { $0.id == id } }
    func tab(withPath path: String) -> DocumentTab? { tabs.first { $0.path == path } }

    /// Opens a tab right after the active one and makes it active.
    @discardableResult
    mutating func open(_ path: String, at requested: Int? = nil) -> DocumentTab {
        let tab = DocumentTab(path: path)
        insert(tab, at: requested)
        return tab
    }

    mutating func insert(_ tab: DocumentTab, at requested: Int? = nil) {
        let index = min(max(requested ?? (activeIndex.map { $0 + 1 } ?? tabs.count), 0), tabs.count)
        tabs.insert(tab, at: index)
        activeID = tab.id
    }

    /// Shows a different document in the active tab, opening the first tab when there is none.
    mutating func replaceActive(with path: String) {
        if let index = activeIndex {
            tabs[index].path = path
        } else {
            open(path)
        }
    }

    mutating func activate(_ id: UUID) {
        guard index(of: id) != nil else { return }
        activeID = id
    }

    /// Closes a tab and returns the tab to show next when the active one closed: the one to its
    /// right, else the one to its left.
    @discardableResult
    mutating func close(_ id: UUID, remember: Bool = true) -> UUID? {
        guard let index = index(of: id) else { return activeID }
        let tab = tabs.remove(at: index)
        if remember {
            closed.append(Closed(tab: tab, index: index))
            if closed.count > Self.closedLimit { closed.removeFirst(closed.count - Self.closedLimit) }
        }
        if activeID == id {
            activeID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
        return activeID
    }

    /// Takes the most recently closed tab whose file still exists.
    mutating func popClosed(exists: (String) -> Bool) -> Closed? {
        while let last = closed.popLast() {
            if exists(last.tab.path) { return last }
        }
        return nil
    }

    /// The tab `offset` places from the active one, wrapping around.
    func neighbor(_ offset: Int) -> UUID? {
        guard let index = activeIndex, tabs.count > 1 else { return nil }
        let count = tabs.count
        return tabs[((index + offset) % count + count) % count].id
    }

    mutating func move(_ id: UUID, to destination: Int) {
        guard let from = index(of: id) else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: min(max(destination, 0), tabs.count))
    }

    mutating func update(_ id: UUID, _ body: (inout DocumentTab) -> Void) {
        guard let index = index(of: id) else { return }
        body(&tabs[index])
    }

    /// Rewrites paths after a rename or move, in open tabs, their history, and closed tabs.
    mutating func remap(_ transform: (String) -> String?) {
        func apply(_ tab: inout DocumentTab) {
            if let path = transform(tab.path) { tab.path = path }
            tab.state.history = tab.state.history.map { transform($0) ?? $0 }
        }
        for index in tabs.indices { apply(&tabs[index]) }
        for index in closed.indices { apply(&closed[index].tab) }
    }

    /// Closes tabs whose document matches, without remembering them. Returns the new active tab.
    mutating func removeAll(where shouldRemove: (String) -> Bool) -> UUID? {
        for tab in tabs where shouldRemove(tab.path) { close(tab.id, remember: false) }
        closed.removeAll { shouldRemove($0.tab.path) }
        return activeID
    }

    mutating func removeAll() {
        tabs = []
        activeID = nil
        closed = []
    }

    /// Titles that tell apart tabs with the same file name by adding the folder.
    func titles() -> [UUID: String] {
        var counts: [String: Int] = [:]
        for tab in tabs { counts[tab.title.lowercased(), default: 0] += 1 }
        var result: [UUID: String] = [:]
        for tab in tabs {
            if counts[tab.title.lowercased(), default: 0] > 1 {
                let folder = ((tab.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                result[tab.id] = "\(tab.title) · \(folder)"
            } else {
                result[tab.id] = tab.title
            }
        }
        return result
    }

    /// Saved tabs that can be restored: inside `root`, still present, without duplicates.
    static func restorable(paths: [String], active: Int, root: String, exists: (String) -> Bool) -> (paths: [String], active: Int) {
        var kept: [String] = []
        var keptActive = 0
        for (index, path) in paths.enumerated() {
            guard path.hasPrefix(root + "/"), FileScanner.isMarkdown(path: path), exists(path), !kept.contains(path) else { continue }
            kept.append(path)
            if index <= active { keptActive = kept.count - 1 }
        }
        return (kept, kept.isEmpty ? 0 : keptActive)
    }
}

/// Observable home of the window's tabs.
@MainActor
@Observable
final class TabStore {
    var list = TabList()
    var alwaysShowTabBar: Bool {
        didSet { UserDefaults.standard.set(alwaysShowTabBar, forKey: AppModel.Keys.alwaysShowTabBar) }
    }
    /// The tab being dragged in the tab bar.
    var draggingID: UUID?

    init() {
        alwaysShowTabBar = UserDefaults.standard.bool(forKey: AppModel.Keys.alwaysShowTabBar)
    }
}
