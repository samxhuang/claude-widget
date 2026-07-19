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
/// Item 4 ("cloud sessions are invisible"): the JS below now also fetches
/// `GET .../recents` in the same round-trip (same org/credentials, no extra
/// navigation) and keeps only its `code_session`-typed items — these are
/// Cowork/Code sessions running entirely server-side, which write no local
/// file and so never appear in SessionsModel/state.json. Results are handed
/// to CloudSessionsModel, which filters out anything whose id is already
/// tracked locally (see `localSessionIds`) before OverlayView shows them.
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

    /// Call periodically (shares AppDelegate's usage refresh cadence).
    func refresh() {
        let script = """
        try {
          const orgsRes = await fetch('https://claude.ai/api/organizations', { credentials: 'include' });
          if (orgsRes.status === 401 || orgsRes.status === 403) { return { loggedOut: true }; }
          if (!orgsRes.ok) { return { error: 'orgs_http_' + orgsRes.status }; }
          const orgs = await orgsRes.json();
          if (!orgs || orgs.length === 0) { return { error: 'no_orgs' }; }
          const orgId = orgs[0].uuid;
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
          // belong in the cloud-sessions list. Fetched in this same
          // round-trip since it's the same org/credentials call as
          // chat_conversations above. Defensive: this is a second,
          // less-verified endpoint — a failure or shape change here must
          // never fail the whole refresh, since chats are the primary
          // payload.
          let cloudSessions = [];
          let cloudSessionsRawShape = null;
          try {
            const recentsRes = await fetch('https://claude.ai/api/organizations/' + orgId + '/recents', { credentials: 'include' });
            if (recentsRes.ok) {
              const recentsBody = await recentsRes.text();
              let recentsParsed;
              try { recentsParsed = JSON.parse(recentsBody); } catch (e) { recentsParsed = null; }
              const recentsList = Array.isArray(recentsParsed)
                ? recentsParsed
                : (recentsParsed && Array.isArray(recentsParsed.data) ? recentsParsed.data
                   : (recentsParsed && Array.isArray(recentsParsed.items) ? recentsParsed.items
                      : (recentsParsed && Array.isArray(recentsParsed.recents) ? recentsParsed.recents : null)));
              if (recentsList) {
                cloudSessions = recentsList
                  .filter(item => item && (item.type === 'code_session' || item.type === 'cowork_session'))
                  .map(item => ({
                    id: item.id || item.uuid || '',
                    title: item.title || item.name || item.summary || '',
                    updated_at: item.updated_at || item.updatedAt || null
                  }))
                  .filter(c => c.id);
                if (cloudSessions.length === 0 && recentsList.length > 0) {
                  cloudSessionsRawShape = 'recents_no_session_items:' + JSON.stringify(recentsList[0]).slice(0, 300);
                }
              } else {
                cloudSessionsRawShape = 'recents_unexpected_shape:' + JSON.stringify(recentsParsed).slice(0, 300);
              }
            } else {
              cloudSessionsRawShape = 'recents_http_' + recentsRes.status;
            }
          } catch (e) {
            cloudSessionsRawShape = 'recents_exception:' + String(e);
          }

          return { ok: true, chats: chats, cloudSessions: cloudSessions, cloudSessionsRawShape: cloudSessionsRawShape };
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

                // Item 4: apply cloud sessions regardless of shape success —
                // apply(raw:localIds:localTitles:) degrades to an empty list
                // on its own if `raw` is empty, and a shape mismatch here
                // (logged below) must never affect the chats path above.
                let cloudRaw = dict["cloudSessions"] as? [[String: Any]] ?? []
                if let rawShape = dict["cloudSessionsRawShape"] as? String {
                    NSLog("[ChatsFetcher] cloud sessions unexpected shape: %@", rawShape)
                }
                let localIds = localSessionIds()
                let localTitles = localSessionTitles()
                cloudSessions.apply(raw: cloudRaw, localIds: localIds, localTitles: localTitles)
                NSLog("[ChatsFetcher] cloud sessions: %d raw, %d after local-id/title filter+cap (%d local ids, %d local titles known)", cloudRaw.count, cloudSessions.sessions.count, localIds.count, localTitles.count)
                return
            }
            model.lastError = "Unexpected response shape"
            NSLog("[ChatsFetcher] unexpected dict shape, keys=%@", Array(dict.keys).description)
        }
    }
}
