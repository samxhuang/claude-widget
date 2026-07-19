import Foundation
import Combine
import ClaudeAPI

/// One recent claude.ai conversation, as returned by the chat_conversations
/// list endpoint.
struct ChatEntry: Identifiable, Equatable, Hashable {
    let uuid: String
    var name: String
    var updatedAt: Date?

    var id: String { uuid }

    /// Conversations can be created without ever getting a title (e.g.
    /// abandoned after one message) — claude.ai's own UI falls back to
    /// "Untitled" in that case, so we match it rather than show blank rows.
    var displayTitle: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}

/// Holds the most recently fetched claude.ai conversation list. Mirrors
/// UsageModel's shape (isLoggedOut / lastError / lastUpdated) so OverlayView
/// can reuse the same affordances for both sections.
final class ChatsModel: ObservableObject {
    @Published var chats: [ChatEntry] = []

    @Published var isLoggedOut: Bool = false
    @Published var lastError: String?
    @Published var lastUpdated: Date?

    @Published var now: Date = Date()

    // Item 3 (merge): `chatsExpanded`/`toggleChatsExpanded` used to back
    // Recent chats' own collapsible section header. That section is gone —
    // chat rows now join the unified Sessions list unconditionally (subject
    // to Sessions' own expand/collapse) — so this model no longer tracks
    // any expand state of its own.

    func tick() {
        now = Date()
    }

    /// Raw-JSON normalization moved into the ClaudeAPI module; this just
    /// re-shapes the typed DTOs into the UI's ChatEntry rows.
    func apply(conversations: [ChatConversation]) {
        chats = conversations.map {
            ChatEntry(uuid: $0.id, name: $0.title, updatedAt: $0.updatedAt)
        }
        lastUpdated = Date()
    }

    /// Compact "5m ago" / "3h ago" / "2d ago" relative label, matching the
    /// terse style used elsewhere in the overlay (resetText, lastUpdatedText).
    func relativeText(for date: Date?) -> String {
        guard let date = date else { return "—" }
        let interval = now.timeIntervalSince(date)
        if interval < 60 { return "just now" }
        let minutes = Int(interval) / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return "\(days)d ago"
    }
}
