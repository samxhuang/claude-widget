import Foundation

/// Every claude.ai URL the app is allowed to open. URL shapes are internal
/// API surface (they've changed before and been probed empirically — see
/// CONTRACT.md's deep-link findings), so they live here, not in the UI.
public enum ClaudeWebURLs {
    /// claude.ai home. Also the deliberate fallback for cloud session rows:
    /// no verifiable per-session URL exists (probed 2026-07-19 — the SPA
    /// shell 200s identically for real and bogus ids), so we open home
    /// rather than guess a path.
    public static let home = URL(string: "https://claude.ai")!

    /// The interactive login page (shown in LoginWindowController's visible
    /// webview; its cookies flow to the hidden API webview via the shared
    /// default WKWebsiteDataStore).
    public static let login = URL(string: "https://claude.ai/login")!

    /// A web chat conversation. Verified for chat_conversations-sourced
    /// uuids only — NOT safe for recents-feed item ids (opaque cse_*
    /// tokens; see CONTRACT.md).
    public static func chat(id: String) -> URL {
        URL(string: "https://claude.ai/chat/\(id)") ?? home
    }
}
