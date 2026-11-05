# AemiTextUI: scope, what is built, and what comes next (2026-11-06)

## Decisions that shaped it

- **Placement.** General text-UI APIs live here. Anything about Markdown goes to AemiMarkdown, anything about lexing to aemi (`AemiLexers`). The Markdown source colouring is therefore `MarkdownSourceHighlighter` in AemiMarkdown; only the AppKit step that applies byte-range styles to a text storage is here (`AemiTextStyling`).
- **Moving code out of Atelier: copy first, then cut over.** Atelier's AGENTS.md wants one move per commit and works in lanes; nothing in Atelier was touched. Atelier keeps its copy until it depends on this package, then deletes its own in a separate commit.
- **Platforms.** macOS (AppKit, TextKit 2) now. iOS later: the neutral targets (`AemiTextRendering`, `AemiTextScroll`) have no AppKit; `AemiTextCanvas` and `AemiTextStyling` are the AppKit ones and would get UIKit twins.
- **Bars.** Performance, safety, resilience, reliability, security, correctness. Every input a renderer is given by other code or by a document is treated as hostile (see `hardening.md`).

## What exists

| Target | Lines | What | Tests |
|---|---|---|---|
| `AemiTextRendering` | ~1,700 | CoreText renderer model, `HeightIndex`, typesetter, decoration layers, bidi policy; copied from `AtelierTextRendering` and hardened | 31 |
| `AemiTextCanvas` | 368 | `TextCanvasView`, the `@MainActor` host (tiles as layers); copied from `AtelierTextView`; **not yet hardened** | 3 |
| `AemiTextStyling` | ~70 | `TextStorageStyler`: byte-range styles to `NSTextStorage` attributes, over a window | 6 |
| `AemiTextScroll` | ~170 | `ScrollMap`: a monotone cubic through anchors shared by two scroll coordinates | 11 |

In AemiMarkdown: `MarkdownSourceHighlighter` (events to byte-range spans of a platform-free style; windowed parse for long text; 1 MiB limit; 16 tests including random windows). In MarkdownLook: `MarkdownSourceHighlight` (the theme) and the lab's source pane, which is now coloured.

## What the survey of Atelier's rendering found

`DiffTextKit` is 56 files and 8,690 lines. Only 18 files (1,312 lines) mention no `DiffCore` or `DiffRendering` type, and they are layout widgets (resizable panes, dividers, sticky cards, minimap geometry, hover tracking). Everything central (`DiffTextView`, the gutter, `DiffLayoutFragment`, `DecorationStore`) is built around `RenderedText`, one `NSAttributedString` for the whole document with per-row diff metadata. **So the TextKit 2 side cannot be copied; it has to be rewritten against the neutral model**, which is `StyledText` (UTF-8 bytes, row starts, style runs) with `DecorationLayer`s. The seam is already half there: `CoreTextPane+Convert` turns `RenderedText` into `StyledText`, and `DiffTextPane` (show, decorations, wrapping, row geometry, scroll to row, row heights, hover) is close to a neutral protocol.

## Which renderer

Atelier's own measurements (`text-renderer.md`, release, 1000 x 800 pt at 2x): a new document of 50,000 rows takes 7,034 ms with TextKit 2 as the app uses it, 25.5 ms used correctly, 3.8 ms with the CoreText prototype; layout memory 237.8 MB against 0.5 MB; split alignment with wrapping 256 ms against 0.23 ms. The costs of a custom renderer are the features TextKit gives for free: selection, find, input methods, accessibility, Writing Tools.
- **Read-only panes** (diff, a rendered page): the CoreText canvas, once selection and accessibility exist. This is what `AemiTextCanvas` is for.
- **Editors** (the lab's source pane, any text field): TextKit 2. Input methods and accessibility are not worth rebuilding.
- **A glyph atlas on Metal** (Atelier's M3, and `sunset`'s design for terminal cells) pays off past what tiles give, at 120 Hz or with very large documents; it is a design only in both places. It is not worth starting before the CoreText canvas has selection.

The right shape is a seam with both backends, as Atelier has (`DiffTextBackend`), made neutral:

```swift
@MainActor protocol TextPane: AnyObject {
    var view: NSView { get }
    func show(_ text: StyledText, layers: [DecorationLayer], keepingScroll: Bool)
    func setWrapping(_ configuration: LayoutConfiguration)
    var geometry: any RowGeometryProviding { get }   // y of a row, rows in a rect, visible rows
    func scroll(toRow row: Int, centered: Bool)
    func hit(at point: CGPoint) -> TextHit?          // row and UTF-8 column, not a diff side
}
```

A TextKit 2 pane implementing it (about 3 to 4 weeks by Atelier's estimate) is the missing half. Nothing in `DiffTextKit` is copied for it; its decoration painting, layout fragment and gutter are the models to read.

## Cutting over Atelier, and ask

1. Atelier adds `AemiTextUI` as a path dependency and switches `DiffTextKit/CoreText` to `AemiTextRendering` and `AemiTextCanvas`, in one commit, every package green; a second commit deletes `AtelierTextRendering` and `AtelierTextView`.
2. **ask's `InputMarkdown`** becomes an adapter: `MarkdownSourceHighlighter.spans` then TerminalKit's `MarkdownTheme` to a `Style` per `MarkdownSourceStyle`. Its tests stay as they are (the window-equals-whole ones are already ported, as byte offsets). **Blocked** until AemiMarkdown is pushed: ask pins AemiMarkdown to the revision TerminalKit pins, so the pin moves in TerminalKit and ask together.

## Scroll sync between the editor and the page

`ScrollMap` is the arithmetic. What it needs from each side:
- **Anchors.** The same blocks in both panes. AemiMarkdown has them (block slots with source byte ranges); `NativeRow` carries `source` as text and not as a byte range, which has to be added. The editor's y for a byte offset comes from TextKit 2 (`textSegmentFrame`); the page's y for a row from SwiftUI geometry. Rows not yet laid out (a `LazyVStack`) use an estimate and are corrected as they are measured, which is the same problem `HeightIndex` solves for the canvas.
- **Which side leads.** The pane the pointer or keys last moved leads; the other follows through the map. A follower's own scroll notifications are ignored while it is being driven (a flag and an epsilon), which is what stops the two panes chasing each other.
- **Smoothness.** `ScrollMap` has a continuous slope at every anchor and never goes backwards, so scrolling past a block boundary does not lurch. A jump (the caret moves to a block that is off screen) is a short animation of the follower toward the mapped position, not a snap.
- **Resilience.** Anchors that arrive half measured (not numbers, out of order, repeated, going back) are repaired, not rejected; the map is rebuilt when either side's layout changes, in O(blocks), and looked up in O(log blocks).

## Open

- Harden `AemiTextCanvas` (`TextCanvasView`: tile layers, `setFrameSize` from a document height that may be huge or NaN).
- `HeightIndex` sums `Float`s; many corrections can drift. A rebuild every N updates or a `Double` tree, once measured to matter.
- Selection, hit-testing by byte offset, and accessibility for the canvas, before any pane uses it where users select text.
- `NativeRow.byteRange`, then the lab's two-pane sync on `ScrollMap`.
- The neutral `TextPane` seam and the TextKit 2 pane behind it.
