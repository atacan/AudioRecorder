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
        .library(name: "AudioRecorder", targets: ["AudioRecorder"]),
        .library(name: "AudioRecorderClient", targets: ["AudioRecorderClient"]),
        .library(name: "AudioDataStreamClient", targets: ["AudioDataStreamClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.0.0"),
        .package(url: "https://github.com/pointfreeco/swift-case-paths", from: "1.1.0"),
        .package(path: "../SystemSoundDependency"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "AudioRecorder"
        ),
        .target(
            name: "AudioRecorderClient",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies")
            ]
        ),
        .target(
            name: "AudioDataStreamClient",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                .product(name: "CasePaths", package: "swift-case-paths"),
                .product(name: "SystemSoundClient", package: "SystemSoundDependency"),
            ]
        ),
        .testTarget(
            name: "AudioRecorderTests",
            dependencies: ["AudioRecorder"]
        ),
        .testTarget(name: "AudioRecorderClientTests", dependencies: ["AudioRecorderClient"])
    ]
)
