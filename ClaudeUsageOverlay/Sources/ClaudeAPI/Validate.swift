import Foundation

/// One contract assertion's outcome.
public struct ValidationCheck {
    public let name: String
    public let pass: Bool
    /// Terse, account-data-free summary (counts, which field failed —
    /// never titles/bodies).
    public let detail: String
}

public struct ValidationReport {
    public let checks: [ValidationCheck]
    public let loggedOut: Bool

    /// 0 = all pass, 2 = logged out (not fixable from code), 1 = contract
    /// failure. Matches .claude/commands/validate-claude-api.md.
    public var exitCode: Int32 {
        if loggedOut { return 2 }
        return checks.allSatisfy { $0.pass } ? 0 : 1
    }

    public var jsonString: String {
        let obj: [String: Any] = [
            "loggedOut": loggedOut,
            "pass": exitCode == 0,
            "checks": checks.map { ["name": $0.name, "pass": $0.pass, "detail": $0.detail] }
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else {
            return "{\"loggedOut\": false, \"pass\": false, \"checks\": []}"
        }
        return s
    }
}

/// Exercises each public ClaudeAPIClient call once against the live API and
/// asserts the contract the rest of the app depends on (see CONTRACT.md).
/// Run via the packaged app binary's `--validate-api` flag — it needs the
/// widget's cookie store (WKWebsiteDataStore bundle-id keying), so it can't
/// be a standalone CLI.
public final class ClaudeAPIValidator {
    private let client: ClaudeAPIClient
    private let dumpDirectory: URL?
    private var checks: [ValidationCheck] = []
    private var sawLoggedOut = false

    /// `dumpDirectory`: when set, raw response bodies are written there as
    /// JSON files for shape re-derivation. Raw dumps are the user's account
    /// data — scratch dirs only, never committed, deleted after use.
    public init(dumpDirectory: URL? = nil) {
        self.client = ClaudeAPIClient()
        self.dumpDirectory = dumpDirectory
        if let dir = dumpDirectory {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            client.debugRawHandler = { label, json in
                guard JSONSerialization.isValidJSONObject(json) || json is [Any],
                      let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) else { return }
                try? data.write(to: dir.appendingPathComponent("\(label).json"))
            }
        }
    }

    /// Runs the three calls sequentially (polite to the shared webview; the
    /// org round-trip inside each call doubles as an /organizations check)
    /// and completes on the main queue with the aggregated report.
    public func run(completion: @escaping (ValidationReport) -> Void) {
        checkUsage { [weak self] in
            self?.checkChats { [weak self] in
                self?.checkRecents { [weak self] in
                    guard let self = self else { return }
                    completion(ValidationReport(checks: self.checks, loggedOut: self.sawLoggedOut))
                }
            }
        }
    }

    private func record(_ name: String, _ pass: Bool, _ detail: String) {
        checks.append(ValidationCheck(name: name, pass: pass, detail: detail))
    }

    private func noteError(_ name: String, _ error: ClaudeAPIError) {
        if case .loggedOut = error { sawLoggedOut = true }
        record(name, false, error.errorDescription ?? "unknown error")
    }

    private func checkUsage(next: @escaping () -> Void) {
        client.fetchUsage { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                self.noteError("usage", error)
            case .success(let report):
                var problems: [String] = []
                if report.session.percent == nil { problems.append("session.percent missing") }
                if report.session.resetsAt == nil { problems.append("session.resetsAt missing/unparseable") }
                if report.weekly.percent == nil { problems.append("weekly.percent missing") }
                if report.weekly.resetsAt == nil { problems.append("weekly.resetsAt missing/unparseable") }
                if problems.isEmpty {
                    self.record("usage", true, "session \(report.session.percent!)%, weekly \(report.weekly.percent!)%, both windows parseable")
                } else {
                    self.record("usage", false, problems.joined(separator: "; "))
                }
            }
            next()
        }
    }

    private func checkChats(next: @escaping () -> Void) {
        client.fetchChatConversations { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                self.noteError("chat_conversations", error)
            case .success(let chats):
                // Empty is a pass (real account state). Items missing an id
                // were already dropped by the client filter, so a shape
                // regression shows up as list-vs-decoded count drift only
                // when the endpoint is populated — report both counts.
                let dateless = chats.filter { $0.updatedAt == nil }.count
                let detail = "\(chats.count) conversations decoded" + (dateless > 0 ? ", \(dateless) with unparseable updated_at" : "")
                self.record("chat_conversations", dateless == 0, detail)
            }
            next()
        }
    }

    private func checkRecents(next: @escaping () -> Void) {
        client.fetchCloudSessions { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                self.noteError("recents", error)
            case .success(let records):
                var problems: [String] = []
                let dateless = records.filter { $0.updatedAt == nil }.count
                if dateless > 0 { problems.append("\(dateless) items with unparseable updated_at") }
                let birthless = records.filter { $0.createdAt == nil }.count
                if birthless > 0 { problems.append("\(birthless) items with unparseable created_at (breaks echo dedupe)") }
                // .unknown means the status vocabulary changed — the app
                // degrades safely, but it's exactly what this validator
                // exists to catch, so it's a failure with the raw values
                // named (status codes only, no account content).
                let unknowns = records.filter { $0.workState == .unknown }
                if !unknowns.isEmpty {
                    let combos = Set(unknowns.map { "status=\($0.statusRaw ?? "nil") worker_status=\($0.workerStatusRaw ?? "nil")" })
                    problems.append("unrecognized status vocabulary: \(combos.sorted().joined(separator: " | "))")
                }
                if problems.isEmpty {
                    let states = ["running": records.filter { $0.workState == .running }.count,
                                  "needsInput": records.filter { $0.workState == .needsInput }.count,
                                  "idle": records.filter { $0.workState == .idle }.count]
                    self.record("recents", true, "\(records.count) session items decoded (\(states["running"]!) running, \(states["needsInput"]!) needs-input, \(states["idle"]!) idle)")
                } else {
                    self.record("recents", false, problems.joined(separator: "; "))
                }
            }
            next()
        }
    }
}
