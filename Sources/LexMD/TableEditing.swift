import AppKit

/// A GitHub-flavored Markdown table: a header row, an alignment row, and body rows.
struct MarkdownTable: Equatable {
    enum Alignment: Equatable { case none, left, center, right }

    /// Leading whitespace of the header line, kept on every formatted line.
    var indent = ""
    /// The header row followed by the body rows; the alignment row is kept in `alignments`.
    var rows: [[String]]
    var alignments: [Alignment]

    init(rows: [[String]], alignments: [Alignment] = [], indent: String = "") {
        self.rows = rows
        self.alignments = alignments
        self.indent = indent
    }

    /// Parses table lines: a header, an alignment row, then body rows.
    init?(lines: [String]) {
        guard lines.count >= 2, let alignments = Self.alignments(lines[1]) else { return nil }
        let header = lines[0]
        indent = String(header.prefix { $0 == " " || $0 == "\t" })
        rows = ([header] + lines.dropFirst(2)).map(Self.cells)
        self.alignments = alignments
    }

    var columnCount: Int { max(alignments.count, rows.map(\.count).max() ?? 0, 1) }

    // MARK: Parsing

    /// Offsets (UTF-16, within the line) of the pipes that separate cells, ignoring escaped ones.
    static func pipeOffsets(_ line: String) -> [Int] {
        var offsets: [Int] = []
        var escaped = false
        for (offset, unit) in line.utf16.enumerated() {
            if escaped { escaped = false; continue }
            if unit == 0x5C { escaped = true } else if unit == 0x7C { offsets.append(offset) }
        }
        return offsets
    }

    /// The cell boundaries of a line: each cell's raw text range, with outer pipes removed.
    static func cellRanges(_ line: String) -> [NSRange] {
        let ns = line as NSString
        let pipes = pipeOffsets(line)
        var start = 0
        var end = ns.length
        var inner = pipes
        let firstText = line.utf16.firstIndex { $0 != 0x20 && $0 != 0x09 }
            .map { line.utf16.distance(from: line.utf16.startIndex, to: $0) } ?? ns.length
        if let first = inner.first, first == firstText {
            start = first + 1
            inner.removeFirst()
        }
        let trimmedEnd = (line.utf16.lastIndex { $0 != 0x20 && $0 != 0x09 })
            .map { line.utf16.distance(from: line.utf16.startIndex, to: $0) }
        if let last = inner.last, last == trimmedEnd {
            end = last
            inner.removeLast()
        }
        guard start <= end else { return [NSRange(location: start, length: 0)] }
        var ranges: [NSRange] = []
        var cellStart = start
        for pipe in inner {
            ranges.append(NSRange(location: cellStart, length: pipe - cellStart))
            cellStart = pipe + 1
        }
        ranges.append(NSRange(location: cellStart, length: end - cellStart))
        return ranges
    }

    static func cells(_ line: String) -> [String] {
        let ns = line as NSString
        return cellRanges(line).map { ns.substring(with: $0).trimmingCharacters(in: .whitespaces) }
    }

