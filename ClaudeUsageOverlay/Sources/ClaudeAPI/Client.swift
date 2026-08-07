import Foundation

/// The app's single entry point to claude.ai's internal HTTP API. Owns the
/// shared hidden authenticated WKWebView (WebSession) and every endpoint
/// path, fetch script, and response-shape assumption. See CONTRACT.md for
/// what each endpoint is known to return (all empirically derived — none of
/// this is a public/documented Anthropic API, and it can change without
/// notice; when it does, this module is the only thing that gets fixed).
///
/// Threading: all completions fire on the main queue (WebSession already
/// guarantees this for the JS bridge; the mapping here stays on that hop).
public final class ClaudeAPIClient {
    /// The script transport (§1.10). Held as the protocol, not the concrete
    /// WKWebView session, so this client can be exercised without a live
    /// webview — see `ClaudeScriptRunner` in Transport.swift.
    private let session: ClaudeScriptRunner

    /// Validator/debug hook: when set, each successful call also hands over
    /// the raw decoded response (label, JSON object) BEFORE normalization.
    /// Raw payloads are the user's account data — the only sanctioned
    /// consumer is the validator's --dump-raw mode writing to a scratch
    /// dir. Never wire this up in the normal app path.
    public var debugRawHandler: ((String, Any) -> Void)?

    /// The normal app path: the shared hidden authenticated WKWebView.
    /// (Kept as a distinct initializer rather than a defaulted argument so
    /// the WebKit-backed transport stays internal to this module.)
    public convenience init() {
        self.init(session: ClaudeWebSession())
    }

    /// Injects a transport — tests (a fake runner returning canned JSON) and
    /// any future non-WebKit host. No existing call site needs to change.
    public init(session: ClaudeScriptRunner) {
        self.session = session
    }

    // MARK: - Public calls

