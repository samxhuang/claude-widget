import Cocoa
import ClaudeAPI

// Plain main.swift (no @main attribute needed) so we can run this as a normal
// AppKit app from a Swift Package executable target — no Xcode project or
// Info.plist required.

if CommandLine.arguments.contains("--validate-api") {
    // Contract-validation mode (see .claude/commands/validate-claude-api.md
    // and Sources/ClaudeAPI/CONTRACT.md): exercises each ClaudeAPI call once
    // against the live API, prints a JSON report, exits 0 (pass) / 1
    // (contract failure or timeout) / 2 (logged out). Runs a UI-less
    // NSApplication because the transport is a WKWebView — which is also why
    // this must be launched via the PACKAGED app binary
    // (ClaudeUsageOverlay.app/Contents/MacOS/ClaudeUsageOverlay), whose
    // bundle id keys the same WKWebsiteDataStore the widget's login uses.
    // Safe to run while the widget itself is running (read-only GETs).
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited) // no Dock icon, no UI

    var dumpDir: URL?
    if let flagIndex = CommandLine.arguments.firstIndex(of: "--dump-raw"),
       flagIndex + 1 < CommandLine.arguments.count {
        // Raw dumps are the user's account data: point this at a scratch
        // dir, never the repo; delete after use.
        dumpDir = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1], isDirectory: true)
    }

    let validator = ClaudeAPIValidator(dumpDirectory: dumpDir)
    validator.run { report in
        print(report.jsonString)
        exit(report.exitCode)
    }
    // Hard timeout: a hung navigation (offline, captive portal) must not
    // leave the validator running forever. WebSession's own backoff would
    // eventually surface errors, but 60s is the agreed ceiling.
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
        print("{\"loggedOut\": false, \"pass\": false, \"checks\": [{\"name\": \"timeout\", \"pass\": false, \"detail\": \"validation did not complete within 60s\"}]}")
        exit(1)
    }
    app.run()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
