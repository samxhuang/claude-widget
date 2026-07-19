// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeUsageOverlay",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // The ONLY code allowed to know claude.ai internal-API details
        // (endpoint paths, JSON field names, status vocabularies, deep-link
        // URL shapes). When the internal API changes, this target — and
        // nothing else — is what gets updated. Boundary enforced by
        // scripts/check_api_boundary.sh; contract documented in
        // Sources/ClaudeAPI/CONTRACT.md and docs/claude-api-module-plan.md.
        .target(
            name: "ClaudeAPI",
            path: "Sources/ClaudeAPI",
            exclude: ["CONTRACT.md"]
        ),
        .executableTarget(
            name: "ClaudeUsageOverlay",
            dependencies: ["ClaudeAPI"],
            path: "Sources/ClaudeUsageOverlay"
        )
    ]
)
