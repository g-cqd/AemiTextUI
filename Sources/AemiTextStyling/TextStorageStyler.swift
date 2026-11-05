public import AppKit

/// Applies styles to text that is already there: attributes only, so the characters, the selection, the cursor and the undo stack are what they were.
///
/// A styler takes runs of *UTF-8 byte ranges* (what a parser or lexer reports) and an `NSTextStorage` (UTF-16, what AppKit measures in), and does the conversion once, forward, in time linear in the window it
/// styles. It styles a window of the text and leaves the rest as it was, so a keystroke in a long document re-styles the screenful it affects. A range that lies outside the text, or on part of a character, is held to
/// the text; styling never throws and never changes a character.
public enum TextStorageStyler {
    /// Resets `window` of `storage` (UTF-8 byte offsets of its string; all of it if nil) to `base`, then adds `attributes(style)` over each run that falls in it.
    /// - Complexity: O(window + runs in it) after one O(1) index lookup per run boundary (breadcrumbed UTF-16 offsets).
    @MainActor
    public static func apply<Style>(
        _ runs: some Sequence<(bytes: Range<Int>, style: Style)>,
        to storage: NSTextStorage,
        window: Range<Int>? = nil,
        base: [NSAttributedString.Key: Any],
        attributes: (Style) -> [NSAttributedString.Key: Any]
    ) {
        let string = storage.string
        let byteCount = string.utf8.count
        let low = Swift.min(Swift.max(window?.lowerBound ?? 0, 0), byteCount)
        let high = Swift.min(Swift.max(window?.upperBound ?? byteCount, low), byteCount)
        let target = NSRange(location: utf16Offset(ofByte: low, in: string), length: 0)
        let end = utf16Offset(ofByte: high, in: string)
        let whole = NSRange(location: target.location, length: end - target.location)
        guard whole.location >= 0, whole.length >= 0, NSMaxRange(whole) <= storage.length else { return }
        storage.beginEditing()
        defer { storage.endEditing() }
        storage.setAttributes(base, range: whole)
        for run in runs {
            let lower = Swift.max(run.bytes.lowerBound, low)
            let upper = Swift.min(run.bytes.upperBound, high)
            guard lower < upper else { continue }
            let start = utf16Offset(ofByte: lower, in: string)
            let stop = utf16Offset(ofByte: upper, in: string)
            guard stop > start, stop <= storage.length else { continue }
            storage.addAttributes(attributes(run.style), range: NSRange(location: start, length: stop - start))
        }
    }

    /// The UTF-16 offset in `string` of the UTF-8 byte offset `byte`: held to the string, and on a character boundary at or before it.
    public static func utf16Offset(ofByte byte: Int, in string: String) -> Int {
        let utf8 = string.utf8
        let clamped = Swift.min(Swift.max(byte, 0), utf8.count)
        let index = utf8.index(utf8.startIndex, offsetBy: clamped)
        return index.utf16Offset(in: string)
    }

    /// The UTF-8 byte offset in `string` of the UTF-16 offset `unit`: held to the string.
    public static func byteOffset(ofUTF16 unit: Int, in string: String) -> Int {
        let utf16 = string.utf16
        let clamped = Swift.min(Swift.max(unit, 0), utf16.count)
        let index = utf16.index(utf16.startIndex, offsetBy: clamped)
        return string.utf8.distance(from: string.utf8.startIndex, to: index)
    }
}
