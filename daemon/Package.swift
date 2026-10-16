// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SentryScreen",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "SentryScreen", path: "Sources/SentryScreen")
    ]
)
