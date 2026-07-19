import Foundation
import Combine
import Darwin

/// Unified per-row status classification, shared by locally-tracked (daemon,
/// state.json's "work_status") and cloud-only (claude.ai /recents' `status`/
/// `worker_status`, mapped by CloudSessionsModel) sessions alike — this is
/// what lets OverlayView use one dot-color language across both kinds of
/// rows instead of the old local-only blue/orange scheme plus a separately-
/// colored cloud dot.
///
/// - `running`: Claude is actively working (local: transcript/subagent
///   touched within the last ~90s; cloud: worker_status == "running").
/// - `needsInput`: turn is stalled waiting on the user — most commonly a
///   permission prompt (local: quiet >90s AND the last event is an assistant
///   turn ending in an unresolved tool_use; see autoresume.py's
///   classify_work_status for the transcript evidence behind that rule).
/// - `idle`: turn finished cleanly, or anything else not covered above.
enum SessionWorkStatus: String {
    case running
    case needsInput = "needs_input"
    case idle

    /// Shown in the dot's `.help` tooltip.
    var label: String {
        switch self {
        case .running: return "Running"
        case .needsInput: return "Needs input"
        case .idle: return "Idle / done"
        }
    }
}

/// One Claude Code session that got cut off by a rate limit, as detected by
/// the claude-autoresume daemon. Mirrors an entry in ~/.claude-autoresume/state.json.
struct SessionEntry: Identifiable, Equatable, Hashable {
    let id: String // session_id
    var projectName: String
    var sessionTitle: String?
    var projectDir: String
    var promptPreview: String
    var resetsAt: Date?      // nil while status == "active" (not rate-limited yet)
    /// Item 5: the session's real last-activity time (daemon's
    /// `last_activity_at` — transcript mtime for CLI sessions,
    /// `lastActivityAt` for Cowork), as opposed to `last_seen`, which is
    /// just poll-cycle bookkeeping. Drives the "<1m" / "17m" age shown in
    /// place of the old, useless "active now" for sessions that haven't hit
    /// a rate limit yet. nil for entries written by a daemon build that
    /// predates this field.
    var lastActivityAt: Date?
    var enabled: Bool
    var forceResume: Bool
    var handled: Bool
    var status: String       // "active" | "waiting"
    /// Daemon-computed "running"/"needs_input"/"idle" classification (see
    /// SessionWorkStatus). `nil` when the running daemon predates this field
    /// (state.json entry has no "work_status" key yet) — callers must
    /// degrade to the legacy blue/orange dot in that case, not treat nil as
    /// idle.
    var workStatus: SessionWorkStatus?
    /// S7: the daemon's explicit session kind — `"cli"` or `"cowork"`. `nil`
    /// for entries written by a daemon build that predates this field, in
    /// which case `isCowork` falls back to the old projectName heuristic.
    /// Preferred over that heuristic because a CLI project directory literally
    /// named "Cowork" would otherwise misclassify as a Cowork row.
    var kind: String?

    /// Cowork-only: opt-in "arm" for OS-level UI automation of Claude
    /// Desktop's native Resume space, orchestrated by the daemon's
    /// cowork_resume module. Deliberately separate from `enabled` (which
    /// drives the CLI resume path and doesn't apply to Cowork rows at all)
    /// — nothing here ever arms itself; default is always off, and as of
    /// this build the daemon-side automation is hardcoded to dry-run, so
    /// arming only produces log lines, not live clicks.
    var resumeArmed: Bool
    /// Daemon-set: the automation orchestrator hit an ambiguous match or
    /// couldn't complete a resume attempt and needs a human to look. Purely
    /// informational here — the widget doesn't clear it, only the daemon
    /// (on a subsequent successful resume) does.
    var needsAttention: Bool

    var isActive: Bool { status == "active" }

    /// Cowork sessions have no rate-limit/resume cycle — Cowork manages its
    /// own lifecycle — so the "auto-resume" toggle and Resume button don't
    /// apply to them; the widget just shows they're running.
    ///
    /// S7: prefer the daemon's explicit `kind` field; only fall back to the
    /// projectName heuristic when the daemon predates `kind` (old builds), so
    /// a CLI project directory named "Cowork" no longer misclassifies.
    var isCowork: Bool {
        if let kind = kind { return kind == "cowork" }
        return projectName == "Cowork"
    }

