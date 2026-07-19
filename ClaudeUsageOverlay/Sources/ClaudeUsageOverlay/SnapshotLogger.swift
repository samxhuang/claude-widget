import Foundation
import Darwin
import ClaudeAPI

/// Appends one usage snapshot per successful UsageFetcher refresh to
/// ~/.claude-autoresume/usage/snapshots.jsonl. A separate Python compactor
/// owns this file's lifecycle (pruning, aggregation) — this logger's only
/// job is to append well-formed lines and never touch anything already on
/// disk, so every write goes through O_APPEND with a single write() syscall
/// of one complete line (individually atomic).
///
/// S6: O_APPEND alone is NOT enough. The compactor rewrites this file
/// read→rewrite→rename; an append that lands after the compactor read but
/// before its rename is on the old inode and gets silently dropped by the
/// rename (violating CLAUDE.md's no-data-loss guarantee for this file).
/// Agreed cross-language protocol (the Python compactor is changed in
/// parallel to match): both sides take an fcntl `flock(LOCK_EX)` on
/// ~/.claude-autoresume/usage/snapshots.lock — the compactor holds it across
/// its whole rewrite, this logger holds it around each append. The append
/// itself is unchanged: still O_APPEND, single write, never truncate. The
/// compactor holds the lock only briefly (file is <1MB), but since we're
/// touching this anyway the append is hopped onto a background queue so even
/// a blocking flock never stalls the (main-thread) caller.
final class SnapshotLogger {
    private let fileURL: URL
    private let lockURL: URL
    /// S6: appends run here, off the main thread — the caller (record(),
    /// invoked on the main thread from UsageFetcher) never blocks on flock.
    private let ioQueue = DispatchQueue(label: "com.claude-widget.snapshot-logger")

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
        self.lockURL = dir.appendingPathComponent("snapshots.lock")
    }

    /// `report` is ClaudeAPI's typed decode of a confirmed-successful,
    /// logged-in usage fetch — failures/loggedOut are never passed in, so
    /// there's nothing to filter here.
    ///
    /// On-disk format note: the `five_hour`/`seven_day`/`utilization`/
    /// `resets_at` names below are the WIDGET'S OWN snapshot format (parsed
    /// by GraphModel and the Python compactor) — they historically mirror
    /// the API's names, but they are frozen here regardless of what the API
    /// renames itself to. The window values come from the report's `*Raw`
    /// fields (exposed for exactly this purpose) and the `raw` payload is
    /// the opaque `rawJSON` blob, kept whole for future analytics.
    func record(report: UsageReport) {
        let now = Date()
        guard now.timeIntervalSince(lastWriteAt) >= minInterval else { return }
        guard let line = Self.buildLine(report: report, timestamp: now) else { return }
        lastWriteAt = now
        ioQueue.async { [weak self] in
            self?.append(line: line)
        }
    }

    private static func buildLine(report: UsageReport, timestamp: Date) -> String? {
        let tsFormatter = ISO8601DateFormatter()
        tsFormatter.formatOptions = [.withInternetDateTime]

        func window(_ w: UsageWindow) -> [String: Any] {
            [
                "utilization": w.utilizationRaw ?? NSNull(),
                "resets_at": w.resetsAtRaw ?? NSNull()
            ]
        }

        let entry: [String: Any] = [
            "ts": tsFormatter.string(from: timestamp),
            "five_hour": window(report.session),
            "seven_day": window(report.weekly),
            "raw": report.rawJSON
        ]

        guard JSONSerialization.isValidJSONObject(entry),
              let data = try? JSONSerialization.data(withJSONObject: entry, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    /// Single open(O_APPEND) + single write() of the full line (including
    /// its trailing newline), no seek/truncate/rewrite — held under the shared
    /// snapshots.lock flock (S6) so the append can't land inside the Python
    /// compactor's read→rewrite→rename window and be silently dropped.
    ///
    /// S6: do NOT use `FileManager.createFile` for the lock file — see
    /// SessionsModel's `withLock` (S1): createFile replaces the inode on every
    /// call, and flock is per-inode, so it would break mutual exclusion
    /// against the compactor's flock. `open(O_RDWR | O_CREAT)` creates the
    /// lock file without disturbing an existing inode.
    private func append(line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }

        // Acquire the shared cross-process lock first. If the lock file can't
        // be opened for some reason, fall through and append anyway rather
        // than dropping the snapshot entirely — an unlocked append is the old,
        // still-mostly-safe behavior, strictly better than losing the line.
        let lockFd = open(lockURL.path, O_RDWR | O_CREAT, 0o644)
        if lockFd >= 0 {
            flock(lockFd, LOCK_EX)
        }
        defer {
            if lockFd >= 0 {
                flock(lockFd, LOCK_UN)
                close(lockFd)
            }
        }

        let fd = open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            _ = Darwin.write(fd, raw.baseAddress, raw.count)
        }
    }
}