    private static let delimiterCell = try! NSRegularExpression(pattern: #"^:?-+:?$"#)

    /// The column alignments of an alignment row such as `| :-- | :-: | --: |`, or nil.
    static func alignments(_ line: String) -> [Alignment]? {
        guard !pipeOffsets(line).isEmpty else { return nil }
        let cells = Self.cells(line)
        var result: [Alignment] = []
        for cell in cells {
            let range = NSRange(location: 0, length: (cell as NSString).length)
            guard delimiterCell.firstMatch(in: cell, range: range) != nil else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): result.append(.center)
            case (true, false): result.append(.left)
            case (false, true): result.append(.right)
            case (false, false): result.append(.none)
            }
        }
        return result
    }

    static func isDelimiterRow(_ line: String) -> Bool { alignments(line) != nil }

    // MARK: Formatting

    /// The formatted text (lines joined by newlines, no trailing newline) and, for every line,
    /// the range of each cell's content within the whole text. Line 1 is the alignment row.
    func formatted() -> (text: String, cells: [[NSRange]]) {
        let columns = columnCount
        let padded = rows.map { $0 + Array(repeating: "", count: max(0, columns - $0.count)) }
        let aligns = (0..<columns).map { $0 < alignments.count ? alignments[$0] : .none }
        var widths = Array(repeating: 3, count: columns)
        for row in padded {
            for (column, cell) in row.enumerated() { widths[column] = max(widths[column], Self.displayWidth(cell)) }
        }

        var text = ""
        var length = 0
        var cellRanges: [[NSRange]] = []
        func appendLine(_ cells: [(text: String, lead: Int, trail: Int)]) {
            if !text.isEmpty {
                text += "\n"
                length += 1
            }
            var line = indent + "|"
            var offset = length + (line as NSString).length
            var ranges: [NSRange] = []
            for cell in cells {
                let contentLength = (cell.text as NSString).length
                line += " " + String(repeating: " ", count: cell.lead) + cell.text
                    + String(repeating: " ", count: cell.trail) + " |"
                ranges.append(NSRange(location: offset + 1 + cell.lead, length: contentLength))
                offset += 1 + cell.lead + contentLength + cell.trail + 2
            }
            text += line
            length = offset
            cellRanges.append(ranges)
        }
        func row(_ cells: [String]) -> [(text: String, lead: Int, trail: Int)] {
            cells.enumerated().map { column, cell in
                let space = widths[column] - Self.displayWidth(cell)
                switch aligns[column] {
                case .right: return (cell, space, 0)
                case .center: return (cell, space / 2, space - space / 2)
                case .left, .none: return (cell, 0, space)
                }
            }
        }
        appendLine(row(padded[0]))
        appendLine(aligns.enumerated().map { column, align in
            let width = widths[column]
            let cell: String = switch align {
            case .none: String(repeating: "-", count: width)
            case .left: ":" + String(repeating: "-", count: width - 1)
            case .right: String(repeating: "-", count: width - 1) + ":"
            case .center: ":" + String(repeating: "-", count: width - 2) + ":"
            }
            return (cell, 0, 0)
        })
        for cells in padded.dropFirst() { appendLine(row(cells)) }
        return (text, cellRanges)
    }

    // MARK: Display width

    /// Columns a string takes in a monospaced font: wide East Asian characters and emoji count as two.
    static func displayWidth(_ string: String) -> Int {
        string.reduce(0) { $0 + displayWidth($1) }
    }

    static func displayWidth(_ character: Character) -> Int {
        let scalars = character.unicodeScalars
        guard let first = scalars.first else { return 0 }
        switch first.properties.generalCategory {
        case .control, .format, .nonspacingMark, .enclosingMark: return 0
        default: break
        }
        if scalars.contains(where: { $0.properties.isEmojiPresentation })
            || (scalars.contains { $0.value == 0xFE0F } && first.properties.isEmoji) {
            return 2
        }
        return isWide(first.value) ? 2 : 1
    }

    private static let wideRanges: [ClosedRange<UInt32>] = [
        0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
        0xA000...0xA4CF, 0xA960...0xA97F, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19,
        0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF,
        0x20000...0x2FFFD, 0x30000...0x3FFFD,
    ]

    private static func isWide(_ value: UInt32) -> Bool {
        wideRanges.contains { $0.contains(value) }
    }
}

/// A table found in the editor text, with the caret's cell.
struct TableLocation {
    /// The table's text, from the start of the header line to the end of the last row (no newline).
    var range: NSRange
    var lines: [String]
    var table: MarkdownTable
    /// Line within the table (0 header, 1 alignment row, then body rows) and cell column of the caret.
    var line: Int
    var column: Int

    /// Finds the table around `location`, skipping front matter, fenced code, and comments.
    /// `blocks` is only consulted once a table is found.
    static func find(in ns: NSString, at location: Int, blocks: () -> MarkdownBlocks) -> TableLocation? {
        guard location <= ns.length else { return nil }
        func lineRange(at index: Int) -> NSRange {
            ns.lineRange(for: NSRange(location: index, length: 0))
        }
        func content(_ range: NSRange) -> String {
            ns.substring(with: range).trimmingCharacters(in: .newlines)
        }
        func isTableLine(_ range: NSRange) -> Bool {
            let text = content(range)
            return !text.trimmingCharacters(in: .whitespaces).isEmpty && !MarkdownTable.pipeOffsets(text).isEmpty
        }
        var caretLine = lineRange(at: location)
        guard isTableLine(caretLine) else { return nil }
        // Collect the run of lines containing pipes around the caret.
        var lineRanges = [caretLine]
        var index = 0
        while lineRanges[0].location > 0 {
            let previous = lineRange(at: lineRanges[0].location - 1)
            guard isTableLine(previous) else { break }
            lineRanges.insert(previous, at: 0)
            index += 1
        }
        while NSMaxRange(lineRanges[lineRanges.count - 1]) < ns.length {
            let next = lineRange(at: NSMaxRange(lineRanges[lineRanges.count - 1]))
            guard isTableLine(next) else { break }
            lineRanges.append(next)
        }
        let texts = lineRanges.map(content)
        // The table starts at the line above the first alignment row.
        guard let delimiter = texts.indices.dropFirst().first(where: { MarkdownTable.isDelimiterRow(texts[$0]) }),
              delimiter - 1 <= index else { return nil }
        let start = delimiter - 1
        let tableLines = Array(texts[start...])
        guard let table = MarkdownTable(lines: tableLines) else { return nil }
        let first = lineRanges[start]
        let last = lineRanges[lineRanges.count - 1]
        let range = NSRange(location: first.location, length: last.location + (texts.last! as NSString).length - first.location)
        let blocked = blocks().items.contains { NSIntersectionRange($0.range, range).length > 0 }
        guard !blocked else { return nil }
        caretLine = lineRanges[index]
        let offset = location - caretLine.location
        let cellRanges = MarkdownTable.cellRanges(texts[index])
        let column = cellRanges.lastIndex { $0.location <= offset } ?? 0
        return TableLocation(range: range, lines: tableLines, table: table, line: index - start, column: column)
    }
}

