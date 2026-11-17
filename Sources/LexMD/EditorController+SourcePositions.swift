import AppKit
import LexMDRendering

/// Source lines and positions in the editor, and the editor as a pane of `ScrollSync`.
extension EditorController {
    // MARK: Source lines

    /// Where each line of the text starts.
    var lineIndex: LineIndex {
        if let cache = lineIndexCache, cache.version == textVersion { return cache.index }
        let index = LineIndex(textView.string)
        lineIndexCache = (textVersion, index)
        return index
    }

    /// The text of lines `lines` (counted from 1), through the last one's line break.
    func range(ofLines lines: ClosedRange<Int>) -> NSRange {
        let index = lineIndex
        let length = (textView.string as NSString).length
        let start = min(index.start(ofLine: lines.lowerBound - 1), length)
        let end = lines.upperBound < index.count ? min(index.start(ofLine: lines.upperBound), length) : length
        return NSRange(location: start, length: max(0, end - start))
    }

    // MARK: Source positions
    //
    // A source position is a line, counted from 1, plus the fraction of it passed, wrapped rows
    // included; see `ScrollSync`. Offsets are heights in the text view.

    /// The text's first and last edges and the document's height.
    private var documentExtent: (textTop: CGFloat, textBottom: CGFloat, height: CGFloat) {
        let top = textView.textContainerOrigin.y
        let used = textView.textLayoutManager?.usageBoundsForTextContainer.maxY ?? 0
        let height = textView.frame.height
        return (top, min(max(top + used, top), height), height)
    }

    /// The frame of the line (paragraph) holding a location, with the text before it laid out:
    /// estimated heights would put it too high or too low.
    private func paragraphFrame(at location: Int) -> CGRect? {
        guard let layout = textView.textLayoutManager, let content = layout.textContentManager else { return nil }
        let start = layout.documentRange.location
        guard let target = content.location(start, offsetBy: location),
              let before = NSTextRange(location: start, end: target) else { return nil }
        layout.ensureLayout(for: before)
        guard let fragment = layout.textLayoutFragment(for: target) else { return nil }
        return fragment.layoutFragmentFrame.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
    }
}

extension EditorController: ScrollSyncPane {
    var syncMetrics: ScrollMetrics? {
        let clip = scrollView.contentView.bounds
        let inset = scrollView.contentInsets.top
        let view = clip.height - inset
        return ScrollMetrics(scroll: clip.minY + inset, view: view, max: max(0, textView.frame.height - view))
    }

    func sourcePosition(at offset: CGFloat) -> Double? {
        let extent = documentExtent
        let lines = Double(lineIndex.count)
        if offset <= extent.textTop { return extent.textTop > 0 ? Double(max(0, offset) / extent.textTop) : 1 }
        guard let layout = textView.textLayoutManager, let content = layout.textContentManager else { return nil }
        let inText = offset - extent.textTop
        layout.ensureLayout(for: CGRect(x: 0, y: inText, width: 1, height: 1))
        // Measured again: laying out replaces estimated heights.
        let bottom = documentExtent.textBottom
        if offset >= bottom {
            let padding = extent.height - bottom
            return lines + 1 + (padding > 0 ? Double(min(1, (offset - bottom) / padding)) : 1)
        }
        guard let fragment = layout.textLayoutFragment(for: CGPoint(x: 1, y: inText)) else { return nil }
        let frame = fragment.layoutFragmentFrame
        let location = content.offset(from: layout.documentRange.location, to: fragment.rangeInElement.location)
        let into = frame.height > 0 ? min(max((inText - frame.minY) / frame.height, 0), 1) : 0
        return min(Double(lineIndex.line(at: location) + 1) + Double(into), lines + 1)
    }

    func offset(ofSourcePosition position: Double) -> CGFloat? {
        let extent = documentExtent
        let lines = Double(lineIndex.count)
        if position <= 1 { return CGFloat(max(0, position)) * extent.textTop }
        if position >= lines + 1 {
            return extent.textBottom + CGFloat(min(1, position - lines - 1)) * (extent.height - extent.textBottom)
        }
        let whole = position.rounded(.down)
        guard let frame = paragraphFrame(at: lineIndex.start(ofLine: Int(whole) - 1)) else { return nil }
        return frame.minY + CGFloat(position - whole) * frame.height
    }

    func followScroll(to scroll: CGFloat) {
        isScrollingQuietly = true
        defer { isScrollingQuietly = false }
        self.scroll(toY: scroll - scrollView.contentInsets.top)
    }
}
