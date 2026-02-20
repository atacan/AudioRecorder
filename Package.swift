// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AudioRecorder",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "AudioRecorderClient", targets: ["AudioRecorderClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.6.2"),
    ],
    targets: [
        .target(
            name: "AudioRecorderClient",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
            ],
            exclude: [
                "THIRD_PARTY_NOTICES.md",
            ]
        ),
        .testTarget(name: "AudioRecorderClientTests", dependencies: ["AudioRecorderClient"]),
    ]
)

/*
AudioRecorderClient target includes small, adapted portions of audio capture and conversion logic inspired by WhisperKit:

- Project: WhisperKit
- Repository: https://github.com/argmaxinc/WhisperKit
- License: MIT
- Source reference used during adaptation:
  - `Sources/WhisperKit/Core/Audio/AudioProcessor.swift`
*/