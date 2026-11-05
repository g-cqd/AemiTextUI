public import CoreGraphics
import CoreText

/// Typesets and draws rows with CoreText, off the main actor (text-renderer.md §3.4). Every CoreText object is built,
/// used and released inside one call: none of `CTFont`, `CTLine` or `CTTypesetter` is `Sendable`, so none crosses a
/// task boundary. Only `Sendable` value types and `CGImage` (itself `Sendable`) come back.
///
/// Colour is resolved and baked into the attributed string ``render(_:of:decorations:configuration:appearance:colorSpace:scale:)``
/// typesets, and text draws with `CTLineDraw`; ``layout(_:of:configuration:)`` typesets the same breaks without any
/// colour, for geometry alone. Drawing glyph runs directly with `CTFontDrawGlyphs` is a follow-up performance pass
/// (text-renderer.md §3.5); `CTLineDraw` is correct and simple, and M1's budget is for a tile of some 32 rows, not a
/// whole document.
public enum TextTypesetter {
    /// Geometry of `rows`.
    /// - Complexity: O(bytes in rows). Throws only on cancellation.
    @concurrent
    public static func layout(
        _ rows: Range<RowIndex>,
        of text: StyledText,
        configuration: LayoutConfiguration
    ) async throws(CancellationError) -> [RowGeometry] {
        try layoutSynchronously(rows, of: text, configuration: configuration)
    }

    /// ``layout(_:of:configuration:)``'s synchronous core: nothing in it ever suspends, so a caller that already
    /// needs an immediate answer off an `async` boundary — a gutter, a minimap or hover hit-testing reading geometry
    /// from the main actor — can call it directly instead of awaiting a child task for cheap, bounded ranges.
    public static func layoutSynchronously(
        _ rows: Range<RowIndex>,
        of text: StyledText,
        configuration: LayoutConfiguration
    ) throws(CancellationError) -> [RowGeometry] {
        let configuration = configuration.sanitized
        let baseFont = Self.font(for: text.styles.font, weight: nil, isItalic: false)
        var fontCache: [FontKey: CTFont] = [FontKey(font: text.styles.font, weight: nil, isItalic: false): baseFont]
        let wrapWidth = Self.wrapWidth(configuration: configuration, cellAdvance: Self.cellAdvance(of: baseFont))
        let baseline = Self.baseline(font: baseFont, lineHeight: configuration.resolvedLineHeight)
        var results: [RowGeometry] = []
        results.reserveCapacity(rows.count)
        for rawRow in stride(from: rows.lowerBound.rawValue, to: rows.upperBound.rawValue, by: 1) {
            if Task.isCancelled { throw CancellationError() }
            let row = RowIndex(rawRow)
            let rowText = RowText(bytes: Self.typesetBytes(of: text, row: row, limit: configuration.maxRowBytes))
            let attributed = Self.attributedString(
                rowText: rowText,
                runs: text.runs[row],
                sheet: text.styles,
                fontCache: &fontCache,
                includeColor: false,
                appearance: .light,
                bidi: configuration.bidi
            )
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            let breaks = Self.breakLines(typesetter: typesetter, length: rowText.utf16Count, wrapWidth: wrapWidth)
            var lines: [VisualLine] = []
            lines.reserveCapacity(breaks.count)
            for range in breaks {
                let line = CTTypesetterCreateLine(typesetter, range)
                lines.append(Self.visualLine(line: line, range: range, rowText: rowText, baseline: baseline))
            }
            let height = Float(configuration.resolvedLineHeight) * Float(max(lines.count, 1))
            results.append(RowGeometry(height: height, lines: lines))
        }
        return results
    }

    /// Typesets and draws `rows` into one image in `colorSpace`.
    @concurrent
    // swiftlint:disable:next function_parameter_count
    public static func render(
        _ rows: Range<RowIndex>,
        of text: StyledText,
        decorations: [DecorationLayer],
        configuration: LayoutConfiguration,
        appearance: Appearance,
        colorSpace: CGColorSpace,
        scale: Double
    ) async throws(CancellationError) -> RenderedTile {
        try renderSynchronously(
            rows,
            of: text,
            decorations: decorations,
            configuration: configuration,
            appearance: appearance,
            colorSpace: colorSpace,
            scale: scale
        )
    }

