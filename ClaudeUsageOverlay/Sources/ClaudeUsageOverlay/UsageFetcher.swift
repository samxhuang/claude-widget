import Foundation

/// Fetches usage numbers by running fetch() calls inside the shared hidden
/// WKWebView (see ClaudeWebSession) whose persistent website data store
/// carries the same claude.ai login cookie as a real browser tab — no token
/// handling, no scraping pixels.
///
/// Endpoints used (discovered by inspecting claude.ai's own network traffic on
/// Settings -> Usage; these are NOT public/documented Anthropic APIs and could
/// change or break at any time):
///   GET https://claude.ai/api/organizations                      -> [{ uuid, ... }]
///   GET https://claude.ai/api/organizations/{uuid}/usage          -> { five_hour, seven_day, ... }
final class UsageFetcher {
    private let session: ClaudeWebSession
    private let model: UsageModel
    private let onLoginNeeded: () -> Void
    // Owned here rather than injected: logging a snapshot is a pure side
    // effect of a successful fetch, not something any other part of the app
    // needs to see or control.
    private let snapshotLogger = SnapshotLogger()

    init(session: ClaudeWebSession, model: UsageModel, onLoginNeeded: @escaping () -> Void) {
        self.session = session
        self.model = model
        self.onLoginNeeded = onLoginNeeded
    }

    /// Call periodically (e.g. every 2 minutes) from AppDelegate's timer.
    func refresh() {
        let script = """
        try {
          const orgsRes = await fetch('https://claude.ai/api/organizations', { credentials: 'include' });
          if (orgsRes.status === 401 || orgsRes.status === 403) { return { loggedOut: true }; }
          if (!orgsRes.ok) { return { error: 'orgs_http_' + orgsRes.status }; }
          const orgs = await orgsRes.json();
          if (!orgs || orgs.length === 0) { return { error: 'no_orgs' }; }
        \(ClaudeWebSession.orgSelectionJS)
          const usageRes = await fetch('https://claude.ai/api/organizations/' + orgId + '/usage', { credentials: 'include' });
          if (usageRes.status === 401 || usageRes.status === 403) { return { loggedOut: true }; }
          if (!usageRes.ok) { return { error: 'usage_http_' + usageRes.status }; }
          const usage = await usageRes.json();
          return { ok: true, usage: usage };
        } catch (e) {
          return { error: String(e) };
        }
        """

        session.run(script: script) { [weak self] result in
            self?.handle(result: result)
        }
    }

    private func handle(result: Result<Any, Error>) {
        switch result {
        case .failure(let error):
            model.lastError = error.localizedDescription

        case .success(let value):
            guard let dict = value as? [String: Any] else {
                model.lastError = "Unexpected response shape"
                return
            }
            if let loggedOut = dict["loggedOut"] as? Bool, loggedOut {
                model.isLoggedOut = true
                onLoginNeeded()
                return
            }
            if let err = dict["error"] as? String {
                model.lastError = err
                return
            }
            if let ok = dict["ok"] as? Bool, ok, let usage = dict["usage"] as? [String: Any] {
                model.isLoggedOut = false
                model.lastError = nil
                model.apply(usage: usage)
                // Feed the usage-analytics compactor. Only reached on a
                // confirmed success (not error, not loggedOut), and the
                // logger itself throttles to >=100s between writes.
                snapshotLogger.record(usage: usage)
            }
        }
    }

    /// Forces a full cookie/session reset (used by "Sign Out" in the menu).
    func signOut(completion: @escaping () -> Void) {
        session.resetSession(completion: completion)
    }
}
