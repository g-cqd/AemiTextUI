// swift-tools-version: 6.4
import PackageDescription

// AemiTextUI: text rendering and text-view building blocks, extracted from Atelier (GitDiffViewer's panes) so that more than one app can use them. Swift 6 language mode, warnings as errors, the upcoming
// features that tighten existentials, isolation and imports: the same strictness as AemiHTML, AemiMarkdown and AemiJSON. No third-party packages, and no dependency on any other package at all for now.
let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility")
]

let package = Package(
    name: "AemiTextUI",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AemiTextRendering", targets: ["AemiTextRendering"]),
        .library(name: "AemiTextCanvas", targets: ["AemiTextCanvas"])
    ],
    targets: [
        // The CoreText renderer's model, style sheets, height index, typesetting and tile rasterization: pure value types over CoreText and CoreGraphics. No AppKit, no tasks of its own.
        .target(name: "AemiTextRendering", swiftSettings: strictSettings),
        .testTarget(
            name: "AemiTextRenderingTests",
            dependencies: ["AemiTextRendering"],
            swiftSettings: strictSettings
        ),
        // The renderer's @MainActor host view: tiles as layers, the height index kept live, hit-testing. AppKit and QuartzCore only; it knows nothing of diffs.
        .target(name: "AemiTextCanvas", dependencies: ["AemiTextRendering"], swiftSettings: strictSettings),
        .testTarget(
            name: "AemiTextCanvasTests",
            dependencies: ["AemiTextCanvas", "AemiTextRendering"],
            swiftSettings: strictSettings
        )
    ]
)