extension EditorController {
    /// Tab and Shift-Tab inside a table: realign it and move to the next or previous cell.
    /// Returns false outside tables so Tab keeps its usual behavior.
    func moveTableCell(backward: Bool) -> Bool {
        let selection = textView.selectedRange()
        guard !textView.hasMarkedText(), let found = tableLocation(at: selection.location) else { return false }
        var table = found.table
        let columns = table.columnCount
        let bodyLines = table.rows.count + 1
        var line = found.line
        var column = min(found.column, columns - 1)
        if backward {
            if line == 1 { line = 0; column = columns - 1 }
            else if column > 0 { column -= 1 }
            else if line == 2 { line = 0; column = columns - 1 }
            else if line > 2 { line -= 1; column = columns - 1 }
        } else {
            if line == 1 { line = 2; column = 0 }
            else if column < columns - 1 { column += 1 }
            else { line = line == 0 ? 2 : line + 1; column = 0 }
            if line >= bodyLines {
                table.rows.append(Array(repeating: "", count: columns))
                line = table.rows.count
            }
        }
        let formatted = table.formatted()
        let target = formatted.cells[line][column]
        let range = NSRange(location: found.range.location + target.location, length: target.length)
        applyTableText(formatted.text, replacing: found.range, actionName: "Format Table")
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        return true
    }

    /// Realigns the table around the caret, keeping the caret in the same cell. Beeps outside tables.
    func formatTable() {
        guard textView.window == nil || textView.window?.firstResponder === textView,
              let found = tableLocation(at: textView.selectedRange().location) else {
            NSSound.beep()
            return
        }
        let formatted = found.table.formatted()
        let line = min(found.line, formatted.cells.count - 1)
        let cell = formatted.cells[line][min(found.column, formatted.cells[line].count - 1)]
        applyTableText(formatted.text, replacing: found.range, actionName: "Format Table")
        textView.setSelectedRange(NSRange(location: found.range.location + NSMaxRange(cell), length: 0))
    }

    /// The table around `location`. Runs for every Tab, so it reads the storage without copying
    /// it and reuses the highlighter's blocks instead of rescanning the document.
    func tableLocation(at location: Int) -> TableLocation? {
        guard let string = textView.textStorage?.mutableString else { return nil }
        return TableLocation.find(in: string, at: location) { currentBlocks }
    }

    /// Replaces only the part of the table that changed, as one undoable edit.
    private func applyTableText(_ text: String, replacing range: NSRange, actionName: String) {
        guard let old = textView.textStorage?.mutableString.substring(with: range) else { return }
        guard old != text else { return }
        let a = Array(old.utf16), b = Array(text.utf16)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        // Keep surrogate pairs whole.
        while prefix > 0, UTF16.isLeadSurrogate(a[prefix - 1]) { prefix -= 1 }
        while suffix > 0, UTF16.isTrailSurrogate(a[a.count - suffix]) { suffix -= 1 }
        let replaced = NSRange(location: range.location + prefix, length: a.count - prefix - suffix)
        let replacement = String(utf16CodeUnits: Array(b[prefix..<(b.count - suffix)]), count: b.count - prefix - suffix)
        replace([TextEdit(range: replaced, replacement: replacement)], actionName: actionName)
    }
}
