// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Condux",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Condux",
            path: "Sources/VibeStudio"
        ),
        .testTarget(name: "ConduxTests", dependencies: ["Condux"], path: "Tests/VibeStudioTests")
    ]
)