    /// A bitmap of `width` by `height` points at `scale`, drawn into with a flipped, top-left origin so a row's `y` matches
    /// document coordinates.
    private static func bitmap(
        width totalWidth: Double,
        height totalHeight: Double,
        scale: Double,
        colorSpace: CGColorSpace
    ) throws(CancellationError) -> CGContext {
        // A bitmap is held to 16,384 pixels each way and 32 million in all (128 MB): a tile is a screenful, and a document that asks for more (one very wide line, a request for a million rows at once) gets the top left of it, not an allocation that
        // takes the machine's memory. Past the cap the image is clipped, and the geometry still says where every row and caret is.
        let pixelWidth = min(max(Int(clampingFinite: (totalWidth * scale).rounded(.up)), 1), maxBitmapSide)
        var pixelHeight = min(max(Int(clampingFinite: (totalHeight * scale).rounded(.up)), 1), maxBitmapSide)
        pixelHeight = max(min(pixelHeight, maxBitmapPixels / pixelWidth), 1)
        let flipHeight =
            pixelHeight == Int(clampingFinite: (totalHeight * scale).rounded(.up))
            ? totalHeight : Double(pixelHeight) / scale
        guard
            let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw CancellationError() }
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        // A flipped, top-left origin so row `y` matches document coordinates.
        context.translateBy(x: 0, y: CGFloat(flipHeight))
        context.scaleBy(x: 1, y: -1)
        return context
    }

    private static let maxBitmapSide = 16_384
    private static let maxBitmapPixels = 32 << 20

    /// The bytes of `row` that are typeset: all of them, or the first `limit` cut back to a character boundary.
    private static func typesetBytes(of text: StyledText, row: RowIndex, limit: Int) -> ArraySlice<UInt8> {
        let bytes = text.bytes(ofRow: row)
        guard bytes.count > limit else { return bytes }
        var end = bytes.startIndex + limit
        while end > bytes.startIndex, bytes[end] & 0xC0 == 0x80 { end -= 1 }
        return bytes[bytes.startIndex ..< end]
    }

    /// ``render(_:of:decorations:configuration:appearance:colorSpace:scale:)``'s synchronous core; see
    /// ``layoutSynchronously(_:of:configuration:)``.
    // swiftlint:disable:next function_parameter_count
    public static func renderSynchronously(
        _ rows: Range<RowIndex>,
        of text: StyledText,
        decorations: [DecorationLayer],
        configuration: LayoutConfiguration,
        appearance: Appearance,
        colorSpace: CGColorSpace,
        scale: Double
    ) throws(CancellationError) -> RenderedTile {
        let configuration = configuration.sanitized
        let baseFont = Self.font(for: text.styles.font, weight: nil, isItalic: false)
        var fontCache: [FontKey: CTFont] = [FontKey(font: text.styles.font, weight: nil, isItalic: false): baseFont]
        let wrapWidth = Self.wrapWidth(configuration: configuration, cellAdvance: Self.cellAdvance(of: baseFont))
        let baseline = Self.baseline(font: baseFont, lineHeight: configuration.resolvedLineHeight)
        let lineHeight = configuration.resolvedLineHeight

        var geometry: [RowGeometry] = []
        var rowTops: [Double] = []
        var rowTexts: [RowText] = []
        var drawLines: [[(line: CTLine, y: Double)]] = []
        var totalWidth: Double = 1
        var y: Double = 0

        for rawRow in stride(from: rows.lowerBound.rawValue, to: rows.upperBound.rawValue, by: 1) {
            if Task.isCancelled { throw CancellationError() }
            let row = RowIndex(rawRow)
            let rowText = RowText(bytes: Self.typesetBytes(of: text, row: row, limit: configuration.maxRowBytes))
            let attributed = Self.attributedString(
                rowText: rowText,
                runs: text.runs[row],
                sheet: text.styles,
                fontCache: &fontCache,
                includeColor: true,
                appearance: appearance,
                bidi: configuration.bidi
            )
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            let breaks = Self.breakLines(typesetter: typesetter, length: rowText.utf16Count, wrapWidth: wrapWidth)
            rowTops.append(y)
            var visualLines: [VisualLine] = []
            var lines: [(CTLine, Double)] = []
            for range in breaks {
                let line = CTTypesetterCreateLine(typesetter, range)
                let visual = Self.visualLine(line: line, range: range, rowText: rowText, baseline: baseline)
                totalWidth = max(totalWidth, Double(visual.width) + configuration.padding * 2)
                visualLines.append(visual)
                lines.append((line, y))
                y += lineHeight
            }
            geometry.append(
                RowGeometry(height: Float(lineHeight) * Float(max(visualLines.count, 1)), lines: visualLines)
            )
            drawLines.append(lines)
            rowTexts.append(rowText)
        }
        let totalHeight = max(y, 1)

        let scale = scale.clamped(to: 1 ... 8, fallback: 1)
        let context = try Self.bitmap(width: totalWidth, height: totalHeight, scale: scale, colorSpace: colorSpace)

        let environment = PaintEnvironment(totalWidth: totalWidth, lineHeight: lineHeight, appearance: appearance)
        for layer in decorations.sorted(by: { $0.zIndex < $1.zIndex }) {
            for (index, rawRow) in stride(from: rows.lowerBound.rawValue, to: rows.upperBound.rawValue, by: 1)
                .enumerated()
            {
                guard let paints = layer.paints[RowIndex(rawRow)] else { continue }
                let target = RowPaintTarget(
                    top: rowTops[index],
                    height: Double(geometry[index].height),
                    lines: drawLines[index],
                    rowText: rowTexts[index]
                )
                for paint in paints { Self.draw(paint, row: target, in: environment, context: context) }
            }
        }

        // The context is flipped, so the text matrix must flip too for glyphs to stand upright.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for lines in drawLines {
            for (line, lineY) in lines {
                context.textPosition = CGPoint(x: CGFloat(configuration.padding), y: CGFloat(lineY + Double(baseline)))
                CTLineDraw(line, context)
            }
        }

        guard let image = context.makeImage() else { throw CancellationError() }
        return RenderedTile(rows: rows, image: image, geometry: geometry)
    }
}