    /// What to show as the primary line in the widget. The session title
    /// (Claude Code's own auto-generated or user-set title, e.g. "Test
    /// session do nothing") is far more useful for telling sessions in the
    /// same project apart than the project folder name alone.
    var displayTitle: String {
        if let title = sessionTitle, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return title
        }
        return projectName
    }
}

/// Reads and writes ~/.claude-autoresume/state.json — the file shared with
/// the Python daemon. Every read-modify-write takes the same advisory file
/// lock (state.json.lock) the daemon uses, so a toggle click here and a
/// daemon poll cycle can't stomp on each other.
///
/// S2: all of that locked file I/O runs off the main thread on a private
/// serial queue (`ioQueue`). The lock is a real cross-process flock now (see
/// S1 in `withLock`), and the daemon can hold it while it scans transcripts —
/// a blocking `flock` on the main thread would beachball the UI for that
/// whole window. Results are published back on main.
final class SessionsModel: ObservableObject {
    @Published var sessions: [SessionEntry] = []
    @Published var now: Date = Date()

    private static let expandedDefaultsKey = "sessionsExpanded"
    /// Persisted across launches. Starts collapsed so the widget doesn't
    /// take over the screen before you've ever looked at it.
    @Published var sessionsExpanded: Bool {
        didSet { UserDefaults.standard.set(sessionsExpanded, forKey: Self.expandedDefaultsKey) }
    }

    private let stateURL: URL
    private let lockURL: URL
    private var lastToggleAt: Date = .distantPast

    /// Flips the expanded/collapsed state. Debounced defensively — a click
    /// on a control inside a non-activating panel can occasionally be
    /// delivered twice in quick succession, which would otherwise expand
    /// and immediately re-collapse the section in one visual frame.
    func toggleSessionsExpanded() {
        let now = Date()
        guard now.timeIntervalSince(lastToggleAt) > 0.35 else { return }
        lastToggleAt = now
        sessionsExpanded.toggle()
    }

    init() {
        self.sessionsExpanded = UserDefaults.standard.object(forKey: Self.expandedDefaultsKey) as? Bool ?? false

        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude-autoresume")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.stateURL = dir.appendingPathComponent("state.json")
        self.lockURL = dir.appendingPathComponent("state.json.lock")
    }

    func tick() {
        now = Date()
    }

