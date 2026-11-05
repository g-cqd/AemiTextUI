/// An immutable snapshot of a document's text (text-renderer.md §3.2): UTF-8 bytes end to end, row starts, and one
/// ASCII bit per row for the identity fast path. Safe to build off the main actor and hand to a typesetting task,
/// since every stored property is `Sendable` and nothing here is mutated after construction.
public struct StyledText: Sendable {
    /// The document's text, one row after another; a row's bytes never include its own terminator.
    public let utf8: [UInt8]
    /// The byte offset of each row's first byte, `rowCount + 1` entries ascending, the last equal to `utf8.count`.
    public let rowStarts: [UInt32]
    public let runs: LineRuns
    public let styles: StyleSheet
    /// Whether `rowStarts` had to be repaired to be consistent with `utf8` (see ``init(utf8:rowStarts:runs:styles:)``).
    public let wasRepaired: Bool
    /// One bit per row: whether every byte in it is ASCII, so a scalar-boundary search can skip decoding.
    private let asciiRows: [Bool]

    /// A text from its bytes and where each row starts. The starts are trusted only as far as they are consistent: each is held to the bytes, to at least the one before it, and the last to the end, so a list that is out of order or points past
    /// the text gives empty rows where it is wrong and not a trap at the first slice (`wasRepaired` says it happened). A list of fewer than two starts is no rows.
    public init(utf8: [UInt8], rowStarts: [UInt32], runs: LineRuns, styles: StyleSheet) {
        let (starts, repaired) = Self.consistent(rowStarts, byteCount: utf8.count)
        self.utf8 = utf8
        self.rowStarts = starts
        self.runs = runs
        self.styles = styles
        wasRepaired = repaired
        asciiRows = starts.indices.dropLast()
            .map { index in
                utf8[Int(starts[index]) ..< Int(starts[index + 1])].allSatisfy { $0 < 0x80 }
            }
    }

    /// `starts` made ascending and held to `0 ... byteCount`, the last set to `byteCount`; and whether that changed anything.
    private static func consistent(_ starts: [UInt32], byteCount: Int) -> ([UInt32], Bool) {
        guard starts.count >= 2 else { return ([], starts.count == 1) }
        let limit = UInt32(clamping: byteCount)
        var fixed = starts
        var repaired = false
        var previous: UInt32 = 0
        for index in fixed.indices {
            let wanted = index == fixed.count - 1 ? limit : Swift.min(Swift.max(fixed[index], previous), limit)
            if wanted != fixed[index] {
                fixed[index] = wanted
                repaired = true
            }
            previous = wanted
        }
        // A text longer than 32-bit offsets reach is cut where they stop: the rows it has are right and the rest is not drawn.
        return (fixed, repaired)
    }

    public var rowCount: Int { max(rowStarts.count - 1, 0) }

    /// - Complexity: O(1).
    public func bytes(ofRow row: RowIndex) -> ArraySlice<UInt8> {
        let index = row.index
        guard rowStarts.indices.contains(index), rowStarts.indices.contains(index + 1) else { return [] }
        return utf8[Int(rowStarts[index]) ..< Int(rowStarts[index + 1])]
    }

    public func isASCII(row: RowIndex) -> Bool {
        asciiRows.indices.contains(row.index) ? asciiRows[row.index] : true
    }

    /// The row a byte offset from the document's start falls in.
    /// - Complexity: O(log rows)
    public func row(containingDocumentOffset offset: Int) -> RowIndex {
        guard rowCount > 0 else { return RowIndex(0) }
        var low = 0
        var high = rowCount
        while low < high {
            let middle = (low + high + 1) / 2
            if Int(rowStarts[middle]) <= offset { low = middle } else { high = middle - 1 }
        }
        return RowIndex(low)
    }
}

extension StyledText {
    /// Builds a text from plain UTF-8 rows, every byte in the plain style (`StyleID(0)`); a caller layers runs on top
    /// through ``LineRuns`` when it has them.
    public static func plain(rows: [[UInt8]], font: FontSpec, plainStyle: TextStyle) -> StyledText {
        var utf8: [UInt8] = []
        var rowStarts: [UInt32] = []
        rowStarts.reserveCapacity(rows.count + 1)
        for row in rows {
            // Offsets are 32 bits: rows that would start beyond them are not taken.
            guard utf8.count <= Int(UInt32.max) - row.count else { break }
            rowStarts.append(UInt32(utf8.count))
            utf8.append(contentsOf: row)
        }
        rowStarts.append(UInt32(utf8.count))
        return StyledText(
            utf8: utf8,
            rowStarts: rowStarts,
            runs: .empty(rowCount: Swift.max(rowStarts.count - 1, 0)),
            styles: StyleSheet(font: font, styles: [plainStyle])
        )
    }

    /// Builds a text from plain `String` rows, for tests and simple hosts.
    public static func plain(rows: [String], font: FontSpec, plainStyle: TextStyle) -> StyledText {
        .plain(rows: rows.map { Array($0.utf8) }, font: font, plainStyle: plainStyle)
    }
}
