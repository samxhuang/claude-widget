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
final class ChatsFetcher {
    private let session: ClaudeWebSession
    private let model: ChatsModel
    private let onLoginNeeded: () -> Void

    init(session: ClaudeWebSession, model: ChatsModel, onLoginNeeded: @escaping () -> Void) {
        self.session = session
        self.model = model
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
          return { ok: true, chats: chats };
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
                return
            }
            model.lastError = "Unexpected response shape"
            NSLog("[ChatsFetcher] unexpected dict shape, keys=%@", Array(dict.keys).description)
        }
    }
}
