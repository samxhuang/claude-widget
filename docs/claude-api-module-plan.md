# Plan: isolate the claude.ai internal-API surface into one module

Goal: everything that knows about claude.ai's **internal, undocumented HTTP
API** (endpoint paths, JSON field names, status vocabularies, deep-link URL
shapes) lives in one small SwiftPM target, `ClaudeAPI`. When Anthropic
changes the internal API, that target — and nothing else — is what gets
updated. The boundary is compiler-enforced (separate target) and
grep-enforced (see "Boundary check" below).

Scope note: this covers the **HTTP API** only. The other Claude-internal
contracts this repo depends on (the `~/.claude/projects/**/*.jsonl`
transcript format, `~/.claude/sessions/<pid>.json`, Cowork's
`local-agent-mode-sessions` metadata — all parsed by the Python daemon) are
a separate, later phase if wanted; they change on a different cadence and
have a different owner (the daemon).

## 1. Current touchpoints (inventory, verified 2026-07-19)

| File | What it knows about the internal API |
|---|---|
| `ClaudeWebSession.swift` | transport (hidden authed WKWebView), `https://claude.ai/new` base URL, `orgSelectionJS` (org `capabilities` vocabulary) |
| `UsageFetcher.swift` | `GET /api/organizations`, `GET .../usage`; JS fetch script; 401/403→loggedOut convention |
| `ChatsFetcher.swift` | `GET .../chat_conversations?limit=30`, `GET .../recents`; response-shape variants; `code_session`/`cowork_session` type filter; raw item field names |
| `UsageModel.swift` | parses `five_hour`/`seven_day` → `utilization`/`resets_at` |
| `ChatsModel.swift` | parses `uuid`/`name`/`updated_at` dicts |
| `CloudSessionsModel.swift` | parses `id`/`title`/`status`/`worker_status`/`created_at`; `mapWorkStatus` (interprets the `worker_status` vocabulary, e.g. `requires_action`) |
| `SnapshotLogger.swift` | projects the raw usage dict into `snapshots.jsonl` |
| `LoginWindowController.swift` | `https://claude.ai/login` |
| `OverlayView.swift` | deep links `https://claude.ai/chat/{uuid}`, `https://claude.ai` |

Not API-coupled (stays put): polling cadences and in-flight guards
(AppDelegate/ChatsFetcher policy), dedupe/merge rules (CloudSessionsModel,
SessionsModel), all persistence, all UI, the entire Python daemon.

**Trap to respect:** `snapshots.jsonl`'s on-disk field names (`five_hour`,
`seven_day`, `utilization`, `resets_at`) *coincidentally mirror* the API
names because SnapshotLogger historically wrote a projection of the raw
response. That on-disk format is consumed by `GraphModel.swift` and the
Python compactor (`usage_collector.py`) and **must not change** when the
API does. After this refactor those names are formally the *widget's own
format*; SnapshotLogger maps DTO → those names explicitly.

## 2. Target structure

```
ClaudeUsageOverlay/
  Package.swift              # + .target(name: "ClaudeAPI"); app target depends on it
  Sources/
    ClaudeAPI/               # ← the ONLY code allowed to know internal-API details
      WebSession.swift       # moved ClaudeWebSession, now internal to the module
      Client.swift           # ClaudeAPIClient — public entry point
      Models.swift           # public DTOs (the contract, below)
      DeepLinks.swift        # ClaudeWebURLs.login / .home / .chat(id:)
      Validate.swift         # runValidation() used by --validate-api (phase 2)
      CONTRACT.md            # endpoint → fields-we-depend-on table, kept current
    ClaudeUsageOverlay/      # everything else, imports ClaudeAPI
```

`UsageFetcher`/`ChatsFetcher` shrink to thin app-side coordinators (timers
stay in AppDelegate): call the client, hand typed DTOs to models, keep the
in-flight guard and the login-needed callback. All JS, URLs, and raw field
names move into `ClaudeAPI`.

## 3. The public interface (the contract with the rest of the app)

Everything below is `public`; nothing else in the module is. If the
internal API changes, these types' *semantics* must be preserved by the fix
— that's what makes the rest of the app insulated.

```swift
public enum ClaudeAPIError: Error {
    case loggedOut                       // 401/403 anywhere → caller shows login
    case backlogFull                     // transport not ready, queue full
    case transport(String)               // webview/JS-bridge failure
    case http(endpoint: String, status: Int)
    case unexpectedShape(endpoint: String, detail: String)  // detail NEVER contains account data
}

public struct UsageWindow {
    public let percent: Int?             // normalized utilization 0–100+
    public let resetsAt: Date?
    // Raw values, exposed ONLY so SnapshotLogger can keep snapshots.jsonl
    // byte-compatible. No other consumer may use them.
    public let utilizationRaw: Double?
    public let resetsAtRaw: String?
}
public struct UsageReport {
    public let session: UsageWindow      // API "five_hour"
    public let weekly: UsageWindow       // API "seven_day"
}

public struct ChatConversation {
    public let id: String                // API uuid/id, normalized
    public let title: String             // API name/title/summary, normalized
    public let updatedAt: Date?
}

public enum CloudWorkState { case running, needsInput, idle, unknown }
public struct CloudSessionRecord {
    public let id: String                // opaque (cse_… today)
    public let title: String
    public let updatedAt: Date?
    public let createdAt: Date?          // dedupe join key — keep populated
    public let isArchived: Bool          // API status == "archived"
    public let workState: CloudWorkState // module-owned mapping of worker_status
    public let statusRaw: String?        // for diagnostics logging only
    public let workerStatusRaw: String?  // for diagnostics logging only
}

public final class ClaudeAPIClient {
    public init()
    public func fetchUsage(completion: @escaping (Result<UsageReport, ClaudeAPIError>) -> Void)
    public func fetchChatConversations(completion: @escaping (Result<[ChatConversation], ClaudeAPIError>) -> Void)
    public func fetchCloudSessions(completion: @escaping (Result<[CloudSessionRecord], ClaudeAPIError>) -> Void)
    public func signOut(completion: @escaping () -> Void)   // cookie/session reset
}

public enum ClaudeWebURLs {
    public static let home: URL          // claude.ai
    public static let login: URL         // claude.ai/login
    public static func chat(id: String) -> URL   // claude.ai/chat/{id}
}
```

