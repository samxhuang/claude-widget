import Foundation

/// Fetches the user's recent claude.ai conversations by running fetch()
/// calls inside the same shared hidden WKWebView UsageFetcher uses (see
/// ClaudeWebSession) — same persistent, authenticated data store, same
/// credentials:'include' pattern, no separate login or token handling.
///
/// --- Endpoint contract (checked empirically 2026-07-18) ---
/// This is NOT a public/documented Anthropic API and could change or break
/// at any time without notice.
///
///   GET https://claude.ai/api/organizations
///     -> [{ uuid, ... }]                             (same call UsageFetcher makes)
///
///   GET https://claude.ai/api/organizations/{org_uuid}/chat_conversations?limit=30
///     -> a plain JSON array (confirmed: HTTP 200, valid JSON, not the 404
///        you get for a wrong path like `/conversations`). Query params
///        (`limit`, `offset`, `sort_by`) are accepted without error.
///
/// What's still unverified: the exact field names inside a *populated*
/// item. The account this was tested against returned `[]` here — real
/// auth, real 200, genuinely zero rows, not a wrong-endpoint symptom
/// (confirmed independently: the sibling `GET .../recents` endpoint, which
/// aggregates the "chat"/"code"/"cowork" surfaces and *did* return 11 real
/// items, reports `enabled_surfaces: ["chat","code","cowork"]` with nothing
/// degraded — the "chat" surface is live for this account, it's just that
/// all 11 of its actual recent items happen to be `type: "code_session"`,
/// i.e. Claude Code/Cowork sessions, because this particular account is a
/// heavy Claude Code user with no recent plain claude.ai web chats).
/// `/recents`'s code_session items use `id`/`title`/`updated_at`/
/// `created_at` (not `uuid`/`name`), which is the best available evidence
/// for what `chat_conversations` items likely look like too, so the JS
/// below normalizes both `uuid`/`id` and `name`/`title`/`summary`
/// defensively rather than assuming one naming convention.
///
/// If a future pass wants conversation data from an account that actually
/// has chat history, re-verify against `/recents` filtered to
/// `type !== "code_session"` as a fallback — it's confirmed live and
/// working, just not chat-specific (mixes in Cowork), and its item `id`
/// format for non-code-session entries (bare uuid vs. some other prefix
/// like code_session's `cse_...`) was never observed, so it's NOT safe to
/// assume `https://claude.ai/chat/{id}` deep-links correctly for those.
///
/// Item 4 ("cloud sessions are invisible"): fetches `GET .../recents` and
/// keeps only its `code_session`/`cowork_session`-typed items — these are
/// Cowork/Code sessions running entirely server-side, which write no local
/// file and so never appear in SessionsModel/state.json. Results are handed
/// to CloudSessionsModel, which filters out anything whose id is already
/// tracked locally (see `localSessionIds`) before OverlayView shows them.
///
/// Item 3 amendment: this used to ride along with chat_conversations in
/// `refresh()`'s single round-trip, both on the same 120s timer. Cloud
/// sessions needed a much faster cadence to feel "live" (they're the only
/// signal a Cowork/Code session running purely server-side is even
/// working), but chat_conversations/usage don't — so `refreshRecentsOnly()`
/// below is now a separate, dedicated `/recents`-only JS round-trip driven
/// by its own 30s timer in AppDelegate, while `refresh()` sticks to
/// chat_conversations on the original 120s cadence. 30s (not the local
/// sessions' 10s) is the ceiling here: this is an authenticated claude.ai
/// internal endpoint, and polling it faster risks rate-limiting/abuse flags
/// on the user's session cookie.
final class ChatsFetcher {
    private let session: ClaudeWebSession
    private let model: ChatsModel
    /// Item 4: cloud-only Cowork/Code sessions ("cloud sessions are
    /// invisible" — a session running entirely on claude.ai's servers writes
    /// no local file, so SessionsModel/the daemon never see it). Fetched via
    /// the same JS round-trip as chat_conversations below, then filtered
    /// against `localSessionIds()` so a session already shown by
    /// SessionsModel isn't duplicated here.
    private let cloudSessions: CloudSessionsModel
    private let localSessionIds: () -> Set<String>
    /// Crash-continuation dedupe (cloud-local rule): a Claude Code process
    /// that crashes mid-conversation gets a new local session id when it
    /// continues, but the SAME conversation still shows up as a cloud
    /// /recents item under yet another id (neither matches the other) —
    /// title-based, since id-based filtering alone can't catch this case.
    /// Titles are of the currently-DISPLAYED local sessions (i.e. after
    /// SessionsModel's own local-local dedupe), not the raw state.json set.
    private let localSessionTitles: () -> Set<String>
    private let onLoginNeeded: () -> Void

