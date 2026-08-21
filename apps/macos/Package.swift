// swift-tools-version: 6.0

import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repositoryRoot = packageRoot.deletingLastPathComponent().deletingLastPathComponent()
let rustLibraryDirectory = repositoryRoot.appendingPathComponent("target/debug").path

let package = Package(
    name: "OpenScribeMacOS",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "OpenScribeApp", targets: ["OpenScribeApp"]),
    ],
    targets: [
        .systemLibrary(
            name: "OpenScribeFFI",
            path: "Sources/OpenScribeFFI"
        ),
        .executableTarget(
            name: "OpenScribeApp",
            dependencies: ["OpenScribeFFI"],
            path: "Sources/OpenScribeApp",
            linkerSettings: [
                .unsafeFlags(["-L", rustLibraryDirectory]),
                .linkedLibrary("open_scribe_uniffi"),
            ]
        ),
        .testTarget(
            name: "OpenScribeAppTests",
            dependencies: ["OpenScribeApp"],
            path: "Tests/OpenScribeAppTests"
        ),
    ]
)
