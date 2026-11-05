import CoreGraphics
import Testing

@testable import AemiTextRendering

/// What the renderer does with input that is wrong, as opposed to the cases that only show it does not trap (`HostileInputTests`).
@Suite("Robustness")
struct RobustnessTests {
    static let style = TextStyle(foreground: .fixed(RGBA(red: 0, green: 0, blue: 0)))
    static let font = FontSpec(pointSize: 12)

    @Test func `invalid UTF-8 keeps the byte and UTF-16 maps aligned`() {
        // A lone continuation byte, a truncated three-byte sequence, an overlong start, and valid text around them.
        let bytes: [UInt8] =
            Array("a".utf8) + [0x80] + Array("b".utf8) + [0xE2, 0x82] + Array("c".utf8) + [0xC0] + Array("é".utf8)
        let row = RowText(bytes: bytes[...])
        // Every ill-formed subpart is one U+FFFD of one UTF-16 unit, standing for the bytes it replaced.
        #expect(row.string == "a\u{FFFD}b\u{FFFD}c\u{FFFD}é")
        #expect(row.utf16Count == 7)
        #expect(row.utf16Offset(atByte: bytes.count) == 7)
        // Bytes: a 0, 0x80 1, b 2, 0xE2 0x82 3-4, c 5, 0xC0 6, é 7-8. UTF-16: a 0, U+FFFD 1, b 2, U+FFFD 3, c 4, U+FFFD 5, é 6.
        #expect(row.utf16Offset(atByte: 5) == 4)
        #expect(row.byteOffset(atUTF16: 4) == 5)
        #expect(row.utf16Offset(atByte: 7) == 6)
        #expect(row.byteOffset(atUTF16: 6) == 7)
        // The two maps invert each other at every boundary of a scalar.
        for unit in 0 ... row.utf16Count { #expect(row.utf16Offset(atByte: row.byteOffset(atUTF16: unit)) == unit) }
    }

    @Test func `offsets outside a row are held to it`() {
        let row = RowText(bytes: Array("héllo".utf8)[...])
        #expect(row.utf16Offset(atByte: -5) == 0)
        #expect(row.utf16Offset(atByte: 1_000) == 5)
        #expect(row.byteOffset(atUTF16: -1) == 0)
        #expect(row.byteOffset(atUTF16: 1_000) == 6)
    }

    @Test func `row starts that are wrong are repaired, and say so`() {
        let styles = StyleSheet(font: Self.font, styles: [Self.style])
        let bytes = Array("abcdef".utf8)
        let good = StyledText(utf8: bytes, rowStarts: [0, 3, 6], runs: .empty(rowCount: 2), styles: styles)
        #expect(!good.wasRepaired)
        #expect(Array(good.bytes(ofRow: RowIndex(1))) == Array("def".utf8))
        let descending = StyledText(utf8: bytes, rowStarts: [0, 5, 2, 6], runs: .empty(rowCount: 3), styles: styles)
        #expect(descending.wasRepaired)
        #expect(descending.rowStarts == [0, 5, 5, 6])
        let past = StyledText(utf8: bytes, rowStarts: [0, 99, 100], runs: .empty(rowCount: 2), styles: styles)
        #expect(past.rowStarts == [0, 6, 6])
        let open = StyledText(utf8: bytes, rowStarts: [0, 3], runs: .empty(rowCount: 1), styles: styles)
        #expect(open.rowStarts == [0, 6], "the last start is the end of the text")
        #expect(StyledText(utf8: bytes, rowStarts: [], runs: .empty(rowCount: 0), styles: styles).rowCount == 0)
    }

    @Test func `runs with offsets that disagree give the row no runs, and a good row keeps its own`() {
        let runs = LineRuns(
            runs: [
                LineRuns.Run(start: 0, length: 2, style: StyleID(0)),
                LineRuns.Run(start: 2, length: 1, style: StyleID(0)),
                LineRuns.Run(start: 3, length: 1, style: StyleID(0))
            ],
            offsets: [0, 2, 1, 3, 9]
        )
        #expect(runs[RowIndex(0)].count == 2)
        #expect(runs[RowIndex(1)].isEmpty, "offsets 2 then 1 run backwards")
        #expect(runs[RowIndex(2)].count == 2)
        #expect(runs[RowIndex(3)].isEmpty, "an offset past the runs")
        #expect(runs[RowIndex(-1)].isEmpty)
    }

    @Test func `a configuration is held to ranges in which layout is defined`() {
        let clean = LayoutConfiguration(
            wrap: .width(.nan),
            lineHeight: .nan,
            lineHeightMultiple: -3,
            tabWidth: -4,
            continuationIndent: 9_999,
            padding: .infinity,
            maxRowBytes: 3
        )
        .sanitized
        #expect(clean.wrap == .none)
        #expect(clean.lineHeight == 16)
        #expect(clean.lineHeightMultiple == 0.1)
        #expect(clean.tabWidth == 1)
        #expect(clean.continuationIndent == 256)
        #expect(clean.padding == 0)
        #expect(clean.maxRowBytes == 256)
        #expect(LayoutConfiguration(wrap: .columns(0), lineHeight: 16).sanitized.wrap == .none)
        #expect(LayoutConfiguration(wrap: .width(-5), lineHeight: 16).sanitized.wrap == .width(1))
        // A good configuration is unchanged.
        let fine = LayoutConfiguration(
            wrap: .width(600),
            lineHeight: 18,
            lineHeightMultiple: 1.2,
            tabWidth: 4,
            padding: 8
        )
        #expect(fine.sanitized == fine)
    }

    @Test func `the carets of a long line agree with the exact ones where the text is plain`() throws {
        // Over 1,024 units the carets come from the glyph runs; the same characters in rows of 1,000 give the exact ones, and the advance of a plain monospaced character is the same either way.
        let short = StyledText.plain(
            rows: [String(repeating: "x", count: 1_000)],
            font: Self.font,
            plainStyle: Self.style
        )
        let long = StyledText.plain(
            rows: [String(repeating: "x", count: 3_000)],
            font: Self.font,
            plainStyle: Self.style
        )
        let configuration = LayoutConfiguration(wrap: .none, lineHeight: 16)
        let exact =
            try
            TextTypesetter.layoutSynchronously(RowIndex(0) ..< RowIndex(1), of: short, configuration: configuration)[0]
            .lines[0].carets
        let linear =
            try TextTypesetter.layoutSynchronously(RowIndex(0) ..< RowIndex(1), of: long, configuration: configuration)[
                0
            ]
            .lines[0].carets
        #expect(exact.count == 1_001)
        #expect(linear.count == 3_001)
        for index in 0 ... 1_000 { #expect(abs(exact[index] - linear[index]) < 0.01, "caret \(index)") }
        for index in 1 ..< linear.count { #expect(linear[index] >= linear[index - 1], "caret \(index) goes back") }
    }

    @Test func `a row longer than the cap is typeset as far as the cap, on a character boundary`() throws {
        // 20,000 two-byte characters, a cap of 1,001 bytes: 500 characters fit, the 501st would be cut in half.
        let text = StyledText.plain(
            rows: [String(repeating: "é", count: 20_000)],
            font: Self.font,
            plainStyle: Self.style
        )
        let configuration = LayoutConfiguration(wrap: .none, lineHeight: 16, maxRowBytes: 1_001)
        let geometry = try TextTypesetter.layoutSynchronously(
            RowIndex(0) ..< RowIndex(1),
            of: text,
            configuration: configuration
        )
        let line = geometry[0].lines[0]
        #expect(line.bytes.upperBound.rawValue == 1_000)
        #expect(line.carets.count == 501)
        // The row keeps its height, and a text of ordinary rows is untouched by the cap.
        #expect(geometry[0].height == 16)
    }

    @Test func `a bitmap is clipped to a size a machine can hold, and shows the top of the document`() throws {
        let rows = (0 ..< 3_000).map { "row \($0)" }
        let text = StyledText.plain(rows: rows, font: Self.font, plainStyle: Self.style)
        let tile = try TextTypesetter.renderSynchronously(
            RowIndex(0) ..< RowIndex(3_000),
            of: text,
            decorations: [],
            configuration: LayoutConfiguration(wrap: .none, lineHeight: 16),
            appearance: .light,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            scale: 8
        )
        // 3,000 rows of 16 points at a scale of 8 would be 384,000 pixels tall.
        #expect(tile.image.height <= 16_384)
        #expect(tile.image.width * tile.image.height <= 32 << 20)
        #expect(tile.geometry.count == 3_000, "the geometry still covers every row")
    }
}