    init(session: ClaudeWebSession, model: ChatsModel, cloudSessions: CloudSessionsModel, localSessionIds: @escaping () -> Set<String>, localSessionTitles: @escaping () -> Set<String>, onLoginNeeded: @escaping () -> Void) {
        self.session = session
        self.model = model
        self.cloudSessions = cloudSessions
        self.localSessionIds = localSessionIds
        self.localSessionTitles = localSessionTitles
        self.onLoginNeeded = onLoginNeeded
    }

    /// Call periodically (shares AppDelegate's usage refresh cadence, 120s).
    /// Item 3 amendment: no longer also fetches /recents — that moved to
    /// `refreshRecentsOnly()` below on its own, faster 30s cadence.
    func refresh() {
        let script = """
        try {
          const orgsRes = await fetch('https://claude.ai/api/organizations', { credentials: 'include' });
          if (orgsRes.status === 401 || orgsRes.status === 403) { return { loggedOut: true }; }
          if (!orgsRes.ok) { return { error: 'orgs_http_' + orgsRes.status }; }
          const orgs = await orgsRes.json();
          if (!orgs || orgs.length === 0) { return { error: 'no_orgs' }; }
        \(ClaudeWebSession.orgSelectionJS)
          const url = 'https://claude.ai/api/organizations/' + orgId + '/chat_conversations?limit=30';
          const res = await fetch(url, { credentials: 'include' });
          if (res.status === 401 || res.status === 403) { return { loggedOut: true }; }
          const bodyText = await res.text();
          if (!res.ok) {
            return { error: 'chats_http_' + res.status, bodySample: bodyText.slice(0, 400) };
          }
          let parsed;
          try {
            parsed = JSON.parse(bodyText);
          } catch (e) {
            return { error: 'parse_error_' + String(e), bodySample: bodyText.slice(0, 400) };
          }
          const list = Array.isArray(parsed)
            ? parsed
            : (parsed && Array.isArray(parsed.conversations) ? parsed.conversations : null);
          if (!list) {
            return { error: 'unexpected_shape', bodySample: bodyText.slice(0, 400) };
          }
          // Field names for a populated item are unverified (see this
          // file's header comment) — normalize the plausible variants
          // (uuid/id, name/title/summary) rather than assume one.
          const chats = list.map(item => ({
            uuid: item.uuid || item.id || '',
            name: item.name || item.title || item.summary || '',
            updated_at: item.updated_at || item.updatedAt || null
          })).filter(c => c.uuid);

          return { ok: true, chats: chats };
        } catch (e) {
          return { error: String(e) };
        }
        """

        session.run(script: script) { [weak self] result in
            self?.handle(result: result)
        }
    }

    /// Item 3 amendment: guards against overlapping in-flight fetches — if
    /// the previous 30s tick's round-trip hasn't returned yet (slow
    /// network, webview hiccup), this tick is skipped rather than stacking
    /// a second concurrent JS call onto the same shared webview.
    private var recentsInFlight = false

