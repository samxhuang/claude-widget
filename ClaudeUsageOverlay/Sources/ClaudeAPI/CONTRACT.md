# ClaudeAPI module contract

This module is the only code in the repo allowed to know claude.ai
internal-API details. Everything here is empirically derived — none of it
is a public/documented Anthropic API, and it can change without notice.
When it does, fix this module only, re-verify with
`ClaudeUsageOverlay.app/Contents/MacOS/ClaudeUsageOverlay --validate-api`,
and update the observations below with the date (the way the existing
entries do). The public Swift surface (Models.swift, Client.swift,
DeepLinks.swift, Validate.swift) is the contract with the rest of the app;
its semantics must survive any API fix.

Transport: a single hidden WKWebView (WebSession.swift) whose persistent
default website data store shares the claude.ai login cookie with the
visible login window. All calls are `fetch(..., { credentials: 'include' })`
from page context. 401/403 on ANY endpoint ⇒ `.loggedOut`.

## Endpoints (observed 2026-07-18/19)

### GET https://claude.ai/api/organizations
`[{ uuid, capabilities?, ... }]`. Org selection: prefer an org whose
`capabilities` array contains one of `chat`/`claude_pro`/`raven`, else
`orgs[0]` (S9; `capabilities` may be absent entirely).

### GET https://claude.ai/api/organizations/{uuid}/usage
`{ five_hour: { utilization, resets_at }, seven_day: { ... }, limits: [...], ... }`
- `utilization`: number (percent).
- `resets_at`: ISO8601, with or without fractional seconds.
- Maps to `UsageReport` (session=five_hour, weekly=seven_day). The whole
  raw object rides along as `rawJSON` for snapshot persistence — the
  snapshots.jsonl on-disk format (which historically mirrors these field
  names) is owned by SnapshotLogger/GraphModel/usage_collector.py, NOT by
  this module; do not "fix" those names when the API renames fields.
- `limits`: array (observed 2026-07-20) of every active/known cap. Each
  entry: `{ group, kind, scope, is_active, resets_at, severity, percent }`.
  - The account-wide caps duplicate the top-level windows: `kind`
    `session` (group `session`) and `weekly_all` (group `weekly`), both
    `scope: null`.
  - **Per-model caps** carry `kind: "weekly_scoped"` and
    `scope: { model: { id, display_name }, surface }`. `scope.model.id`
    has been observed `null`, so `display_name` (e.g. `"Fable"`) is the
    join key. Example live entry: `{ kind: "weekly_scoped", scope: { model:
    { id: null, display_name: "Fable" } }, is_active: true, percent: 100,
    severity: "critical", resets_at: "…" }`.
  - `decodeScopedLimits` keeps ONLY the model-scoped entries →
    `UsageReport.scopedLimits: [ScopedLimit]`. This is the sole source of a
    per-model cap's reset time: a CLI transcript that hits one records a
    plain 429 `isApiErrorMessage` with NO reset of its own, so the widget
    relays `scopedLimits` to the daemon via
    `~/.claude-autoresume/usage/scoped_limits.json` (widget-owned on-disk
    format, same freeze rule as snapshots.jsonl) to arm auto-resume.
