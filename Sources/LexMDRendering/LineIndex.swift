import Foundation

/// Where each line of a text starts, to turn offsets into lines and back.
///
/// A line ends at LF, CRLF, or a CR on its own, as the Markdown parser and the editor's text
/// layout both count them, so a line number means the same line everywhere. Offsets are in the
/// units the index was built from: UTF-16 for `init(_:)`, bytes for `init(utf8:)`.
package struct LineIndex: Sendable, Equatable {
    /// The offset of each line's first unit; the first line starts at 0.
    package let starts: [Int]

    package init(_ text: String) {
        self.init(units: text.utf16)
    }

    package init(utf8 bytes: [UInt8]) {
        self.init(units: bytes)
    }

    private init<Units: Sequence>(units: Units) where Units.Element: BinaryInteger {
        var starts = [0]
        var offset = 0
        var afterReturn = false
        for unit in units {
            if afterReturn, unit != 0x0A { starts.append(offset) }
            offset += 1
            if unit == 0x0A { starts.append(offset) }
            afterReturn = unit == 0x0D
        }
        if afterReturn { starts.append(offset) }
        self.starts = starts
    }

    /// The number of lines; a text that ends with a line break has an empty last line.
    package var count: Int { starts.count }

    /// The index (from 0) of the line holding `offset`.
    package func line(at offset: Int) -> Int {
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Where the line at `index` (from 0) starts; indexes past either end give the nearest line.
    package func start(ofLine index: Int) -> Int {
        starts[min(max(index, 0), starts.count - 1)]
    }
}