    /// Fetches ONLY `/recents` (not chat_conversations) — see this file's
    /// header comment for why this is split out from `refresh()` and on its
    /// own 30s timer (AppDelegate's cloudSessionsTimer). Re-resolves the org
    /// id itself each call rather than caching it, since this genuinely is
    /// an independent round-trip now (not a shared context with refresh()),
    /// and `/organizations` is a cheap, small call.
    func refreshRecentsOnly() {
        guard !recentsInFlight else {
            NSLog("[ChatsFetcher] recents-only fetch skipped: previous fetch still in flight")
            return
        }
        recentsInFlight = true

        let script = """
        try {
          const orgsRes = await fetch('https://claude.ai/api/organizations', { credentials: 'include' });
          if (orgsRes.status === 401 || orgsRes.status === 403) { return { loggedOut: true }; }
          if (!orgsRes.ok) { return { error: 'orgs_http_' + orgsRes.status }; }
          const orgs = await orgsRes.json();
          if (!orgs || orgs.length === 0) { return { error: 'no_orgs' }; }
        \(ClaudeWebSession.orgSelectionJS)

          // Item 4: cloud-only sessions. /recents aggregates the
          // "chat"/"code"/"cowork" surfaces. Root-caused 2026-07-18 via a
          // temporary full-payload dump (removed after diagnosis): items
          // come back with type "code_session" (Claude Code sessions) AND
          // "cowork_session" (Cowork sessions) — the original filter only
          // kept "code_session", which is why an actively-running Cowork
          // session ("Pittsburgh medical team search", type:
          // "cowork_session", status: "active") never showed up even though
          // it was right there in the response, sorted first (this endpoint
          // returns newest-updated-first already). Both types are Cowork/
          // Code sessions running server-side with no local file, so both
          // belong in the cloud-sessions list.
          const recentsRes = await fetch('https://claude.ai/api/organizations/' + orgId + '/recents', { credentials: 'include' });
          if (recentsRes.status === 401 || recentsRes.status === 403) { return { loggedOut: true }; }
          if (!recentsRes.ok) { return { error: 'recents_http_' + recentsRes.status }; }
          const recentsBody = await recentsRes.text();
          let recentsParsed;
          try { recentsParsed = JSON.parse(recentsBody); } catch (e) { return { error: 'parse_error_' + String(e) }; }
          const recentsList = Array.isArray(recentsParsed)
            ? recentsParsed
            : (recentsParsed && Array.isArray(recentsParsed.data) ? recentsParsed.data
               : (recentsParsed && Array.isArray(recentsParsed.items) ? recentsParsed.items
                  : (recentsParsed && Array.isArray(recentsParsed.recents) ? recentsParsed.recents : null)));
          if (!recentsList) {
            return { error: 'unexpected_shape' };
          }
          const cloudSessions = recentsList
            .filter(item => item && (item.type === 'code_session' || item.type === 'cowork_session'))
            .map(item => ({
              id: item.id || item.uuid || '',
              title: item.title || item.name || item.summary || '',
              updated_at: item.updated_at || item.updatedAt || null,
              // Status classification item: /recents items carry a coarse
              // `status` field plus a `worker_status` field specifically
              // describing what the underlying Code/Cowork worker process
              // is doing right now (e.g. observed "running" on an
              // actively-executing session). Passed through raw (not
              // interpreted here) so CloudSessionsModel can map them — see
              // that model's header comment for what's verified vs. not.
              status: item.status || null,
              worker_status: item.worker_status || item.workerStatus || null
            }))
            .filter(c => c.id);

          return { ok: true, cloudSessions: cloudSessions };
        } catch (e) {
          return { error: String(e) };
        }
        """

        session.run(script: script) { [weak self] result in
            self?.recentsInFlight = false
            self?.handleRecentsOnly(result: result)
        }
    }

    private func handle(result: Result<Any, Error>) {
        switch result {
        case .failure(let error):
            model.lastError = error.localizedDescription
            NSLog("[ChatsFetcher] JS bridge error: %@", error.localizedDescription)

        case .success(let value):
            guard let dict = value as? [String: Any] else {
                model.lastError = "Unexpected response shape"
                NSLog("[ChatsFetcher] unexpected top-level response (not a dict)")
                return
            }
            if let loggedOut = dict["loggedOut"] as? Bool, loggedOut {
                model.isLoggedOut = true
                NSLog("[ChatsFetcher] loggedOut")
                onLoginNeeded()
                return
            }
            if let err = dict["error"] as? String {
                model.lastError = err
                let sample = (dict["bodySample"] as? String) ?? ""
                NSLog("[ChatsFetcher] error=%@ bodySample=%@", err, sample)
                return
            }
            if let ok = dict["ok"] as? Bool, ok, let chats = dict["chats"] as? [[String: Any]] {
                model.isLoggedOut = false
                model.lastError = nil
                model.apply(chats: chats)
                NSLog("[ChatsFetcher] fetched %d conversations", chats.count)
                return
            }
            model.lastError = "Unexpected response shape"
            NSLog("[ChatsFetcher] unexpected dict shape, keys=%@", Array(dict.keys).description)
        }
    }

