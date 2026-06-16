// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Talkie",
    platforms: [
        .macOS("26.0"),
    ],
    targets: [
        .executableTarget(
            name: "Talkie",
            path: "Sources/Talkie",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // macOS 26's Swift concurrency runtime crashes *inside* the dynamic
                // main-actor isolation check that Swift 6 injects at @objc / SwiftUI
                // callback boundaries — `swift_task_isCurrentExecutor` →
                // `swift_task_isMainExecutorImpl` → `swift_getObjectType` faults with
                // EXC_BAD_ACCESS. We hit it from two unrelated sites (NSView.hitTest
                // on the accessibility path, and a TimelineView content closure in the
                // live background); it's reachable from anywhere AppKit/SwiftUI calls
                // back into a @MainActor view, so it can't be fixed per-site. This
                // disables only the *runtime* assertion — full static Swift 6
                // isolation checking still runs at compile time — so the concurrency
                // model is unchanged. See the 2026-06-16 crash reports.
                .unsafeFlags(["-Xfrontend", "-disable-dynamic-actor-isolation"]),
            ]
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
        // Feature 18: the ONLY networked module (opt-in Claude bridge). The app
        // core never imports it; compiled in only for a connected build flavor.
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
)
