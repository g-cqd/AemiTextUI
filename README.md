# AemiTextUI

Text rendering and text-view building blocks, extracted from [Atelier](../Atelier) (GitDiffViewer's panes) so that more than one app can use them. No third-party packages, and no dependency on any other package for now. Swift 6.4, macOS 15; iOS later.

| Target | What |
|---|---|
| `AemiTextRendering` | The CoreText renderer: an immutable `StyledText` (UTF-8 bytes, row starts, style runs), `LayoutConfiguration`, a `HeightIndex` with O(log rows) queries, `TextTypesetter` (layout and tile rasterization off the main actor), decoration layers, bidi policy (the Trojan Source class is neutralized by default). Pure value types over CoreText and CoreGraphics. |
| `AemiTextCanvas` | `TextCanvasView`, the `@MainActor` AppKit host: tiles as layers, the height index kept live, hit-testing. It knows nothing of diffs. |

```sh
swift test          # 39 tests, about a second
```

## Where the code came from, and what changed

`AtelierTextRendering` and `AtelierTextView` were copied (Atelier is untouched; it keeps its own until it depends on this package) and renamed. The copy was then hardened, because a renderer is handed numbers and
offsets by code with bugs and by documents that are hostile. `docs/design/hardening.md` has the findings, each with the test that found it.

Markdown-specific code belongs in AemiMarkdown, lexing in aemi; this package is for general text-UI APIs.
