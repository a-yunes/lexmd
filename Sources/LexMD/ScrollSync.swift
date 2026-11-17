import AppKit

/// Keeps the editor and the preview scrolled to the same place in Split view. Whichever pane the
/// reader scrolls leads, and the other follows so both show the same source at the same height.
///
/// Places are named by source position: a line, counted from 1, plus the fraction of it passed
/// (12.5 is halfway down line 12, wrapped rows included). 0 is the very top of a pane's document
/// and `lines + 2` its very end. Each pane maps positions to its own offsets.
@MainActor
final class ScrollSync {
    enum Side { case editor, preview }

    /// How long a pane keeps the lead after its last scroll. Until then, the other pane takes
    /// it only with the reader's input.
    static let hold: TimeInterval = 0.3
    /// How long a pane that starts out of line takes to glide into line.
    static let catchUp: TimeInterval = 0.25

    /// On in Split view. The preview only reports its layout and scrolls while it is on.
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            lead = nil
            preview?.setReportsScrolling(isEnabled)
        }
    }

    private weak var editor: (any ScrollSyncPane)?
    private weak var preview: (any ScrollSyncPane)?
    private let reducesMotion: () -> Bool

    /// The pane the reader last scrolled, the source position it showed, and when it last led.
    private struct Lead {
        var side: Side
        var position: Double
        var last: Date
        /// How far out of line the other pane was when this lead began, and when that was.
        var glide: (distance: CGFloat, began: Date)?
    }
    private var lead: Lead?
    private var glideTask: Task<Void, Never>?

    init(reducesMotion: @escaping () -> Bool = { Motion.isReduced }) {
        self.reducesMotion = reducesMotion
    }

    /// The panes may be connected after syncing was turned on, so the preview is told now.
    func connect(editor: any ScrollSyncPane, preview: any ScrollSyncPane) {
        self.editor = editor
        self.preview = preview
        preview.setReportsScrolling(isEnabled)
    }

    /// A pane scrolled, and not because it was following. `input` says the reader did it with
    /// the wheel, keys or mouse in that pane.
    ///
    /// After a pane follows, its layout settles and moves it a little, and the page keeps its
    /// place when content above loads. Those scrolls come without input, so while the other
    /// pane holds the lead they are not taken for the reader.
    func paneScrolled(_ side: Side, input: Bool, at now: Date = Date()) {
        guard isEnabled, let leader = pane(side) else { return }
        let held = lead.map { now.timeIntervalSince($0.last) < Self.hold } ?? false
        if let lead, lead.side != side, held, !input { return }
        guard let metrics = leader.syncMetrics, let position = leader.sourcePosition(at: metrics.anchorPoint) else { return }

        let continuing = held && lead?.side == side
        var next = Lead(side: side, position: position, last: now, glide: continuing ? lead?.glide : nil)
        // Each pane may have been placed on its own (an outline click, a tab switch). The
        // follower then closes the distance over a moment instead of jumping.
        if !continuing, !reducesMotion(), let distance = distanceToFollow(next), abs(distance) > 2 {
            next.glide = (distance, now)
        }
        lead = next
        if step(at: now), glideTask == nil {
            // A task rather than a timer, which waits while a scroll gesture is being tracked.
            glideTask = Task { [weak self] in
                while let self, self.step(at: Date()) {
                    try? await Task.sleep(for: .milliseconds(16))
                }
                self?.glideTask = nil
            }
        }
    }

    /// Moves the follower to the led position, plus what is left of its starting distance.
    /// Returns whether some of that distance is left.
    @discardableResult
    func step(at now: Date) -> Bool {
        guard isEnabled, var lead = lead, let follower = pane(lead.side == .editor ? .preview : .editor),
              let offset = follower.offset(ofSourcePosition: lead.position),
              // After the offset: finding it may lay out text and change the pane's height.
              let metrics = follower.syncMetrics else { return false }
        var left: CGFloat = 0
        if let glide = lead.glide {
            left = Self.remaining(of: glide.distance, after: now.timeIntervalSince(glide.began))
            if left == 0 { lead.glide = nil }
            // Gliding is still following: the lead holds until it ends.
            lead.last = max(lead.last, now)
        }
        follower.followScroll(to: metrics.scroll(showing: offset) + left)
        self.lead = lead
        return lead.glide != nil
    }

    /// How far the follower is from where the lead puts it.
    private func distanceToFollow(_ lead: Lead) -> CGFloat? {
        guard let follower = pane(lead.side == .editor ? .preview : .editor),
              let offset = follower.offset(ofSourcePosition: lead.position), let metrics = follower.syncMetrics else { return nil }
        return metrics.scroll - metrics.scroll(showing: offset)
    }

    private func pane(_ side: Side) -> (any ScrollSyncPane)? {
        side == .editor ? editor : preview
    }

    /// How much of a starting distance is left after `elapsed` seconds: all of it at first,
    /// easing out to none after `catchUp`.
    static func remaining(of distance: CGFloat, after elapsed: TimeInterval) -> CGFloat {
        let progress = min(1, max(0, elapsed / catchUp))
        return progress >= 1 ? 0 : distance * CGFloat(pow(1 - progress, 3))
    }
}

