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
    ]
)
