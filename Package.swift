// swift-tools-version:6.0
import PackageDescription
import Foundation

// Dev-tools flavor. When TALKIE_DEV_TOOLS is set at build time, the in-app
// GitHub updater (Sources/TalkieUpdater) — a SEPARATE networked module, exactly
// like TalkieBridge — is compiled in and linked into the app, and the app target
// gets the `TALKIE_DEV_TOOLS` compilation condition so the Developer ▸ App
// updates UI appears. The DEFAULT build links neither networked module, so the
// shipped core stays provably offline (feature 15 / scripts/check-no-network.sh).
//
//   ./scripts/run.sh                     → default (zero-network) build
//   TALKIE_DEV_TOOLS=1 ./scripts/run.sh  → dev build with the in-app updater
//   ./scripts/release_dev.sh             → publishes a dev build for collaborators
let devTools = (ProcessInfo.processInfo.environment["TALKIE_DEV_TOOLS"]?.isEmpty == false)

// macOS 26's Swift concurrency runtime crashes *inside* the dynamic main-actor
// isolation check that Swift 6 injects at @objc / SwiftUI callback boundaries —
// `swift_task_isCurrentExecutor` → `swift_task_isMainExecutorImpl` →
// `swift_getObjectType` faults with EXC_BAD_ACCESS. We hit it from two unrelated
// sites (NSView.hitTest on the accessibility path, and a TimelineView content
// closure in the live background); it's reachable from anywhere AppKit/SwiftUI
// calls back into a @MainActor view, so it can't be fixed per-site. This disables
// only the *runtime* assertion — full static Swift 6 isolation checking still runs
// at compile time — so the concurrency model is unchanged. See the 2026-06-16
// crash reports. Scoped to the app target (the only one that hits SwiftUI/AppKit).
let talkieSwiftSettings: [SwiftSetting] =
    [
        .swiftLanguageMode(.v6),
        .unsafeFlags(["-Xfrontend", "-disable-dynamic-actor-isolation"]),
    ] + (devTools ? [.define("TALKIE_DEV_TOOLS")] : [])

let talkieDependencies: [Target.Dependency] = devTools ? ["TalkieUpdater"] : []

var targets: [Target] = [
    .executableTarget(
        name: "Talkie",
        dependencies: talkieDependencies,
        path: "Sources/Talkie",
        swiftSettings: talkieSwiftSettings
    ),
    // Feature 06: a SEPARATE, always-local stdio MCP server over the on-disk
    // Talkie stores. Zero dependencies (vendored JSON-RPC), no network, no
    // import of the app target — so the privacy wall stays structural.
    .executableTarget(
        name: "talkie-mcp",
        path: "Sources/TalkieMCP",
        swiftSettings: [
            .swiftLanguageMode(.v6),
        ]
    ),
    // Feature 17: a self-contained on-device transcription benchmark (WER +
    // real-time-factor). Independent of the app target.
    .executableTarget(
        name: "talkie-bench",
        path: "Sources/TalkieBench",
        swiftSettings: [
            .swiftLanguageMode(.v6),
        ]
    ),
    // Feature 18: the ONLY always-considered networked module (opt-in Claude
    // bridge). The app core never imports it; compiled in only for a connected
    // build flavor.
    .target(
        name: "TalkieBridge",
        path: "Sources/TalkieBridge",
        swiftSettings: [
            .swiftLanguageMode(.v6),
        ]
    ),
    // Pure-logic unit tests (no Core Audio, no model): the meeting-detection
    // state machine and the live-subtopic confidence gating. Bootstraps the
    // repo's first test target.
    .testTarget(
        name: "TalkieTests",
        dependencies: ["Talkie"],
        path: "Tests/TalkieTests",
        swiftSettings: [
            .swiftLanguageMode(.v6),
        ]
    ),
]

// The in-app updater target exists only in the dev-tools flavor, so the default
// package graph never even builds networked update code.
if devTools {
    targets.append(
        .target(
            name: "TalkieUpdater",
            path: "Sources/TalkieUpdater",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        )
    )
    // Gated by the SAME devTools condition: the default package graph never sees
    // this target, so `swift test` stays at the offline-core baseline. Run it with
    // `TALKIE_DEV_TOOLS=1 swift test`. Covers the pure artifact-verification gate.
    targets.append(
        .testTarget(
            name: "TalkieUpdaterTests",
            dependencies: ["TalkieUpdater"],
            path: "Tests/TalkieUpdaterTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        )
    )
}

let package = Package(
    name: "Talkie",
    platforms: [
        .macOS("26.0"),
    ],
    targets: targets
)