/// A pane that `ScrollSync` keeps in line with the other. Offsets are measured from the top of
/// the pane's document.
@MainActor
protocol ScrollSyncPane: AnyObject {
    /// Where the pane is scrolled, or nil while it can't say (its page hasn't reported yet).
    var syncMetrics: ScrollMetrics? { get }
    func sourcePosition(at offset: CGFloat) -> Double?
    func offset(ofSourcePosition position: Double) -> CGFloat?
    /// Scrolls to follow the other pane, which is not reported as the reader scrolling.
    func followScroll(to scroll: CGFloat)
    /// Whether the pane reports its scrolls and layout; only the preview has to be told.
    func setReportsScrolling(_ reports: Bool)
}

extension ScrollSyncPane {
    func setReportsScrolling(_ reports: Bool) {}
}

/// How far a pane is scrolled from 0, its visible height, and the furthest it scrolls. Its
/// document's height is `max + view`.
struct ScrollMetrics: Equatable {
    var scroll: CGFloat
    var view: CGFloat
    var max: CGFloat

    /// Where in the view the two panes show the same source, as a distance below its top. It is
    /// mid-height, so the reader can look straight across from one pane to the other. Near the
    /// start of a document it slides to the top edge, and near the end to the bottom edge, so
    /// both ends line up and every part of both documents can be reached.
    var anchorOffset: CGFloat {
        guard max > 0 else { return 0 }
        let reach = min(view, max) / 2
        if scroll < reach { return scroll * (view / 2) / reach }
        if scroll > max - reach { return view - (max - scroll) * (view / 2) / reach }
        return view / 2
    }

    /// The point of the document shown at the anchor.
    var anchorPoint: CGFloat { scroll + anchorOffset }

    /// The scroll that shows the document point `y` at the anchor.
    func scroll(showing y: CGFloat) -> CGFloat {
        guard max > 0 else { return 0 }
        let reach = min(view, max) / 2
        let rate = 1 + view / (2 * reach)
        let height = max + view
        let scroll: CGFloat
        if y < reach + view / 2 {
            scroll = y / rate
        } else if y > height - reach - view / 2 {
            scroll = max - (height - y) / rate
        } else {
            scroll = y - view / 2
        }
        return min(max, Swift.max(0, scroll))
    }
}

/// Source positions paired with offsets, both increasing, with straight lines between them.
struct PositionMap: Equatable {
    private(set) var positions: [Double] = []
    private(set) var offsets: [CGFloat] = []

    /// Pairs that would go backwards in either direction are left out.
    init(_ pairs: [(position: Double, offset: CGFloat)]) {
        for pair in pairs {
            if let position = positions.last, let offset = offsets.last {
                guard pair.position >= position, pair.offset >= offset, pair.position > position || pair.offset > offset else { continue }
            }
            positions.append(pair.position)
            offsets.append(pair.offset)
        }
    }

    func offset(of position: Double) -> CGFloat? {
        guard let index = Self.lastIndex(in: positions, atOrBefore: position) else { return offsets.first }
        guard index < positions.count - 1 else { return offsets.last }
        let span = positions[index + 1] - positions[index]
        return offsets[index] + CGFloat((position - positions[index]) / span) * (offsets[index + 1] - offsets[index])
    }

    func position(at offset: CGFloat) -> Double? {
        guard let index = Self.lastIndex(in: offsets, atOrBefore: offset) else { return positions.first }
        guard index < offsets.count - 1 else { return positions.last }
        let span = offsets[index + 1] - offsets[index]
        return positions[index] + Double((offset - offsets[index]) / span) * (positions[index + 1] - positions[index])
    }

    /// The last index whose value is at most `value`, or nil when every value is greater.
    private static func lastIndex<Value: Comparable>(in values: [Value], atOrBefore value: Value) -> Int? {
        var low = 0, high = values.count
        while low < high {
            let mid = (low + high) / 2
            if values[mid] <= value { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? low - 1 : nil
    }
}
