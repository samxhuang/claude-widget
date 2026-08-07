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
        ),
        // Unit tests for the ClaudeAPI module. ClaudeAPIClient became
        // testable when its transport was abstracted behind
        // ClaudeScriptRunner (audit §1.10) — these drive every decode and
        // error path through a fake runner returning canned JSON, with no
        // webview and no network. The app target has no test target: it is
        // AppKit/SwiftUI and out of scope here.
        //
        // Run them with ./run_tests.command — these use swift-testing, and a
        // bare `swift test` only works if full Xcode is installed (see that
        // script's header for the Command-Line-Tools workaround).
        .testTarget(
            name: "ClaudeAPITests",
            dependencies: ["ClaudeAPI"],
            path: "Tests/ClaudeAPITests"
        )
    ]
)
