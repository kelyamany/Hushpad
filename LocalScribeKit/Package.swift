// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LocalScribeKit",
    platforms: [.macOS(.v26), .iOS(.v26), .watchOS(.v26)],
    products: [
        /// Shared by all three apps (including watchOS): data model, storage, recording, sync, export.
        .library(name: "LocalScribeCore", targets: ["LocalScribeCore"]),
        /// Mac + iPhone: local transcription, speaker separation, screenshots, notes, import.
        .library(name: "LocalScribeKit", targets: ["LocalScribeKit"]),
        /// Shared SwiftUI design system: colours, record button, waveform, speaker chips (all platforms).
        .library(name: "LocalScribeUI", targets: ["LocalScribeUI"]),
        .executable(name: "scribe", targets: ["scribe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.18.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "LocalScribeCore"),
        .target(name: "LocalScribeUI", dependencies: ["LocalScribeCore"], resources: [.copy("Fonts")]),
        .target(
            name: "LocalScribeKit",
            dependencies: [
                "LocalScribeCore",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "SpeakerKit", package: "WhisperKit"),
            ]
        ),
        .executableTarget(
            name: "scribe",
            dependencies: [
                "LocalScribeKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "LocalScribeKitTests",
            dependencies: ["LocalScribeKit", "LocalScribeCore", "LocalScribeUI"],
            resources: [.copy("Fixtures")]
        ),
    ]
)

// Tests that call real cloud providers (made-up text only) are never part of `swift test`: they can break for
// reasons outside this repo. Run them on demand with
//   LOCALSCRIBE_LIVE=1 swift test --filter LiveProviderTests
if Context.environment["LOCALSCRIBE_LIVE"] == "1" {
    package.targets.append(.testTarget(name: "LiveProviderTests", dependencies: ["LocalScribeKit", "LocalScribeCore"]))
}

