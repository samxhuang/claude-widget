import Foundation
import Darwin

/// Appends one usage snapshot per successful UsageFetcher refresh to
/// ~/.claude-autoresume/usage/snapshots.jsonl. A separate Python compactor
/// owns this file's lifecycle (pruning, aggregation) — this logger's only
/// job is to append well-formed lines and never touch anything already on
/// disk, so every write goes through O_APPEND with a single write() syscall
/// of one complete line (individually atomic; safe to interleave with the
/// compactor's own reads).
final class SnapshotLogger {
    private let fileURL: URL

    /// Refresh fires roughly every 2 minutes, but nothing stops a manual
    /// "Refresh Now" from landing right after a timer tick. Throttling here
    /// (rather than relying on the caller) keeps the guarantee local to the
    /// one thing that needs it.
    private let minInterval: TimeInterval = 100
    private var lastWriteAt: Date = .distantPast

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-autoresume")
            .appendingPathComponent("usage")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("snapshots.jsonl")
    }

    /// `usage` is the raw JSON object returned by claude.ai's
    /// GET /organizations/{id}/usage endpoint (the `{ five_hour, seven_day,
    /// ... }` object) — callers are expected to only call this on a
    /// confirmed-successful, logged-in fetch; failures/loggedOut are never
    /// passed in, so there's nothing to filter here.
    func record(usage: [String: Any]) {
        let now = Date()
        guard now.timeIntervalSince(lastWriteAt) >= minInterval else { return }
        guard let line = Self.buildLine(usage: usage, timestamp: now) else { return }
        lastWriteAt = now
        append(line: line)
    }

    private static func buildLine(usage: [String: Any], timestamp: Date) -> String? {
        let tsFormatter = ISO8601DateFormatter()
        tsFormatter.formatOptions = [.withInternetDateTime]

        func window(_ dict: [String: Any]?) -> [String: Any] {
            [
                "utilization": (dict?["utilization"] as? NSNumber) ?? NSNull(),
                "resets_at": (dict?["resets_at"] as? String) ?? NSNull()
            ]
        }

        let entry: [String: Any] = [
            "ts": tsFormatter.string(from: timestamp),
            "five_hour": window(usage["five_hour"] as? [String: Any]),
            "seven_day": window(usage["seven_day"] as? [String: Any]),
            "raw": usage
        ]

        guard JSONSerialization.isValidJSONObject(entry),
              let data = try? JSONSerialization.data(withJSONObject: entry, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    /// Single open(O_APPEND) + single write() of the full line (including
    /// its trailing newline) so the write is atomic even if something else
    /// is reading the file concurrently — no seek, no truncate, no rewrite.
    private func append(line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        let fd = open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            _ = Darwin.write(fd, raw.baseAddress, raw.count)
        }
    }
}
