// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeUsageOverlay",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "ClaudeUsageOverlay",
            path: "Sources/ClaudeUsageOverlay"
        )
    ]
)
