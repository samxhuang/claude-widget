import Foundation
import Combine

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

    private static let expandedDefaultsKey = "chatsExpanded"
    /// Persisted across launches, same pattern as SessionsModel.sessionsExpanded.
    /// Starts collapsed.
    @Published var chatsExpanded: Bool {
        didSet { UserDefaults.standard.set(chatsExpanded, forKey: Self.expandedDefaultsKey) }
    }

    private var lastToggleAt: Date = .distantPast

    init() {
        self.chatsExpanded = UserDefaults.standard.object(forKey: Self.expandedDefaultsKey) as? Bool ?? false
    }

    /// Debounced the same way SessionsModel.toggleSessionsExpanded is — a
    /// click delivered twice in quick succession inside a non-activating
    /// panel would otherwise expand and immediately re-collapse in one frame.
    func toggleChatsExpanded() {
        let now = Date()
        guard now.timeIntervalSince(lastToggleAt) > 0.35 else { return }
        lastToggleAt = now
        chatsExpanded.toggle()
    }

    func tick() {
        now = Date()
    }

    func apply(chats rawChats: [[String: Any]]) {
        let parsed: [ChatEntry] = rawChats.compactMap { dict in
            guard let uuid = dict["uuid"] as? String else { return nil }
            let name = dict["name"] as? String ?? ""
            let updatedAt = Self.parseDate(dict["updated_at"] as? String)
            return ChatEntry(uuid: uuid, name: name, updatedAt: updatedAt)
        }
        chats = parsed
        lastUpdated = Date()
    }

    private static func parseDate(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
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
