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

// Connected flavor. When TALKIE_CONNECTED is set at build time, the opt-in Claude
// bridge (Sources/TalkieBridge) — a SEPARATE networked module, exactly like
// TalkieUpdater — is compiled in and linked into the app, and the app target gets
// the `TALKIE_CONNECTED` compilation condition so `PrivacyWall`'s gate lifts (see
// PrivacyWall.isAllowed) and the bridge is reachable. The DEFAULT build links
// neither networked module, so the shipped core stays provably offline (feature 15 /
// scripts/check-no-network.sh).
//
//   ./scripts/run.sh                    → default (zero-network) build
//   TALKIE_CONNECTED=1 ./scripts/run.sh → connected build with the Claude bridge
let connected = (ProcessInfo.processInfo.environment["TALKIE_CONNECTED"]?.isEmpty == false)

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
        + (connected ? [.define("TALKIE_CONNECTED")] : [])

let talkieDependencies: [Target.Dependency] =
    ["TalkieFileKit", "TalkieDiarization"] + (devTools ? ["TalkieUpdater"] : []) + (connected ? ["TalkieBridge"] : [])

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
    // G4: the shared, offline file-transcription kit. Extracted from TalkieBench
    // (AudioFileLoader decode/resample + FileTranscriber, a faithful standalone
    // mirror of the app's SpeechAnalyzer path) so BOTH `talkie-bench` and the
    // `talkie` CLI reuse one implementation. Zero dependencies, no import of the
    // app target — the recognition stack is exercised read-only, so this stays a
    // separate, network-free library and the bench's WER numbers are unchanged.
    .target(
        name: "TalkieFileKit",
        path: "Sources/TalkieFileKit",
        swiftSettings: [
            .swiftLanguageMode(.v6),
        ]
    ),
    // Feature 17: a self-contained on-device transcription benchmark (WER +
    // real-time-factor). Independent of the app target; shares the decode +
    // recognition path with the CLI via TalkieFileKit.
    .executableTarget(
        name: "talkie-bench",
        dependencies: ["TalkieFileKit"],
        path: "Sources/TalkieBench",
        swiftSettings: [
            .swiftLanguageMode(.v6),
        ]
    ),
    // G4: MacWhisper-Pro-style local batch file transcription for free —
    // `talkie transcribe interview.m4a --srt`, `talkie last`. Named `talkie-cli`
    // (NOT `talkie`) because the app binary is `Talkie` and APFS is
    // case-insensitive; build_app.sh copies it to Contents/MacOS/talkie at bundle
    // time. Hand-rolled arg parsing (no swift-argument-parser), 100% on-device.
    .executableTarget(
        name: "talkie-cli",
        dependencies: ["TalkieFileKit"],
        path: "Sources/TalkieCLI",
        swiftSettings: [
            .swiftLanguageMode(.v6),
        ]
    ),
    // Speaker diarization (pyannote community-1 via FluidAudio's CoreML
    // conversion). An ISOLATED wrapper, same idea as TalkieUpdater/TalkieBridge:
    // the app target never imports FluidAudio, only this module's tiny Sendable
    // API (no FluidAudio types cross the boundary). Runs fully offline from the
    // CoreML models bundled in Contents/Resources/DiarizationModels: it loads
    // them itself from that folder (MLModel(contentsOf:)); the vendored FluidAudio
    // contains no download/ModelHub/networking code at all. Models are fetched at
    // BUILD time by scripts/fetch_diarization_models.sh (pinned revision,
    // SHA-256 manifest); see THIRD_PARTY_NOTICES.md for licenses.
    .target(
        name: "TalkieDiarization",
        dependencies: ["FluidAudio"],
        path: "Sources/TalkieDiarization",
        swiftSettings: [
            .swiftLanguageMode(.v6),
        ]
    ),
    // Vendored subset of FluidAudio v0.18.3 (Apache-2.0): ONLY the offline
    // community-1 diarizer. All model-download / Hugging Face / URLSession code
    // is removed, so this module contains no networking. See
    // Sources/FluidAudio/VENDORED.md for provenance and the re-sync procedure.
    .target(
        name: "FluidAudio",
        dependencies: ["FastClusterWrapper"],
        path: "Sources/FluidAudio",
        exclude: ["VENDORED.md", "LICENSE", "fastcluster-LICENSE.md", "vbx-LICENSE.md"],
        swiftSettings: [
            .define("Diarizer"),
        ]
    ),
    // Vendored C++ hierarchical clustering (fastcluster, BSD-2-Clause) used by
    // the diarizer's AHC step. Pure computation, no I/O.
    .target(
        name: "FastClusterWrapper",
        path: "Sources/FastClusterWrapper",
        publicHeadersPath: "include"
    ),
    // Model-dependent tests SKIP (not fail) when Vendor/DiarizationModels is
    // absent, so CI without the fetched models stays green.
    .testTarget(
        name: "TalkieDiarizationTests",
        dependencies: ["TalkieDiarization", "FluidAudio"],
        path: "Tests/TalkieDiarizationTests",
        swiftSettings: [
            .swiftLanguageMode(.v6),
        ]
    ),
    // Pure-logic unit tests (no Core Audio, no model): the meeting-detection
    // state machine and the live-subtopic confidence gating. Bootstraps the
    // repo's first test target.
    .testTarget(
        name: "TalkieFileKitTests",
        dependencies: ["TalkieFileKit"],
        path: "Tests/TalkieFileKitTests",
        swiftSettings: [
            .swiftLanguageMode(.v6),
        ]
    ),
    // Opt-in end-to-end file harness (skips unless TALKIE_FILETEST_INPUT is set).
    // Separate target so it builds in release (the main test target uses DEBUG-only hooks).
    .testTarget(
        name: "FileDiarizationHarnessTests",
        dependencies: ["Talkie", "TalkieDiarization", "TalkieFileKit"],
        path: "Tests/FileDiarizationHarnessTests",
        swiftSettings: [
            .swiftLanguageMode(.v6),
        ]
    ),
    .testTarget(
        name: "TalkieTests",
        dependencies: ["Talkie", "TalkieDiarization"],
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

// The Claude bridge target exists only in the connected flavor, so the default
// package graph never even builds networked bridge code (Feature 18: the opt-in
// Claude bridge — the app core never imports it).
if connected {
    targets.append(
        .target(
            name: "TalkieBridge",
            path: "Sources/TalkieBridge",
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