    /// Re-reads state.json and republishes the list of not-yet-handled
    /// (i.e. still "waiting") sessions, soonest reset first.
    func refresh() {
        withLock { [weak self] in
            guard let self = self else { return }
            guard let raw = try? Data(contentsOf: self.stateURL),
                  let json = try? JSONSerialization.jsonObject(with: raw) as? [String: [String: Any]] else {
                return
            }
            var entries: [SessionEntry] = []
            for (sessionId, dict) in json {
                let handled = dict["handled"] as? Bool ?? false
                if handled { continue } // only show live, actionable sessions in the widget
                guard let projectDir = dict["project_dir"] as? String else { continue }
                let resetsAtNum = dict["resets_at"] as? Double // nil while status == "active"
                let lastActivityNum = dict["last_activity_at"] as? Double
                entries.append(SessionEntry(
                    id: sessionId,
                    projectName: dict["project_name"] as? String ?? (projectDir as NSString).lastPathComponent,
                    sessionTitle: dict["session_title"] as? String,
                    projectDir: projectDir,
                    promptPreview: dict["prompt_preview"] as? String ?? "",
                    resetsAt: resetsAtNum.map { Date(timeIntervalSince1970: $0) },
                    lastActivityAt: lastActivityNum.map { Date(timeIntervalSince1970: $0) },
                    enabled: dict["enabled"] as? Bool ?? false,
                    forceResume: dict["force_resume"] as? Bool ?? false,
                    handled: handled,
                    status: dict["status"] as? String ?? "active",
                    workStatus: (dict["work_status"] as? String).flatMap(SessionWorkStatus.init(rawValue:)),
                    kind: dict["kind"] as? String,
                    resumeArmed: dict["resume_armed"] as? Bool ?? false,
                    needsAttention: dict["needs_attention"] as? Bool ?? false
                ))
            }
            // Crash-continuation dedupe (local-local rule): if a Claude Code
            // process crashes mid-conversation and continues, the daemon
            // writes a NEW session id while the old one is still within its
            // 30-minute window — same title, same project, both "active" —
            // so without this the widget shows both as if they were two
            // separate live sessions. Only collapse pairs that are BOTH
            // "active"; "waiting" (rate-limited) rows are distinct resumable
            // states and must never be hidden this way.
            //
            // S5(a): but two genuinely concurrent live sessions can also share
            // a (project, title) — most obviously the default/auto-generated
            // title before either has been renamed. Collapsing those hides a
            // real running session. The distinguishing evidence: a crashed
            // predecessor by definition STOPS writing, so in a real
            // crash-continuation at most ONE row of the group is recently
            // active. So only collapse when ≤1 row in the group has activity
            // within the last ~3 minutes; if two or more are recently active
            // they're concurrent live sessions and all are shown. When we do
            // collapse, keep the most-recently-active row. Self-heals once the
            // old id ages out of the daemon's window.
            let recentActivityWindow: TimeInterval = 180
            let nowRef = Date()
            func isRecentlyActive(_ e: SessionEntry) -> Bool {
                guard let last = e.lastActivityAt else { return false }
                return nowRef.timeIntervalSince(last) < recentActivityWindow
            }
            var dedupedEntries: [SessionEntry] = []
            var groupsByKey: [String: [SessionEntry]] = [:]
            var activeKeyOrder: [String] = []
            for entry in entries {
                guard entry.isActive else {
                    dedupedEntries.append(entry)
                    continue
                }
                let key = entry.projectName + "\u{0}" + (entry.sessionTitle ?? "")
                if groupsByKey[key] == nil {
                    groupsByKey[key] = []
                    activeKeyOrder.append(key)
                }
                groupsByKey[key]?.append(entry)
            }
            for key in activeKeyOrder {
                let group = groupsByKey[key] ?? []
                if group.count <= 1 {
                    dedupedEntries.append(contentsOf: group)
                    continue
                }
                // Two or more recently-active rows sharing a key => genuinely
                // concurrent live sessions; show them. R2-3: show only the
                // recently-active ones, NOT the whole group — any additional
                // quiet rows in the same group are crash-predecessors of one of
                // those live sessions and must still collapse away (otherwise a
                // group of {active A, active B, stale C} would render C too).
                // Otherwise (≤1 recently active) treat it as a
                // crash-continuation and collapse to the most-recent row.
                let recentlyActive = group.filter(isRecentlyActive)
                if recentlyActive.count >= 2 {
                    dedupedEntries.append(contentsOf: recentlyActive)
                } else if let best = group.max(by: {
                    ($0.lastActivityAt ?? .distantPast) < ($1.lastActivityAt ?? .distantPast)
                }) {
                    dedupedEntries.append(best)
                }
            }
            entries = dedupedEntries

            // Rate-limited (waiting) sessions first, soonest reset first; active ones after.
            entries.sort { a, b in
                switch (a.resetsAt, b.resetsAt) {
                case let (ra?, rb?): return ra < rb
                case (nil, nil): return a.projectName < b.projectName
                case (nil, _): return false
                case (_, nil): return true
                }
            }
            DispatchQueue.main.async {
                // Only reassign (and thus only trigger a SwiftUI/hosting-view
                // invalidation) if something actually changed. The 5s poll
                // was previously replacing this array unconditionally, which
                // churned the whole view tree every cycle for no reason.
                if self.sessions != entries {
                    self.sessions = entries
                }
            }
        }
    }

    func setEnabled(_ sessionId: String, _ enabled: Bool) {
        mutate(sessionId: sessionId) { entry in
            entry["enabled"] = enabled
        }
        refresh()
    }

    func resumeNow(_ sessionId: String) {
        mutate(sessionId: sessionId) { entry in
            entry["force_resume"] = true
        }
        refresh()
    }

    /// Cowork-only "arm" toggle for the (currently dry-run-only) UI
    /// automation resume path. Same locked read-modify-write pattern as
    /// `setEnabled`/`resumeNow` — this is a pure state-file write, it does
    /// not itself trigger any automation. The daemon's cowork_resume
    /// module is what reads this flag on its next poll cycle.
    func setResumeArmed(_ sessionId: String, _ armed: Bool) {
        mutate(sessionId: sessionId) { entry in
            entry["resume_armed"] = armed
        }
        refresh()
    }

