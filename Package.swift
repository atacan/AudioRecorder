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
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(name: "AudioRecorderClient", targets: ["AudioRecorderClient"]),
        .library(name: "AudioDataStreamClient", targets: ["AudioDataStreamClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.6.2"),
        .package(url: "https://github.com/pointfreeco/swift-case-paths", from: "1.5.6"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.10.2"),
        .package(path: "../SystemSoundDependency"),
    ],
    targets: [
        .target(
            name: "AudioRecorderClient",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "SystemSoundClient", package: "SystemSoundDependency"),
            ]
        ),
        .target(
            name: "AudioDataStreamClient",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                .product(name: "CasePaths", package: "swift-case-paths"),
                .product(name: "SystemSoundClient", package: "SystemSoundDependency"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
        .testTarget(name: "AudioRecorderClientTests", dependencies: ["AudioRecorderClient"])
    ]
)