    /// GET usage for the selected org. Success ⇒ both windows decoded (the
    /// raw response also rides along for snapshot persistence — see
    /// UsageReport.rawJSON).
    public func fetchUsage(completion: @escaping (Result<UsageReport, ClaudeAPIError>) -> Void) {
        let script = """
        try {
        \(Self.orgPreambleJS)
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
            switch Self.envelope(result: result, endpoint: "usage") {
            case .failure(let err):
                completion(.failure(err))
            case .success(let dict):
                guard let usage = jsonObject(dict["usage"]) else {
                    completion(.failure(.unexpectedShape(endpoint: "usage", detail: "usage_missing_payload")))
                    return
                }
                self?.debugRawHandler?("usage", usage)
                completion(.success(Self.decodeUsage(usage)))
            }
        }
    }

    /// GET the recent web-chat conversation list. An empty list is success
    /// (a real account state — verified against a live account with zero
    /// web chats), not an error.
    public func fetchChatConversations(completion: @escaping (Result<[ChatConversation], ClaudeAPIError>) -> Void) {
        let script = """
        try {
        \(Self.orgPreambleJS)
          const url = 'https://claude.ai/api/organizations/' + orgId + '/chat_conversations?limit=30';
          const res = await fetch(url, { credentials: 'include' });
          if (res.status === 401 || res.status === 403) { return { loggedOut: true }; }
          if (!res.ok) { return { error: 'chats_http_' + res.status }; }
          const bodyText = await res.text();
          let parsed;
          try {
            parsed = JSON.parse(bodyText);
          } catch (e) {
            return { error: 'chats_parse_error' };
          }
          const list = Array.isArray(parsed)
            ? parsed
            : (parsed && Array.isArray(parsed.conversations) ? parsed.conversations : null);
          if (!list) { return { error: 'chats_unexpected_shape' }; }
          // Field names for a populated item are only partially verified
          // (see CONTRACT.md) — normalize the plausible variants
          // (uuid/id, name/title/summary) rather than assume one.
          const chats = list.map(item => ({
            uuid: item.uuid || item.id || '',
            name: item.name || item.title || item.summary || '',
            updated_at: item.updated_at || item.updatedAt || null
          })).filter(c => c.uuid);
          return { ok: true, chats: chats, raw: list };
        } catch (e) {
          return { error: String(e) };
        }
        """
        session.run(script: script) { [weak self] result in
            switch Self.envelope(result: result, endpoint: "chats") {
            case .failure(let err):
                completion(.failure(err))
            case .success(let dict):
                guard let chats = jsonObjectArray(dict["chats"]) else {
                    completion(.failure(.unexpectedShape(endpoint: "chats", detail: "chats_missing_payload")))
                    return
                }
                if let raw = dict["raw"] { self?.debugRawHandler?("chat_conversations", raw) }
                let parsed = chats.compactMap { item -> ChatConversation? in
                    guard let id = jsonString(item["uuid"]), !id.isEmpty else { return nil }
                    return ChatConversation(
                        id: id,
                        title: jsonString(item["name"]) ?? "",
                        updatedAt: Self.parseISODate(jsonString(item["updated_at"]))
                    )
                }
                completion(.success(parsed))
            }
        }
    }

    /// GET the recents feed, filtered to cloud Code/Cowork sessions (the
    /// two session-typed item types — plain chat items are dropped here).
    /// Newest-first is NOT guaranteed by this module (the endpoint happens
    /// to return it, but callers sort for themselves).
    public func fetchCloudSessions(completion: @escaping (Result<[CloudSessionRecord], ClaudeAPIError>) -> Void) {
        let script = """
        try {
        \(Self.orgPreambleJS)
          const recentsRes = await fetch('https://claude.ai/api/organizations/' + orgId + '/recents', { credentials: 'include' });
          if (recentsRes.status === 401 || recentsRes.status === 403) { return { loggedOut: true }; }
          if (!recentsRes.ok) { return { error: 'recents_http_' + recentsRes.status }; }
          const recentsBody = await recentsRes.text();
          let recentsParsed;
          try { recentsParsed = JSON.parse(recentsBody); } catch (e) { return { error: 'recents_parse_error' }; }
          const recentsList = Array.isArray(recentsParsed)
            ? recentsParsed
            : (recentsParsed && Array.isArray(recentsParsed.data) ? recentsParsed.data
               : (recentsParsed && Array.isArray(recentsParsed.items) ? recentsParsed.items
                  : (recentsParsed && Array.isArray(recentsParsed.recents) ? recentsParsed.recents : null)));
          if (!recentsList) { return { error: 'recents_unexpected_shape' }; }
          // Both session types are Cowork/Code sessions running server-side
          // with no local file (root-caused 2026-07-18: the original
          // code_session-only filter hid live Cowork sessions).
          const cloudSessions = recentsList
            .filter(item => item && (item.type === 'code_session' || item.type === 'cowork_session'))
            .map(item => ({
              id: item.id || item.uuid || '',
              title: item.title || item.name || item.summary || '',
              updated_at: item.updated_at || item.updatedAt || null,
              status: item.status || null,
              worker_status: item.worker_status || item.workerStatus || null,
              // created_at is the ONLY joinable signal for deduping cloud
              // echoes of local sessions (ids are opaque cse_* tokens with
              // every linking field null) — keep it populated.
              created_at: item.created_at || item.createdAt || null
            }))
            .filter(c => c.id);
          return { ok: true, cloudSessions: cloudSessions, raw: recentsList };
        } catch (e) {
          return { error: String(e) };
        }
        """
        session.run(script: script) { [weak self] result in
            switch Self.envelope(result: result, endpoint: "recents") {
            case .failure(let err):
                completion(.failure(err))
            case .success(let dict):
                guard let raw = jsonObjectArray(dict["cloudSessions"]) else {
                    completion(.failure(.unexpectedShape(endpoint: "recents", detail: "recents_missing_payload")))
                    return
                }
                if let rawList = dict["raw"] { self?.debugRawHandler?("recents", rawList) }
                let records = raw.compactMap { item -> CloudSessionRecord? in
                    guard let id = jsonString(item["id"]), !id.isEmpty else { return nil }
                    let statusRaw = jsonString(item["status"])
                    let workerStatusRaw = jsonString(item["worker_status"])
                    return CloudSessionRecord(
                        id: id,
                        title: jsonString(item["title"]) ?? "",
                        updatedAt: Self.parseISODate(jsonString(item["updated_at"])),
                        createdAt: Self.parseISODate(jsonString(item["created_at"])),
                        isArchived: statusRaw?.trimmingCharacters(in: .whitespaces).lowercased() == "archived",
                        workState: Self.mapWorkState(status: statusRaw, workerStatus: workerStatusRaw),
                        statusRaw: statusRaw,
                        workerStatusRaw: workerStatusRaw
                    )
                }
                completion(.success(records))
            }
        }
    }

    /// Forces a full cookie/session reset ("Sign Out"). Affects every call
    /// on this client — there's one claude.ai login, not one per feature.
    public func signOut(completion: @escaping () -> Void) {
        session.resetSession(completion: completion)
    }

    /// Manual sign-in: install a claude.ai session cookie captured from the
    /// user's real browser. The escape hatch for SSO setups the embedded login
    /// window can't complete (passkey/YubiKey, managed-browser device trust) —
    /// see ClaudeWebSession.installSessionKey. `installed == false` means the
    /// pasted text yielded no usable cookie value; a `true` here only means the
    /// cookie was set, so callers should follow with a real fetch to confirm it
    /// actually authenticates.
    public func signIn(sessionKey pasted: String, completion: @escaping (_ installed: Bool) -> Void) {
        session.installSessionKey(pasted, completion: completion)
    }

    // MARK: - Shared script fragments

    /// Fetches /organizations and defines `orgId`, preferring an org whose
    /// `capabilities` array (when present) advertises a chat-capable
    /// surface over a blind `orgs[0]` (S9 — multi-org accounts). Every
    /// endpoint script starts with this.
    private static let orgPreambleJS = """
      const orgsRes = await fetch('https://claude.ai/api/organizations', { credentials: 'include' });
      if (orgsRes.status === 401 || orgsRes.status === 403) { return { loggedOut: true }; }
      if (!orgsRes.ok) { return { error: 'orgs_http_' + orgsRes.status }; }
      const orgs = await orgsRes.json();
      if (!orgs || orgs.length === 0) { return { error: 'no_orgs' }; }
      const pickOrg = (list) => {
        const wanted = ['chat', 'claude_pro', 'raven'];
        const preferred = list.find(o => Array.isArray(o.capabilities) && o.capabilities.some(c => wanted.includes(c)));
        return preferred || list[0];
      };
      const orgId = pickOrg(orgs).uuid;
    """

    // MARK: - Response envelope + decoding

    /// Unwraps the common `{loggedOut}` / `{error}` / `{ok: true, …}`
    /// envelope every script returns. `error` strings of the form
    /// `<name>_http_<status>` become `.http`; everything else becomes
    /// `.unexpectedShape` with the terse code as detail.
    private static func envelope(result: Result<Any, Error>, endpoint: String) -> Result<[String: Any], ClaudeAPIError> {
        switch result {
        case .failure(let error):
            // Transport-neutral (§1.10): any runner can signal a full
            // backlog, not just the WKWebView one.
            if case ClaudeTransportError.backlogFull = error {
                return .failure(.backlogFull)
            }
            return .failure(.transport(error.localizedDescription))
        case .success(let value):
            guard let dict = jsonObject(value) else {
                return .failure(.unexpectedShape(endpoint: endpoint, detail: "\(endpoint)_not_a_dict"))
            }
            // jsonBool, not `as? Bool`: this gates EVERY response, and the
            // cast only works on Darwin (audit §1.3). Semantics unchanged —
            // a missing key or a non-boolean still yields nil.
            if let loggedOut = jsonBool(dict["loggedOut"]), loggedOut {
                return .failure(.loggedOut)
            }
            if let err = jsonString(dict["error"]) {
                if let (name, status) = parseHTTPErrorCode(err) {
                    return .failure(.http(endpoint: name, status: status))
                }
                return .failure(.unexpectedShape(endpoint: endpoint, detail: err))
            }
            guard let ok = jsonBool(dict["ok"]), ok else {
                return .failure(.unexpectedShape(endpoint: endpoint, detail: "\(endpoint)_bad_envelope"))
            }
            return .success(dict)
        }
    }

    /// "usage_http_500" -> ("usage", 500); nil for anything else.
    private static func parseHTTPErrorCode(_ code: String) -> (String, Int)? {
        guard let range = code.range(of: "_http_") else { return nil }
        guard let status = Int(code[range.upperBound...]) else { return nil }
        return (String(code[..<range.lowerBound]), status)
    }

    private static func decodeUsage(_ usage: [String: Any]) -> UsageReport {
        func window(_ dict: [String: Any]?) -> UsageWindow {
            let utilizationRaw = dict?["utilization"]
            let resetsRaw = jsonString(dict?["resets_at"])
            return UsageWindow(
                percent: jsonInt(utilizationRaw),
                resetsAt: parseISODate(resetsRaw),
                // Stays an NSNumber: SnapshotLogger writes it verbatim into
                // the widget's frozen snapshots.jsonl format.
                utilizationRaw: jsonNumber(utilizationRaw),
                resetsAtRaw: resetsRaw
            )
        }
        return UsageReport(
            session: window(jsonObject(usage["five_hour"])),
            weekly: window(jsonObject(usage["seven_day"])),
            scopedLimits: decodeScopedLimits(usage["limits"]),
            spendLimit: decodeSpendLimit(usage["spend"], usage["extra_usage"]),
            rawJSON: usage
        )
    }

    /// The Enterprise / spend-capped account's dollar Spend Limit — the number
    /// Desktop's usage tab shows. Two shapes carry it in the same response and
    /// agree; we prefer the structured `spend` object and fall back to the flat
    /// `extra_usage` block:
    ///   spend:       { used:{amount_minor,exponent,currency},
    ///                  limit:{amount_minor,exponent,currency}, enabled, severity }
    ///   extra_usage: { used_credits, monthly_limit, utilization, currency,
    ///                  decimal_places, is_enabled }
    /// Both absent (Max/Pro) ⇒ nil. The sibling promo keys (cinder_cove,
    /// omelette_promotional, …) are volatile internal codenames and ignored.
    /// See CONTRACT.md and Models.SpendLimit.
    private static func decodeSpendLimit(_ spendRaw: Any?, _ extraRaw: Any?) -> SpendLimit? {
        let spend = jsonObject(spendRaw)
        let extra = jsonObject(extraRaw)

        func money(_ dict: [String: Any]?, _ key: String) -> (minor: Int, exp: Int, cur: String)? {
            guard let m = jsonObject(dict?[key]),
                  let minor = jsonInt(m["amount_minor"]) else { return nil }
            return (minor,
                    jsonInt(m["exponent"]) ?? 2,
                    jsonString(m["currency"]) ?? "USD")
        }

        if let used = money(spend, "used"), let limit = money(spend, "limit") {
            return SpendLimit(
                spentMinor: used.minor,
                limitMinor: limit.minor,
                exponent: limit.exp,
                currency: limit.cur,
                utilizationPercent: jsonDouble(extra?["utilization"]),
                enabled: jsonBool(spend?["enabled"]) ?? true,
                severity: jsonString(spend?["severity"])
            )
        }

        // Fallback: the flat extra_usage shape (same numbers).
        if let extra,
           let usedC = jsonInt(extra["used_credits"]),
           let monthly = jsonInt(extra["monthly_limit"]) {
            return SpendLimit(
                spentMinor: usedC,
                limitMinor: monthly,
                exponent: jsonInt(extra["decimal_places"]) ?? 2,
                currency: jsonString(extra["currency"]) ?? "USD",
                utilizationPercent: jsonDouble(extra["utilization"]),
                enabled: jsonBool(extra["is_enabled"]) ?? true,
                severity: nil
            )
        }

        return nil
    }

    /// The usage `limits[]` array carries a mix of entries: the account-wide
    /// session/weekly caps (already decoded as UsageWindows above) AND
    /// per-model caps, distinguished by a `scope.model` object. We keep only
    /// the model-scoped ones — e.g.
    /// `{kind: "weekly_scoped", scope: {model: {display_name: "Fable"}},
    ///   resets_at, percent, severity, is_active}`. Entries without a model
    /// scope are dropped (not our concern here); a completely absent/oddly
    /// shaped array yields an empty list, never a crash.
    private static func decodeScopedLimits(_ raw: Any?) -> [ScopedLimit] {
        guard let items = jsonObjectArray(raw) else { return [] }
        return items.compactMap { item -> ScopedLimit? in
            guard let scope = jsonObject(item["scope"]),
                  let model = jsonObject(scope["model"]) else { return nil }
            let display = jsonString(model["display_name"])?.trimmingCharacters(in: .whitespaces)
            guard let display, !display.isEmpty else { return nil }
            let resetsRaw = jsonString(item["resets_at"])
            return ScopedLimit(
                modelDisplayName: display,
                modelID: jsonString(model["id"]),
                resetsAt: parseISODate(resetsRaw),
                percent: jsonInt(item["percent"]),
                severity: jsonString(item["severity"]),
                isActive: jsonBool(item["is_active"]) ?? false,
                resetsAtRaw: resetsRaw
            )
        }
    }

    /// Maps the recents feed's raw `status`/`worker_status` vocabulary to
    /// CloudWorkState. Every rule here is empirically grounded — see
    /// CONTRACT.md for the observed value log. `worker_status` (the more
    /// specific field, describing the worker process directly) takes
    /// priority over the coarser `status`. Anything unrecognized maps to
    /// `.unknown` — never a guess — so an API vocabulary change degrades to
    /// "no attention demanded" and gets flagged by the validator instead of
    /// wrongly alerting (or crashing) the widget.
    static func mapWorkState(status: String?, workerStatus: String?) -> CloudWorkState {
        let w = workerStatus?.trimmingCharacters(in: .whitespaces).lowercased()
        let s = status?.trimmingCharacters(in: .whitespaces).lowercased()

        if let w {
            if w == "running" || w == "active" || w == "executing" || w == "working" {
                return .running
            }
            // "requires_action" confirmed live 2026-07-19 (pending
            // permission-prompt Bash action). The .contains checks are
            // still-unverified conservative guesses for adjacent vocab.
            if w == "requires_action" || w.contains("wait") || w.contains("input") || w.contains("pending") || w.contains("blocked") || w == "paused" {
                return .needsInput
            }
            if w == "idle" {
                return .idle
            }
        }
        if let s {
            if s.contains("wait") || s.contains("input") || s.contains("blocked") || s == "needs_attention" {
                return .needsInput
            }
            if s == "active" && w == nil {
                // No worker_status to disambiguate; a bare "active" status
                // is the best available signal something is happening.
                return .running
            }
            if s == "archived" && w == nil {
                return .idle
            }
        }
        // Neither field carried a recognized value. Distinguish "fields
        // absent/empty" (historically .idle — stale or finished sessions)
        // from "fields present but unrecognized" (an API vocabulary change
        // → .unknown, surfaced by the validator).
        if (w == nil || w!.isEmpty) && (s == nil || s!.isEmpty) {
            return .idle
        }
        return .unknown
    }

    /// ISO8601 with and without fractional seconds — the two variants the
    /// API has been observed to emit.
    static func parseISODate(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }
}
