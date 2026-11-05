import CoreGraphics
import Testing

@testable import AemiTextRendering

/// A renderer is handed numbers and offsets by code that has bugs and by documents that are hostile (a row of ten million bytes, a style run that points past its row, a width of NaN from a layout that divided by zero). None of that may take the process down: each case
/// below runs in a child process and must exit normally, which a trap (an out-of-range slice, `Int(.nan)`, an overflow) does not. What a call returns for such input is a separate matter, tested after the call.
@Suite("Hostile input")
struct HostileInputTests {
    static let plain = TextStyle(foreground: .fixed(RGBA(red: 0, green: 0, blue: 0)))
    static let font = FontSpec(pointSize: 12)

    static let badNumbers: [Double] = [.nan, .infinity, -.infinity, -1, 0, 1e300, -1e300, .leastNonzeroMagnitude]

    // MARK: The model

    @Test func `row starts that are not ascending, not inside the bytes, or not closed do not trap`() async {
        await #expect(processExitsWith: .success) {
            let bytes = Array("hello world".utf8)
            let styles = StyleSheet(font: HostileInputTests.font, styles: [HostileInputTests.plain])
            let cases: [[UInt32]] = [
                [], [0], [5, 2, 11], [0, 99, 11], [11, 0], [0, 4_000_000_000], [UInt32.max, 0, 11], [3, 3, 3]
            ]
            for starts in cases {
                let text = StyledText(
                    utf8: bytes,
                    rowStarts: starts,
                    runs: .empty(rowCount: max(starts.count - 1, 0)),
                    styles: styles
                )
                for row in 0 ..< max(text.rowCount, 1) + 2 {
                    _ = text.bytes(ofRow: RowIndex(row))
                    _ = text.isASCII(row: RowIndex(row))
                }
                _ = text.row(containingDocumentOffset: 0)
                _ = text.row(containingDocumentOffset: Int.max)
                _ = text.row(containingDocumentOffset: -5)
            }
        }
    }

    @Test func `style runs that point past their row or past the runs do not trap`() async {
        await #expect(processExitsWith: .success) {
            let runs = LineRuns(
                runs: [
                    LineRuns.Run(start: 0, length: 2, style: StyleID(0)),
                    LineRuns.Run(start: UInt32.max, length: UInt16.max, style: StyleID(9))
                ],
                offsets: [0, 7, 1, 0]
            )
            _ = runs[RowIndex(0)]
            _ = runs[RowIndex(1)]
            _ = runs[RowIndex(2)]
            _ = runs[RowIndex(Int.max)]
            let styles = StyleSheet(font: HostileInputTests.font, styles: [HostileInputTests.plain])
            let text = StyledText(utf8: Array("ab\ncd".utf8), rowStarts: [0, 2, 5], runs: runs, styles: styles)
            let configuration = LayoutConfiguration(wrap: .none, lineHeight: 16)
            _ = try TextTypesetter.layoutSynchronously(
                RowIndex(0) ..< RowIndex(2),
                of: text,
                configuration: configuration
            )
            _ = try TextTypesetter.renderSynchronously(
                RowIndex(0) ..< RowIndex(2),
                of: text,
                decorations: [],
                configuration: configuration,
                appearance: .light,
                colorSpace: CGColorSpaceCreateDeviceRGB(),
                scale: 1
            )
        }
    }

    @Test func `positions and indices saturate and do not overflow`() async {
        await #expect(processExitsWith: .success) {
            _ = ByteOffset(Int.max)
            _ = ByteOffset(Int.min)
            _ = RowIndex(Int.max)
            _ = RowIndex(Int.min)
            _ = UTF16Offset(Int.max)
            _ = ByteOffset(Int32.max) + Int.max
            _ = ByteOffset(Int32.min) + Int.min
            _ = RowIndex(Int32.max).advanced(by: Int.max)
            _ = RowIndex(Int32.min).advanced(by: Int.min)
            _ = RowIndex(0).distance(to: RowIndex(Int32.max))
        }
    }

    // MARK: Numbers

    @Test(arguments: badNumbers)
    func `a height index built with a bad line height or width does not trap`(number: Double) async {
        await #expect(processExitsWith: .success) { [number] in
            let styles = StyleSheet(font: HostileInputTests.font, styles: [HostileInputTests.plain])
            let text = StyledText.plain(
                rows: [[UInt8]](repeating: Array("some text to wrap".utf8), count: 20),
                font: HostileInputTests.font,
                plainStyle: HostileInputTests.plain
            )
            _ = styles
            for wrap in [
                LayoutConfiguration.Wrap.none, .width(number),
                .columns(Int(clamping: Int64(number.isFinite ? max(min(number, 1e18), -1e18) : 0)))
            ] {
                let configuration = LayoutConfiguration(
                    wrap: wrap,
                    lineHeight: number,
                    lineHeightMultiple: number,
                    tabWidth: Int(clamping: Int64(number.isFinite ? max(min(number, 1e9), -1e9) : 0)),
                    padding: number
                )
                var index = HeightIndex(text: text, configuration: configuration, cellAdvance: number)
                _ = index.documentHeight
                _ = index.y(of: RowIndex(3))
                _ = index.row(atY: number)
                _ = index.setHeight(Float(number), of: RowIndex(2))
                _ = index.documentHeight
                _ = index.row(atY: 10)
            }
        }
    }

    @Test(arguments: badNumbers)
    func `typesetting and rendering with a bad number do not trap`(number: Double) async {
        await #expect(processExitsWith: .success) { [number] in
            let text = StyledText.plain(
                rows: [Array("a row of text".utf8), []],
                font: HostileInputTests.font,
                plainStyle: HostileInputTests.plain
            )
            let configuration = LayoutConfiguration(wrap: .width(number), lineHeight: number, padding: number)
            _ = try TextTypesetter.layoutSynchronously(
                RowIndex(0) ..< RowIndex(2),
                of: text,
                configuration: configuration
            )
            _ = try? TextTypesetter.renderSynchronously(
                RowIndex(0) ..< RowIndex(2),
                of: text,
                decorations: [],
                configuration: configuration,
                appearance: .light,
                colorSpace: CGColorSpaceCreateDeviceRGB(),
                scale: number
            )
            // A bad font size and a bad scale on a good configuration.
            let font = FontSpec(pointSize: number)
            let odd = StyledText.plain(rows: [Array("text".utf8)], font: font, plainStyle: HostileInputTests.plain)
            _ = try? TextTypesetter.renderSynchronously(
                RowIndex(0) ..< RowIndex(1),
                of: odd,
                decorations: [],
                configuration: LayoutConfiguration(wrap: .none, lineHeight: 16),
                appearance: .dark,
                colorSpace: CGColorSpaceCreateDeviceRGB(),
                scale: number
            )
        }
    }

    // MARK: Size

    @Test func `one row of ten million bytes is rendered without asking for a bitmap the size of the row`() async {
        await #expect(processExitsWith: .success) {
            let row = [UInt8](repeating: UInt8(ascii: "x"), count: 10_000_000)
            let text = StyledText.plain(rows: [row], font: HostileInputTests.font, plainStyle: HostileInputTests.plain)
            let tile = try? TextTypesetter.renderSynchronously(
                RowIndex(0) ..< RowIndex(1),
                of: text,
                decorations: [],
                configuration: LayoutConfiguration(wrap: .none, lineHeight: 16),
                appearance: .light,
                colorSpace: CGColorSpaceCreateDeviceRGB(),
                scale: 2
            )
            // Whatever it returns, it is not an image of the whole row: 10 million cells at 7 points and a scale of 2 would be 140 million pixels across.
            if let tile {
                precondition(
                    tile.image.width <= 16_384 && tile.image.height <= 16_384,
                    "\(tile.image.width) x \(tile.image.height)"
                )
            }
        }
    }
}
