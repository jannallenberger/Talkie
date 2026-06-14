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
    ]
)