    // MARK: - Locked file I/O

    /// S2: every locked read-modify-write runs here, off the main thread.
    /// Serial, so a `mutate()` enqueued immediately before a `refresh()` (see
    /// setEnabled/resumeNow/setResumeArmed) is guaranteed to run first —
    /// preserving read-your-writes ordering for the fire-and-forget public API.
    private let ioQueue = DispatchQueue(label: "com.claude-widget.sessions-io")

    /// Takes the same advisory flock the Python daemon holds around every
    /// state.json read-modify-write, so a widget toggle and a daemon poll
    /// cycle can't interleave and clobber each other.
    ///
    /// S1 — DO NOT reintroduce `FileManager.default.createFile(atPath:...)`
    /// here. createFile replaces the lock file's inode on every call (verified
    /// empirically: the inode number changes each time), and flock is
    /// per-inode. With createFile in place the widget would take flock on a
    /// brand-new inode while the daemon still held flock on the OLD inode —
    /// the two locks referencing different inodes exclude nothing, so a toggle
    /// racing a daemon poll silently lost. The `open(O_RDWR | O_CREAT)` below
    /// already creates the file when it's absent WITHOUT replacing an existing
    /// inode, which is exactly what a shared cross-process flock requires.
    private func withLock(_ body: @escaping () -> Void) {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            let fd = open(self.lockURL.path, O_RDWR | O_CREAT, 0o644)
            guard fd >= 0 else { body(); return }
            flock(fd, LOCK_EX)
            body()
            flock(fd, LOCK_UN)
            close(fd)
        }
    }

    /// S8: keeps the non-throwing, fire-and-forget signature but NSLogs each
    /// distinct failure path (read / parse / entry-missing / serialize /
    /// write) so a toggle that silently reverts — because the write never
    /// landed — is at least diagnosable from Console.app.
    private func mutate(sessionId: String, _ change: @escaping (inout [String: Any]) -> Void) {
        withLock { [weak self] in
            guard let self = self else { return }
            guard let raw = try? Data(contentsOf: self.stateURL) else {
                NSLog("[SessionsModel] mutate(%@): read failed", sessionId)
                return
            }
            guard var json = try? JSONSerialization.jsonObject(with: raw) as? [String: [String: Any]] else {
                NSLog("[SessionsModel] mutate(%@): parse failed", sessionId)
                return
            }
            guard var entry = json[sessionId] else {
                NSLog("[SessionsModel] mutate(%@): entry missing", sessionId)
                return
            }
            change(&entry)
            json[sessionId] = entry
            guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) else {
                NSLog("[SessionsModel] mutate(%@): serialize failed", sessionId)
                return
            }
            let tmpURL = self.stateURL.appendingPathExtension("tmp")
            do {
                try out.write(to: tmpURL)
                _ = try FileManager.default.replaceItemAt(self.stateURL, withItemAt: tmpURL)
            } catch {
                NSLog("[SessionsModel] mutate(%@): write failed: %@", sessionId, error.localizedDescription)
            }
        }
    }

    /// Countdown text for "waiting" (rate-limited) sessions only — callers
    /// with an active session (resetsAt == nil) use activityAgeText below
    /// instead. Kept as a `Date?`-taking function (rather than requiring a
    /// non-optional Date) so call sites can pass `entry.resetsAt` directly.
    func resetText(for date: Date?) -> String {
        guard let date = date else { return "active now" }
        let interval = date.timeIntervalSince(now)
        if interval <= 0 { return "ready to resume" }
        return "resumes in \(DurationFormat.compact(interval))"
    }

    /// Item 5: replaces the old, uninformative "active now" for sessions
    /// that haven't hit a rate limit yet — shows how long since the
    /// session's last real activity instead ("<1m", "17m", …), so rows
    /// don't all read identically. Falls back to the previous "active now"
    /// wording if lastActivityAt is missing (e.g. a state.json entry written
    /// by a daemon build that predates this field).
    func activityAgeText(_ lastActivityAt: Date?) -> String {
        guard let last = lastActivityAt else { return "active now" }
        let interval = max(0, now.timeIntervalSince(last))
        if interval < 60 { return "<1m" }
        return DurationFormat.compact(interval)
    }
}
