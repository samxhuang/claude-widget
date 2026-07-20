import Foundation
import ClaudeAPI

/// Relays the usage endpoint's active per-model caps (e.g. the weekly Fable
/// limit) to the daemon by writing ~/.claude-autoresume/usage/scoped_limits.json
/// after each successful usage fetch.
///
/// Why this exists: the daemon is pure-stdlib and can't reach claude.ai, so it
/// can't learn a per-model cap's reset time on its own. A CLI transcript that
/// hits such a cap records only a plain 429 (`isApiErrorMessage`) with NO reset
/// time — the reset lives solely on the usage page. The widget already fetches
/// usage, so it drops the active caps here for the daemon to read; the daemon
/// then arms a model-limited session for auto-resume against the relayed reset
/// (see autoresume.py's load_scoped_limits / _parse_cli_transcript model-limit
/// detection).
///
/// On-disk format note: the `model_display_name` / `resets_at` / `percent`
/// field names are the WIDGET'S OWN relay format (parsed by the Python daemon),
/// frozen here independently of whatever the API renames itself to — same rule
/// as SnapshotLogger's snapshots.jsonl. The typed `ScopedLimit` values come
/// from the ClaudeAPI module; this file never touches raw API field names.
///
/// Concurrency: single writer (this logger), single reader (the daemon).
/// `Data.write(options: .atomic)` writes to an auxiliary file and rename()s it
/// into place, so the daemon's read sees either the old inode or the new one,
/// never a half-written file. Unlike SnapshotLogger (which shares an
/// append-target with the Python compactor) no cross-process flock is needed.
final class ScopedLimitLogger {
    private let fileURL: URL
    /// Writes run off the main thread; the caller (record(), invoked on the
    /// main thread from UsageFetcher) never blocks on disk I/O.
    private let ioQueue = DispatchQueue(label: "com.claude-widget.scoped-limit-logger")

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-autoresume")
            .appendingPathComponent("usage")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("scoped_limits.json")
    }

    /// `report` is a confirmed-successful, logged-in usage decode. Writes the
    /// currently-active per-model caps every refresh (no throttle: the file is
    /// a full-state snapshot the daemon reads on its own 10s cadence, and an
    /// empty `limits` array is itself meaningful — it clears a cap that just
    /// reset). A write is skipped only if the payload can't be serialized.
    func record(report: UsageReport) {
        guard let data = Self.buildPayload(report: report) else { return }
        ioQueue.async { [weak self] in
            self?.write(data: data)
        }
    }

    private static func buildPayload(report: UsageReport) -> Data? {
        let tsFormatter = ISO8601DateFormatter()
        tsFormatter.formatOptions = [.withInternetDateTime]

        // Relay only the ACTIVE caps — an inactive one has nothing to wait on.
        let limits: [[String: Any]] = report.scopedLimits
            .filter { $0.isActive }
            .map { limit in
                [
                    "model_display_name": limit.modelDisplayName,
                    "model_id": limit.modelID ?? NSNull(),
                    "resets_at": limit.resetsAtRaw ?? NSNull(),
                    "percent": limit.percent.map { NSNumber(value: $0) } ?? NSNull(),
                    "severity": limit.severity ?? NSNull(),
                ]
            }

        let payload: [String: Any] = [
            "updated_at": tsFormatter.string(from: Date()),
            "limits": limits,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return nil
        }
        return data
    }

    private func write(data: Data) {
        do {
            // .atomic ⇒ Foundation writes an auxiliary file and rename()s it
            // over the target; the daemon never observes a partial file, and
            // this creates the file cleanly on first run.
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort: on failure leave any previous scoped_limits.json in
            // place (a stale-but-valid reset is better than none).
            NSLog("ScopedLimitLogger write failed: \(error.localizedDescription)")
        }
    }
}