    /// Item 3 amendment: handles `refreshRecentsOnly()`'s response. Deliberately
    /// does not touch `model`/`model.lastError` (that's chats' own state,
    /// unrelated to this endpoint) — a failure here is logged only, same
    /// "defensive, never affects the sibling payload" spirit as the old
    /// combined handler had for cloud sessions.
    private func handleRecentsOnly(result: Result<Any, Error>) {
        switch result {
        case .failure(let error):
            NSLog("[ChatsFetcher] recents-only JS bridge error: %@", error.localizedDescription)

        case .success(let value):
            guard let dict = value as? [String: Any] else {
                NSLog("[ChatsFetcher] recents-only unexpected top-level response (not a dict)")
                return
            }
            if let loggedOut = dict["loggedOut"] as? Bool, loggedOut {
                model.isLoggedOut = true
                NSLog("[ChatsFetcher] recents-only loggedOut")
                onLoginNeeded()
                return
            }
            if let err = dict["error"] as? String {
                NSLog("[ChatsFetcher] recents-only error=%@", err)
                return
            }
            guard let ok = dict["ok"] as? Bool, ok else {
                NSLog("[ChatsFetcher] recents-only unexpected dict shape, keys=%@", Array(dict.keys).description)
                return
            }
            let cloudRaw = dict["cloudSessions"] as? [[String: Any]] ?? []
            // Status classification item: log the raw status/worker_status
            // combos actually coming back so the mapping in
            // CloudSessionsModel can be verified/tuned against real data
            // rather than guessed — see that model's `mapWorkStatus`.
            let statusCombos = Set(cloudRaw.map { item -> String in
                let s = (item["status"] as? String) ?? "nil"
                let w = (item["worker_status"] as? String) ?? "nil"
                return "status=\(s) worker_status=\(w)"
            })
            if !statusCombos.isEmpty {
                NSLog("[ChatsFetcher] cloud session status/worker_status combos observed: %@", statusCombos.sorted().joined(separator: " | "))
            }
            let localIds = localSessionIds()
            let localTitles = localSessionTitles()
            cloudSessions.apply(raw: cloudRaw, localIds: localIds, localTitles: localTitles)
            NSLog("[ChatsFetcher] cloud sessions: %d raw, %d after local-id/title filter+cap (%d local ids, %d local titles known)", cloudRaw.count, cloudSessions.sessions.count, localIds.count, localTitles.count)
        }
    }
}

// MARK: - Item 3B click-to-open findings (cloud session rows)
//
// Investigated whether a `/recents` code/cowork-session item carries (or
// claude.ai otherwise exposes) a reliable per-session deep link, so
// OverlayView's cloudSessionRow could open the actual session instead of
// just claude.ai's home page. Findings, captured 2026-07-19 against a real,
// live `code_session` item (id `cse_01X5hALQTXdpLkt6giaVJW3Y`):
//
// 1. Raw item keys (no URL/permalink-ish field present):
//    bound_device_uuid, chat_project_id, created_at, id, is_agent_owned,
//    model, pending_action, permission_mode, preview, project_uuid,
//    scheduled_task_id, status, title, type, unread, updated_at,
//    worker_status. Nothing resembling `url`/`permalink`/`link`/`path`.
// 2. Probed candidate claude.ai paths from the shared authenticated
//    webview (GET, credentials included):
//      https://claude.ai/code/{realId}                -> 200, 13285 bytes
//      https://claude.ai/session/{realId}              -> 200, 12947 bytes
//      https://claude.ai/code/definitely-not-a-real-id -> 200, 13285 bytes
//    The bogus id returned byte-for-byte the SAME response as the real
//    id's `/code/{id}` (identical length AND leading-HTML sample) — i.e.
//    the server returns its generic SPA shell for ANY `/code/*` path
//    regardless of whether the id is real, because routing happens
//    client-side in JS, not server-side. `/session/{id}`'s slightly
//    different byte count (not compared against a bogus id) is most
//    plausibly just a different static meta-tag block for that route
//    prefix, not evidence of id validation — nothing here is a reliable
//    "this id exists" signal at the HTTP level.
//
// Conclusion: no verifiable per-session claude.ai URL was found. Per the
// task's own instructed fallback, cloudSessionRow's click handler
// (OverlayView.openCloudSession) opens https://claude.ai generically rather
// than a guessed path that may not resolve to anything useful.
//
// Bonus finding from the same probe: `worker_status: "requires_action"` was
// observed on a live session (a permission-prompt-style pending Bash
// action) — a worker_status value CloudSessionsModel.mapWorkStatus didn't
// recognize as needs-input at the time (its needs-input branch only matched
// "wait"/"input"/"pending"/"blocked"/"paused", all previously an
// "unverified forward guess" per that function's own header comment). Fixed
// there now that it's empirically confirmed.
