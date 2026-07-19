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
    /// Status classification item: unified running/needs-input/idle
    /// classification, computed at fetch time by
    /// CloudSessionsModel.mapWorkStatus from the raw `status`/
    /// `worker_status` fields /recents returns (see that function's doc
    /// comment for the values actually observed against the live,
    /// authenticated endpoint). Always populated (never nil) since — unlike
    /// the local daemon's state.json field — this is computed fresh on every
    /// fetch, no stale-build fallback needed.
    var workStatus: SessionWorkStatus

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
    /// Status classification item: per-workStatus counts across the full
    /// (pre-display-cap) filtered list, for the Sessions section header's
    /// combined "N running · N input · N done" breakdown — computed over
    /// the same set `totalCount` is, not just the capped `sessions` array,
    /// so a needs-input session doesn't silently drop out of the count just
    /// because it scrolled past the display cap.
    @Published var runningCount: Int = 0
    @Published var needsInputCount: Int = 0
    @Published var idleCount: Int = 0
    @Published var now: Date = Date()

    /// The fixed-height ScrollView (see OverlayView/SectionLayout) absorbs
    /// overflow fine for a handful of rows, but 13 mostly-day-old sessions
    /// was clutter — cap the visible list and let the badge show the rest.
    private static let displayCap = 8
    /// Cloud sessions idle longer than this are dropped entirely, mirroring
    /// the daemon's ACTIVE_WINDOW_MINUTES lookback for local sessions so
    /// both halves of the Sessions list age out on the same clock.
    private static let lookbackWindow: TimeInterval = 30 * 60
    /// A cloud session updated within this window is considered
    /// actively-running "right now" (vs. an old/idle one) for the
    /// brighter-text/dot treatment in OverlayView.
    private static let activeWindow: TimeInterval = 10 * 60
    /// S5(b): cloud titles equal (case-insensitively) to one of these — or
    /// empty/"untitled" — are too generic to be evidence that a cloud row is
    /// the same conversation as a local one, so the title-based dedupe is
    /// skipped for them (it would false-positive and hide real, distinct cloud
    /// sessions that merely share a default name). Kept lowercased to match
    /// the normalized comparison below.
    private static let genericTitles: Set<String> = [
        "untitled",
        "cowork session",
        "general coding session"
    ]

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
    ///
    /// S5(b): this title match is now GUARDED two ways to stop it hiding
    /// genuinely distinct cloud sessions. (1) Generic/empty titles ("untitled"
    /// and the known defaults "cowork session" / "general coding session" —
    /// see `genericTitles`) are skipped: they false-positive constantly
    /// because many unrelated sessions share a default name. (2) `localTitles`
    /// is pre-filtered by the caller (AppDelegate) to only RECENTLY-ACTIVE
    /// local sessions, since the crash-continuation case it exists for always
    /// involves a recently-live local row — a stale local row must not hide a
    /// live cloud one. Residual risk: two truly distinct sessions that share a
    /// specific, non-generic title AND are both recently active locally/cloud
    /// would still collapse — accepted as rare (a specific shared title on two
    /// concurrently-live sessions is unlikely) and strictly narrower than the
    /// previous any-title-match behavior.
    func apply(raw: [[String: Any]], localIds: Set<String>, localTitles: Set<String>) {
        let cutoff = Date().addingTimeInterval(-Self.lookbackWindow)
        let parsed: [CloudSessionEntry] = raw.compactMap { dict in
            guard let id = dict["id"] as? String, !id.isEmpty, !localIds.contains(id) else { return nil }
            // Cloud echo of a locally-tracked CLI session: claude.ai's
            // server-side record for a Desktop-attached CLI session carries a
            // "local_" prefix on the transcript uuid (same convention as the
            // deep-link imports — see openLocalSession's history), while the
            // daemon keys the local entry by the bare uuid. Without stripping
            // the prefix here the echo dodges the id dedupe, and the title
            // dedupe can't catch it either (claude.ai titles the synced copy
            // itself, so the two titles differ). Cowork rows are unaffected:
            // they're tracked locally under the local_-prefixed id already,
            // so they match on the plain contains() above.
            if id.hasPrefix("local_"), localIds.contains(String(id.dropFirst("local_".count))) {
                return nil
            }
            let title = dict["title"] as? String ?? ""
            let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // S5(b): only treat a title match as a dedupe signal when the title
            // is specific — skip empty/"untitled"/known-generic-default titles
            // (they'd hide unrelated cloud sessions that merely share a default
            // name). `localTitles` is already limited to recently-active local
            // sessions by the caller.
            let titleIsSpecific = !normalizedTitle.isEmpty && !Self.genericTitles.contains(normalizedTitle)
            if titleIsSpecific && localTitles.contains(normalizedTitle) { return nil }
            let updatedAt = Self.parseDate(dict["updated_at"] as? String)
            // Same 30-minute lookback as local sessions: idle cloud sessions
            // age out of the list rather than lingering for days. Unparseable
            // dates are treated as stale, not shown forever.
            guard let updated = updatedAt, updated >= cutoff else { return nil }
            let rawStatus = (dict["status"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased()
            let workStatus = Self.mapWorkStatus(
                status: dict["status"] as? String,
                workerStatus: dict["worker_status"] as? String
            )
            // Deleted-session fix (2026-07-19): deleting a session in Claude
            // Desktop's GUI archives its cloud copy rather than removing it
            // from /recents right away, so a deleted session would linger
            // here as a phantom "cloud session" row (reported against a
            // deleted Code session that popped back up under its old cloud
            // title). Live per-item dump of all 13 /recents items at the
            // time: every dead/deleted item was status=archived with an
            // idle worker, while every genuinely-live session was either
            // status=active (visible in Desktop's sidebar) or had a
            // running worker (archived+running — Desktop auto-archive with
            // the worker still going, which must stay visible). So:
            // archived + no live/needs-input worker = not a real session
            // anymore, drop it. (This also filters the cloud echoes of the
            // duplicate "General coding session" imports the old deep-link
            // click behavior created — see OverlayView.openLocalSession —
            // after those dups are deleted.)
            if rawStatus == "archived" && workStatus == .idle { return nil }
            return CloudSessionEntry(id: id, title: title, updatedAt: updated, workStatus: workStatus)
        }
        // Newest-first: /recents already comes back sorted this way, but
        // sort explicitly rather than depend on an undocumented endpoint's
        // ordering staying stable.
        let sorted = parsed.sorted { (a, b) in
            (a.updatedAt ?? .distantPast) > (b.updatedAt ?? .distantPast)
        }
        totalCount = sorted.count
        runningCount = sorted.filter { $0.workStatus == .running }.count
        needsInputCount = sorted.filter { $0.workStatus == .needsInput }.count
        idleCount = sorted.filter { $0.workStatus == .idle }.count
        sessions = Array(sorted.prefix(Self.displayCap))
    }

    /// Maps /recents' raw `status`/`worker_status` fields to the unified
    /// SessionWorkStatus. Verified empirically (2026-07-19) against the
    /// live, authenticated endpoint via the widget's own webview (ran the
    /// real app, captured its stdout across two ~2-minute refresh cycles).
    /// Every combo actually observed across 13 raw items, both cycles:
    ///   status=active   worker_status=idle
    ///   status=archived worker_status=idle
    ///   status=archived worker_status=running
    /// i.e. `worker_status: "running"` is confirmed real (it's what an
    /// actively-executing session reports, consistent with this account
    /// having live Code sessions running while this was captured) — but,
    /// surprisingly, it showed up paired with `status: "archived"`, not
    /// `status: "active"` as originally hypothesized; "archived" here
    /// evidently describes something else (e.g. whether the item is pinned
    /// to a visible surface) rather than whether the underlying worker is
    /// still going. No `status`/`worker_status` value resembling
    /// "waiting"/"needs input"/"blocked" was observed in this data — this
    /// account's sessions were either running or fully idle at capture
    /// time, so the needs-input branches below are an unverified,
    /// conservative forward guess (keyword-matched), not confirmed against
    /// real data. `worker_status` is the more specific of the two fields
    /// (describes the underlying Code/Cowork worker process directly), so
    /// it takes priority over the coarser `status` field when both are
    /// present. Falls back to `.idle` for anything not recognized (stale/
    /// finished sessions, or a future endpoint change) rather than guessing
    /// — a false "idle" undersells a session's activity but never wrongly
    /// demands the user's attention, which is the safer direction to err
    /// for a field whose full value space isn't confirmed.
    ///
    /// Item 3B update (2026-07-19): `worker_status: "requires_action"` was
    /// subsequently observed on a real, live session with a pending
    /// permission-prompt-style action (a Bash tool call awaiting approval)
    /// — a genuine needs-input case the keyword list above didn't catch (it
    /// doesn't contain "wait"/"input"/"pending"/"blocked" and isn't
    /// "paused"). Added as an explicit exact match now that it's
    /// empirically confirmed, rather than folded into the fuzzier
    /// `.contains` checks meant for still-unverified guesses.
    static func mapWorkStatus(status: String?, workerStatus: String?) -> SessionWorkStatus {
        let w = workerStatus?.trimmingCharacters(in: .whitespaces).lowercased()
        let s = status?.trimmingCharacters(in: .whitespaces).lowercased()

        if let w {
            if w == "running" || w == "active" || w == "executing" || w == "working" {
                return .running
            }
            if w == "requires_action" || w.contains("wait") || w.contains("input") || w.contains("pending") || w.contains("blocked") || w == "paused" {
                return .needsInput
            }
        }
        if let s {
            if s.contains("wait") || s.contains("input") || s.contains("blocked") || s == "needs_attention" {
                return .needsInput
            }
            if s == "active" && w == nil {
                // No worker_status to disambiguate further; a bare "active"
                // status with nothing else is the best signal available that
                // something is happening.
                return .running
            }
        }
        return .idle
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