// The typesetting and drawing helpers, split from ``TextTypesetter``'s own body only to stay under the file's
// type-body-length limit; there is no visibility change, since `private` is file-scoped.
extension TextTypesetter {
    // MARK: Fonts

    private struct FontKey: Hashable {
        var font: FontSpec
        var weight: FontWeight?
        var isItalic: Bool
    }

    private static func font(for spec: FontSpec, weight: FontWeight?, isItalic: Bool) -> CTFont {
        // A size that is not a number, or is outside 1 to 1,000 points, is the nearest one that is (12 if it is not a number).
        let size = CGFloat(spec.pointSize.clamped(to: 1 ... 1_000, fallback: 12))
        var base: CTFont
        if let name = spec.postScriptName, !name.isEmpty {
            base = CTFontCreateWithName(name as CFString, size, nil)
        } else {
            base =
                CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil)
                ?? CTFontCreateWithName("Menlo" as CFString, size, nil)
        }
        if !spec.features.isEmpty {
            let settings =
                spec.features.map { feature -> CFDictionary in
                    let entry: [CFString: Any] = [
                        kCTFontOpenTypeFeatureTag: feature.tag, kCTFontOpenTypeFeatureValue: feature.value
                    ]
                    return entry as CFDictionary
                } as CFArray
            let attributes: [CFString: Any] = [kCTFontFeatureSettingsAttribute: settings]
            let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
            base = CTFontCreateCopyWithAttributes(base, size, nil, descriptor)
        }
        if weight != nil || isItalic {
            var value = CTFontSymbolicTraits(rawValue: 0)
            var mask = CTFontSymbolicTraits(rawValue: 0)
            if let weight, weight >= .semibold {
                value.insert(.traitBold)
                mask.insert(.traitBold)
            }
            if isItalic {
                value.insert(.traitItalic)
                mask.insert(.traitItalic)
            }
            if let styled = CTFontCreateCopyWithSymbolicTraits(base, size, nil, value, mask) {
                base = styled
            }
        }
        return base
    }

    /// The advance of one cell: the digit "0" of `font`, or an estimate when the font has none.
    private static func cellAdvance(of font: CTFont) -> Double {
        var character = UniChar(UnicodeScalar("0").value)
        var glyph: CGGlyph = 0
        guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), glyph != 0 else {
            return Double(CTFontGetSize(font)) * 0.6
        }
        var advance = CGSize.zero
        withUnsafePointer(to: glyph) { pointer in
            _ = CTFontGetAdvancesForGlyphs(font, .horizontal, pointer, &advance, 1)
        }
        return advance.width > 0 ? Double(advance.width) : Double(CTFontGetSize(font)) * 0.6
    }

    /// Baseline y from the top of a line box `lineHeight` tall, the font's own ascent and descent centred in it.
    private static func baseline(font: CTFont, lineHeight: Double) -> Float {
        let ascent = Double(CTFontGetAscent(font))
        let descent = Double(CTFontGetDescent(font))
        let extra = max((lineHeight - (ascent + descent)) / 2, 0)
        return Float(ascent + extra)
    }

    // MARK: Attributed strings

    // swiftlint:disable:next function_parameter_count
    private static func attributedString(
        rowText: RowText,
        runs: ArraySlice<LineRuns.Run>,
        sheet: StyleSheet,
        fontCache: inout [FontKey: CTFont],
        includeColor: Bool,
        appearance: Appearance,
        bidi: BidiPolicy
    ) -> CFAttributedString {
        guard let mutable = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0) else {
            preconditionFailure("the default allocator could not create an attributed string")
        }
        // Under forceLeftToRight the controls are drawn as their placeholders, unit for unit, so the offsets that
        // `rowText` maps (the runs, the carets) still hold for the text drawn.
        let drawn = bidi == .forceLeftToRight ? BidiPlaceholders.replacingControls(in: rowText.string) : rowText.string
        assert(drawn.utf16.count == rowText.utf16Count, "bidi substitution changed the row's UTF-16 length")
        CFAttributedStringReplaceString(mutable, CFRange(location: 0, length: 0), drawn as CFString)
        let fullRange = CFRange(location: 0, length: rowText.utf16Count)
        if bidi == .forceLeftToRight {
            CFAttributedStringSetAttribute(
                mutable,
                fullRange,
                kCTParagraphStyleAttributeName,
                Self.leftToRightParagraphStyle()
            )
        }
        let plainStyle = sheet[StyleID(0)] ?? TextStyle(foreground: .fixed(RGBA(red: 0, green: 0, blue: 0)))

        func resolvedFont(_ style: TextStyle) -> CTFont {
            let key = FontKey(font: sheet.font, weight: style.weight, isItalic: style.isItalic)
            if let cached = fontCache[key] { return cached }
            let made = Self.font(for: sheet.font, weight: style.weight, isItalic: style.isItalic)
            fontCache[key] = made
            return made
        }

        CFAttributedStringSetAttribute(mutable, fullRange, kCTFontAttributeName, resolvedFont(plainStyle))
        if includeColor {
            CFAttributedStringSetAttribute(
                mutable,
                fullRange,
                kCTForegroundColorAttributeName,
                Self.cgColor(plainStyle.foreground.resolved(for: appearance))
            )
        }
        for run in runs {
            guard let style = sheet[run.style] else { continue }
            let start = rowText.utf16Offset(atByte: Int(run.start))
            let end = rowText.utf16Offset(atByte: Int(run.start) + Int(run.length))
            let range = CFRange(location: start, length: end - start)
            guard range.length > 0 else { continue }
            if !style.hasSameFont(as: plainStyle) {
                CFAttributedStringSetAttribute(mutable, range, kCTFontAttributeName, resolvedFont(style))
            }
            if includeColor {
                CFAttributedStringSetAttribute(
                    mutable,
                    range,
                    kCTForegroundColorAttributeName,
                    Self.cgColor(style.foreground.resolved(for: appearance))
                )
            }
        }
        return mutable
    }

    /// A paragraph style whose base writing direction is left to right, whatever the row's first strong character.
    private static func leftToRightParagraphStyle() -> CTParagraphStyle {
        withUnsafePointer(to: CTWritingDirection.leftToRight) { direction in
            let setting = CTParagraphStyleSetting(
                spec: .baseWritingDirection,
                valueSize: MemoryLayout<CTWritingDirection>.size,
                value: direction
            )
            return CTParagraphStyleCreate([setting], 1)
        }
    }

    private static func cgColor(_ rgba: RGBA) -> CGColor {
        CGColor(
            srgbRed: CGFloat(rgba.red),
            green: CGFloat(rgba.green),
            blue: CGFloat(rgba.blue),
            alpha: CGFloat(rgba.alpha)
        )
    }

    // MARK: Line breaking and geometry

    private static func wrapWidth(configuration: LayoutConfiguration, cellAdvance: Double) -> Double? {
        switch configuration.wrap {
            case .none: nil
            case .width(let width): max(width - configuration.padding * 2, 1)
            case .columns(let count): Double(count) * cellAdvance
        }
    }

    private static func breakLines(typesetter: CTTypesetter, length: Int, wrapWidth: Double?) -> [CFRange] {
        guard let wrapWidth, wrapWidth > 0, length > 0 else {
            return [CFRange(location: 0, length: length)]
        }
        var ranges: [CFRange] = []
        var start = 0
        while start < length {
            let count = max(CTTypesetterSuggestLineBreak(typesetter, start, wrapWidth), 1)
            ranges.append(CFRange(location: start, length: count))
            start += count
        }
        return ranges
    }

    /// A line this many UTF-16 units long or shorter gets its carets from CoreText one index at a time: exact, and cheap while the line is short.
    private static let exactCaretUnitLimit = 1_024

    /// One `CTLineGetOffsetForStringIndex` per boundary. Each call walks the line, so the whole is quadratic in the line's length (0.6 s at 4,000 units, 40 s at 32,000): for short lines only.
    private static func exactCarets(line: CTLine, range: CFRange) -> [Float] {
        var carets: [Float] = []
        carets.reserveCapacity(range.length + 1)
        for offset in range.location ... (range.location + range.length) {
            carets.append(Float(CTLineGetOffsetForStringIndex(line, offset, nil)))
        }
        return carets
    }

    /// The carets of a long line from its glyph runs, in time linear in the line: a glyph covers the characters from its string index to the next glyph's in logical order, and the characters of a cluster (a ligature, a base and its marks) share
    /// the glyph's width equally. For left-to-right text of one glyph per character this is what ``exactCarets(line:range:)`` gives; for a cluster the split is an even one and not the font's own. The two ends of the line, which are
    /// exact, are asked from CoreText directly, and a boundary no glyph starts at takes the one before it.
    private static func runCarets(line: CTLine, range: CFRange) -> [Float] {
        let length = range.length
        var carets = [Float](repeating: .nan, count: length + 1)
        carets[0] = Float(CTLineGetOffsetForStringIndex(line, range.location, nil))
        carets[length] = Float(CTLineGetOffsetForStringIndex(line, range.location + length, nil))
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var indices = [CFIndex](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
            let runRange = CTRunGetStringRange(run)
            let rightToLeft = CTRunGetStatus(run).contains(.rightToLeft)
            for glyph in 0 ..< count {
                // The glyph's characters run to the next glyph's index in logical order: the following glyph in a left-to-right run, the preceding one in a right-to-left run (visual order is reversed there).
                let next =
                    rightToLeft
                    ? (glyph > 0 ? indices[glyph - 1] : runRange.location + runRange.length)
                    : (glyph + 1 < count ? indices[glyph + 1] : runRange.location + runRange.length)
                let first = indices[glyph] - range.location
                let span = next - indices[glyph]
                guard span > 0, first >= 0, first + span <= length else { continue }
                let left = Float(positions[glyph].x)
                let width = Float(advances[glyph].width)
                for step in 0 ..< span {
                    let fraction = Float(step) / Float(span)
                    carets[first + step] = rightToLeft ? left + width - width * fraction : left + width * fraction
                }
            }
        }
        // A boundary nothing started at (inside a glyph a font made of several characters, or a run CoreText did not report) is where the one before it is.
        var last = carets[0]
        for index in carets.indices {
            if carets[index].isNaN { carets[index] = last } else { last = carets[index] }
        }
        return carets
    }

    private static func visualLine(line: CTLine, range: CFRange, rowText: RowText, baseline: Float) -> VisualLine {
        let carets =
            range.length <= exactCaretUnitLimit
            ? Self.exactCarets(line: line, range: range) : Self.runCarets(line: line, range: range)
        let width = Float(CTLineGetTypographicBounds(line, nil, nil, nil))
        let startByte = rowText.byteOffset(atUTF16: range.location)
        let endByte = rowText.byteOffset(atUTF16: range.location + range.length)
        return VisualLine(
            bytes: ByteOffset(startByte) ..< ByteOffset(endByte),
            carets: carets,
            baseline: baseline,
            width: width
        )
    }

    // MARK: Decoration paint

    /// One row's already-typeset lines and text, for mapping a decoration's byte range to a rectangle.
    private struct RowPaintTarget {
        var top: Double
        var height: Double
        var lines: [(line: CTLine, y: Double)]
        var rowText: RowText
    }

    /// What every row's paint shares.
    private struct PaintEnvironment {
        var totalWidth: Double
        var lineHeight: Double
        var appearance: Appearance
    }

    private static func draw(
        _ paint: DecorationLayer.Paint,
        row: RowPaintTarget,
        in environment: PaintEnvironment,
        context: CGContext
    ) {
        let rowRect = CGRect(
            x: 0,
            y: CGFloat(row.top),
            width: CGFloat(environment.totalWidth),
            height: CGFloat(row.height)
        )
        switch paint {
            case .rowFill(let color):
                context.setFillColor(Self.cgColor(color.resolved(for: environment.appearance)))
                context.fill(rowRect)
            case .rangeFill(let range, let color):
                guard
                    let rect = Self.rect(
                        for: range,
                        lineHeight: environment.lineHeight,
                        lines: row.lines,
                        rowText: row.rowText
                    )
                else { return }
                context.setFillColor(Self.cgColor(color.resolved(for: environment.appearance)))
                context.fill(rect)
            case .underline(let range, let shape, let color):
                let rect =
                    range.flatMap({
                        Self.rect(for: $0, lineHeight: environment.lineHeight, lines: row.lines, rowText: row.rowText)
                    }) ?? rowRect
                context.setStrokeColor(Self.cgColor(color.resolved(for: environment.appearance)))
                context.setLineWidth(shape == .double ? 2 : 1)
                let y = rect.minY + 1
                context.stroke(CGRect(x: rect.minX, y: y, width: rect.width, height: 0.5))
        }
    }

    /// The rectangle a byte range covers: the visual line whose row-relative UTF-16 range contains its start, the x
    /// of each end found through that line's own coordinates; approximate when a range spans more than one visual
    /// line, since a decoration layer paints per row and code emphasis rarely wraps.
    private static func rect(
        for range: Range<ByteOffset>,
        lineHeight: Double,
        lines: [(line: CTLine, y: Double)],
        rowText: RowText
    ) -> CGRect? {
        let start = rowText.utf16Offset(atByte: Int(range.lowerBound.rawValue))
        let end = rowText.utf16Offset(atByte: Int(range.upperBound.rawValue))
        guard end > start,
            let (line, y) = lines.first(where: { line, _ in
                let stringRange = CTLineGetStringRange(line)
                return start >= stringRange.location && start <= stringRange.location + stringRange.length
            }) ?? lines.first
        else { return nil }
        let stringRange = CTLineGetStringRange(line)
        let clampedStart = min(max(start, stringRange.location), stringRange.location + stringRange.length)
        let clampedEnd = min(max(end, stringRange.location), stringRange.location + stringRange.length)
        let startX = CTLineGetOffsetForStringIndex(line, clampedStart, nil)
        let endX = CTLineGetOffsetForStringIndex(line, clampedEnd, nil)
        guard endX > startX else { return nil }
        return CGRect(x: startX, y: CGFloat(y), width: endX - startX, height: CGFloat(lineHeight))
    }
}
