import Foundation
import ClaudeAPI

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
    /// classification. The raw API vocabulary is interpreted inside the
    /// ClaudeAPI module (see its CONTRACT.md for the values actually
    /// observed live); CloudSessionsModel.displayStatus then maps the
    /// module's CloudWorkState onto this. Always populated (never nil) since — unlike
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
final class CloudSessionsModel: Observable {
    /// Newest-first, capped to `displayCap` (see apply below). Use
    /// `totalCount` for the full pre-cap count (e.g. the section badge).
    @Observed var sessions: [CloudSessionEntry] = []
    /// Full count of cloud sessions after id/title filtering but before the
    /// display cap — 13 rows of mostly day-old sessions was clutter, so the
    /// visible list is capped while the badge can still show how many exist.
    @Observed var totalCount: Int = 0
    /// Status classification item: per-workStatus counts across the full
    /// (pre-display-cap) filtered list, for the Sessions section header's
    /// combined "N running · N input · N done" breakdown — computed over
    /// the same set `totalCount` is, not just the capped `sessions` array,
    /// so a needs-input session doesn't silently drop out of the count just
    /// because it scrolled past the display cap.
    @Observed var runningCount: Int = 0
    @Observed var needsInputCount: Int = 0
    @Observed var idleCount: Int = 0
    @Observed var now: Date = Date()

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

    /// Replaces the full list with `records` (typed CloudSessionRecords
    /// from the ClaudeAPI module — all raw-JSON parsing happens there),
    /// filtered to just the ones NOT already tracked
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
    func apply(records: [CloudSessionRecord], localIds: Set<String>, localTitles: Set<String>,
               localStartDates: [Date] = []) {
        let cutoff = Date().addingTimeInterval(-Self.lookbackWindow)
        let parsed: [CloudSessionEntry] = records.compactMap { record in
            guard !localIds.contains(record.id) else { return nil }
            // Cloud echo of a locally-tracked CLI session. Verified against a
            // live /recents dump: these rows id as opaque cse_* tokens with
            // EVERY linking field null (no session uuid, no bound device, no
            // preview; the per-session detail endpoint 404s), and claude.ai
            // titles the echo itself, so neither the id nor the title dedupe
            // can catch them. The one joinable signal is created_at — the
            // cloud record is created within ~1s of the local transcript file
            // (verified: 09:44:39.0Z vs 09:44:39.9Z) — so any row created
            // within a ±30s window of a known local CLI session's transcript
            // birth is treated as that session's echo (R2-1: was ±3min, which
            // over-suppressed; 30s is still 30x the verified ~1s skew).
            // SessionsModel retains a dropped session's start date past its
            // local drop for the echo lookback (then evicts it — see
            // cliStartCache there), so echoes of sessions the daemon has since
            // dropped for idleness stay hidden too. That cache is in-memory:
            // after a widget relaunch, an echo of a since-dropped session can
            // reappear for up to the 30-min lookback — accepted; it self-heals
            // as the echo ages out, and eviction makes persistence not worth
            // the plumbing. Residual risk: a genuine cloud session started
            // within 30 seconds of a local one is hidden until the local
            // session's echo ages out of the lookback — accepted; the
            // alternative was a phantom copy of every live local session at
            // the top of the list.
            if let created = record.createdAt,
               localStartDates.contains(where: { abs($0.timeIntervalSince(created)) < 30 }) {
                return nil
            }
            let title = record.title
            let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // S5(b): only treat a title match as a dedupe signal when the title
            // is specific — skip empty/"untitled"/known-generic-default titles
            // (they'd hide unrelated cloud sessions that merely share a default
            // name). `localTitles` is already limited to recently-active local
            // sessions by the caller.
            let titleIsSpecific = !normalizedTitle.isEmpty && !Self.genericTitles.contains(normalizedTitle)
            if titleIsSpecific && localTitles.contains(normalizedTitle) { return nil }
            // Same 30-minute lookback as local sessions: idle cloud sessions
            // age out of the list rather than lingering for days. Unparseable
            // dates are treated as stale, not shown forever.
            guard let updated = record.updatedAt, updated >= cutoff else { return nil }
            let workStatus = Self.displayStatus(for: record.workState)
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
            if record.isArchived && workStatus == .idle { return nil }
            return CloudSessionEntry(id: record.id, title: title, updatedAt: updated, workStatus: workStatus)
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

    /// The raw `status`/`worker_status` vocabulary interpretation moved
    /// into the ClaudeAPI module (ClaudeAPIClient.mapWorkState — it's
    /// internal-API knowledge, empirically derived; see the module's
    /// CONTRACT.md for the observed value log). What stays here is the
    /// display policy: `.unknown` (fields present but unrecognized — likely
    /// an API change) renders as idle, because a false "idle" undersells a
    /// session's activity but never wrongly demands the user's attention.
    /// The validator (--validate-api) flags `.unknown` separately, so the
    /// degradation is detected rather than silent.
    static func displayStatus(for state: CloudWorkState) -> SessionWorkStatus {
        switch state {
        case .running: return .running
        case .needsInput: return .needsInput
        case .idle, .unknown: return .idle
        }
    }

    /// Whether `entry` was updated recently enough to treat as "active right
    /// now" (brighter text / dot) rather than an old, idle session.
    func isActive(_ entry: CloudSessionEntry) -> Bool {
        guard let date = entry.updatedAt else { return false }
        return now.timeIntervalSince(date) < Self.activeWindow
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
