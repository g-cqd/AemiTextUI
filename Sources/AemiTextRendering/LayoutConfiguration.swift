/// How bidirectional text is handled (text-renderer.md §3.7): a row's base direction is set by the policy rather than
/// by its first strong character, and the direction controls that could reorder a row are drawn as placeholders.
public enum BidiPolicy: Hashable, Sendable {
    /// Every row's base direction is left to right, so a row that starts with right-to-left letters begins at the
    /// left. Right-to-left words still read right to left inside the row. The bidi controls (U+202A to U+202E,
    /// U+2066 to U+2069, U+200E, U+200F and U+061C) are drawn as placeholders of the same length (`▸`, `◂`, `↔`, `□`),
    /// which reorder nothing; the controls themselves no longer reorder the text around them (the Trojan Source class,
    /// CVE-2021-42574).
    case forceLeftToRight
    /// The Unicode Bidirectional Algorithm runs unmodified: each row takes its base direction from its first strong
    /// character, and the controls reorder the text around them.
    case unicodeDefault
}

public struct LayoutConfiguration: Hashable, Sendable {
    public enum Wrap: Hashable, Sendable {
        case none
        case width(Double)
        case columns(Int)
    }

    public var wrap: Wrap
    /// Given, never derived: the one value both backends share (text-renderer.md §1.3 finding 7).
    public var lineHeight: Double
    public var lineHeightMultiple: Double
    /// In cells.
    public var tabWidth: Int
    /// In cells, for a wrapped row's continuation lines.
    public var continuationIndent: Int
    public var padding: Double
    public var bidi: BidiPolicy
    /// The most bytes of one row that are typeset. A row longer than this (a minified bundle on one line) is drawn as far as this and no further: typesetting costs time and memory in proportion to the row, and a row of ten million bytes would otherwise
    /// take minutes and gigabytes to draw. The cut falls on a character boundary; the rest of the row is still in the text and still counts for its height.
    public var maxRowBytes: Int

    public init(
        wrap: Wrap,
        lineHeight: Double,
        lineHeightMultiple: Double = 1,
        tabWidth: Int = 4,
        continuationIndent: Int = 2,
        padding: Double = 0,
        bidi: BidiPolicy = .forceLeftToRight,
        maxRowBytes: Int = LayoutConfiguration.defaultMaxRowBytes
    ) {
        self.wrap = wrap
        self.lineHeight = lineHeight
        self.lineHeightMultiple = lineHeightMultiple
        self.tabWidth = tabWidth
        self.continuationIndent = continuationIndent
        self.padding = padding
        self.bidi = bidi
        self.maxRowBytes = maxRowBytes
    }

    /// 16 KiB: the longest a row is typeset by default. Laying out a wrapped row grows faster than its length (0.4 s at 16 KiB, 5 s at 64 KiB, measured), and a line of that length is not read as text.
    public static let defaultMaxRowBytes = 16_384

    /// The line height a row of unwrapped text takes: ``lineHeight`` times ``lineHeightMultiple``, of the sanitized values (never zero, negative, infinite or NaN).
    public var resolvedLineHeight: Double { sanitized.lineHeight * sanitized.lineHeightMultiple }

    /// The same configuration with every number held to a range in which layout is defined: a line height of 1 to 1,024 points (16 if it is not a number), a multiple of 0.1 to 10, tabs of 1 to 64 cells, a continuation indent of 0 to 256, a padding of 0 to
    /// 1,024 points, a wrap width of at least 1 point and at most 1,000,000 (a width that is not a number does not wrap), a column count of 1 to 1,000,000 (a count below 1 does not wrap), and a row cap of 256 bytes to 16 MiB. What the layout code reads is
    /// always this, so a configuration made from a divided-by-zero, a negative or a very large number draws something odd and does not take the process down.
    public var sanitized: LayoutConfiguration {
        var clean = self
        clean.lineHeight = lineHeight.clamped(to: 1 ... 1_024, fallback: 16)
        clean.lineHeightMultiple = lineHeightMultiple.clamped(to: 0.1 ... 10, fallback: 1)
        clean.tabWidth = Swift.min(Swift.max(tabWidth, 1), 64)
        clean.continuationIndent = Swift.min(Swift.max(continuationIndent, 0), 256)
        clean.padding = padding.clamped(to: 0 ... 1_024, fallback: 0)
        clean.maxRowBytes = Swift.min(Swift.max(maxRowBytes, 256), 16 << 20)
        switch wrap {
            case .none: break
            case .width(let width):
                clean.wrap = width.isNaN ? .none : .width(Swift.min(Swift.max(width, 1), 1_000_000))
            case .columns(let count):
                clean.wrap = count < 1 ? .none : .columns(Swift.min(count, 1_000_000))
        }
        return clean
    }
}
