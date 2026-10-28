// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HushpadKit",
    platforms: [.macOS(.v26), .iOS(.v26), .watchOS(.v26)],
    products: [
        /// Shared by all three apps (including watchOS): data model, storage, recording, sync, export.
        .library(name: "HushpadCore", targets: ["HushpadCore"]),
        /// Mac + iPhone: local transcription, speaker separation, screenshots, notes, import.
        .library(name: "HushpadKit", targets: ["HushpadKit"]),
        /// Shared SwiftUI design system: colours, record button, waveform, speaker chips (all platforms).
        .library(name: "HushpadUI", targets: ["HushpadUI"]),
        .executable(name: "hushpad", targets: ["hushpad"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "HushpadCore"),
        .target(name: "HushpadUI", dependencies: ["HushpadCore"], resources: [.copy("Fonts")]),
        .target(
            name: "HushpadKit",
            dependencies: [
                "HushpadCore",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
            ]
        ),
        .executableTarget(
            name: "hushpad",
            dependencies: [
                "HushpadKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "HushpadKitTests",
            dependencies: ["HushpadKit", "HushpadCore", "HushpadUI"],
            resources: [.copy("Fixtures")]
        ),
    ]
)

// Tests that call real cloud providers (made-up text only) are never part of `swift test`: they can break for
// reasons outside this repo. Run them on demand with
//   HUSHPAD_LIVE=1 swift test --filter LiveProviderTests
if Context.environment["HUSHPAD_LIVE"] == "1" {
    package.targets.append(.testTarget(name: "LiveProviderTests", dependencies: ["HushpadKit", "HushpadCore"]))
}

