import Foundation
import ClaudeAPI

/// Thin coordinator between AppDelegate's refresh timer and the ClaudeAPI
/// module: asks the client for a typed UsageReport and distributes it to
/// UsageModel (display) and SnapshotLogger (persistence). Everything about
/// HOW usage is fetched — endpoints, auth, response shapes — lives in
/// ClaudeAPI; this file must never learn any of it.
final class UsageFetcher {
    private let client: ClaudeAPIClient
    private let model: UsageModel
    private let onLoginNeeded: () -> Void
    // Owned here rather than injected: logging a snapshot is a pure side
    // effect of a successful fetch, not something any other part of the app
    // needs to see or control.
    private let snapshotLogger = SnapshotLogger()
    // Relays active per-model caps (e.g. the Fable limit) to the daemon so it
    // can arm auto-resume for model-limited sessions — the daemon can't reach
    // claude.ai to learn their reset times itself. Same side-effect-only
    // ownership as snapshotLogger.
    private let scopedLimitLogger = ScopedLimitLogger()

    init(client: ClaudeAPIClient, model: UsageModel, onLoginNeeded: @escaping () -> Void) {
        self.client = client
        self.model = model
        self.onLoginNeeded = onLoginNeeded
    }

    /// Call periodically (e.g. every 2 minutes) from AppDelegate's timer.
    func refresh() {
        client.fetchUsage { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(.loggedOut):
                self.model.isLoggedOut = true
                self.onLoginNeeded()
            case .failure(let error):
                self.model.lastError = error.errorDescription
            case .success(let report):
                self.model.isLoggedOut = false
                self.model.lastError = nil
                self.model.apply(report: report)
                // Feed the usage-analytics compactor. Only reached on a
                // confirmed success (not error, not loggedOut), and the
                // logger itself throttles to >=100s between writes.
                self.snapshotLogger.record(report: report)
                // Relay active per-model caps for the daemon (unthrottled —
                // the file is a full-state snapshot, and clearing a just-reset
                // cap needs to propagate promptly).
                self.scopedLimitLogger.record(report: report)
            }
        }
    }

    /// Forces a full cookie/session reset (used by "Sign Out" in the menu).
    func signOut(completion: @escaping () -> Void) {
        client.signOut(completion: completion)
    }
}
