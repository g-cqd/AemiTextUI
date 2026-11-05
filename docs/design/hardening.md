# Hardening the copied renderer (2026-11-06)

The copy of Atelier's CoreText stack (1,527 lines, 25 tests) was reviewed for what it does with input that is wrong. Every finding below has a test; the hostile cases run each call in a child process (Swift Testing exit tests), so a trap fails the test instead of ending the run.

| Finding | Before | Now |
|---|---|---|
| `StyledText` sliced `utf8[rowStarts[i] ..< rowStarts[i+1]]` unchecked | a row-start list out of order or past the end trapped in `init` | repaired (ascending, held to the bytes, closed at the end), `wasRepaired` says so |
| `LineRuns` subscript trusted its offsets | offsets past the runs or backwards trapped | that row has no runs |
| `ByteOffset(Int)`, `RowIndex(Int)`, `+` and `advanced(by:)` used `Int32(x)` and plain addition | trapped past 2^31 | saturate |
| `Int(width / cellAdvance)`, `Int(totalWidth * scale)` and similar | trapped on NaN, infinity or huge values | `Int(clampingFinite:)`; a `sanitized` configuration holds every number to a range where layout is defined |
| Font size and scale taken as given | NaN or 0 reached CoreText | clamped (1 to 1,000 points; scale 1 to 8) |
| `RowText` decoded with `String(decoding:)` | each ill-formed byte became a three-byte U+FFFD, so every offset after it was wrong | decoded by hand; an ill-formed subpart is one U+FFFD standing for exactly the bytes it replaced; the two maps invert each other |
| One bitmap sized by the widest line | a wide line asked for gigabytes | 16,384 pixels a side and 32 million in all; clipped, and the clip shows the top of the document |
| Carets by one `CTLineGetOffsetForStringIndex` per index | **quadratic in a line's length**: 0.6 s at 4,000 units, 9 s at 16,000, 40 s at 32,000; a minified line froze the pane | lines over 1,024 units take their carets from the glyph runs in one linear pass (exact below that; equal on plain monospaced text, tested); 7 ms at 4,000, 0.5 s at 32,000 |
| No bound on a row's typesetting | a row of ten million bytes did not finish in 100 s | `LayoutConfiguration.maxRowBytes`, 16 KiB by default, cut on a character boundary; wrapped layout also grows faster than linear (0.4 s at 16 KiB, 5 s at 64 KiB), which is why the cap is not higher |
| `HeightIndex.setHeight` with NaN, negative or huge heights | NaN or a negative height broke the prefix sums the row search depends on | ignored if not finite, held to 0 ... 1,000,000 |

Not done: the height index sums `Float`s, so many `setHeight` corrections can drift; a rebuild after N updates, or a `Double` tree, is the fix once a document is measured to need it. The AppKit canvas (`TextCanvasView`) has not had this pass yet.
