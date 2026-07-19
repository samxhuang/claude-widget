import Foundation
import Combine

/// One cloud-only Cowork/Code session surfaced via claude.ai's `/recents`
/// endpoint (item 4: "cloud sessions are invisible"). These run entirely
/// server-side and write no local files (nothing under
/// ~/Library/Application Support/Claude/local-agent-mode-sessions, nothing
/// in ~/.claude-autoresume/state.json), so SessionsModel/the daemon have no
/// way to know they exist — the widget has to go ask claude.ai directly.
/// See ChatsFetcher's header comment for the endpoint contract this is
/// parsed from.
struct CloudSessionEntry: Identifiable, Equatable, Hashable {
    let id: String
    var title: String
    var updatedAt: Date?

    /// Same "don't show a blank row" fallback as ChatEntry.displayTitle.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}

/// Holds the most recently fetched list of cloud-only sessions — i.e.
/// `/recents`' `code_session`-typed items with any id already present in
/// SessionsModel's locally-tracked list filtered out, so a session that
/// exists both locally and in the cloud view isn't shown twice. Fetched
/// alongside ChatsFetcher's chat_conversations call (same shared webview,
/// same JS round-trip) rather than a dedicated fetcher/webview — see
/// ChatsFetcher.swift. Purely a reader/republisher, same spirit as
/// PlanFitModel/GraphModel: this widget never writes anything back to
/// claude.ai for these.
final class CloudSessionsModel: ObservableObject {
    /// Newest-first, capped to `displayCap` (see apply below). Use
    /// `totalCount` for the full pre-cap count (e.g. the section badge).
    @Published var sessions: [CloudSessionEntry] = []
    /// Full count of cloud sessions after id/title filtering but before the
    /// display cap — 13 rows of mostly day-old sessions was clutter, so the
    /// visible list is capped while the badge can still show how many exist.
    @Published var totalCount: Int = 0
    @Published var now: Date = Date()

    /// The fixed-height ScrollView (see OverlayView/SectionLayout) absorbs
    /// overflow fine for a handful of rows, but 13 mostly-day-old sessions
    /// was clutter — cap the visible list and let the badge show the rest.
    private static let displayCap = 8
    /// A cloud session updated within this window is considered
    /// actively-running "right now" (vs. an old/idle one) for the
    /// brighter-text/dot treatment in OverlayView.
    private static let activeWindow: TimeInterval = 10 * 60

    func tick() {
        now = Date()
    }

    /// Replaces the full list with `raw` (already normalized down to the
    /// `{id, title, updated_at}` shape ChatsFetcher's JS produces — see its
    /// header comment), filtered to just the ones NOT already tracked
    /// locally, sorted newest-first, and capped to the `displayCap` most
    /// recent. `localIds` is SessionsModel.sessions' ids at the time of the
    /// call — passed in rather than this model reaching for SessionsModel
    /// directly, so it stays an independently-readable model like its
    /// siblings rather than taking a cross-model dependency.
    ///
    /// `localTitles` (case-insensitive, trimmed) additionally filters out
    /// any cloud item whose title matches a currently-displayed local
    /// session's title — a crash-continuation dedupe: a Claude Code process
    /// that crashes mid-conversation gets a NEW local session id when it
    /// continues, but the same conversation still shows up as a cloud
    /// /recents item under yet another id that matches neither the old nor
    /// the new local id, so id-based filtering alone can't catch it.
    func apply(raw: [[String: Any]], localIds: Set<String>, localTitles: Set<String>) {
        let parsed: [CloudSessionEntry] = raw.compactMap { dict in
            guard let id = dict["id"] as? String, !id.isEmpty, !localIds.contains(id) else { return nil }
            let title = dict["title"] as? String ?? ""
            let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !localTitles.contains(normalizedTitle) else { return nil }
            let updatedAt = Self.parseDate(dict["updated_at"] as? String)
            return CloudSessionEntry(id: id, title: title, updatedAt: updatedAt)
        }
        // Newest-first: /recents already comes back sorted this way, but
        // sort explicitly rather than depend on an undocumented endpoint's
        // ordering staying stable.
        let sorted = parsed.sorted { (a, b) in
            (a.updatedAt ?? .distantPast) > (b.updatedAt ?? .distantPast)
        }
        totalCount = sorted.count
        sessions = Array(sorted.prefix(Self.displayCap))
    }

    /// Whether `entry` was updated recently enough to treat as "active right
    /// now" (brighter text / dot) rather than an old, idle session.
    func isActive(_ entry: CloudSessionEntry) -> Bool {
        guard let date = entry.updatedAt else { return false }
        return now.timeIntervalSince(date) < Self.activeWindow
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

    /// Compact "5m ago" / "3h ago" / "2d ago" label, matching
    /// ChatsModel.relativeText's style.
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
