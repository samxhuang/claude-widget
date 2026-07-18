import Foundation
import Combine
import Darwin

/// One Claude Code session that got cut off by a rate limit, as detected by
/// the claude-autoresume daemon. Mirrors an entry in ~/.claude-autoresume/state.json.
struct SessionEntry: Identifiable, Equatable, Hashable {
    let id: String // session_id
    var projectName: String
    var sessionTitle: String?
    var projectDir: String
    var promptPreview: String
    var resetsAt: Date?      // nil while status == "active" (not rate-limited yet)
    var enabled: Bool
    var forceResume: Bool
    var handled: Bool
    var status: String       // "active" | "waiting"

    var isActive: Bool { status == "active" }

    /// Cowork sessions have no rate-limit/resume cycle — Cowork manages its
    /// own lifecycle — so the "auto-resume" toggle and Resume button don't
    /// apply to them; the widget just shows they're running.
    var isCowork: Bool { projectName == "Cowork" }

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
        withLock {
            guard let raw = try? Data(contentsOf: stateURL),
                  let json = try? JSONSerialization.jsonObject(with: raw) as? [String: [String: Any]] else {
                return
            }
            var entries: [SessionEntry] = []
            for (sessionId, dict) in json {
                let handled = dict["handled"] as? Bool ?? false
                if handled { continue } // only show live, actionable sessions in the widget
                guard let projectDir = dict["project_dir"] as? String else { continue }
                let resetsAtNum = dict["resets_at"] as? Double // nil while status == "active"
                entries.append(SessionEntry(
                    id: sessionId,
                    projectName: dict["project_name"] as? String ?? (projectDir as NSString).lastPathComponent,
                    sessionTitle: dict["session_title"] as? String,
                    projectDir: projectDir,
                    promptPreview: dict["prompt_preview"] as? String ?? "",
                    resetsAt: resetsAtNum.map { Date(timeIntervalSince1970: $0) },
                    enabled: dict["enabled"] as? Bool ?? false,
                    forceResume: dict["force_resume"] as? Bool ?? false,
                    handled: handled,
                    status: dict["status"] as? String ?? "active"
                ))
            }
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

    // MARK: - Locked file I/O

    private func withLock(_ body: () -> Void) {
        FileManager.default.createFile(atPath: lockURL.path, contents: nil)
        let fd = open(lockURL.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { body(); return }
        flock(fd, LOCK_EX)
        body()
        flock(fd, LOCK_UN)
        close(fd)
    }

    private func mutate(sessionId: String, _ change: (inout [String: Any]) -> Void) {
        withLock {
            guard let raw = try? Data(contentsOf: stateURL),
                  var json = try? JSONSerialization.jsonObject(with: raw) as? [String: [String: Any]] else {
                return
            }
            guard var entry = json[sessionId] else { return }
            change(&entry)
            json[sessionId] = entry
            guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) else { return }
            let tmpURL = stateURL.appendingPathExtension("tmp")
            try? out.write(to: tmpURL)
            _ = try? FileManager.default.replaceItemAt(stateURL, withItemAt: tmpURL)
        }
    }

    func resetText(for date: Date?) -> String {
        guard let date = date else { return "active now" }
        let interval = date.timeIntervalSince(now)
        if interval <= 0 { return "ready to resume" }
        let totalMinutes = Int(interval) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return "resumes in \(hours)h \(minutes)m" }
        return "resumes in \(minutes)m"
    }
}
