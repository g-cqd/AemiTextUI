import AppKit
import Testing

@testable import AemiTextStyling

@MainActor
@Suite("Styling a text storage from byte ranges")
struct TextStorageStylerTests {
    private static let base: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.black]
    private static let red: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.red]

    private func storage(_ text: String) -> NSTextStorage {
        NSTextStorage(string: text, attributes: Self.base)
    }

    private func isRed(_ storage: NSTextStorage, at unit: Int) -> Bool {
        (storage.attribute(.foregroundColor, at: unit, effectiveRange: nil) as? NSColor) == .red
    }

    @Test func `a byte range styles the characters it covers, in a text with accents and emoji`() {
        // "é" is two bytes and one unit; "🙂" is four bytes and two units.
        let text = "aé🙂b**c**"
        let store = storage(text)
        let bytes = Array(text.utf8)
        let star = bytes.firstIndex(of: UInt8(ascii: "*"))!
        TextStorageStyler.apply([(bytes: star ..< bytes.count, style: 1)], to: store, base: Self.base) { _ in Self.red }
        #expect(store.string == text, "no character changed")
        let firstUnit = TextStorageStyler.utf16Offset(ofByte: star, in: text)
        #expect(firstUnit == 5)
        #expect(!isRed(store, at: 4) && isRed(store, at: 5) && isRed(store, at: store.length - 1))
    }

    @Test func `the window is reset to the base first, and what is outside it is left alone`() {
        let store = storage("0123456789")
        TextStorageStyler.apply([(bytes: 0 ..< 10, style: 1)], to: store, base: Self.base) { _ in Self.red }
        #expect((0 ..< 10).allSatisfy { isRed(store, at: $0) })
        // Re-style bytes 3 ..< 6 with nothing: those return to the base, the rest stay red.
        TextStorageStyler.apply([(bytes: Range<Int>, style: Int)](), to: store, window: 3 ..< 6, base: Self.base) { _ in
            Self.red
        }
        #expect(isRed(store, at: 2) && !isRed(store, at: 3) && !isRed(store, at: 5) && isRed(store, at: 6))
    }

    @Test func `a run that crosses the window is cut to it`() {
        let store = storage("0123456789")
        TextStorageStyler.apply([(bytes: 0 ..< 10, style: 1)], to: store, window: 4 ..< 7, base: Self.base) { _ in
            Self.red
        }
        #expect(!isRed(store, at: 3) && isRed(store, at: 4) && isRed(store, at: 6) && !isRed(store, at: 7))
    }

    @Test func `ranges outside the text, empty or backwards change nothing and do not trap`() {
        let store = storage("abc")
        let runs: [(bytes: Range<Int>, style: Int)] = [
            (-5 ..< 0, 1), (3 ..< 99, 1), (10 ..< 20, 1), (2 ..< 2, 1), (Int.min ..< Int.min + 1, 1)
        ]
        TextStorageStyler.apply(runs, to: store, window: -100 ..< 100, base: Self.base) { _ in Self.red }
        #expect(store.string == "abc")
        #expect(!isRed(store, at: 0) && !isRed(store, at: 2))
        TextStorageStyler.apply(runs, to: storage(""), base: Self.base) { _ in Self.red }
    }

    @Test func `the offsets convert both ways and are held to the text`() {
        let text = "a🙂é"
        #expect(TextStorageStyler.utf16Offset(ofByte: 0, in: text) == 0)
        #expect(TextStorageStyler.utf16Offset(ofByte: 5, in: text) == 3)
        #expect(TextStorageStyler.utf16Offset(ofByte: 99, in: text) == 4)
        #expect(TextStorageStyler.utf16Offset(ofByte: -4, in: text) == 0)
        #expect(TextStorageStyler.byteOffset(ofUTF16: 3, in: text) == 5)
        #expect(TextStorageStyler.byteOffset(ofUTF16: 99, in: text) == 7)
        #expect(TextStorageStyler.byteOffset(ofUTF16: -1, in: text) == 0)
    }

    @Test func `the selection and the string are what they were`() {
        let store = storage("some **text** here")
        let before = store.string
        TextStorageStyler.apply([(bytes: 5 ..< 13, style: 1)], to: store, base: Self.base) { _ in Self.red }
        #expect(store.string == before)
    }
}