- **`spend` / `extra_usage`** (observed 2026-07-20, Enterprise account): the
  account's dollar Spend Limit — the authoritative figure Claude Desktop's
  usage tab shows ("$4.04 of $1,000.00 spent"). Two blocks in the same
  response carry it and agree; `decodeSpendLimit` prefers the structured
  `spend`, falls back to flat `extra_usage`:
  - `spend`: `{ used: { currency:"USD", amount_minor:404, exponent:2 },
    limit: { currency:"USD", amount_minor:100000, exponent:2 },
    cap: { money:null, credits:{ amount_minor, exponent } },
    enabled:true, severity:"normal", percent, balance, disclaimer,
    auto_reload, can_toggle, can_purchase_credits, disabled_reason }`.
    Money is MINOR units + `exponent` (amount_minor 404, exponent 2 = $4.04).
  - `extra_usage`: `{ used_credits:404, monthly_limit:100000, utilization:0.404,
    currency:"USD", decimal_places:2, is_enabled, weekly, daily,
    disabled_reason }` — same numbers, flat.
  - Maps to `UsageReport.spendLimit: SpendLimit?`. **Max/Pro** return both
    blocks but empty (`spend.limit:null`, `spend.enabled:false`,
    `extra_usage.*:null`) ⇒ `decodeSpendLimit` yields **nil** (no bar).
  - **No reset date** is present in this payload — Desktop's "resets on
    <date>" is sourced elsewhere (a billing endpoint we don't call), so
    `SpendLimit` has no `resetsAt`.
  - Sibling keys `cinder_cove`, `omelette_promotional`, `iguana_necktie`,
    `amber_ladder`, `nimbus_quill`, `tangelo`, `seven_day_*` are **volatile
    internal codenames** (promotions/experiments) — `cinder_cove` even uses a
    different shape (`used_dollars`/`limit_dollars` floats + `resets_at`). NOT
    parsed; only `spend`/`extra_usage` are treated as stable.

### GET https://claude.ai/api/organizations/{uuid}/chat_conversations?limit=30
Plain JSON array (confirmed HTTP 200 + valid JSON; wrong paths 404).
Populated-item field names only partially verified (test account had zero
web chats) — best evidence is /recents' item shape, so decoding normalizes
`uuid|id`, `name|title|summary`, `updated_at|updatedAt`. Empty array is a
real account state, not an error.

### GET https://claude.ai/api/organizations/{uuid}/recents
Aggregates the chat/code/cowork surfaces; response is a bare array or
wrapped under `data`/`items`/`recents`. Session items have
`type: "code_session" | "cowork_session"` (both kept — filtering to
code_session only hid live Cowork sessions, root-caused 2026-07-18).
Observed item keys (live dump 2026-07-19): bound_device_uuid,
chat_project_id, created_at, id, is_agent_owned, model, pending_action,
permission_mode, preview, project_uuid, scheduled_task_id, status, title,
type, unread, updated_at, worker_status.
- `id`: opaque `cse_…` token; every linking field null on echoes of local
  sessions; per-session detail endpoint 404s. `created_at` is the only
  joinable signal (cloud record created within ~1s of the local
  transcript).
- Returns newest-first, but that's undocumented — callers must sort.

#### status/worker_status vocabulary (drives CloudWorkState)
Observed live (2026-07-19, 13 items × 2 refresh cycles):
  status=active   worker_status=idle          → .idle
  status=archived worker_status=idle          → .idle
  status=archived worker_status=running       → .running  (archived ≠ dead!)
  worker_status=requires_action               → .needsInput (confirmed on a
                                                pending permission prompt)
`worker_status` takes priority over `status`. The `.contains`-based
needs-input matches (wait/input/pending/blocked/paused) are unverified
conservative guesses. Fields present but unrecognized → `.unknown`
(validator failure; app displays as idle). Both fields absent/empty →
`.idle` (stale/finished item, historical behavior).

## Deep links (DeepLinks.swift)
- `https://claude.ai/chat/{uuid}` — verified for chat conversation uuids.
- Cloud session items: NO verifiable per-session URL exists. Probed
  2026-07-19: `/code/{id}` and `/session/{id}` return the generic SPA
  shell (200) for real AND bogus ids — routing is client-side, so a 200
  proves nothing. Cloud rows open `ClaudeWebURLs.home`.
- `claude://resume?session={id}` (Desktop deep link) is deliberately NOT
  used: it always creates a duplicate imported session server-side (see
  CLAUDE.md "Click-to-open duplicate tabs").

## Rate/politeness constraints (enforced by callers, documented here)
Usage + chat_conversations poll at 120s, recents at 30s (AppDelegate
timers). 30s is the agreed floor for recents — faster risks rate-limiting/
abuse flags on the user's session cookie. The validator makes ~4 requests
once per run; keep it that way.
