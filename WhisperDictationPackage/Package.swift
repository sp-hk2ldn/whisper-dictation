// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "WhisperDictationFeature",
    platforms: [.macOS(.v14)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "WhisperDictationFeature",
            targets: ["WhisperDictationFeature"]
        ),
        .executable(
            name: "InsertionHarness",
            targets: ["InsertionHarness"]
        ),
        .executable(
            name: "TerminalProbe",
            targets: ["TerminalProbe"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/argmaxinc/WhisperKit.git",
            exact: "1.0.0"
        ),
    ],
    targets: [
        .target(name: "AudioExceptionBridge"),
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "WhisperDictationFeature",
            dependencies: [
                "AudioExceptionBridge",
                .product(name: "WhisperKit", package: "WhisperKit")
            ]
        ),
        .testTarget(
            name: "WhisperDictationFeatureTests",
            dependencies: [
                "AudioExceptionBridge",
                "WhisperDictationFeature"
            ]
        ),
        .executableTarget(
            name: "InsertionHarness"
        ),
        .executableTarget(
            name: "TerminalProbe"
        ),
    ]
)