Semantics the module guarantees (and a future API-fix must re-establish):

- Completions fire on the main queue (today's behavior).
- `.loggedOut` is the single "re-auth needed" signal for every call.
- Org selection (multi-org accounts) happens inside the module.
- `CloudSessionRecord.workState` interprets whatever vocabulary the API
  uses *at that time*; `requires_action`-style values map to `.needsInput`,
  unknown values to `.unknown` (never crash, never guess `running`).
- Empty lists are success, not errors (a real account state).
- Error payloads/log lines never include response bodies or account data
  (existing release-hygiene rule).

What the rest of the app explicitly does NOT get: endpoint URLs, raw JSON,
the JS scripts, the WKWebView (LoginWindowController keeps its own webview
— shared cookies come from `WKWebsiteDataStore.default()`, not from this
module — and takes its URL from `ClaudeWebURLs.login`).

## 4. Boundary check (grep-enforced)

Add `scripts/check_api_boundary.sh`: fails if `claude.ai`, `/api/`,
`chat_conversations`, `/recents`, `worker_status`, `five_hour`, or
`seven_day` appear in Swift source outside `Sources/ClaudeAPI/` —
**except** `SnapshotLogger.swift` and `GraphModel.swift`, which may use
`five_hour`/`seven_day`/`utilization`/`resets_at` as the widget's own
on-disk snapshot field names (documented there). The validation prompt runs
this check.

## 5. Validation mode (`--validate-api`)

`main.swift` branches before constructing AppDelegate:

- `--validate-api [--dump-raw <dir>] [--json]` runs a UI-less NSApplication
  pass that exercises each public client call once against the live API and
  asserts the contract: orgs reachable and one selectable; usage has both
  windows with parseable utilization + resets_at; chat_conversations
  returns a list (possibly empty) whose items normalize to id+title;
  /recents returns a list, session-typed items normalize with id, parseable
  created_at, and a recognized (or explicitly `.unknown`) workState.
- Output: one JSON report on stdout —
  `{"checks": [{"name": …, "pass": …, "detail": …}], "loggedOut": bool}`.
  Exit 0 = all pass, 2 = logged out (not fixable from code), 1 = contract
  failure. 60s overall timeout → exit 1.
- `--dump-raw <dir>` additionally writes raw response bodies to `<dir>`
  for shape re-derivation. Dumps contain account data: scratch dirs only,
  never committed, deleted after use.
- Must run from the **packaged app binary**
  (`ClaudeUsageOverlay.app/Contents/MacOS/ClaudeUsageOverlay`) so
  `WKWebsiteDataStore.default()` resolves to the same cookie store as the
  widget's login. Concurrent run alongside the live widget is fine
  (read-only GETs, ~4 requests once — no cadence concerns).

## 6. Migration steps (behavior-preserving; one PR or two)

1. Add `ClaudeAPI` target; move `ClaudeWebSession` in (internal), add
   DTOs/errors/URL builders, port the three fetch scripts into
   `Client.swift` with normalization moved from the models' `apply()` into
   DTO decoding. Move `mapWorkStatus` from CloudSessionsModel into the
   module (keep its verified `requires_action` handling).
2. Convert consumers: `UsageModel.apply(_: UsageReport)`,
   `ChatsModel.apply(_: [ChatConversation])`,
   `CloudSessionsModel.apply(_: [CloudSessionRecord], …)` (dedupe logic
   unchanged, now reading typed fields), `SnapshotLogger.record(_:
   UsageReport)` writing the identical on-disk shape from the `*Raw`
   fields. Swap OverlayView/LoginWindowController URL literals for
   `ClaudeWebURLs`.
3. Add `--validate-api` (+ `Validate.swift`), `check_api_boundary.sh`, and
   `CONTRACT.md`.
4. Add the runnable prompt (`.claude/commands/validate-claude-api.md`,
   already in this repo — see it for the operational loop).
5. Verify: `swift build -c release` clean; run boundary check; run
   validator against the live API; `python3 claude-autoresume/
   test_usage_collector.py` (guards the snapshot format);
   `./build_and_run.command` and eyeball usage bars + Sessions list.

Risk notes: keep `run(script:)` queue/backlog semantics exactly (R2-1
lessons in ClaudeWebSession comments); keep completions on the main queue;
don't touch polling cadences; snapshots.jsonl append still goes through
`usage/snapshots.lock`.
