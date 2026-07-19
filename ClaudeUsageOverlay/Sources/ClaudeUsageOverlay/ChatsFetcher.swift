import Foundation
import ClaudeAPI

/// Thin coordinator between AppDelegate's timers and the ClaudeAPI module
/// for the two list feeds: recent web chats (ChatsModel) and cloud-only
/// Code/Cowork sessions (CloudSessionsModel). Endpoint knowledge lives
/// entirely in ClaudeAPI (see its CONTRACT.md); what stays here is app
/// policy — cadence ownership, the in-flight guard, and the local-session
/// dedupe inputs handed to CloudSessionsModel.
///
/// Cadence (item 3 amendment): chats refresh on AppDelegate's 120s timer;
/// cloud sessions get their own dedicated 30s timer because they're the
/// only liveness signal for a session running purely server-side. 30s (not
/// the local sessions' 10s) is the ceiling — this is an authenticated
/// claude.ai internal endpoint, and polling faster risks rate-limiting/
/// abuse flags on the user's session cookie (also documented in
/// ClaudeAPI/CONTRACT.md).
final class ChatsFetcher {
    private let client: ClaudeAPIClient
    private let model: ChatsModel
    /// Item 4: cloud-only Cowork/Code sessions ("cloud sessions are
    /// invisible" — a session running entirely on claude.ai's servers writes
    /// no local file, so SessionsModel/the daemon never see it). Fetched
    /// from the recents feed, then filtered against `localSessionIds()` so
    /// a session already shown by SessionsModel isn't duplicated here.
    private let cloudSessions: CloudSessionsModel
    private let localSessionIds: () -> Set<String>
    /// Crash-continuation dedupe (cloud-local rule): a Claude Code process
    /// that crashes mid-conversation gets a new local session id when it
    /// continues, but the SAME conversation still shows up as a cloud
    /// recents item under yet another id (neither matches the other) —
    /// title-based, since id-based filtering alone can't catch this case.
    /// Titles are of the currently-DISPLAYED local sessions (i.e. after
    /// SessionsModel's own local-local dedupe), not the raw state.json set.
    private let localSessionTitles: () -> Set<String>
    /// Known local CLI sessions' transcript creation dates (SessionsModel's
    /// append-only cache) — the created_at dedupe signal for cloud echoes.
    private let localStartDates: () -> [Date]
    private let onLoginNeeded: () -> Void

    init(client: ClaudeAPIClient, model: ChatsModel, cloudSessions: CloudSessionsModel, localSessionIds: @escaping () -> Set<String>, localSessionTitles: @escaping () -> Set<String>, localStartDates: @escaping () -> [Date], onLoginNeeded: @escaping () -> Void) {
        self.client = client
        self.model = model
        self.cloudSessions = cloudSessions
        self.localSessionIds = localSessionIds
        self.localSessionTitles = localSessionTitles
        self.localStartDates = localStartDates
        self.onLoginNeeded = onLoginNeeded
    }

    /// Call periodically (shares AppDelegate's usage refresh cadence, 120s).
    func refresh() {
        client.fetchChatConversations { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(.loggedOut):
                self.model.isLoggedOut = true
                NSLog("[ChatsFetcher] loggedOut")
                self.onLoginNeeded()
            case .failure(let error):
                // Release hygiene: error descriptions from ClaudeAPI are
                // terse codes, never response bodies/account data.
                self.model.lastError = error.errorDescription
                NSLog("[ChatsFetcher] error=%@", error.errorDescription ?? "unknown")
            case .success(let chats):
                self.model.isLoggedOut = false
                self.model.lastError = nil
                self.model.apply(conversations: chats)
                NSLog("[ChatsFetcher] fetched %d conversations", chats.count)
            }
        }
    }

    /// Item 3 amendment: guards against overlapping in-flight fetches — if
    /// the previous 30s tick's round-trip hasn't returned yet (slow
    /// network, webview hiccup), this tick is skipped rather than stacking
    /// a second concurrent call onto the same shared webview.
    private var recentsInFlight = false

    /// Fetches ONLY the cloud-sessions feed (not chat_conversations) — on
    /// its own 30s timer (AppDelegate's cloudSessionsTimer); see the class
    /// header comment for why the cadences are split.
    func refreshRecentsOnly() {
        guard !recentsInFlight else {
            NSLog("[ChatsFetcher] recents-only fetch skipped: previous fetch still in flight")
            return
        }
        recentsInFlight = true

        client.fetchCloudSessions { [weak self] result in
            guard let self = self else { return }
            self.recentsInFlight = false
            switch result {
            case .failure(.loggedOut):
                self.model.isLoggedOut = true
                NSLog("[ChatsFetcher] recents-only loggedOut")
                self.onLoginNeeded()
            case .failure(let error):
                // Deliberately does not touch model.lastError (that's
                // chats' own state, unrelated to this endpoint) — a failure
                // here is logged only.
                NSLog("[ChatsFetcher] recents-only error=%@", error.errorDescription ?? "unknown")
            case .success(let records):
                // Status classification item: log the raw status combos
                // actually coming back so ClaudeAPI's work-state mapping
                // can be verified/tuned against real data rather than
                // guessed (status codes only — no titles/content).
                let statusCombos = Set(records.map { rec in
                    "status=\(rec.statusRaw ?? "nil") worker=\(rec.workerStatusRaw ?? "nil")"
                })
                if !statusCombos.isEmpty {
                    NSLog("[ChatsFetcher] cloud session status combos observed: %@", statusCombos.sorted().joined(separator: " | "))
                }
                let localIds = self.localSessionIds()
                let localTitles = self.localSessionTitles()
                self.cloudSessions.apply(records: records, localIds: localIds, localTitles: localTitles,
                                         localStartDates: self.localStartDates())
                NSLog("[ChatsFetcher] cloud sessions: %d raw, %d after local-id/title filter+cap (%d local ids, %d local titles known)", records.count, self.cloudSessions.sessions.count, localIds.count, localTitles.count)
            }
        }
    }
}
